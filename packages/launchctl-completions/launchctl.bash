# shellcheck shell=bash

_launchctl_services_in() {
  { command launchctl print "$1" 2>/dev/null ||
    command sudo -n launchctl print "$1" 2>/dev/null; } |
    command awk '/^\tservices = \{/ {f=1; next} /^\t\}/ {f=0} f {print $NF}'
}

_launchctl_maybe_nospace() {
  local c
  ((${#COMPREPLY[@]})) || return
  for c in "${COMPREPLY[@]}"; do
    [[ $c == */ ]] || return
  done
  compopt -o nospace 2>/dev/null
}

_launchctl_service_targets() {
  local mode=$1 cur=$2 uid domain d s
  uid=$(id -u)
  local -a domains=("system/" "user/$uid/" "gui/$uid/")
  [[ $mode == persistent ]] || domains+=("pid/" "session/")
  local pattern='^(system|user/[0-9]+|gui/[0-9]+|pid/[0-9]+|session/[0-9]+)/'
  [[ $mode == persistent ]] && pattern='^(system|user/[0-9]+|gui/[0-9]+)/'
  if [[ $cur =~ $pattern ]]; then
    domain=${BASH_REMATCH[1]}
    while IFS= read -r s; do
      [[ $domain/$s == "$cur"* ]] && COMPREPLY+=("$domain/$s")
    done < <(_launchctl_services_in "$domain")
    return
  fi
  for d in "${domains[@]}"; do
    [[ $d == "$cur"* ]] && COMPREPLY+=("$d")
  done
  if [[ -n $cur ]]; then
    for d in system "user/$uid" "gui/$uid"; do
      while IFS= read -r s; do
        [[ $s == "$cur"* ]] && COMPREPLY+=("$d/$s")
      done < <(_launchctl_services_in "$d")
    done
  fi
  _launchctl_maybe_nospace
}

_launchctl_domain_targets() {
  local cur=$1 uid d
  uid=$(id -u)
  for d in system "user/$uid" "gui/$uid" pid/ session/; do
    [[ $d == "$cur"* ]] && COMPREPLY+=("$d")
  done
  _launchctl_maybe_nospace
}

_launchctl_labels() {
  command launchctl list 2>/dev/null | command awk 'NR>1 {print $3}'
}

_launchctl_files() {
  local cur=$1
  compopt -o filenames 2>/dev/null
  while IFS= read -r f; do
    COMPREPLY+=("$f")
  done < <(compgen -f -- "$cur")
}

_launchctl() {
  local cur prev sub f
  COMPREPLY=()
  cur=${COMP_WORDS[COMP_CWORD]}
  prev=${COMP_WORDS[COMP_CWORD - 1]}
  local subs='bootstrap bootout enable disable kickstart attach debug kill
    blame print print-cache print-disabled print-token plist procinfo hostinfo
    resolveport limit examine config dumpstate dump-xsc dumpjpcategory reboot
    bootshell load unload remove list start stop setenv unsetenv getenv bsexec
    asuser reload-atf submit managerpid manageruid managername error variant
    version help'
  if ((COMP_CWORD == 1)); then
    while IFS= read -r f; do COMPREPLY+=("$f"); done < <(compgen -W "$subs" -- "$cur")
    return
  fi
  sub=${COMP_WORDS[1]}
  local i n=0
  for ((i = 2; i < COMP_CWORD; i++)); do
    [[ ${COMP_WORDS[i]} == -* ]] || ((n++))
  done
  local cands=""
  case $sub in
  enable | disable)
    ((n == 0)) && _launchctl_service_targets persistent "$cur"
    ;;
  blame | print)
    ((n == 0)) && _launchctl_service_targets all "$cur"
    ;;
  kickstart)
    if [[ $cur == -* ]]; then
      cands="-k -p -s"
    elif ((n == 0)); then _launchctl_service_targets all "$cur"; fi
    ;;
  attach)
    if [[ $cur == -* ]]; then
      cands="-k -s -x"
    elif ((n == 0)); then _launchctl_service_targets all "$cur"; fi
    ;;
  bootout)
    if [[ $cur == -* ]]; then
      cands="--wait"
    elif ((n == 0)); then
      _launchctl_service_targets all "$cur"
    else _launchctl_files "$cur"; fi
    ;;
  debug)
    if ((n == 0)); then
      _launchctl_service_targets all "$cur"
    else
      cands="--program --start-suspended --guard-malloc
          --malloc-stack-logging --malloc-nano-allocator --debug-libraries
          --NSZombie --32 --stdin --stdout --stderr --environment"
    fi
    ;;
  kill)
    if ((n == 0)); then
      cands=$(compgen -A signal)
    elif ((n == 1)); then _launchctl_service_targets all "$cur"; fi
    ;;
  bootstrap)
    if ((n == 0)); then
      _launchctl_domain_targets "$cur"
    else _launchctl_files "$cur"; fi
    ;;
  print-disabled)
    ((n == 0)) && _launchctl_domain_targets "$cur"
    ;;
  plist)
    _launchctl_files "$cur"
    ;;
  limit)
    ((n == 0)) && cands="cpu filesize data stack core rss memlock maxproc maxfiles"
    ;;
  examine)
    if ((n == 0)); then
      cands=$(compgen -c -- "$cur")
    else _launchctl_files "$cur"; fi
    ;;
  config)
    ((n == 0)) && cands="system user"
    ((n == 1)) && cands="umask path"
    ;;
  reboot)
    if [[ $cur == -* ]]; then
      cands="-s"
    elif ((n == 0)); then cands="system halt userspace logout apps"; fi
    ;;
  error)
    ((n == 0)) && cands="posix mach bootstrap"
    ;;
  load | unload)
    case $prev in
    -S) cands="Aqua Background LoginWindow System" ;;
    -D) cands="system local user" ;;
    *)
      if [[ $cur == -* ]]; then
        cands="-w -F -S -D"
      else _launchctl_files "$cur"; fi
      ;;
    esac
    ;;
  start | stop | remove | list)
    ((n == 0)) && cands=$(_launchctl_labels)
    ;;
  submit)
    case $prev in
    -p | -o | -e) _launchctl_files "$cur" ;;
    -l) ;;
    *)
      if [[ $cur == -* ]]; then
        cands="-l -p -o -e"
      else _launchctl_files "$cur"; fi
      ;;
    esac
    ;;
  asuser)
    if ((n == 0)); then
      cands=$(dscl . -list /Users UniqueID 2>/dev/null | command awk '{print $2}')
    elif ((n == 1)); then cands=$(compgen -c -- "$cur"); fi
    ;;
  bsexec)
    ((n == 1)) && cands=$(compgen -c -- "$cur")
    ;;
  help)
    cands=$subs
    ;;
  esac
  if [[ -n $cands ]]; then
    while IFS= read -r f; do COMPREPLY+=("$f"); done < <(compgen -W "$cands" -- "$cur")
  fi
}

complete -F _launchctl launchctl
