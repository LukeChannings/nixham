function __launchctl_services
    launchctl list 2>/dev/null | awk 'NR>1 && $3 ~ /\./ {print $3}'
end

function __launchctl_domain_targets
    set -l uid (id -u)
    printf '%s\tSystem-wide domain\n' system
    printf 'user/%s\tUser domain for current user\n' $uid
    printf 'gui/%s\tGUI domain for current user\n' $uid
end

complete -c launchctl -f

complete -c launchctl -n '__fish_use_subcommand' -a bootstrap      -d 'Bootstrap a launchd domain or add services'
complete -c launchctl -n '__fish_use_subcommand' -a bootout        -d 'Tear down a launchd domain or remove services'
complete -c launchctl -n '__fish_use_subcommand' -a enable         -d 'Enable an existing service in a domain'
complete -c launchctl -n '__fish_use_subcommand' -a disable        -d 'Disable an existing service in a domain'
complete -c launchctl -n '__fish_use_subcommand' -a kickstart      -d 'Force a service to start'
complete -c launchctl -n '__fish_use_subcommand' -a kill           -d 'Send a signal to a running service'
complete -c launchctl -n '__fish_use_subcommand' -a blame          -d 'Print the reason a service is running'
complete -c launchctl -n '__fish_use_subcommand' -a print          -d 'Print a description of a domain or service'
complete -c launchctl -n '__fish_use_subcommand' -a print-cache    -d 'Print the launchd service cache'
complete -c launchctl -n '__fish_use_subcommand' -a print-disabled -d 'Print disabled services in a domain'
complete -c launchctl -n '__fish_use_subcommand' -a procinfo       -d 'Print information about a process'
complete -c launchctl -n '__fish_use_subcommand' -a hostinfo       -d 'Print information about the system'
complete -c launchctl -n '__fish_use_subcommand' -a resolveport    -d 'Resolve a port name to a process'
complete -c launchctl -n '__fish_use_subcommand' -a examine        -d 'Reflect on launchd state'
complete -c launchctl -n '__fish_use_subcommand' -a config         -d 'Set persistent configuration values'
complete -c launchctl -n '__fish_use_subcommand' -a runstats       -d 'Print runtime statistics for a service'
complete -c launchctl -n '__fish_use_subcommand' -a reboot         -d 'Reboot the system'
complete -c launchctl -n '__fish_use_subcommand' -a error          -d 'Print a description for an error code'
complete -c launchctl -n '__fish_use_subcommand' -a variant        -d 'Print the launchd variant'
complete -c launchctl -n '__fish_use_subcommand' -a version        -d 'Print the launchd version'
complete -c launchctl -n '__fish_use_subcommand' -a load           -d 'Load configuration files (deprecated)'
complete -c launchctl -n '__fish_use_subcommand' -a unload         -d 'Unload configuration files (deprecated)'
complete -c launchctl -n '__fish_use_subcommand' -a start          -d 'Start the specified job (deprecated)'
complete -c launchctl -n '__fish_use_subcommand' -a stop           -d 'Stop the specified job (deprecated)'
complete -c launchctl -n '__fish_use_subcommand' -a list           -d 'List jobs and information about jobs'
complete -c launchctl -n '__fish_use_subcommand' -a remove         -d 'Remove the specified job (deprecated)'
complete -c launchctl -n '__fish_use_subcommand' -a submit         -d 'Submit a job from the command line (deprecated)'
complete -c launchctl -n '__fish_use_subcommand' -a asuser         -d 'Run as the given user'
complete -c launchctl -n '__fish_use_subcommand' -a bsexec         -d 'Run in the given bootstrap context'
complete -c launchctl -n '__fish_use_subcommand' -a managerpid     -d 'Print the PID of the managing launchd'
complete -c launchctl -n '__fish_use_subcommand' -a manageruid     -d 'Print the UID of the managing launchd'
complete -c launchctl -n '__fish_use_subcommand' -a managername    -d 'Print the name of the managing launchd'
complete -c launchctl -n '__fish_use_subcommand' -a help           -d 'Print usage information'

complete -c launchctl -n '__fish_seen_subcommand_from bootstrap; and test (count (commandline -opc)) -eq 2' \
    -a '(__launchctl_domain_targets)'
complete -c launchctl -n '__fish_seen_subcommand_from bootstrap; and test (count (commandline -opc)) -ge 3' \
    -F -a '*.plist'

complete -c launchctl -n '__fish_seen_subcommand_from bootout; and test (count (commandline -opc)) -eq 2' \
    -a '(__launchctl_domain_targets)'
complete -c launchctl -n '__fish_seen_subcommand_from bootout; and test (count (commandline -opc)) -ge 3' \
    -a '(__launchctl_services)'

complete -c launchctl -n '__fish_seen_subcommand_from enable disable blame' \
    -a '(__launchctl_services)'

complete -c launchctl -n '__fish_seen_subcommand_from kickstart' -s k -d 'Kill a running instance before restarting'
complete -c launchctl -n '__fish_seen_subcommand_from kickstart' -s p -d 'Print the PID of the started service on stdout'
complete -c launchctl -n '__fish_seen_subcommand_from kickstart' -a '(__launchctl_services)'

complete -c launchctl -n '__fish_seen_subcommand_from kill; and test (count (commandline -opc)) -eq 2' \
    -a 'SIGTERM\tTerminate SIGKILL\tKill SIGHUP\tHangup SIGINT\tInterrupt SIGQUIT\tQuit SIGUSR1\tUser1 SIGUSR2\tUser2 SIGSTOP\tStop SIGCONT\tContinue SIGWINCH\tWindow'
complete -c launchctl -n '__fish_seen_subcommand_from kill; and test (count (commandline -opc)) -ge 3' \
    -a '(__launchctl_services)'

complete -c launchctl -n '__fish_seen_subcommand_from print' \
    -a '(__launchctl_domain_targets)'
complete -c launchctl -n '__fish_seen_subcommand_from print' \
    -a '(__launchctl_services)'

complete -c launchctl -n '__fish_seen_subcommand_from print-disabled' \
    -a '(__launchctl_domain_targets)'

complete -c launchctl -n '__fish_seen_subcommand_from procinfo resolveport bsexec' \
    -a '(ps -ax -o pid= | string trim)'

complete -c launchctl -n '__fish_seen_subcommand_from runstats' \
    -a '(__launchctl_services)'

complete -c launchctl -n '__fish_seen_subcommand_from config; and test (count (commandline -opc)) -eq 2' \
    -a 'system\tPersistent system configuration user\tPersistent user configuration'

complete -c launchctl -n '__fish_seen_subcommand_from reboot' \
    -a 'system\tFull system reboot userspace\tReboot only userspace logout\tLog out the current user apps\tReboot only applications reroot\tReboot with a new root filesystem'

complete -c launchctl -n '__fish_seen_subcommand_from load unload' -s w \
    -d 'Override the Disabled key and persist the new value'
complete -c launchctl -n '__fish_seen_subcommand_from load unload' -s F \
    -d 'Force the loading/unloading operation'
complete -c launchctl -n '__fish_seen_subcommand_from load unload' -s S -r \
    -d 'Target a session type' -a 'Aqua LoginWindow Background System'
complete -c launchctl -n '__fish_seen_subcommand_from load unload' -s D -r \
    -d 'Load/unload from the specified domain' -a 'all local network system login user'
complete -c launchctl -n '__fish_seen_subcommand_from load unload' -F -a '*.plist'

complete -c launchctl -n '__fish_seen_subcommand_from start stop remove list' \
    -a '(__launchctl_services)'

complete -c launchctl -n '__fish_seen_subcommand_from submit' -s l -r -d 'Specify the job label'
complete -c launchctl -n '__fish_seen_subcommand_from submit' -s p -r -d 'Specify the program to run' -F
complete -c launchctl -n '__fish_seen_subcommand_from submit' -s o -r -d 'Redirect stdout to file' -F
complete -c launchctl -n '__fish_seen_subcommand_from submit' -s e -r -d 'Redirect stderr to file' -F

complete -c launchctl -n '__fish_seen_subcommand_from asuser; and test (count (commandline -opc)) -eq 2' \
    -a '(dscl . -list /Users 2>/dev/null | grep -v "^_")'
