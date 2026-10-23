echo "act_runner $*" >>"$calls"
if [ "$1" = create-runner-file ]; then
  echo '{"name":"x","labels":[]}' >.runner
fi
