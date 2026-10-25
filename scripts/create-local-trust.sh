#!/bin/bash
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: create-local-trust.sh BIN_STAGE APP_STAGE' >&2; exit 2; }
BIN_STAGE="$1"
APP_STAGE="$2"
# All paths and identities below are fixed installation targets. No caller can
# turn metadata into arbitrary trusted code. Only the administrator installer
# stores this output in the root-owned, non-writable local-trust.json.
entry() {
  local role="$1" source="$2" destination="$3" identifier="$4" architecture details hash separator='' count=0
  [[ -f "$source" && ! -L "$source" ]] || { echo "Missing regular executable: $source" >&2; return 1; }
  /usr/bin/codesign --verify --strict --all-architectures --test-requirement "=identifier \"$identifier\"" "$source"
  printf '{"role":"%s","path":"%s","identifier":"%s","cdhashes":[' "$role" "$destination" "$identifier"
  for architecture in arm64 x86_64; do
    if details="$(/usr/bin/codesign --display --verbose=4 --arch "$architecture" "$source" 2>&1)"; then
      hash="$(printf '%s\n' "$details" | /usr/bin/sed -n 's/^CDHash=//p')"
      [[ "$hash" =~ ^[a-f0-9]{40}$ ]] || { echo "Invalid code-directory hash for $source ($architecture)." >&2; return 1; }
      printf '%s"%s"' "$separator" "$hash"
      separator=','; count=$((count + 1))
    fi
  done
  [[ "$count" -gt 0 ]] || { echo "No supported architecture for $source." >&2; return 1; }
  printf ']}'
}
printf '{"version":1,"entries":['
for component in service agent bridge; do
  [[ "$component" == service ]] || printf ','
  entry "$component" "$BIN_STAGE/kids-quota-$component" "/Library/Application Support/KidsQuota/bin/kids-quota-$component" "com.kidsquota.$component"
done
printf ','
entry parent "$APP_STAGE/Contents/MacOS/Kids Quota" '/Applications/Kids Quota.app/Contents/MacOS/Kids Quota' com.kidsquota.app
printf ','
entry safari "$APP_STAGE/Contents/PlugIns/KidsQuotaSafari.appex/Contents/MacOS/KidsQuotaSafari" '/Applications/Kids Quota.app/Contents/PlugIns/KidsQuotaSafari.appex/Contents/MacOS/KidsQuotaSafari' com.kidsquota.app.safari
printf ']}\n'
