#!/usr/bin/env bash
# Drives ZipSwap's agent renewal of a saved Claude login (see
# skills/z-claude-reauth/SKILL.md). ZipSwap runs the real sign-in and saves
# the login; this only asks for it and reads ZipSwap's status file.
#   renew-claude-login.sh list           accounts, soonest sign-in end first
#   renew-claude-login.sh start EMAIL    ask ZipSwap to renew; prints the sign-in link
#   renew-claude-login.sh wait EMAIL     wait until ZipSwap saved the login (it
#                                        fails the renewal if the end date did not move)
#   renew-claude-login.sh cancel EMAIL   stop a renewal that can't finish
set -euo pipefail
STATUS="$HOME/Library/Application Support/ZipSwap/ClaudeLogins/renew-status.json"

field() { # field EMAIL KEY: a key from the status file, only while it is about EMAIL
  python3 -I - "$STATUS" "$1" "$2" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if data.get("email", "").lower() == sys.argv[2].lower():
    print(data.get(sys.argv[3]) or "")
PY
}

poll() { # poll EMAIL SECONDS STATE...: wait for one of the states
  local email=$1 seconds=$2; shift 2
  local deadline=$((SECONDS + seconds)) state
  while [ $SECONDS -lt $deadline ]; do
    state=$(field "$email" state)
    for want in "$@" failed; do
      [ "$state" = "$want" ] && { echo "$state"; return 0; }
    done
    sleep 1
  done
  echo "timeout"
}

case "${1:-}" in
  list)
    claude-swap list --json | python3 -I -c '
import json, sys
rows = json.load(sys.stdin)["accounts"]
for r in sorted(rows, key=lambda r: r.get("loginExpiresAt") or "9999"):
    ends = r.get("loginExpiresAt") or "unknown"
    print(ends.ljust(22), r["email"], "(active)" if r.get("active") else "")'
    ;;
  start)
    email=${2:?usage: start EMAIL}
    rm -f "${STATUS:?}"
    open -g "zipswap://renew-login?email=$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$email")"
    case $(poll "$email" 90 open-link) in
      open-link)
        url=$(field "$email" signInURL)
        [ -n "$url" ] || { echo "ZipSwap gave no sign-in link. Run cancel, then start again." >&2; exit 1; }
        echo "$url" ;;
      failed) echo "ZipSwap: $(field "$email" message)" >&2; exit 1 ;;
      *) echo "ZipSwap did not answer. Is it running and up to date?" >&2; exit 1 ;;
    esac
    ;;
  wait)
    email=${2:?usage: wait EMAIL}
    case $(poll "$email" "${3:-120}" done) in
      done) echo "renewed $email, sign-in now ends $(field "$email" signInEnds)" ;;
      failed) echo "ZipSwap: $(field "$email" message)" >&2; exit 1 ;;
      *) echo "Sign-in did not finish yet." >&2; exit 2 ;;
    esac
    ;;
  cancel)
    email=${2:?usage: cancel EMAIL}
    open -g "zipswap://renew-login?cancel=1&email=$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$email")"
    [ "$(poll "$email" 20 none)" = failed ] && echo "cancelled $email" || { echo "Nothing to cancel for $email." >&2; exit 1; }
    ;;
  *) sed -n '2,9p' "$0"; exit 64 ;;
esac
