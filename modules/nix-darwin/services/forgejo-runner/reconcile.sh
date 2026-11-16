# reconcile.sh <state dir> <label> <closure>: roll the daemon onto <closure>
# once it is idle.
#
# The plist is generation-stable, so activation never restarts the runner and
# it keeps serving the generation it started with. This is the other half of
# that bargain: convergence, deferred until no job is riding the daemon.
#
# Commands are unqualified so the suite can stub them; launchd gives the job
# /usr/bin:/bin:/usr/sbin:/sbin, which carries all of them.
set -eu
state=$1 label=$2 closure=$3

if [ "$(cat "$state/.runner-closure" 2>/dev/null || true)" = "$closure" ]; then
  exit 0
fi

# Host-exec jobs are the daemon's own children, so a childless daemon is idle.
# A task CLAIMED but not yet spawned reads as idle too; the drain on SIGTERM
# (runner.shutdown_timeout) is what covers that window.
pid=$(cat "$state/.runner-pid" 2>/dev/null || true)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && pgrep -P "$pid" >/dev/null 2>&1; then
  echo "forgejo-runner is running jobs; deferring the roll onto $closure" >&2
  exit 0
fi

echo "rolling forgejo-runner onto $closure" >&2
exec launchctl kickstart -k "system/$label"
