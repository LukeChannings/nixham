# start.sh [<model>...]: serves, and pulls each model once the server
# answers, retrying with backoff. The script lives and exits as the server.
[ $# -gt 0 ] || exec "$ollama" serve

"$ollama" serve &
serve_pid=$!
loader_pid=

stop() {
  [ -z "$loader_pid" ] || kill "$loader_pid" 2>/dev/null
  kill -TERM "$serve_pid" 2>/dev/null
}
trap stop TERM INT HUP

load_models() {
  local pending failed model delay=1
  until "$ollama" list >/dev/null 2>&1; do
    kill -0 "$serve_pid" 2>/dev/null || exit 0
    sleep 1
  done

  pending=("$@")
  while [ "${#pending[@]}" -gt 0 ]; do
    failed=()
    for model in "${pending[@]}"; do
      echo "ollama-start: pulling $model" >&2
      "$ollama" pull "$model" || failed+=("$model")
    done
    pending=(${failed[@]+"${failed[@]}"})
    if [ "${#pending[@]}" -gt 0 ]; then
      echo "ollama-start: pull failed for ${pending[*]}; retrying in ${delay}s" >&2
      sleep "$delay"
      delay=$((delay * 2 > 600 ? 600 : delay * 2))
    fi
  done
  echo "ollama-start: all declared models are loaded" >&2
}

load_models "$@" &
loader_pid=$!

# A trapped signal interrupts `wait`; bash remembers the server's own
# status for the last one.
while kill -0 "$serve_pid" 2>/dev/null; do
  wait "$serve_pid"
done
wait "$serve_pid"
status=$?
# launchd kills what's left of the job's process group, e.g. a pull.
kill "$loader_pid" 2>/dev/null
exit "$status"
