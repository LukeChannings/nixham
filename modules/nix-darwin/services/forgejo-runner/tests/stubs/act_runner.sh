echo "act_runner $*" >>"$calls"
if [ "$1" = create-runner-file ]; then
  echo '{"name":"x","labels":[]}' >.runner
fi
# start.sh execs us, so this is the pid launchd sees -- and the one the
# reconcile looks for job children under.
if [ "$1" = daemon ]; then
  echo "$$" >"$state/.daemon-pid"
fi
