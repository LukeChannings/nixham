# volumes-root.sh <volumes dir> <target> <mount root or ""> <owner>: points
# the volumes dir at target with a symlink, claiming only an absent or empty
# volumes dir. Run as root, with GNU coreutils first on PATH.
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo >&2 "usage: $0 <volumes dir> <target> <mount root> <owner>"
  exit 2
fi
volumesDir=$1 target=$2 mountRoot=$3 owner=$4

skip() {
  echo >&2 "apple-container: $*; leaving $volumesDir alone"
  exit 0
}

# A mount point is on another device than its parent; an unmounted volume
# leaves at most a plain directory behind.
if [ -n "$mountRoot" ]; then
  if [ ! -d "$mountRoot" ] ||
    [ "$(stat -L -c %d -- "$mountRoot")" = "$(stat -L -c %d -- "$(dirname -- "$mountRoot")")" ]; then
    skip "$mountRoot is not mounted"
  fi
fi

if { [ -e "$target" ] || [ -L "$target" ]; } && [ ! -d "$target" ]; then
  skip "$target exists but is not a directory"
fi

# Only the runtime's own dir is created: macOS owns ~/Library and its modes.
stateDir=$(dirname -- "$volumesDir")
appSupportDir=$(dirname -- "$stateDir")
[ -d "$appSupportDir" ] || skip "$appSupportDir does not exist yet"

# Numeric: a primary gid need not have a group name.
group=$(id -g -- "$owner")
install -d -o "$owner" -g "$group" -- "$target"
[ -d "$stateDir" ] || install -d -o "$owner" -g "$group" -- "$stateDir"

if [ -L "$volumesDir" ]; then
  # -ef also accepts the target spelled differently (trailing slash, case).
  current=$(readlink -- "$volumesDir")
  if [ "$current" != "$target" ] && ! [ "$volumesDir" -ef "$target" ]; then
    skip "it already links to $current, not $target"
  fi
elif [ ! -e "$volumesDir" ]; then
  ln -s -- "$target" "$volumesDir"
elif [ -d "$volumesDir" ] && [ -z "$(ls -A -- "$volumesDir")" ]; then
  rmdir -- "$volumesDir"
  ln -s -- "$target" "$volumesDir"
else
  skip "it is not empty (move its contents into $target and remove it to redirect)"
fi
chown -h -- "$owner:$group" "$volumesDir"
