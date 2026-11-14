# Fake of macOS ipconfig(8) backed by the fake ifconfig's $FAKE_NET state.
# DHCP leases land immediately when the interface is UP with a MAC, unless
# $FAKE_DHCP_FAIL is set (no server answering). With $FAKE_DHCP_DELAY=n the
# lease only lands on the nth getifaddr after the client last started, as
# configd takes seconds to publish and a re-arm restarts it.
# `v4` and `v6` hold how each service was made: `set` or `setService`.

d=$FAKE_NET/$2

dhcp() {
  rm -f "$d/lease" "$d/pending"
  echo "$1" >"$d/v4"
  if [ -z "$FAKE_DHCP_FAIL" ] && [ -e "$d/up" ] && [ -e "$d/ether" ]; then
    if [ -n "$FAKE_DHCP_DELAY" ]; then
      echo "$FAKE_DHCP_DELAY" >"$d/pending"
    else
      echo "lease-for-$(cat "$d/ether")" >"$d/lease"
    fi
  fi
}

case $1 in
getifaddr)
  if [ -e "$d/pending" ]; then
    n=$(($(cat "$d/pending") - 1))
    if [ "$n" -le 0 ]; then
      rm "$d/pending"
      echo "lease-for-$(cat "$d/ether")" >"$d/lease"
    else
      echo "$n" >"$d/pending"
    fi
  fi
  [ -e "$d/lease" ] && cat "$d/lease"
  exit 0
  ;;
set)
  echo "ipconfig $*" >>"$FAKE_LOG"
  [ -d "$d" ] || exit 1
  case $3 in
  DHCP) dhcp set ;;
  NONE) rm -f "$d/lease" "$d/pending" "$d/v4" ;;
  AUTOMATIC-V6) echo set >"$d/v6" ;;
  NONE-V6) rm -f "$d/v6" ;;
  *) exit 1 ;;
  esac
  ;;
setService)
  # An existing service with the method is kept as it is, client and all.
  echo "ipconfig $*" >>"$FAKE_LOG"
  [ -d "$d" ] || exit 1
  case $3 in
  DHCP) [ -e "$d/v4" ] || dhcp setService ;;
  AUTOMATIC-V6) [ -e "$d/v6" ] || echo setService >"$d/v6" ;;
  *) exit 1 ;;
  esac
  echo 00000000-0000-0000-0000-000000000000
  ;;
*) exit 1 ;;
esac
