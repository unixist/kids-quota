#!/bin/bash
set -euo pipefail
[[ $# -gt 0 ]] || { echo 'Usage: ci-check.sh command [arguments...]' >&2; exit 2; }
check_log="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/kids-quota-check.XXXXXX")"
trap 'rm -f "$check_log"' EXIT
if "$@" > "$check_log" 2>&1; then
  cat "$check_log"
else
  check_status=$?
  cat "$check_log"
  # Make bounded failure details visible in the check annotations as well as
  # the full log. Escape workflow-command delimiters in the command's output.
  python3 - "$check_log" <<'PY'
import pathlib, re, sys
lines = pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines()
pattern = r"\berror:|Test Case .* failed|threw error|AssertionError|RuntimeError|FAIL:|ERROR:|FAILED"
errors = [line for line in lines if re.search(pattern, line)]
for line in (errors or [line for line in lines if line.strip()])[-10:]:
    message = line[:600].replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::error title=Validation failure::{message}")
PY
  exit "$check_status"
fi
