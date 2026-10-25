#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS=''
CHECK_ONLY=0
MODE=signed
TEAM_ID=''
CHROME_ID=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --local) MODE=local; shift ;;
    --artifacts) ARTIFACTS="${2:?Missing artifacts directory}"; shift 2 ;;
    --team-id) TEAM_ID="${2:?Missing team ID}"; shift 2 ;;
    --chrome-extension-id) CHROME_ID="${2:?Missing Chrome extension ID}"; shift 2 ;;
    *) echo 'Usage: install.sh [--check] [--local] --artifacts DIR [--team-id TEAM] [--chrome-extension-id ID]' >&2; exit 2 ;;
  esac
done
ARTIFACTS="${ARTIFACTS:-$(cd "$SCRIPT_DIR/.." && pwd)/dist/$MODE}"
if [[ "$MODE" == signed ]]; then
  [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Provide the actual 10-character Apple team ID.' >&2; exit 2; }
else
  RELEASE="$ARTIFACTS/local-release.json"
  [[ -f "$RELEASE" && ! -L "$RELEASE" ]] || { echo 'Missing local release metadata.' >&2; exit 1; }
  [[ "$(/usr/bin/plutil -extract schemaVersion raw -o - "$RELEASE")" == 1 && "$(/usr/bin/plutil -extract networkFilterEnabled raw -o - "$RELEASE")" == false ]] || { echo 'Local release must have app network filtering disabled.' >&2; exit 1; }
  LOCAL_CHROME_ID="$(/usr/bin/plutil -extract chromeExtensionId raw -o - "$RELEASE")"
  [[ -z "$CHROME_ID" || "$CHROME_ID" == "$LOCAL_CHROME_ID" ]] || { echo 'Chrome ID differs from the bundled local release.' >&2; exit 1; }
  CHROME_ID="$LOCAL_CHROME_ID"
  [[ -f "$ARTIFACTS/browser/chrome/manifest.json" && -x "$SCRIPT_DIR/create-local-trust.sh" ]] || { echo 'Missing bundled browser extension or local trust helper.' >&2; exit 1; }
  # Chromium derives the extension ID from this public key, independently of
  # the unpacked folder's path. Reject mismatched native-host registration.
  DERIVED_CHROME_ID="$(/usr/bin/plutil -extract key raw -o - "$ARTIFACTS/browser/chrome/manifest.json" | /usr/bin/base64 -D | /usr/bin/openssl dgst -sha256 | /usr/bin/awk '{print $NF}' | /usr/bin/cut -c1-32 | /usr/bin/tr '0123456789abcdef' 'abcdefghijklmnop')"
  [[ "$CHROME_ID" == "$DERIVED_CHROME_ID" ]] || { echo 'The bundled Chrome key does not match the local release extension ID.' >&2; exit 1; }
fi
[[ -z "$CHROME_ID" || "$CHROME_ID" =~ ^[a-p]{32}$ ]] || { echo 'Chrome IDs must contain 32 letters a-p.' >&2; exit 2; }
verify_code() {
  local path="$1" identifier="$2" requirement details
  # Drain codesign's output before matching. With pipefail, an early grep -q
  # exit can otherwise turn a valid signature into a false SIGPIPE failure.
  details="$(/usr/bin/codesign --display --verbose=4 "$path" 2>&1)" || return 1
  if [[ "$MODE" == local ]]; then
    requirement="identifier \"$identifier\""
    /usr/bin/grep -q '^Signature=adhoc$' <<< "$details" || { echo "Expected an ad-hoc signed local component: $path" >&2; return 1; }
  else
    requirement="anchor apple generic and identifier \"$identifier\" and certificate leaf[subject.OU] = \"$TEAM_ID\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
  fi
  /usr/bin/codesign --verify --strict --all-architectures --verbose=2 --test-requirement "=$requirement" "$path"
  /usr/bin/grep -q 'flags=.*runtime' <<< "$details" || { echo "Missing hardened runtime: $path" >&2; return 1; }
}
for component in service agent bridge; do verify_code "$ARTIFACTS/bin/kids-quota-$component" "com.kidsquota.$component"; done
APP="$ARTIFACTS/Kids Quota.app"
verify_code "$APP" com.kidsquota.app
if [[ "$MODE" == signed ]]; then
  verify_code "$APP/Contents/Library/SystemExtensions/com.kidsquota.app.networkfilter.systemextension" com.kidsquota.app.networkfilter
else
  [[ ! -e "$APP/Contents/Library/SystemExtensions" ]] || { echo 'The local app must not embed an activatable system extension.' >&2; exit 1; }
  verify_code "$APP/Contents/Resources/DisabledExtensions/com.kidsquota.app.networkfilter.systemextension" com.kidsquota.app.networkfilter
fi
verify_code "$APP/Contents/PlugIns/KidsQuotaSafari.appex" com.kidsquota.app.safari
[[ -f "$ARTIFACTS/bin/kids-quota_KidsQuotaCore.bundle/Contents/Resources/public_suffix_list.dat" || -f "$ARTIFACTS/bin/kids-quota_KidsQuotaCore.bundle/public_suffix_list.dat" ]] || { echo 'Missing bundled Public Suffix List.' >&2; exit 1; }
if [[ "$CHECK_ONLY" == 1 ]]; then echo "Artifact identities, $MODE signatures, hardened runtime, and resource presence verified."; exit 0; fi
[[ $(/usr/bin/id -u) == 0 ]] || { echo 'Installation requires an administrator: run with sudo.' >&2; exit 1; }
DATA='/Library/Application Support/KidsQuota'
DEST_APP='/Applications/Kids Quota.app'
DAEMON='/Library/LaunchDaemons/com.kidsquota.service.plist'
AGENT='/Library/LaunchAgents/com.kidsquota.agent.plist'
for path in "$DATA" "$DATA/bin" "$DATA/local-trust.json" "$DATA/BrowserExtensions" "$DATA/BrowserExtensions/Chrome" "$DEST_APP" "$DAEMON" "$AGENT" "$DATA/admin.token" "$DATA/clients.json" "$DATA/quota.sqlite"; do
  [[ ! -L "$path" ]] || { echo "Refusing symbolic link at installation destination: $path" >&2; exit 1; }
done
umask 077
# Others can traverse this directory to execute the protected agent, but cannot
# list it. Tokens and database files have separate private permissions.
/usr/bin/install -d -o root -g admin -m 0751 "$DATA"
/bin/chmod -N "$DATA"
STAGING_DIRS=(); DESTINATIONS=(); REPLACEMENTS=(); BACKUPS=(); CHANGED=()
COMMITTED=0; HAD_SERVICE=0; SERVICE_STOPPED=0; NEW_STARTED=0
finish_install() {
  local result=$? index rollback_ok=1
  trap - EXIT INT TERM HUP
  set +e +u
  if [[ "$COMMITTED" != 1 ]]; then
    if [[ "$SERVICE_STOPPED" == 1 || "$NEW_STARTED" == 1 ]]; then /bin/launchctl bootout system/com.kidsquota.service 2>/dev/null; fi
    for ((index=${#DESTINATIONS[@]}-1; index>=0; index--)); do
      if [[ "${CHANGED[$index]:-0}" == 1 ]]; then
        if ! /bin/rm -rf "${DESTINATIONS[$index]}"; then rollback_ok=0; continue; fi
        if [[ -e "${BACKUPS[$index]}" ]]; then /bin/mv "${BACKUPS[$index]}" "${DESTINATIONS[$index]}" || rollback_ok=0; fi
      fi
    done
    if [[ "$SERVICE_STOPPED" == 1 && "$HAD_SERVICE" == 1 && "$rollback_ok" == 1 ]]; then
      /bin/launchctl bootstrap system "$DAEMON" && /bin/launchctl kickstart system/com.kidsquota.service || rollback_ok=0
    fi
    if [[ "$rollback_ok" == 1 ]]; then echo 'Installation did not complete; prior installed artifacts and service registration were restored.' >&2
    else echo 'Rollback could not complete. Preserve the private staging directories for administrator recovery:' >&2; printf '%s\n' "${STAGING_DIRS[@]}" >&2; fi
  fi
  if [[ "$rollback_ok" == 1 ]]; then for path in "${STAGING_DIRS[@]}"; do /bin/rm -rf "$path"; done; fi
  exit "$result"
}
trap finish_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
stage_destination() {
  local destination="$1" parent stage index
  parent="$(dirname "$destination")"
  stage="$(/usr/bin/mktemp -d "$parent/.kidsquota-install.XXXXXX")"
  /usr/sbin/chown root:wheel "$stage"; /bin/chmod 0700 "$stage"
  STAGING_DIRS+=("$stage")
  index=${#DESTINATIONS[@]}
  DESTINATIONS+=("$destination"); REPLACEMENTS+=("$stage/new${2:-}"); BACKUPS+=("$stage/previous"); CHANGED+=(0)
  STAGED_PATH="${REPLACEMENTS[$index]}"
}
restrict_parent_executable() {
  local app="$1" executable parent_binary
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
  [[ -n "$executable" && "$executable" != */* && "$executable" != . && "$executable" != .. ]] || { echo 'Invalid parent application executable name.' >&2; return 1; }
  parent_binary="$app/Contents/MacOS/$executable"
  [[ -f "$parent_binary" && ! -L "$parent_binary" ]] || { echo 'Parent executable must be a regular file.' >&2; return 1; }
  # Do not restrict the containing app: child Safari and the system-extension
  # loader need its nested extensions and resources. Only the parent UI binary
  # becomes unreadable and non-executable to standard accounts.
  /bin/chmod -N "$parent_binary"
  /usr/sbin/chown root:admin "$parent_binary"
  /bin/chmod 0750 "$parent_binary"
}
activate_existing_agents() {
  local accounts account uid domain failures=0
  if ! accounts="$(/usr/bin/dscl . -list /Users UniqueID)"; then
    echo 'Could not enumerate login sessions. Sign out and back in, or restart, to load account protection.' >&2
    return 0
  fi
  while read -r account uid; do
    [[ "$uid" =~ ^[0-9]+$ && "$uid" -ge 500 ]] || continue
    domain="gui/$uid"
    # A local account is not proof of a live GUI session. Ask launchd before
    # bootstrapping, and never launch the GUI app or collector in root's session.
    /bin/launchctl print "$domain" >/dev/null 2>&1 || continue
    if /bin/launchctl print "$domain/com.kidsquota.agent" >/dev/null 2>&1; then
      if ! /bin/launchctl bootout "$domain/com.kidsquota.agent"; then failures=1; continue; fi
    fi
    if ! /bin/launchctl bootstrap "$domain" "$AGENT" || ! /bin/launchctl kickstart "$domain/com.kidsquota.agent"; then failures=1; fi
  done <<< "$accounts"
  if [[ "$failures" == 1 ]]; then echo 'Some login sessions need a sign-out/sign-in or restart before account protection is active.' >&2; fi
}
# Every replacement has a private staging/backup directory on its destination's
# filesystem. Copies and signature checks finish before stopping the old job.
stage_destination "$DATA/bin"; BIN_STAGE="$STAGED_PATH"
/usr/bin/install -d -o root -g wheel -m 0755 "$BIN_STAGE"
for component in service agent bridge; do /usr/bin/install -o root -g wheel -m 0755 "$ARTIFACTS/bin/kids-quota-$component" "$BIN_STAGE/kids-quota-$component"; done
/usr/bin/ditto "$ARTIFACTS/bin/kids-quota_KidsQuotaCore.bundle" "$BIN_STAGE/kids-quota_KidsQuotaCore.bundle"
stage_destination "$DEST_APP" .app; APP_STAGE="$STAGED_PATH"
/usr/bin/ditto "$APP" "$APP_STAGE"
/usr/sbin/chown -R root:wheel "$BIN_STAGE" "$APP_STAGE"
/bin/chmod -RN "$BIN_STAGE" "$APP_STAGE"
/bin/chmod -R go-w "$BIN_STAGE" "$APP_STAGE"
/bin/chmod -R a+rX "$BIN_STAGE" "$APP_STAGE"
restrict_parent_executable "$APP_STAGE"
for component in service agent bridge; do verify_code "$BIN_STAGE/kids-quota-$component" "com.kidsquota.$component"; done
verify_code "$APP_STAGE" com.kidsquota.app
/usr/bin/codesign --verify --deep --strict "$APP_STAGE"
if [[ "$MODE" == local ]]; then
  /usr/bin/install -d -o root -g wheel -m 0755 "$DATA/BrowserExtensions"
  /bin/chmod -N "$DATA/BrowserExtensions"
  stage_destination "$DATA/BrowserExtensions/Chrome"; CHROME_STAGE="$STAGED_PATH"
  /usr/bin/ditto "$ARTIFACTS/browser/chrome" "$CHROME_STAGE"
  /usr/sbin/chown -R root:wheel "$CHROME_STAGE"
  /bin/chmod -RN "$CHROME_STAGE"
  /bin/chmod -R go-w "$CHROME_STAGE"
  /bin/chmod -R a+rX "$CHROME_STAGE"
  stage_destination "$DATA/local-trust.json"; TRUST_STAGE="$STAGED_PATH"
  "$SCRIPT_DIR/create-local-trust.sh" "$BIN_STAGE" "$APP_STAGE" > "$TRUST_STAGE"
  /usr/sbin/chown root:wheel "$TRUST_STAGE"
  /bin/chmod -N "$TRUST_STAGE"
  /bin/chmod 0600 "$TRUST_STAGE"
fi
stage_destination "$DAEMON"; DAEMON_STAGE="$STAGED_PATH"
cat > "$DAEMON_STAGE" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.kidsquota.service</string>
<key>ProgramArguments</key><array><string>/Library/Application Support/KidsQuota/bin/kids-quota-service</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>UserName</key><string>root</string><key>Umask</key><integer>63</integer>
<key>ThrottleInterval</key><integer>10</integer>
<key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST
if [[ "$MODE" == local ]]; then
  /usr/libexec/PlistBuddy -c 'Add :ProgramArguments:1 string --local-install' "$DAEMON_STAGE"
fi
stage_destination "$AGENT"; AGENT_STAGE="$STAGED_PATH"
cat > "$AGENT_STAGE" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.kidsquota.agent</string>
<key>ProgramArguments</key><array><string>/Library/Application Support/KidsQuota/bin/kids-quota-agent</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>ThrottleInterval</key><integer>10</integer>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
/usr/sbin/chown root:wheel "$DAEMON_STAGE" "$AGENT_STAGE"
/bin/chmod 0644 "$DAEMON_STAGE" "$AGENT_STAGE"
/usr/bin/plutil -lint "$DAEMON_STAGE" "$AGENT_STAGE"
if [[ -n "$CHROME_ID" ]]; then
  HOST_DIR='/Library/Google/Chrome/NativeMessagingHosts'
  [[ ! -L "$HOST_DIR" && ! -L "$HOST_DIR/com.kidsquota.bridge.json" ]] || { echo 'Refusing a symbolic link at the native host destination.' >&2; exit 1; }
  /usr/bin/install -d -o root -g wheel -m 0755 "$HOST_DIR"
  stage_destination "$HOST_DIR/com.kidsquota.bridge.json"; HOST_STAGE="$STAGED_PATH"
  cat > "$HOST_STAGE" <<JSON
{"name":"com.kidsquota.bridge","description":"Kids Quota authenticated native bridge","path":"/Library/Application Support/KidsQuota/bin/kids-quota-bridge","type":"stdio","allowed_origins":["chrome-extension://$CHROME_ID/"]}
JSON
  /usr/sbin/chown root:wheel "$HOST_STAGE"
  /bin/chmod 0644 "$HOST_STAGE"
else
  echo 'Chrome native-host registration skipped: supply the real extension ID to enable Chrome.'
fi
if /bin/launchctl print system/com.kidsquota.service >/dev/null 2>&1; then
  HAD_SERVICE=1
  /bin/launchctl bootout system/com.kidsquota.service
  SERVICE_STOPPED=1
fi
for ((index=0; index<${#DESTINATIONS[@]}; index++)); do
  if [[ -e "${DESTINATIONS[$index]}" ]]; then /bin/mv "${DESTINATIONS[$index]}" "${BACKUPS[$index]}"; fi
  CHANGED[$index]=1
  /bin/mv "${REPLACEMENTS[$index]}" "${DESTINATIONS[$index]}"
done
/usr/bin/codesign --verify --deep --strict "$DEST_APP"
if [[ "$MODE" == local ]]; then "$DATA/bin/kids-quota-service" --local-install --init
else "$DATA/bin/kids-quota-service" --init; fi
if [[ -f "$DATA/admin.token" ]]; then /usr/sbin/chown root:admin "$DATA/admin.token"; /bin/chmod 0640 "$DATA/admin.token"; fi
for private in "$DATA/clients.json" "$DATA/quota.sqlite" "$DATA/quota.sqlite-wal" "$DATA/quota.sqlite-shm"; do
  if [[ -f "$private" ]]; then /usr/sbin/chown root:wheel "$private"; /bin/chmod 0600 "$private"; fi
done
NEW_STARTED=1
/bin/launchctl bootstrap system "$DAEMON"
/bin/launchctl kickstart system/com.kidsquota.service
# Catch immediate startup failures (for example an occupied loopback port) while
# the old installation is still available for rollback.
for attempt in 1 2 3; do
  /bin/sleep 1
  JOB_STATUS="$(/bin/launchctl print system/com.kidsquota.service)" || { echo 'The installed service registration is unavailable.' >&2; exit 1; }
  /usr/bin/grep -q 'state = running' <<< "$JOB_STATUS" || { echo 'The installed service did not remain running.' >&2; exit 1; }
done
COMMITTED=1
activate_existing_agents
echo 'Installed. Open Kids Quota from Applications in an administrator account to finish setup.'
if [[ "$MODE" == local ]]; then
  echo 'App network blocking is disabled in this local build. Load the bundled Chrome extension and enable Safari development extensions in each child account; see Start here.txt.'
else echo 'Browser extension enablement and app network-filter approval remain explicit setup steps.'; fi
