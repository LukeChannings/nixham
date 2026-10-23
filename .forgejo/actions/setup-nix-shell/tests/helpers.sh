# shellcheck shell=bash

# github_env <name>: reads <name> back out of $GITHUB_ENV, as the runner
# parses it: NAME=VALUE lines and NAME<<DELIMITER heredocs.
github_env() {
  local line key delim value
  while IFS= read -r line; do
    if [[ $line == *'<<'* ]]; then
      key=${line%%<<*} delim=${line#*<<} value=
      while IFS= read -r line && [ "$line" != "$delim" ]; do
        value+=${value:+$'\n'}$line
      done
    else
      key=${line%%=*} value=${line#*=}
    fi
    [ "$key" != "$1" ] || {
      printf '%s' "$value"
      return
    }
  done <"$GITHUB_ENV"
  return 1
}
