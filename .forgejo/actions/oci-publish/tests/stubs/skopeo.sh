# Registry tags are files under $registry holding their manifest digest.
# Like the runners, there's no /var/tmp: skopeo needs --tmpdir to unpack.
echo "$*" >>"$BATS_TEST_TMPDIR/skopeo.log"
[ "$1" = --tmpdir ] && [ -d "$2" ] || {
  echo 'stat /var/tmp: no such file or directory' >&2
  exit 1
}
case " $* " in
*" inspect "*)
  src=${*: -1:1}
  cat "$registry/${src##*:}" 2>/dev/null
  ;;
*" copy "*)
  src=${*: -2:1} dst=${*: -1:1}
  if [[ $src == docker://* ]]; then digest=$(cat "$registry/${src##*:}"); else digest=sha256:built; fi
  printf %s "$digest" >"$registry/${dst##*:}"
  ;;
esac
