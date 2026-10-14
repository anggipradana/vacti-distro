# shellcheck shell=sh
# Vacti OS default prompt - a subtle, brand-accented PS1 for interactive login
# shells. Installed to /etc/profile.d/vacti-ps1.sh. Lightweight 16-colour ANSI
# only (cyan user@host, blue path), so it is readable on any terminal. It only
# acts on an interactive shell and steps aside if the user or root already set a
# custom PS1, so it never overrides an operator's own prompt.
case $- in
  *i*) ;;
  *) return 2>/dev/null || exit 0 ;;
esac

# Only apply to the stock prompt (do not clobber a user-customised PS1).
_vacti_default_ps1='\u@\h:\w\$ '
if [ -z "${VACTI_PS1_APPLIED:-}" ] && { [ -z "${PS1:-}" ] || [ "${PS1:-}" = "$_vacti_default_ps1" ] || [ "${PS1:-}" = '\h:\w\$ ' ]; }; then
  if [ -n "${BASH_VERSION:-}" ]; then
    PS1='\[\033[96m\]\u@\h\[\033[0m\] \[\033[94m\]\w\[\033[0m\] \[\033[90m\]>\[\033[0m\] '
  else
    PS1='$(whoami)@$(hostname -s) $ '
  fi
  VACTI_PS1_APPLIED=1
fi
unset _vacti_default_ps1
