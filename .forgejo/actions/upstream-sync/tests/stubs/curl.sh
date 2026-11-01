method=GET url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
  -X) method=$2 && shift ;;
  -d) data=$2 && shift ;;
  -H) shift ;;
  http*) url=$1 ;;
  esac
  shift
done
path=${url#https://forge.example/api/v1/repos/owner/fork/}
printf '%s %s %s\n' "$method" "$path" "$data" >>"$BATS_TEST_TMPDIR/curl.calls"
case "$method $path" in
"GET pulls?"*) printf '%s' "${PULLS:-[]}" ;;
"GET issues/"*/comments) printf '%s' "${COMMENTS:-[]}" ;;
"POST pulls") printf '{"number":1}' ;;
"POST issues/"*/comments) printf '{}' ;;
*) exit 22 ;;
esac
