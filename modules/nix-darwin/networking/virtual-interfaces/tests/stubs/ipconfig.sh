# Fake of macOS ipconfig(8) backed by the fake ifconfig's $FAKE_NET state.
# DHCP leases land immediately when the interface is UP with a MAC, unless
# $FAKE_DHCP_FAIL is set (no server answering). With $FAKE_DHCP_DELAY=n the
# lease only lands on the nth getifaddr after the last `set DHCP`, as configd
# takes seconds to publish and a re-arm restarts it.

d=$FAKE_NET/$2

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
  DHCP)
    rm -f "$d/lease" "$d/pending"
    if [ -z "$FAKE_DHCP_FAIL" ] && [ -e "$d/up" ] && [ -e "$d/ether" ]; then
      if [ -n "$FAKE_DHCP_DELAY" ]; then
        echo "$FAKE_DHCP_DELAY" >"$d/pending"
      else
        echo "lease-for-$(cat "$d/ether")" >"$d/lease"
      fi
    fi
    ;;
  AUTOMATIC-V6) touch "$d/v6" ;;
  NONE-V6) rm -f "$d/v6" ;;
  *) exit 1 ;;
  esac
  ;;
*) exit 1 ;;
esac
