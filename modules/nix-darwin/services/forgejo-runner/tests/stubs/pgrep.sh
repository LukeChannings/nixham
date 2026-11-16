echo "pgrep $*" >>"$calls"
# The daemon has children -- a job is in flight -- only when the test says so.
[ "${JOBS_IN_FLIGHT:-0}" = 1 ]
