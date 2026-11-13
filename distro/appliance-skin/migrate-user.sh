#!/bin/bash
# migrate-user.sh - operator-invoked kali -> arparp login migration (B2 spec, with the
# operator decisions: ONE shared ARPARP password, the operator's EXISTING SSH key as the
# break-glass key, no FIDO2, no per-host escrow).
#
# Separate from the apt lifecycle: installing/removing/auto-reverting vacti-appliance-skin
# never runs or reverses this. Every phase is DRY-RUN unless --commit is given.
#
#   phase-a     credential kill, NO engine restart:
#               - shared password from /etc/vacti-appliance-skin/arparp-password onto uid 1000
#               - root break-glass: operator key(s) in /root/.ssh/authorized_keys behind a
#                 logging forced command; existing bare root keys are wrapped, not dropped
#               - sshd key-only drop-in (05-vacti-hardening.conf, PermitRootLogin
#                 forced-commands-only), validated in a loopback test sshd BEFORE install,
#                 re-verified with `sshd -T` after, then `reload` (live sessions survive)
#               - 15-min dead-man removes the drop-in unless you run `disarm` from a NEW session
#   phase-b     rename uid 1000 in place (usermod -l; uid, home, files unchanged), re-point
#               engine.env ENGINE_USER, operator-user, sudoers, lightdm autologin, then re-run
#               the vacti-engine postinst (one engine restart, same engine_id). Runs detached
#               (it terminates the uid-1000 sessions); verified; auto-rolls back on failure;
#               20-min dead-man rolls back unless you `disarm` from a NEW arparp session.
#   rollback-a  remove the sshd drop-in (password + break-glass keys stay)
#   rollback-b  rename back and re-point everything to the old name
#   disarm      cancel the pending dead-man(s) after proving a fresh login works
#   status      show where this host stands
#
# Snapshots: /var/lib/vacti-appliance-skin/migrate/{phaseA,phaseB}-before-<epoch>.tar.gz
set -euo pipefail
umask 077

OLD_USER="${VACTI_OLD_USER:-kali}"
NEW_USER="${VACTI_NEW_USER:-arparp}"
TARGET_UID="${VACTI_TARGET_UID:-1000}"
PW_FILE=/etc/vacti-appliance-skin/arparp-password
MIG_DIR=/var/lib/vacti-appliance-skin/migrate
SSHD_DROPIN=/etc/ssh/sshd_config.d/05-vacti-hardening.conf
BG_WRAPPER=/usr/local/sbin/vacti-break-glass
BG_PUB=/etc/vacti-engine/break-glass.pub
ENGINE_ENV=/etc/vacti-engine/engine.env
OPERATOR_USER_FILE=/etc/vacti-engine/operator-user
ENGINE_POSTINST=/var/lib/dpkg/info/vacti-engine.postinst
ENGINE_BUSY=/var/lib/vacti-engine/.busy
BUSY_STALE_SEC="${VACTI_BUSY_STALE_SEC:-18000}"
DEADMAN_A_MIN="${VACTI_DEADMAN_A_MIN:-15}"
DEADMAN_B_MIN="${VACTI_DEADMAN_B_MIN:-20}"
KEY_RE='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]+'

MODE=dry-run
AUTO=0
OPERATOR_FPR=""
CMD="${1:-}"
[ $# -gt 0 ] && shift

log() {
  printf '[migrate-user] %s\n' "$*"
  logger -t vacti-skin-migrate -- "$*" 2>/dev/null || true
}
die() {
  log "ABORT: $*"
  exit 1
}
# run a mutating step (commit) or describe it (dry-run)
act() {
  local d="$1"
  shift
  if [ "$MODE" = commit ]; then
    log "do: ${d}"
    "$@"
  else
    log "[dry-run] would: ${d}"
  fi
}

usage() {
  sed -n '2,32p' "$(readlink -f "$0")" | sed 's/^# \{0,1\}//'
  cat <<EOF

usage: migrate-user.sh <phase-a|phase-b|rollback-a|rollback-b|disarm|status> [--dry-run|--commit]
                       [--operator-fpr SHA256:...]   require this key fingerprint (phase-a)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry-run ;;
    --commit) MODE=commit ;;
    --auto)
      AUTO=1
      MODE=commit
      ;;
    --operator-fpr)
      OPERATOR_FPR="${2:-}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

for n in "$OLD_USER" "$NEW_USER"; do
  [[ "$n" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid user name: ${n}"
done
[[ "$TARGET_UID" =~ ^[0-9]+$ ]] || die "invalid uid: ${TARGET_UID}"

uid_user() { getent passwd "$TARGET_UID" | cut -d: -f1; }
uid_home() { getent passwd "$TARGET_UID" | cut -d: -f6; }
need_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }

reload_sshd() {
  if systemctl is-active --quiet ssh.service 2>/dev/null; then
    systemctl reload ssh.service
  elif systemctl is-active --quiet sshd.service 2>/dev/null; then
    systemctl reload sshd.service
  else
    log "ssh.service not active (socket-activated?): new config applies per connection"
  fi
}

snapshot() { # <name> <paths...>
  local name="$1" out p
  shift
  local keep=()
  for p in "$@"; do [ -e "/${p}" ] && keep+=("$p"); done
  install -d -m 0700 "$MIG_DIR"
  out="${MIG_DIR}/${name}-before-$(date +%s).tar.gz"
  tar -C / -czf "$out" "${keep[@]}"
  chmod 0600 "$out"
  log "snapshot: ${out}"
}

# --- keys -------------------------------------------------------------------------
key_fpr() { printf '%s\n' "$1" | ssh-keygen -lf - -E sha256 2>/dev/null | awk '{print $2}'; }
valid_key() { printf '%s\n' "$1" | ssh-keygen -lf - >/dev/null 2>&1; }

# "type base64" for every valid option-less operator key (uid-1000 authorized_keys + break-glass.pub)
collect_operator_keys() {
  local h line k
  h="$(uid_home)"
  {
    [ -f "${h}/.ssh/authorized_keys" ] && cat "${h}/.ssh/authorized_keys"
    [ -f "$BG_PUB" ] && cat "$BG_PUB"
    true
  } 2>/dev/null | while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ $KEY_RE ]]; then
      k="${BASH_REMATCH[0]}"
      valid_key "$k" && printf '%s\n' "$k"
    fi
  done | sort -u
}

# StrictModes-equivalent: owned by <uid> or root, not group/other writable
strict_ok() {
  local path="$1" owner="$2" st u m
  st="$(stat -c '%u %a' "$path" 2>/dev/null)" || return 1
  u="${st% *}"
  m="${st#* }"
  { [ "$u" = "$owner" ] || [ "$u" = 0 ]; } || return 1
  (((8#$m & 8#022) == 0))
}

render_dropin() {
  cat <<'EOF'
# vacti-appliance-skin migrate-user phase A (B2). Managed file: `migrate-user.sh rollback-a`
# (or the phase-A dead-man) removes it. sshd is first-value-wins and Debian includes
# sshd_config.d/*.conf at the TOP of sshd_config, so this 05- file overrides later drop-ins
# and the main file body. Root may log in ONLY with a key carrying a forced command
# (/usr/local/sbin/vacti-break-glass); nobody may log in with a password.
PermitRootLogin forced-commands-only
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
EOF
}

render_wrapper() {
  cat <<'EOF'
#!/bin/bash
# vacti-break-glass - forced command for root SSH keys under
# `PermitRootLogin forced-commands-only` (installed by vacti-appliance-skin migrate-user.sh;
# deliberately NOT a package file, so it survives removal/auto-revert of the skin).
# Logs every use to the auth log, then runs the requested command or a login shell.
logger -t vacti-break-glass -p authpriv.notice -- "root key login from ${SSH_CONNECTION%% *} (command: ${SSH_ORIGINAL_COMMAND:+yes}${SSH_ORIGINAL_COMMAND:-no})" 2>/dev/null || true
if [ "${1:-}" = selftest ]; then
  echo vacti-break-glass-selftest-ok
  exit 0
fi
if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
  exec /bin/bash -c "$SSH_ORIGINAL_COMMAND"
fi
exec /bin/bash -l
EOF
}

# effective sshd value for a connection spec
sshd_eff() { # <config|""> <user> <keyword>
  local cfgopt=()
  [ -n "$1" ] && cfgopt=(-f "$1")
  sshd -T "${cfgopt[@]}" -C "user=$2,host=localhost,addr=127.0.0.1" 2>/dev/null | awk -v k="$3" '$1==k {$1=""; sub(/^ /,""); print; exit}'
}

# all hardening values in effect for both the login user and root
check_effective() { # <config|"">
  local cfg="$1" u bad=0 v algos t
  u="$(uid_user)"
  for kv in passwordauthentication=no kbdinteractiveauthentication=no pubkeyauthentication=yes \
    permitemptypasswords=no permitrootlogin=forced-commands-only authenticationmethods=publickey; do
    v="$(sshd_eff "$cfg" "$u" "${kv%%=*}")"
    [ "$v" = "${kv#*=}" ] || {
      log "effective ${kv%%=*} for ${u} is '${v}', want '${kv#*=}'"
      bad=1
    }
  done
  v="$(sshd_eff "$cfg" root permitrootlogin)"
  [ "$v" = forced-commands-only ] || {
    log "effective permitrootlogin for root is '${v}'"
    bad=1
  }
  v="$(sshd_eff "$cfg" "$u" authorizedkeysfile)"
  [[ " $v " == *".ssh/authorized_keys"* ]] || {
    log "authorizedkeysfile '${v}' does not read .ssh/authorized_keys"
    bad=1
  }
  algos="$(sshd_eff "$cfg" "$u" pubkeyacceptedalgorithms)"
  [ -n "$algos" ] || algos="$(sshd_eff "$cfg" "$u" pubkeyacceptedkeytypes)"
  if [ -n "$algos" ]; then
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      case "$t" in ssh-rsa) t=rsa-sha2 ;; esac
      [[ ",$algos," == *",$t"* ]] || {
        log "operator key type ${t} not accepted by pubkeyacceptedalgorithms"
        bad=1
      }
    done < <(collect_operator_keys | awk '{print $1}' | sort -u)
  fi
  return "$bad"
}

# Loopback proof under the CANDIDATE config: a throwaway sshd on 127.0.0.1 must accept a
# user key, accept a root key WITH the forced command, and REFUSE a bare root key.
loopback_test() {
  local tmp="$1" port="" p pid ok=0 out u
  u="$(uid_user)"
  for p in $(seq 22900 22999); do
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -q ":${p}\$" || {
      port="$p"
      break
    }
  done
  [ -n "$port" ] || {
    log "no free loopback port for the sshd self-test"
    return 1
  }
  install -d -m 0755 "${tmp}/keys"
  for k in user root bare; do ssh-keygen -q -t ed25519 -N '' -C "vacti-skin-selftest-${k}" -f "${tmp}/k_${k}"; done
  cp "${tmp}/k_user.pub" "${tmp}/keys/${u}"
  {
    printf 'restrict,pty,command="%s selftest" %s\n' "$BG_WRAPPER" "$(cat "${tmp}/k_root.pub")"
    cat "${tmp}/k_bare.pub"
  } > "${tmp}/keys/root"
  chmod 0644 "${tmp}/keys/"*
  /usr/sbin/sshd -D -e -f "${tmp}/sshd_config" -p "$port" -o ListenAddress=127.0.0.1 \
    -o "PidFile=${tmp}/sshd.pid" -o "AuthorizedKeysFile=${tmp}/keys/%u" -o AuthorizedKeysCommand=none \
    2> "${tmp}/sshd.log" &
  pid=$!
  for _ in $(seq 1 50); do
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -q "^127.0.0.1:${port}\$" && break
    sleep 0.1
  done
  local sshopt=(-F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR -p "$port")
  if ssh "${sshopt[@]}" -i "${tmp}/k_user" "${u}@127.0.0.1" true; then
    log "self-test: ${u} key login OK"
  else
    log "self-test: ${u} key login FAILED"
    ok=1
  fi
  out="$(ssh "${sshopt[@]}" -i "${tmp}/k_root" root@127.0.0.1 true 2>/dev/null || true)"
  if [ "$out" = vacti-break-glass-selftest-ok ]; then
    log "self-test: root break-glass (forced command) OK"
  else
    log "self-test: root break-glass FAILED"
    ok=1
  fi
  if ssh "${sshopt[@]}" -i "${tmp}/k_bare" root@127.0.0.1 true 2>/dev/null; then
    log "self-test: bare root key was ACCEPTED (forced-commands-only not in effect)"
    ok=1
  else
    log "self-test: bare root key refused OK"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$ok" = 0 ] || sed 's/^/  sshd: /' "${tmp}/sshd.log" | tail -n 20
  return "$ok"
}

write_root_keys() {
  local f=/root/.ssh/authorized_keys tmpf line k b64
  install -d -m 0700 -o root -g root /root/.ssh || return 1
  tmpf="$(mktemp /root/.ssh/.authorized_keys.vacti.XXXXXX)" || return 1
  if [ -f "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ -z "$line" || "$line" == \#* ]]; then
        printf '%s\n' "$line"
      elif [[ "$line" =~ $KEY_RE ]]; then
        # existing bare root key: keep it working under forced-commands-only via the wrapper
        printf 'command="%s" %s\n' "$BG_WRAPPER" "$line"
      elif [[ "$line" == *command=* ]]; then
        printf '%s\n' "$line"
      else
        printf 'command="%s",%s\n' "$BG_WRAPPER" "$line"
      fi
    done < "$f" > "$tmpf" || return 1
  fi
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    b64="${k#* }"
    grep -qF -- " ${b64}" "$tmpf" && continue
    printf 'restrict,pty,command="%s" %s vacti-break-glass\n' "$BG_WRAPPER" "$k" >> "$tmpf" || return 1
  done < <(collect_operator_keys)
  chown root:root "$tmpf" && chmod 0600 "$tmpf" && mv -f "$tmpf" "$f" || return 1
}

install_wrapper() {
  local t
  install -d -m 0755 "$(dirname "$BG_WRAPPER")" || return 1
  t="$(mktemp "${BG_WRAPPER}.XXXXXX")" || return 1
  render_wrapper > "$t" && chmod 0755 "$t" && chown root:root "$t" && mv -f "$t" "$BG_WRAPPER"
}

set_password() {
  local u pw
  u="$(uid_user)"
  pw="$(< "$PW_FILE")"
  printf '%s:%s\n' "$u" "$pw" | chpasswd || return 1
  chage -M -1 -E -1 "$u" || return 1
  [ "$(passwd -S "$u" 2>/dev/null | awk '{print $2}')" = P ] || {
    log "password status for ${u} is not usable (P)"
    return 1
  }
}

install_dropin() {
  local t
  install -d -m 0755 "$(dirname "$SSHD_DROPIN")" || return 1
  t="$(mktemp "${SSHD_DROPIN}.XXXXXX")" || return 1
  render_dropin > "$t" && chmod 0644 "$t" && mv -f "$t" "$SSHD_DROPIN" || return 1
  if ! sshd -t; then
    rm -f "$SSHD_DROPIN"
    log "sshd -t rejected the installed config; drop-in removed"
    return 1
  fi
  if ! check_effective ""; then
    rm -f "$SSHD_DROPIN"
    log "installed drop-in is not effective (a setting before the Include wins?); drop-in removed"
    return 1
  fi
}

deadman_stop() { # <a|b>
  systemctl stop "vacti-skin-deadman-$1.timer" "vacti-skin-deadman-$1.service" 2>/dev/null || true
  systemctl reset-failed "vacti-skin-deadman-$1.timer" "vacti-skin-deadman-$1.service" 2>/dev/null || true
}

arm_deadman_a() {
  deadman_stop a
  # self-contained: does not depend on this script or the package still being installed
  systemd-run --quiet --unit=vacti-skin-deadman-a --on-active="${DEADMAN_A_MIN}min" \
    --timer-property=AccuracySec=10s /bin/sh -c \
    "rm -f '${SSHD_DROPIN}'; systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service 2>/dev/null || true; logger -t vacti-skin-migrate 'phase-A dead-man fired: removed ${SSHD_DROPIN}'"
}

# ---------------------------------------------------------------------------------------
# phase A
# ---------------------------------------------------------------------------------------
preflight_a() { # sets PF_TMP (candidate config dir)
  local u h pw st keys n
  need_root
  for b in sshd ssh ssh-keygen chpasswd chage passwd systemd-run; do
    command -v "$b" >/dev/null 2>&1 || [ -x "/usr/sbin/$b" ] || die "missing tool: ${b}"
  done
  # ss (iproute2) is only needed by the commit-mode loopback self-test
  if [ "$MODE" = commit ]; then command -v ss >/dev/null 2>&1 || die "missing tool: ss (iproute2)"; fi
  u="$(uid_user)"
  h="$(uid_home)"
  [ -n "$u" ] || die "no account with uid ${TARGET_UID}"
  [ "$u" = "$OLD_USER" ] || [ "$u" = "$NEW_USER" ] || die "uid ${TARGET_UID} is '${u}', expected ${OLD_USER} or ${NEW_USER}"
  # shared password: operator-populated, root-only, fail-closed
  [ -f "$PW_FILE" ] || die "${PW_FILE} is missing: populate it (0400 root:root) with the shared ARPARP password first"
  st="$(stat -c '%U %G %a' "$PW_FILE")"
  [ "${st%% *}" = root ] || die "${PW_FILE} must be owned by root (is: ${st})"
  ((8#${st##* } & 8#077)) && die "${PW_FILE} must not be group/other accessible (mode ${st##* }; want 0400)"
  pw="$(< "$PW_FILE")"
  [ -n "$pw" ] || die "${PW_FILE} is empty"
  [[ "$pw" != *$'\n'* ]] || die "${PW_FILE} must hold a single line"
  [ "${#pw}" -ge 12 ] || die "shared password shorter than 12 characters"
  [ "$pw" != "$OLD_USER" ] && [ "$pw" != "$u" ] || die "shared password equals the user name"
  unset pw
  # operator key(s): the SSH key path must keep working, fail-closed
  keys="$(collect_operator_keys)"
  n="$(printf '%s' "$keys" | grep -c . || true)"
  [ "$n" -ge 1 ] || die "no valid operator SSH key in ${h}/.ssh/authorized_keys or ${BG_PUB}"
  if [ -n "$OPERATOR_FPR" ]; then
    local hit=0 k
    while IFS= read -r k; do [ "$(key_fpr "$k")" = "$OPERATOR_FPR" ] && hit=1; done <<< "$keys"
    [ "$hit" = 1 ] || die "operator key ${OPERATOR_FPR} not found in ${h}/.ssh/authorized_keys or ${BG_PUB}"
  fi
  [ -f "${h}/.ssh/authorized_keys" ] || die "${h}/.ssh/authorized_keys missing"
  strict_ok "$h" "$TARGET_UID" || die "${h} fails sshd StrictModes (owner/mode)"
  strict_ok "${h}/.ssh" "$TARGET_UID" || die "${h}/.ssh fails sshd StrictModes (owner/mode)"
  strict_ok "${h}/.ssh/authorized_keys" "$TARGET_UID" || die "${h}/.ssh/authorized_keys fails sshd StrictModes (owner/mode)"
  log "operator keys: ${n} ($(while IFS= read -r k; do key_fpr "$k"; done <<< "$keys" | tr '\n' ' '))"
  sshd -t || die "current sshd config does not pass sshd -t; fix it before hardening"
  # candidate = our drop-in included FIRST + the live config (relative Includes resolve to /etc/ssh)
  PF_TMP="$(mktemp -d /run/vacti-skin-sshtest.XXXXXX)"
  chmod 0755 "$PF_TMP"
  render_dropin > "${PF_TMP}/05-vacti-hardening.conf"
  {
    echo "Include ${PF_TMP}/05-vacti-hardening.conf"
    cat /etc/ssh/sshd_config
  } > "${PF_TMP}/sshd_config"
  sshd -t -f "${PF_TMP}/sshd_config" || die "candidate sshd config fails sshd -t"
  check_effective "${PF_TMP}/sshd_config" || die "candidate sshd config does not yield the hardened effective values"
  log "preflight A passed (user ${u}, home ${h})"
}

phase_a() {
  PF_TMP=""
  trap '[ -n "${PF_TMP:-}" ] && rm -rf "$PF_TMP"' EXIT
  preflight_a
  act "snapshot sshd/passwd/shadow/root+user .ssh/sudoers.d" \
    snapshot phaseA etc/ssh etc/passwd etc/shadow etc/group etc/gshadow root/.ssh "$(uid_home | sed 's#^/##')/.ssh" etc/sudoers.d
  act "install ${BG_WRAPPER} (logging forced command for root keys)" install_wrapper
  if [ "$MODE" = commit ]; then
    loopback_test "$PF_TMP" || die "loopback sshd self-test failed; NOTHING hardened (sshd config, password, root keys untouched)"
  else
    log "[dry-run] would: loopback sshd self-test (user key OK, root forced-command OK, bare root key refused)"
  fi
  act "write root break-glass keys to /root/.ssh/authorized_keys (operator keys behind ${BG_WRAPPER}; existing bare root keys wrapped)" write_root_keys
  act "set the shared ARPARP password on $(uid_user) (uid ${TARGET_UID}) from ${PW_FILE}" set_password
  act "arm ${DEADMAN_A_MIN}-min phase-A dead-man (removes ${SSHD_DROPIN} unless disarmed)" arm_deadman_a
  act "install ${SSHD_DROPIN} + sshd -t + effective-config verify" install_dropin
  act "reload sshd (existing sessions are kept)" reload_sshd
  if [ "$MODE" = commit ]; then
    date -u '+%FT%TZ' > "${MIG_DIR}/phaseA.done"
    log "PHASE A DONE. Within ${DEADMAN_A_MIN} min, from a NEW terminal:"
    log "  1) ssh -i <operator key> $(uid_user)@<host>   (key login works, password refused)"
    log "  2) ssh -i <operator key> root@<host>           (break-glass shell, logged)"
    log "  3) sudo ${MIG_DIR%/migrate}/../../../usr/libexec/vacti-appliance-skin/migrate-user.sh disarm"
  fi
}

# ---------------------------------------------------------------------------------------
# phase B
# ---------------------------------------------------------------------------------------
engine_user_in_env() { sed -n 's/^ENGINE_USER=//p' "$ENGINE_ENV" 2>/dev/null | head -1 | tr -d "\"' "; }

busy_now() {
  [ -f "$ENGINE_BUSY" ] || return 1
  local a
  a=$(($(date +%s) - $(stat -c %Y "$ENGINE_BUSY" 2>/dev/null || echo 0)))
  ((a < BUSY_STALE_SEC))
}

preflight_b() {
  need_root
  for b in usermod groupmod loginctl visudo systemd-run pgrep pkill timeout; do
    command -v "$b" >/dev/null 2>&1 || [ -x "/usr/sbin/$b" ] || die "missing tool: ${b}"
  done
  if [ "$(uid_user)" = "$NEW_USER" ] && ! getent passwd "$OLD_USER" >/dev/null; then
    log "uid ${TARGET_UID} is already ${NEW_USER}; phase B already done"
    exit 0
  fi
  [ "$(uid_user)" = "$OLD_USER" ] || die "uid ${TARGET_UID} is '$(uid_user)', expected ${OLD_USER}"
  ! getent passwd "$NEW_USER" >/dev/null || die "account ${NEW_USER} already exists"
  ! getent group "$NEW_USER" >/dev/null || die "group ${NEW_USER} already exists"
  { [ ! -e "/home/${NEW_USER}" ] || [ -L "/home/${NEW_USER}" ]; } || die "/home/${NEW_USER} exists and is not a symlink"
  [ -f "$SSHD_DROPIN" ] || die "phase A not applied (${SSHD_DROPIN} missing): run phase-a first"
  [ "$(sshd_eff "" root permitrootlogin)" = forced-commands-only ] || die "phase A hardening not in effect"
  grep -qF "command=\"${BG_WRAPPER}\"" /root/.ssh/authorized_keys 2>/dev/null || die "root break-glass key missing: run phase-a first"
  [ -x "$BG_WRAPPER" ] || die "${BG_WRAPPER} missing: run phase-a first"
  [ -f "$ENGINE_ENV" ] || die "${ENGINE_ENV} missing (engine not enrolled?)"
  [ "$(engine_user_in_env)" = "$OLD_USER" ] || die "ENGINE_USER in ${ENGINE_ENV} is '$(engine_user_in_env)', expected ${OLD_USER}"
  [ -x "$ENGINE_POSTINST" ] || die "${ENGINE_POSTINST} missing"
  ! busy_now || die "engine is busy (fresh ${ENGINE_BUSY}); retry when idle"
  log "preflight B passed"
}

quiesce_uid() { # <name>
  loginctl disable-linger "$1" 2>/dev/null || true
  loginctl terminate-user "$1" 2>/dev/null || true
  systemctl stop "user@${TARGET_UID}.service" 2>/dev/null || true
  for _ in $(seq 1 30); do
    pgrep -u "$TARGET_UID" >/dev/null || return 0
    sleep 1
  done
  pkill -KILL -u "$TARGET_UID" 2>/dev/null || true
  sleep 2
  ! pgrep -u "$TARGET_UID" >/dev/null
}

mv_if() { if [ -e "$1" ] && [ ! -e "$2" ]; then mv "$1" "$2"; fi; }

rename_account() { # <from> <to>
  local from="$1" to="$2" f
  if getent passwd "$from" >/dev/null; then
    usermod -l "$to" "$from" || return 1
  fi
  if getent group "$from" >/dev/null && ! getent group "$to" >/dev/null; then
    groupmod -n "$to" "$from" || return 1
  fi
  for f in /etc/subuid /etc/subgid; do
    [ -f "$f" ] && { sed -i "s/^${from}:/${to}:/" "$f" || return 1; }
  done
  mv_if "/var/spool/cron/crontabs/${from}" "/var/spool/cron/crontabs/${to}"
  mv_if "/var/mail/${from}" "/var/mail/${to}"
  mv_if "/var/lib/AccountsService/users/${from}" "/var/lib/AccountsService/users/${to}"
  mv_if "/var/lib/AccountsService/icons/${from}" "/var/lib/AccountsService/icons/${to}"
  return 0
}

repoint_config() { # <from> <to>
  local from="$1" to="$2" f t
  # engine.env: ONLY the ENGINE_USER line (tokens in the file may have rotated)
  sed -i -E "s/^ENGINE_USER=[\"']?${from}[\"']?[[:space:]]*\$/ENGINE_USER=${to}/" "$ENGINE_ENV" || return 1
  [ "$(engine_user_in_env)" = "$to" ] || {
    log "ENGINE_USER did not become ${to}"
    return 1
  }
  # operator-user seed (authorized_keys converge target)
  if [ "$to" = "$NEW_USER" ]; then
    [ -f "$OPERATOR_USER_FILE" ] || echo created > "${MIG_DIR}/operator-user.created"
    printf '%s\n' "$to" > "$OPERATOR_USER_FILE" || return 1
  elif [ -f "${MIG_DIR}/operator-user.created" ]; then
    rm -f "$OPERATOR_USER_FILE" "${MIG_DIR}/operator-user.created"
  elif [ -f "$OPERATOR_USER_FILE" ]; then
    printf '%s\n' "$to" > "$OPERATOR_USER_FILE" || return 1
  fi
  chmod 0644 "$OPERATOR_USER_FILE" 2>/dev/null || true
  # sudoers: every grant whose user field is the old name (incl. legacy vacti-vpn); postinst
  # re-templates its own files again afterwards. visudo-validated, atomic.
  for f in /etc/sudoers.d/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in *.* | *~ | README) continue ;; esac
    grep -qE "^(Defaults:)?${from}([[:space:],]|\$)" "$f" || continue
    t="$(mktemp "/etc/sudoers.d/.vacti-skin.XXXXXX")" || return 1
    sed -E "s/^${from}([[:space:]])/${to}\1/; s/^Defaults:${from}([[:space:],])/Defaults:${to}\1/" "$f" > "$t" || return 1
    if ! visudo -cqf "$t"; then
      rm -f "$t"
      log "visudo rejected the rewritten ${f}"
      return 1
    fi
    chown root:root "$t" && chmod 0440 "$t" && mv -f "$t" "$f" || return 1
    log "sudoers: ${f} ${from} -> ${to}"
  done
  visudo -cq || {
    log "visudo -c fails after the sudoers rewrite"
    return 1
  }
  # lightdm autologin (desktop autologin keeps working after the rename)
  for f in /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/*.conf; do
    [ -f "$f" ] || continue
    sed -i -E "s/^(autologin-user[[:space:]]*=[[:space:]]*)${from}[[:space:]]*\$/\1${to}/" "$f" || return 1
  done
  rm -f "/var/lib/systemd/linger/${from}"
  return 0
}

rerun_engine_postinst() {
  local ver
  # shellcheck disable=SC2016  # ${Version} is a dpkg-query format field
  ver="$(dpkg-query -W -f='${Version}' vacti-engine 2>/dev/null)" || return 1
  DPKG_MAINTSCRIPT_PACKAGE=vacti-engine DPKG_MAINTSCRIPT_NAME=postinst \
    timeout 600 "$ENGINE_POSTINST" configure "$ver"
}

wait_engine_active() {
  for _ in $(seq 1 60); do
    systemctl is-active --quiet vacti-engine.service && return 0
    sleep 5
  done
  return 1
}

verify_b() {
  [ "$(id -u "$NEW_USER" 2>/dev/null)" = "$TARGET_UID" ] || { log "verify: ${NEW_USER} is not uid ${TARGET_UID}"; return 1; }
  ! getent passwd "$OLD_USER" >/dev/null || { log "verify: ${OLD_USER} still exists"; return 1; }
  [ "$(systemctl show -p User --value vacti-engine.service 2>/dev/null)" = "$NEW_USER" ] || { log "verify: vacti-engine User= is not ${NEW_USER}"; return 1; }
  wait_engine_active || { log "verify: vacti-engine did not become active within 5 min"; return 1; }
  sudo -n -l -U "$NEW_USER" >/dev/null 2>&1 || { log "verify: sudo -l -U ${NEW_USER} failed"; return 1; }
  return 0
}

rollback_b_body() {
  log "rollback B: ${NEW_USER} -> ${OLD_USER}"
  systemctl stop vacti-engine-update.timer 2>/dev/null || true
  systemctl stop vacti-engine.service vacti-submission-runner.service 2>/dev/null || true
  if getent passwd "$NEW_USER" >/dev/null && ! getent passwd "$OLD_USER" >/dev/null; then
    quiesce_uid "$NEW_USER" || log "rollback B: uid ${TARGET_UID} processes still alive; trying usermod anyway"
    rename_account "$NEW_USER" "$OLD_USER" || log "rollback B: rename back FAILED"
  fi
  if [ -L "/home/${NEW_USER}" ]; then rm -f "/home/${NEW_USER}"; fi
  repoint_config "$NEW_USER" "$OLD_USER" || log "rollback B: config re-point incomplete"
  rerun_engine_postinst || log "rollback B: engine postinst re-run failed"
  systemctl start vacti-engine-update.timer 2>/dev/null || true
  rm -f "${MIG_DIR}/phaseB.done"
  deadman_stop b
  log "rollback B finished: uid ${TARGET_UID} is $(uid_user)"
}

phase_b_detached_body() {
  preflight_b
  snapshot phaseB etc/passwd etc/shadow etc/group etc/gshadow etc/subuid etc/subgid etc/vacti-engine \
    etc/sudoers.d etc/lightdm etc/systemd/system var/lib/systemd/linger "var/spool/cron/crontabs/${OLD_USER}" \
    "var/lib/AccountsService/users/${OLD_USER}"
  deadman_stop b
  systemd-run --quiet --unit=vacti-skin-deadman-b --on-active="${DEADMAN_B_MIN}min" \
    --timer-property=AccuracySec=10s "${MIG_DIR}/migrate-user.sh" rollback-b --auto
  log "dead-man B armed (${DEADMAN_B_MIN} min)"
  systemctl stop vacti-engine-update.timer 2>/dev/null || true
  if busy_now; then
    systemctl start vacti-engine-update.timer 2>/dev/null || true
    deadman_stop b
    die "engine became busy; nothing changed"
  fi
  local failed=0
  systemctl stop vacti-engine.service vacti-submission-runner.service || failed=1
  [ "$failed" = 0 ] && { quiesce_uid "$OLD_USER" || { log "uid ${TARGET_UID} processes would not exit"; failed=1; }; }
  [ "$failed" = 0 ] && { rename_account "$OLD_USER" "$NEW_USER" || failed=1; }
  if [ "$failed" = 0 ] && [ ! -e "/home/${NEW_USER}" ]; then
    ln -s "$(uid_home)" "/home/${NEW_USER}" || failed=1
  fi
  [ "$failed" = 0 ] && { repoint_config "$OLD_USER" "$NEW_USER" || failed=1; }
  [ "$failed" = 0 ] && { rerun_engine_postinst || { log "engine postinst re-run failed"; failed=1; }; }
  [ "$failed" = 0 ] && { verify_b || failed=1; }
  if [ "$failed" != 0 ]; then
    log "PHASE B FAILED: rolling back automatically"
    rollback_b_body
    exit 1
  fi
  systemctl start vacti-engine-update.timer 2>/dev/null || true
  date -u '+%FT%TZ' > "${MIG_DIR}/phaseB.done"
  log "PHASE B DONE: uid ${TARGET_UID} is ${NEW_USER}, engine active as ${NEW_USER}."
  log "Within ${DEADMAN_B_MIN} min: ssh -i <operator key> ${NEW_USER}@<host>, then: sudo /usr/libexec/vacti-appliance-skin/migrate-user.sh disarm"
}

phase_b() {
  if [ "$MODE" != commit ]; then
    preflight_b
    log "[dry-run] would: snapshot passwd/shadow/group/subuid/engine config/sudoers.d/lightdm/units/linger/cron"
    log "[dry-run] would: arm ${DEADMAN_B_MIN}-min phase-B dead-man (rollback-b unless disarmed)"
    log "[dry-run] would: stop vacti-engine-update.timer, vacti-engine, vacti-submission-runner (idle-gated)"
    log "[dry-run] would: terminate ${OLD_USER} sessions, usermod -l ${NEW_USER} ${OLD_USER}, groupmod -n ${NEW_USER} ${OLD_USER} (uid/home unchanged)"
    log "[dry-run] would: ln -s $(uid_home) /home/${NEW_USER}"
    log "[dry-run] would: ENGINE_USER=${NEW_USER} in ${ENGINE_ENV}, ${OPERATOR_USER_FILE}=${NEW_USER}, sudoers ${OLD_USER}->${NEW_USER} (incl. vacti-vpn), lightdm autologin"
    log "[dry-run] would: re-run ${ENGINE_POSTINST} configure (re-templates units/sudoers/tailscale operator/linger, restarts engine)"
    log "[dry-run] would: verify (uid, User=, engine active, sudo -l) or roll back automatically"
    return 0
  fi
  if [ -z "${VACTI_SKIN_DETACHED:-}" ]; then
    preflight_b
    install -d -m 0700 "$MIG_DIR"
    if [ "$(readlink -f "$0")" != "${MIG_DIR}/migrate-user.sh" ]; then
      install -m 0700 "$(readlink -f "$0")" "${MIG_DIR}/migrate-user.sh"
    fi
    local unit
    unit="vacti-skin-migrate-b-$(date +%s)"
    systemd-run --quiet --unit="$unit" --collect -p Type=exec \
      --setenv=VACTI_SKIN_DETACHED=1 --setenv=VACTI_OLD_USER="$OLD_USER" \
      --setenv=VACTI_NEW_USER="$NEW_USER" --setenv=VACTI_TARGET_UID="$TARGET_UID" \
      "${MIG_DIR}/migrate-user.sh" phase-b --commit
    log "phase B started detached as ${unit} (your ${OLD_USER} session will be terminated)."
    log "follow: journalctl -fu ${unit}   (or after reconnecting as ${NEW_USER}: journalctl -t vacti-skin-migrate)"
    return 0
  fi
  phase_b_detached_body
}

rollback_a() {
  need_root
  act "remove ${SSHD_DROPIN}" rm -f "$SSHD_DROPIN"
  act "sshd -t + reload" sh -c 'sshd -t' && act "reload sshd" reload_sshd
  act "cancel the phase-A dead-man" deadman_stop a
  if [ "$MODE" = commit ]; then rm -f "${MIG_DIR}/phaseA.done"; fi
  log "rollback A: shared password and root break-glass keys are left in place (still valid)"
}

rollback_b() {
  need_root
  if [ "$MODE" != commit ]; then
    log "[dry-run] would: stop engine units, rename ${NEW_USER} -> ${OLD_USER}, drop /home/${NEW_USER} symlink, re-point engine.env/operator-user/sudoers/lightdm back, re-run engine postinst"
    return 0
  fi
  if [ "$AUTO" = 1 ]; then log "rollback B triggered by the phase-B dead-man (not disarmed in time)"; fi
  rollback_b_body
}

disarm() {
  need_root
  [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SUDO_USER:-}" ] || log "note: run disarm from a FRESH ssh login, that login is the proof"
  deadman_stop a
  deadman_stop b
  log "dead-man timers cancelled; uid ${TARGET_UID} is $(uid_user)"
}

status() {
  echo "uid ${TARGET_UID}        : $(uid_user) ($(uid_home))"
  echo "phase A done    : $(cat "${MIG_DIR}/phaseA.done" 2>/dev/null || echo no)"
  echo "phase B done    : $(cat "${MIG_DIR}/phaseB.done" 2>/dev/null || echo no)"
  echo "sshd drop-in    : $([ -f "$SSHD_DROPIN" ] && echo present || echo absent)"
  echo "permitrootlogin : $(sshd_eff "" root permitrootlogin)"
  echo "password auth   : $(sshd_eff "" "$(uid_user)" passwordauthentication)"
  echo "break-glass     : $([ -x "$BG_WRAPPER" ] && grep -qF "command=\"${BG_WRAPPER}\"" /root/.ssh/authorized_keys 2>/dev/null && echo installed || echo absent)"
  echo "ENGINE_USER     : $(engine_user_in_env)"
  echo "dead-man A      : $(systemctl is-active vacti-skin-deadman-a.timer 2>/dev/null || true)"
  echo "dead-man B      : $(systemctl is-active vacti-skin-deadman-b.timer 2>/dev/null || true)"
  echo "password file   : $([ -f "$PW_FILE" ] && stat -c '%U:%G %a' "$PW_FILE" || echo missing)"
}

case "$CMD" in
  phase-a) phase_a ;;
  phase-b) phase_b ;;
  rollback-a) rollback_a ;;
  rollback-b) rollback_b ;;
  disarm) disarm ;;
  status) status ;;
  -h | --help | '') usage ;;
  *)
    usage >&2
    exit 2
    ;;
esac
