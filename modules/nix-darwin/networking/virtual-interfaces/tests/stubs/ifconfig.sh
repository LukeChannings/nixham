# Stateful fake of macOS ifconfig(8) for the networking.virtualInterfaces
# test. Each interface is a directory under $FAKE_NET holding its state:
#   up       present when the interface is UP
#   ether    MAC address
#   peer     feth peer
#   vlan     "<tag> <parent>"
#   members  bridge members, one per line
#   v6       present while the AUTOMATIC-V6 service is armed (set by ipconfig)
# Mutating calls are appended to $FAKE_LOG.

net=$FAKE_NET

if [ "$1" = -l ]; then
  ls "$net" | tr '\n' ' '
  echo
  exit 0
fi

i=$1
shift
d=$net/$i

if [ $# -eq 0 ]; then
  if [ ! -d "$d" ]; then
    echo "ifconfig: interface $i does not exist" >&2
    exit 1
  fi
  flags=BROADCAST
  [ -e "$d/up" ] && flags=UP,BROADCAST
  echo "$i: flags=8863<$flags,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500"
  [ -e "$d/ether" ] && printf '\tether %s\n' "$(cat "$d/ether")"
  [ -e "$d/peer" ] && printf '\tpeer: %s\n' "$(cat "$d/peer")"
  # An armed AUTOMATIC-V6 service always brings up a link-local address.
  [ -e "$d/v6" ] && printf '\tinet6 fe80::1%%%s prefixlen 64 scopeid 0x1\n' "$i"
  case $i in
  vlan*)
    if [ -e "$d/vlan" ]; then
      # shellcheck disable=SC2046
      set -- $(cat "$d/vlan")
      printf '\tvlan: %s parent interface: %s\n' "$1" "$2"
    else
      printf '\tvlan: 0 parent interface: <none>\n'
    fi
    ;;
  esac
  if [ -e "$d/members" ]; then
    while read -r m; do
      printf '\tmember: %s flags=3<LEARNING,DISCOVER>\n' "$m"
    done <"$d/members"
  fi
  exit 0
fi

echo "ifconfig $i $*" >>"$FAKE_LOG"

if [ "$1" = create ]; then
  [ -d "$d" ] && exit 1
  mkdir "$d"
  exit 0
fi
[ -d "$d" ] || exit 1

case $1 in
destroy) rm -rf "$d" ;;
up) touch "$d/up" ;;
down) rm -f "$d/up" ;;
lladdr) echo "$2" >"$d/ether" ;;
peer)
  [ -e "$d/peer" ] && exit 1
  [ -d "$net/$2" ] || exit 1
  echo "$2" >"$d/peer"
  echo "$i" >"$net/$2/peer"
  ;;
vlan)
  # vlan <tag> vlandev <parent>; one vlan per (parent, tag).
  [ -e "$d/vlan" ] && exit 1
  for o in "$net"/vlan*; do
    [ "$(cat "$o/vlan" 2>/dev/null)" = "$2 $4" ] && exit 1
  done
  echo "$2 $4" >"$d/vlan"
  ;;
-vlandev) rm -f "$d/vlan" ;;
addm)
  # An interface can be a member of only one bridge.
  for b in "$net"/bridge*; do
    grep -qx "$2" "$b/members" 2>/dev/null && exit 1
  done
  echo "$2" >>"$d/members"
  ;;
deletem)
  grep -vx "$2" "$d/members" >"$d/members.new" || true
  mv "$d/members.new" "$d/members"
  ;;
*) exit 1 ;;
esac
