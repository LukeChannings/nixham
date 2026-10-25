# Fake of macOS sysctl(8) for net.inet6.ip6.prefer_tempaddr. The value lives
# in $FAKE_SYSCTL, absent meaning macOS's default of 1. Writes land in
# $FAKE_LOG.

case "$1 $2" in
"-n net.inet6.ip6.prefer_tempaddr")
  cat "$FAKE_SYSCTL" 2>/dev/null || echo 1
  ;;
"-w net.inet6.ip6.prefer_tempaddr=0")
  echo "sysctl $*" >>"$FAKE_LOG"
  echo 0 >"$FAKE_SYSCTL"
  ;;
*) exit 1 ;;
esac
