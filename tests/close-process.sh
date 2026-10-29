#!/usr/bin/env bash
# Self-check for scripts/close-process with throwaway stand-ins, never real apps. Run: bash tests/close-process.sh
# A symlink to sleep gives the unique process name rt-standin (comm comes from the exec path).

set -u
close=$(cd "$(dirname "$0")/.." && pwd)/scripts/close-process
tmp=$(mktemp -d)
trap 'systemctl --user stop "rt-svc-$$" 2>/dev/null; pkill -KILL -x rt-standin; [[ -n ${cid:-} ]] && docker rm -f "$cid" >/dev/null 2>&1; rm -rf "$tmp"' EXIT
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

# A process inside a Docker container: its row stops the whole container.
# shortcut: borrows the first local image and assumes /bin/sh and /bin/sleep in it; set RT_IMAGE to pick another.
img=${RT_IMAGE:-$(docker image ls -q 2>/dev/null | head -1)}
if [[ -n $img ]]; then
  cid=$(docker run -d --rm --stop-timeout 1 --entrypoint /bin/sh "$img" -c 'cp /bin/sleep /tmp/rt-dock && exec /tmp/rt-dock 600') ||
    fail "docker run failed"
  for _ in {1..40}; do pgrep -x rt-dock >/dev/null && break; sleep 0.25; done
  pgrep -x rt-dock >/dev/null || fail "the container stand-in never started"
  "$close" rt-dock || fail "docker close exited $?"
  [[ -z $(docker ps -q --filter "id=$cid") ]] || fail "the container still runs"
else
  echo "skip: no local Docker image"
fi

echo PASS
