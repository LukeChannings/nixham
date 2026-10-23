# The runtime's state is files in $runtime: containers.json, images.json, and
# present, the refs `image inspect` finds.
echo "$*" >>"$runtime/calls"
case "$*" in
"ls --all --format json") cat "$runtime/containers.json" ;;
"image ls --format json") cat "$runtime/images.json" ;;
"image inspect "*) grep -qxF "$3" "$runtime/present" ;;
"image rm "*)
  [ "$3" != "$runtime_busy" ] || {
    echo "Error: busy" >&2
    exit 1
  }
  printf 'Reclaimed 1 MB in disk space\n%s\n' "$3"
  ;;
"delete --force "*) ;;
*) exit 1 ;;
esac
