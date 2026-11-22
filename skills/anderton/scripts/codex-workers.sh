#!/usr/bin/env bash
# Route commands through the existing Claude Anderton's worker ownership.
set -euo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$scripts/session-lib.sh"
usage() {
  echo "usage: codex-workers.sh status|output|register <worker> | message <worker> <text>" >&2
  exit 2
}
action=${1:-}
case $action in
  status | output | register) [ "$#" -eq 2 ] || usage ;;
  message) if [ "$#" -ne 3 ] || [ -z "$3" ]; then usage; fi ;;
  sweep) [ "$#" -eq 1 ] || usage ;;
  *) usage ;;
esac
records=$("$scripts/waiting.sh" --codex-workers)
if [ "$action" = sweep ]; then
  set --
  while IFS= read -r record; do
    if [ -n "$record" ] && jq -e '.id != ""' "$record" >/dev/null 2>&1; then
      set -- "$@" "$record"
    fi
  done <<<"$records"
  if [ "$#" -gt 0 ]; then
    exec "$scripts/codex-worker.py" sweep "$@"
  fi
  exit 0
fi
case $2 in '' | -* | *[!a-z0-9-]*) usage ;; esac
record=""
while IFS= read -r owned; do
  if [ "${owned##*/}" = "$2.json" ]; then record=$owned; break; fi
done <<<"$records"
if [ -z "$record" ]; then
  echo "No Codex worker '$2' owned by this Anderton." >&2
  exit 1
fi
if [ "$action" = register ] || [ "$action" = message ]; then
  expected_thread=$(jq -r .id "$record")
  root=$(invoking_root)
  take_repository_lock "$root"
  lock_worker "$record"
  if ! worker_belongs "$record" "$root" "$(caller_claim "$root")" ||
    ! jq -e --arg id "$expected_thread" '.provider == "codex" and .id == $id' "$record" >/dev/null; then
    echo "Codex worker '$2' changed while acquiring its lock." >&2
    exit 1
  fi
fi
if [ "$action" = register ]; then
  thread=$expected_thread
  launch_token=$(jq -r '.codexLaunchToken // ""' "$record")
  if [ -z "$thread" ]; then
    thread=$("$scripts/codex-worker.py" find "$(jq -r .codexHome "$record")" "$(jq -r .dir "$record")" \
      --after "$(jq -r '.codexBaseline // ""' "$record")" --token "$launch_token") || {
      echo "No verified Codex thread yet. Inspect the worker tab and check that it received the launch brief." >&2
      exit 1
    }
  fi
  bind_codex_worker "$record" "$thread" "$launch_token"
  printf '%s\n' "$thread"
  exit 0
fi
if ! jq -e '.id != ""' "$record" >/dev/null; then
  echo "Codex worker '$2' needs to register its thread first." >&2
  exit 1
fi
if [ "$action" = status ]; then
  exec "$scripts/codex-worker.py" state "$record"
fi
if [ "$action" = output ]; then
  exec "$scripts/codex-worker.py" output "$record"
fi
"$scripts/codex-worker.py" message "$record" -- "$3"
