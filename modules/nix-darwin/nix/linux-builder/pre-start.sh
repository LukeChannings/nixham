# pre-start.sh <name> <label key> <label value> <repository> <ref>: before
# <name> starts, deletes the other containers carrying the label, and, unless
# <ref> is already here, every other image in <repository>: one per past
# generation. Run as the runtime's user, with container and jq on PATH.
set -uo pipefail

if [ "$#" -ne 5 ]; then
  echo >&2 "usage: $0 <name> <label key> <label value> <repository> <ref>"
  exit 2
fi
name=$1 key=$2 value=$3 repo=$4 keep=$5

if json="$(container ls --all --format json)"; then
  jq -r --arg k "$key" --arg v "$value" --arg n "$name" \
    '.[].configuration | select(.labels[$k] == $v and .id != $n) | .id' <<<"$json" |
    while IFS= read -r c; do
      echo >&2 "linux-builder: deleting the stale container $c"
      container delete --force "$c" >/dev/null || true
    done
fi

container image inspect "$keep" >/dev/null 2>&1 && exit 0

json="$(container image ls --format json)" || exit 0
# Loaded images keep their ref verbatim (`linux-builder:<hash>`), pulled ones
# are normalised (`docker.io/library/linux-builder:…`): both are the same
# repository. A name with a `/` in it is a registry path, so
# `linux-builder:5000/x` and `ghcr.io/…/linux-builder` are someone else's.
jq -r --arg repo "$repo" --arg keep "$keep" '
  def norm: if test("/") then . else "docker.io/library/" + . end;
  ($keep | norm) as $k
  | ("docker.io/library/" + $repo) as $r
  | .[].configuration.name
  | select(norm | (startswith($r + ":") or startswith($r + "@")) and . != $k)
' <<<"$json" | while IFS= read -r ref; do
  # `image rm` also removes the image of a container made from it, which
  # keeps its own copy of the rootfs.
  if out="$(container image rm "$ref" 2>&1)"; then
    echo >&2 "linux-builder: deleted the stale image $ref (${out%%$'\n'*})"
  else
    echo >&2 "linux-builder: WARN could not delete the stale image $ref: ${out//$'\n'/ }"
  fi
done
exit 0
