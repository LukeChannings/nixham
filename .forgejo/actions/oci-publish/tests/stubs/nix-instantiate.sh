# Upstream Nix's read-only --eval can't import from a path it copied to the store.
[[ " $* " == *" --read-write-mode "* ]] || {
  echo "error: path '/nix/store/source' is not valid" >&2
  exit 1
}
echo '"closure"'
