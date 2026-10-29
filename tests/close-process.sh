#!/usr/bin/env bash
# Self-check for scripts/close-process with throwaway stand-ins, never real apps. Run: bash tests/close-process.sh
# A symlink to sleep gives the unique process name rt-standin (comm comes from the exec path).

set -u
close=$(cd "$(dirname "$0")/.." && pwd)/scripts/close-process
tmp=$(mktemp -d)
trap 'systemctl --user stop "rt-svc-$$" 2>/dev/null; pkill -KILL -x rt-standin; rm -rf "$tmp"' EXIT
ln -s "$(command -v sleep)" "$tmp/rt-standin"
fail() { echo "FAIL: $*"; exit 1; }
count() { pgrep -cx rt-standin; }
wait_count() { for _ in {1..20}; do [[ $(count) == "$1" ]] && return 0; sleep 0.25; done; fail "expected $1 stand-ins, got $(count)"; }

# One in an app scope (closable), one in a plain user service (must be left alone).
systemd-run --user --quiet --scope --unit "app-rt-$$.scope" "$tmp/rt-standin" 600 &
systemd-run --user --quiet --unit "rt-svc-$$" "$tmp/rt-standin" 600
wait_count 2

"$close" rt-standin || fail "graceful close exited $?"
wait_count 1
systemctl --user is-active -q "rt-svc-$$" || fail "the service stand-in was touched"

# One that ignores SIGTERM: graceful close reports 3, --force kills it.
systemd-run --user --quiet --scope --unit "app-rt2-$$.scope" bash -c "trap '' TERM; exec '$tmp/rt-standin' 600" &
wait_count 2
"$close" rt-standin
rc=$?
[[ $rc == 3 ]] || fail "SIGTERM-ignoring stand-in: expected exit 3, got $rc"
"$close" --force rt-standin || fail "force close exited $?"
wait_count 1

echo PASS
