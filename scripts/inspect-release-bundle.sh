#!/bin/bash

set -euo pipefail

app_path="${1:-}"
if [[ -z "$app_path" || ! -d "$app_path" ]]; then
  printf 'Usage: %s /path/to/Mossmark.app\n' "$0" >&2
  exit 2
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
codesign --display --entitlements :- "$app_path"

network_client_entitlement="$({
  codesign --display --entitlements :- "$app_path" 2>/dev/null \
    | plutil -convert json -o - -- - \
    | python3 -c 'import json, sys
print("true" if json.load(sys.stdin).get("com.apple.security.network.client") is True else "")'
} || true)"
[[ "$network_client_entitlement" == "true" ]] || {
  printf 'com.apple.security.network.client is missing; WKWebView helper processes will crash in the sandbox.\n' >&2
  exit 1
}

resource_path="$app_path/Contents/Resources"
privacy_manifest="$resource_path/PrivacyInfo.xcprivacy"
notices="$resource_path/THIRD_PARTY_NOTICES.md"
project_license="$resource_path/LICENSE"
editor_index="$resource_path/dist/index.html"

[[ -f "$privacy_manifest" ]] || { printf 'PrivacyInfo.xcprivacy is missing.\n' >&2; exit 1; }
[[ -f "$notices" ]] || { printf 'THIRD_PARTY_NOTICES.md is missing.\n' >&2; exit 1; }
[[ -f "$editor_index" ]] || { printf 'EditorEngine dist/index.html is missing.\n' >&2; exit 1; }

[[ -f "$project_license" ]] || { printf 'LICENSE is missing.\n' >&2; exit 1; }

plutil -lint "$privacy_manifest"
printf 'Release bundle structure and signature checks passed.\n'
