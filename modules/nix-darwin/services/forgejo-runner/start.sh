# start.sh <state dir> <instance> <secret file> <name> <labels> <config> <closure>:
# registers the runner, then runs it.
set -euo pipefail
state=$1 instance=$2 secret=$3 name=$4 labels=$5 config=$6 closure=$7

mkdir -p "$state"
cd "$state"
# Recreated at every start, so Forgejo is told the labels even after its
# runner database is reset.
act_runner create-runner-file --instance "$instance" --secret "$(tr -d '\n' <"$secret")" --name "$name"
# create-runner-file leaves the labels empty.
jq --argjson labels "$labels" '.labels = $labels' .runner >.runner.tmp
mv .runner.tmp .runner
# What reconcile.sh reads: which generation this daemon is running, and whose
# children are its in-flight jobs. `exec` keeps this pid.
printf '%s\n' "$closure" >.runner-closure
printf '%s\n' "$$" >.runner-pid
exec act_runner daemon --config "$config"
