# serve: ready after a second, then serves until SIGTERM, which it exits 3
# on. list: whether it's ready. pull: records the model; fails before the
# server is ready, and the first time for "flaky".
case "$1" in
serve)
  trap 'touch "$FAKE_STATE/stopped"; exit 3' TERM
  sleep 1
  touch "$FAKE_STATE/ready"
  while :; do
    sleep 0.1 &
    wait $!
  done
  ;;
list)
  [ -e "$FAKE_STATE/ready" ]
  ;;
pull)
  if [ ! -e "$FAKE_STATE/ready" ]; then
    echo "pull $2 before ready" >>"$FAKE_STATE/errors"
    exit 1
  fi
  if [ "$2" = flaky ] && [ ! -e "$FAKE_STATE/flaky-tried" ]; then
    touch "$FAKE_STATE/flaky-tried"
    exit 1
  fi
  echo "$2" >>"$FAKE_STATE/pulled"
  ;;
esac
