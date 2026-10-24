function __launchctl_subcommands
    printf '%s\t%s\n' \
        bootstrap 'Bootstrap a domain or a service into a domain' \
        bootout 'Tear down a domain or remove a service from a domain' \
        enable 'Enable an existing service' \
        disable 'Disable an existing service' \
        kickstart 'Force an existing service to start' \
        attach "Attach the system's debugger to a service" \
        debug 'Configure the next invocation of a service for debugging' \
        kill 'Send a signal to the service instance' \
        blame 'Print the reason a service is running' \
        print 'Print a description of a domain or service' \
        print-cache 'Print information about the service cache' \
        print-disabled 'Print which services are disabled' \
        print-token 'Print service identifier given an xpc event token' \
        plist 'Print a property list embedded in a binary' \
        procinfo 'Print port information about a process' \
        hostinfo 'Print port information about the host' \
        resolveport 'Resolve a port name from a process to an endpoint' \
        limit "Read or modify launchd's resource limits" \
        examine 'Run an analysis tool against launchd' \
        config 'Modify persistent configuration parameters' \
        dumpstate 'Dump launchd state to stdout' \
        dump-xsc 'Dump launchd XPC string caches to stdout' \
        dumpjpcategory 'Dump the jetsam properties category for all services' \
        reboot 'Initiate a system reboot of the specified type' \
        bootshell 'Bring the system up from single-user mode' \
        load 'Bootstrap a service or directory of services (legacy)' \
        unload 'Unload a service or directory of services (legacy)' \
        remove 'Unload the specified service name (legacy)' \
        list 'List information about services (legacy)' \
        start 'Start the specified service (legacy)' \
        stop 'Stop the specified service if it is running (legacy)' \
        setenv 'Set environment variables for all services in the domain' \
        unsetenv 'Unset environment variables for all services in the domain' \
        getenv 'Get the value of an environment variable from launchd' \
        bsexec "Execute a program in another process' bootstrap context" \
        asuser 'Execute a program in the bootstrap context of a given user' \
        reload-atf 'Reload the active trial factors' \
        submit 'Submit a basic job from the command line (legacy)' \
        managerpid 'Print the PID of the launchd controlling the session' \
        manageruid 'Print the UID of the current launchd session' \
        managername 'Print the name of the current launchd session' \
        error 'Print a description of an error' \
        variant 'Print the launchd variant' \
        version 'Print the launchd version' \
        help 'Print the usage for a given subcommand'
end

function __launchctl_services_in -a domain
    begin
        command launchctl print $domain 2>/dev/null
        or command sudo -n launchctl print $domain 2>/dev/null
    end | awk '/^\tservices = \{/ {f=1; next} /^\t\}/ {f=0} f {print $NF}'
end

function __launchctl_service_targets
    set -l mode $argv[1]
    set -l token (commandline -ct)
    set -l uid (id -u)
    set -l pattern '^(system|user/[0-9]+|gui/[0-9]+|pid/[0-9]+|session/[0-9]+)/'
    if test "$mode" = persistent
        set pattern '^(system|user/[0-9]+|gui/[0-9]+)/'
    end
    set -l m (string match -r $pattern -- $token)
    if set -q m[2]
        for s in (__launchctl_services_in $m[2])
            printf '%s/%s\n' $m[2] $s
        end
        return
    end
    printf '%s\t%s\n' \
        system/ 'System-wide domain' \
        user/$uid/ 'User domain (background services)' \
        gui/$uid/ 'GUI domain (per-login services)'
    if test "$mode" != persistent
        printf '%s\t%s\n' \
            pid/ 'Process domain: pid/<pid>/' \
            session/ 'Audit session domain: session/<asid>/'
    end
    if test -n "$token"
        for d in system user/$uid gui/$uid
            for s in (__launchctl_services_in $d)
                string match -q -- "$token*" $s
                and printf '%s/%s\n' $d $s
            end
        end
    end
end

function __launchctl_domain_targets
    set -l uid (id -u)
    printf '%s\t%s\n' \
        system 'System-wide domain' \
        user/$uid 'User domain (background services)' \
        gui/$uid 'GUI domain (per-login services)' \
        pid/ 'Process domain: pid/<pid>' \
        session/ 'Audit session domain: session/<asid>'
end

function __launchctl_labels
    command launchctl list 2>/dev/null | awk 'NR>1 {print $3}'
end

function __launchctl_uids
    dscl . -list /Users UniqueID 2>/dev/null | awk '{print $2 "\t" $1}'
end

function __launchctl_narg -a n
    test (count (string match -rv '^-' -- (commandline -opc))) -eq $n
end

function __launchctl_narg_ge -a n
    test (count (string match -rv '^-' -- (commandline -opc))) -ge $n
end

complete -c launchctl -f

complete -c launchctl -n __fish_use_subcommand -a '(__launchctl_subcommands)'

complete -c launchctl -n '__fish_seen_subcommand_from enable disable; and __launchctl_narg 2' \
    -a '(__launchctl_service_targets persistent)'
complete -c launchctl -n '__fish_seen_subcommand_from kickstart attach blame print bootout debug; and __launchctl_narg 2' \
    -a '(__launchctl_service_targets)'
complete -c launchctl -n '__fish_seen_subcommand_from kill; and __launchctl_narg 3' \
    -a '(__launchctl_service_targets)'

complete -c launchctl -n '__fish_seen_subcommand_from kill; and __launchctl_narg 2' \
    -a 'SIGHUP SIGINT SIGQUIT SIGILL SIGTRAP SIGABRT SIGEMT SIGFPE SIGKILL SIGBUS SIGSEGV SIGSYS SIGPIPE SIGALRM SIGTERM SIGURG SIGSTOP SIGTSTP SIGCONT SIGCHLD SIGTTIN SIGTTOU SIGIO SIGXCPU SIGXFSZ SIGVTALRM SIGPROF SIGWINCH SIGINFO SIGUSR1 SIGUSR2'

complete -c launchctl -n '__fish_seen_subcommand_from bootstrap; and __launchctl_narg 2' \
    -a '(__launchctl_domain_targets)'
complete -c launchctl -n '__fish_seen_subcommand_from bootstrap bootout; and __launchctl_narg_ge 3' -F

complete -c launchctl -n '__fish_seen_subcommand_from print-disabled; and __launchctl_narg 2' \
    -a '(__launchctl_domain_targets)'

complete -c launchctl -n '__fish_seen_subcommand_from kickstart' -s k -d 'Terminate the running instance first'
complete -c launchctl -n '__fish_seen_subcommand_from kickstart' -s p -d 'Print the PID of the service'
complete -c launchctl -n '__fish_seen_subcommand_from kickstart' -s s -d 'Start suspended so a debugger may attach'

complete -c launchctl -n '__fish_seen_subcommand_from attach' -s k -d 'Terminate the running instance first'
complete -c launchctl -n '__fish_seen_subcommand_from attach' -s s -d "Force the service to start"
complete -c launchctl -n '__fish_seen_subcommand_from attach' -s x -d 'Attach to the execution trampoline (implies -k)'

complete -c launchctl -n '__fish_seen_subcommand_from bootout' -l wait -d 'Wait for bootout to complete'

complete -c launchctl -n '__fish_seen_subcommand_from debug' -l program -rF -d "Use a different binary as the service's executable"
complete -c launchctl -n '__fish_seen_subcommand_from debug' -l start-suspended -d 'Start suspended so a debugger may attach'
complete -c launchctl -n '__fish_seen_subcommand_from debug' -l guard-malloc -d 'Enable libgmalloc'
complete -c launchctl -n '__fish_seen_subcommand_from debug' -l malloc-stack-logging -d 'Enable malloc stack logging'
complete -c launchctl -n '__fish_seen_subcommand_from debug' -l malloc-nano-allocator -d 'Enable the malloc nano allocator'
complete -c launchctl -n '__fish_seen_subcommand_from debug' -l debug-libraries -d 'Prefer debug variants of libraries'
complete -c launchctl -n '__fish_seen_subcommand_from debug' -l NSZombie -d 'Enable NSZombie'
complete -c launchctl -n '__fish_seen_subcommand_from debug' -l 32 -d 'Run in 32-bit mode'
complete -c launchctl -n '__fish_seen_subcommand_from debug' -l stdin -d 'Set standard input [path]'
complete -c launchctl -n '__fish_seen_subcommand_from debug' -l stdout -d 'Set standard output [path]'
complete -c launchctl -n '__fish_seen_subcommand_from debug' -l stderr -d 'Set standard error [path]'
complete -c launchctl -n '__fish_seen_subcommand_from debug' -l environment -d 'Set environment variables'

complete -c launchctl -n '__fish_seen_subcommand_from plist' -F

complete -c launchctl -n '__fish_seen_subcommand_from limit; and __launchctl_narg 2' \
    -a 'cpu filesize data stack core rss memlock maxproc maxfiles'

complete -c launchctl -n '__fish_seen_subcommand_from examine' \
    -xa '(__fish_complete_subcommand --fcs-skip=2)'

complete -c launchctl -n '__fish_seen_subcommand_from config; and __launchctl_narg 2' \
    -a 'system\t"Persistent system configuration" user\t"Persistent user configuration"'
complete -c launchctl -n '__fish_seen_subcommand_from config; and __launchctl_narg 3' \
    -a 'umask\t"Set the umask for services in the domain" path\t"Set the PATH for services in the domain"'

complete -c launchctl -n '__fish_seen_subcommand_from reboot; and __launchctl_narg 2' \
    -a 'system\t"Full system reboot" halt\t"Halt without rebooting" userspace\t"Re-exec launchd and bring userspace back up" logout\t"Tear down the GUI login session" apps\t"Terminate non-launchd apps in the session"'
complete -c launchctl -n '__fish_seen_subcommand_from reboot' -s s

complete -c launchctl -n '__fish_seen_subcommand_from error; and __launchctl_narg 2' \
    -a 'posix mach bootstrap'

complete -c launchctl -n '__fish_seen_subcommand_from load unload' -s w \
    -d 'Override the Disabled key and persist the new value'
complete -c launchctl -n '__fish_seen_subcommand_from load unload' -s F \
    -d 'Force the operation, ignoring the Disabled key'
complete -c launchctl -n '__fish_seen_subcommand_from load unload' -s S -x \
    -d 'Target a session type' -a 'Aqua Background LoginWindow System'
complete -c launchctl -n '__fish_seen_subcommand_from load unload' -s D -x \
    -d 'Load/unload all plists in a search path' -a 'system local user'
complete -c launchctl -n '__fish_seen_subcommand_from load unload' -F

complete -c launchctl -n '__fish_seen_subcommand_from start stop remove list; and __launchctl_narg 2' \
    -a '(__launchctl_labels)'

complete -c launchctl -n '__fish_seen_subcommand_from submit' -s l -x -d 'Unique label to assign the job'
complete -c launchctl -n '__fish_seen_subcommand_from submit' -s p -rF -d 'Program to execute'
complete -c launchctl -n '__fish_seen_subcommand_from submit' -s o -rF -d 'File for stdout'
complete -c launchctl -n '__fish_seen_subcommand_from submit' -s e -rF -d 'File for stderr'

complete -c launchctl -n '__fish_seen_subcommand_from asuser; and __launchctl_narg 2' \
    -a '(__launchctl_uids)'
complete -c launchctl -n '__fish_seen_subcommand_from asuser; and __launchctl_narg_ge 3' \
    -xa '(__fish_complete_subcommand --fcs-skip=3)'
complete -c launchctl -n '__fish_seen_subcommand_from bsexec; and __launchctl_narg_ge 3' \
    -xa '(__fish_complete_subcommand --fcs-skip=3)'

complete -c launchctl -n '__fish_seen_subcommand_from help; and __launchctl_narg 2' \
    -a '(__launchctl_subcommands)'
