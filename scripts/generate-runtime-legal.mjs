#!/usr/bin/env node

import { createRequire } from "node:module";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";

const repositoryRoot = resolve(import.meta.dirname, "..");
const editorRoot = join(repositoryRoot, "EditorEngine");
const require = createRequire(join(editorRoot, "package.json"));
const visited = new Map();
const upstreamLicenseRoot = join(repositoryRoot, "docs/licenses/upstream");
const upstreamLicenses = JSON.parse(readFileSync(join(upstreamLicenseRoot, "manifest.json"), "utf8"));

function npmPurl(name, version) {
  if (name.startsWith("@")) {
    const [scope, packageName] = name.split("/");
    return `pkg:npm/%40${scope.slice(1)}/${packageName}@${version}`;
  }
  return `pkg:npm/${name}@${version}`;
}

function packageJSONPath(name, fromDirectory) {
  const installedCandidate = join(fromDirectory, "node_modules", name, "package.json");
  if (existsSync(installedCandidate)) return installedCandidate;
  let ancestor = fromDirectory;
  while (ancestor !== dirname(ancestor)) {
    if (basename(ancestor) === "node_modules") {
      const siblingCandidate = join(ancestor, name, "package.json");
      if (existsSync(siblingCandidate)) return siblingCandidate;
    }
    ancestor = dirname(ancestor);
  }
  const rootCandidate = join(editorRoot, "node_modules", name, "package.json");
  if (existsSync(rootCandidate)) return rootCandidate;
  try {
    return require.resolve(`${name}/package.json`, { paths: [fromDirectory] });
  } catch {
    let current = dirname(require.resolve(name, { paths: [fromDirectory] }));
    while (current !== dirname(current)) {
      const candidate = join(current, "package.json");
      if (existsSync(candidate)) {
        const metadata = JSON.parse(readFileSync(candidate, "utf8"));
        if (metadata.name === name) return candidate;
      }
      current = dirname(current);
    }
    throw new Error(`Unable to locate package.json for ${name}`);
  }
}

function licenseText(packageDirectory, metadata) {
  const candidates = readdirSync(packageDirectory)
    .filter((name) => /^(licen[cs]e|copying|notice)(\.|$)/i.test(name))
    .filter((name) => statSync(join(packageDirectory, name)).isFile())
    .sort();
  if (candidates.length === 0) {
    const key = `${metadata.name}@${metadata.version}`;
    const original = upstreamLicenses[key];
    if (!original) throw new Error(`Missing original upstream license for ${key}`);
    const text = readFileSync(join(upstreamLicenseRoot, original.file), "utf8");
    const digest = createHash("sha256").update(text).digest("hex");
    if (digest !== original.sha256) throw new Error(`Upstream license checksum mismatch for ${key}`);
    return text.trim();
  }
  return candidates
    .map((name) => readFileSync(join(packageDirectory, name), "utf8").trim())
    .join("\n\n");
}

function visit(name, fromDirectory) {
  const path = packageJSONPath(name, fromDirectory);
  const metadata = JSON.parse(readFileSync(path, "utf8"));
  const key = `${metadata.name}@${metadata.version}`;
  if (visited.has(key)) return key;
  const directory = dirname(realpathSync(path));
  const text = licenseText(directory, metadata);
  const declaredLicense = typeof metadata.license === "string"
    ? metadata.license
    : /\bMIT License\b/i.test(text)
      ? "MIT"
      : "NOASSERTION";
  const item = {
    bomRef: npmPurl(name, metadata.version),
    name: metadata.name,
    version: metadata.version,
    license: declaredLicense,
    repository: typeof metadata.repository === "string"
      ? metadata.repository
      : metadata.repository?.url ?? null,
    licenseText: text,
    dependencies: [],
  };
  visited.set(key, item);
  for (const dependency of Object.keys({
    ...(metadata.dependencies ?? {}),
    ...(metadata.optionalDependencies ?? {}),
  })) {
    item.dependencies.push(visit(dependency, directory));
  }
  item.dependencies.sort();
  return key;
}

const editorPackage = JSON.parse(readFileSync(join(editorRoot, "package.json"), "utf8"));
const applicationDependencies = Object.keys(editorPackage.dependencies ?? {})
  .map((dependency) => visit(dependency, editorRoot));

const swiftResolved = JSON.parse(readFileSync(join(repositoryRoot, "Package.resolved"), "utf8"));
const zipPin = swiftResolved.pins.find((pin) => pin.identity === "zipfoundation");
if (!zipPin?.state.version || !zipPin?.state.revision) {
  throw new Error("ZIPFoundation must be pinned in Package.resolved");
}
const zipDirectory = join(repositoryRoot, ".build/checkouts/ZIPFoundation");
const zipRevision = execFileSync("git", ["-C", zipDirectory, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (zipRevision !== zipPin.state.revision) {
  throw new Error("ZIPFoundation checkout does not match Package.resolved; run swift package resolve");
}
const zipKey = `ZIPFoundation@${zipPin.state.version}`;
visited.set(zipKey, {
  bomRef: `pkg:swift/github.com/weichsel/ZIPFoundation@${zipPin.state.version}`,
  name: "ZIPFoundation",
  version: zipPin.state.version,
  license: "MIT",
  repository: zipPin.location,
  licenseText: licenseText(zipDirectory, { name: "ZIPFoundation", version: zipPin.state.version }),
  dependencies: [],
});
applicationDependencies.push(zipKey);

const packages = [...visited.values()].sort((left, right) =>
  `${left.name}@${left.version}`.localeCompare(`${right.name}@${right.version}`),
);

const sbom = {
  bomFormat: "CycloneDX",
  specVersion: "1.6",
  serialNumber: "urn:uuid:b46443c0-5f37-4dc8-b99b-2a2ed95672df",
  version: 1,
  metadata: {
    component: {
      "bom-ref": "mossmark@1.0.0",
      type: "application",
      name: "Mossmark",
      version: "1.0.0",
    },
  },
  components: packages.map((item) => ({
    "bom-ref": item.bomRef,
    type: "library",
    name: item.name,
    version: item.version,
    licenses: [item.license.includes("(")
      ? { expression: item.license }
      : { license: { id: item.license } }],
    purl: item.bomRef,
    ...(item.repository ? { externalReferences: [{ type: "vcs", url: item.repository }] } : {}),
  })),
  dependencies: [
    {
      ref: "mossmark@1.0.0",
      dependsOn: applicationDependencies.map((key) => visited.get(key).bomRef).sort(),
    },
    ...packages.map((item) => ({
      ref: item.bomRef,
      dependsOn: item.dependencies.map((key) => visited.get(key).bomRef),
    })),
  ],
};

const notices = [
  "# Third-Party Notices",
  "",
  "Mossmark includes the following runtime software. This file is generated from the locked, installed runtime dependency graph by `scripts/generate-runtime-legal.mjs`.",
  "",
  ...packages.flatMap((item) => [
    `## ${item.name} ${item.version}`,
    "",
    `Declared license: ${item.license}`,
    item.repository ? `\nSource: ${item.repository}` : "",
    "",
    "```text",
    item.licenseText,
    "```",
    "",
  ]),
  "The Mossmark project itself is not licensed by the third-party licenses above.",
  "",
].join("\n");

writeFileSync(
  join(repositoryRoot, "docs/release/runtime-sbom.json"),
  `${JSON.stringify(sbom, null, 2)}\n`,
);
writeFileSync(join(repositoryRoot, "THIRD_PARTY_NOTICES.md"), notices);
printf(`${packages.length} runtime packages written to SBOM and notices.\n`);

function printf(message) {
  process.stdout.write(message);
}
