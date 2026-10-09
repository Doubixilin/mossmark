#!/bin/bash

set -u

mode="${1:-source}"
failures=0

pass() { printf '[pass] %s\n' "$1"; }
fail() { printf '[fail] %s\n' "$1" >&2; failures=$((failures + 1)); }
require_match() {
  if rg -q "$1" "$2"; then pass "$3"; else fail "$3"; fi
}

# Keep the old arguments usable for existing local workflows.
if [[ "$mode" != "source" && "$mode" != "release" && "$mode" != "--code-only" ]]; then
  printf 'Usage: %s [source|release|--code-only]\n' "$0" >&2
  exit 2
fi

require_match '^MIT License$' LICENSE "project MIT license is present"
require_match '"license": "MIT"' EditorEngine/package.json "editor package declares the project license"
license_resource_count="$(rg -c '^      - path: LICENSE$' project.yml)"
if [[ "$license_resource_count" == "2" ]]; then
  pass "both application targets bundle the project license"
else
  fail "both application targets must bundle LICENSE"
fi
require_match 'THIRD_PARTY_NOTICES\.md' project.yml "third-party notices are bundled"
require_match 'NSPrivacyAccessedAPICategoryUserDefaults' Apps/Shared/PrivacyInfo.xcprivacy "local preferences have a privacy manifest declaration"
require_match 'CA92\.1' Apps/Shared/PrivacyInfo.xcprivacy "UserDefaults reason CA92.1 is declared"
require_match 'com\.apple\.security\.app-sandbox' Apps/MossmarkMac/MossmarkMac.entitlements "macOS sandbox is configured"
require_match 'com\.apple\.security\.network\.client' Apps/MossmarkMac/MossmarkMac.entitlements "macOS WKWebView helper-process entitlement is configured"
require_match 'en\.lproj' Mossmark.xcodeproj/project.pbxproj "English localization is in the generated project"
require_match 'zh-Hans\.lproj' Mossmark.xcodeproj/project.pbxproj "Simplified Chinese localization is in the generated project"
require_match 'LICENSE' Mossmark.xcodeproj/project.pbxproj "the generated project includes the project license"

if rg -n 'import StoreKit|TipStore|EngagementTracker|requestReview|storeKitConfiguration|\.storekit' Apps Sources project.yml >/dev/null; then
  fail "active application sources or project settings still reference App Store features"
else
  pass "active application sources and settings contain no purchase or review flow"
fi
if rg -n 'setValue\([^\n]*forKey:|fatalError\(' Apps Sources >/dev/null; then
  fail "application sources contain KVC or fatalError risks"
else
  pass "application sources contain no KVC setValue(forKey:) or fatalError"
fi
if plutil -lint Apps/Shared/PrivacyInfo.xcprivacy >/dev/null; then
  pass "privacy manifest parses successfully"
else
  fail "privacy manifest is malformed"
fi
if [[ -f docs/release/runtime-sbom.json ]] && ! rg -q 'LICENSE FILE NOT FOUND' THIRD_PARTY_NOTICES.md \
  && node -e 'const fs=require("node:fs"); const bom=JSON.parse(fs.readFileSync("docs/release/runtime-sbom.json", "utf8")); if (!bom.components?.length) process.exit(1)'; then
  pass "runtime SBOM and original third-party license notices are present"
else
  fail "runtime SBOM or third-party license notices are missing or malformed"
fi
if [[ -f EditorEngine/dist/index.html ]]; then
  pass "offline editor bundle is present (rebuild after editing frontend sources)"
else
  fail "EditorEngine/dist/index.html is missing; build the editor bundle first"
fi
if (( failures > 0 )); then
  printf '%d preflight check(s) failed.\n' "$failures" >&2
  exit 1
fi
printf 'Mossmark source preflight passed; installer signing and notarization are separate checks.\n'
