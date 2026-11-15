begin='# BEGIN nix-darwin networking.hosts'
end='# END nix-darwin networking.hosts'

[ -e "$hosts_file" ] || : >"$hosts_file"
tmp=$(mktemp "$hosts_file.XXXXXX") || exit 1
awk -v b="$begin" -v e="$end" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$hosts_file" >"$tmp"
if [ -n "$entries" ]; then
  printf '%s\n%s\n%s\n' "$begin" "$entries" "$end" >>"$tmp"
fi

if cmp -s "$tmp" "$hosts_file"; then
  rm -f "$tmp"
  exit 0
fi

chmod 644 "$tmp"
mv -f "$tmp" "$hosts_file"
dscacheutil -flushcache
killall -HUP mDNSResponder
