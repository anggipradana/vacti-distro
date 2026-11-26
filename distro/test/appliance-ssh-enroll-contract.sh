#!/usr/bin/env bash
# appliance-ssh-enroll-contract.sh - regression test for the OVA/Docker field bugs:
#
#   B1 engine.env had no ENGINE_ID (firstboot + docker entrypoint) -> every appliance ran
#      as the engine schema default kali-engine-01 (tailnet kali-engine-01, -01-1, ...).
#   B2 Debian cloud base sets PasswordAuthentication no -> default arparp login never
#      worked over SSH.
#   B3 the engine converges CP operator keys into the ENGINE user's home, not arparp's,
#      so `ssh -i <cp-key> arparp@<appliance>` was "Permission denied (publickey)".
#   B4 virt-customize copy-in leaked the build-host uid onto /etc, /usr and root-run
#      scripts (privilege escalation for the first extra local account; also makes
#      sshd reject the AuthorizedKeysCommand helper).
#   B5 kiosk pairing-code exchange ran a blocking `tailscale up` BEFORE printing the
#      token under a 40s subprocess timeout -> consumed code, no enroll POST.
#   B6 firstboot / docker `tailscale up` without --reset failed after the kiosk had
#      already set non-default prefs.
#
# Functional where it can be (stubs, sandboxed paths, a throwaway sshd -T), static
# otherwise. No root, no network, no systemd. Safe in ci/lint.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
ENR="${ROOT}/distro/enroll"
FIRSTBOOT_SH="${ENR}/firstboot/vacti-firstboot"
DOCKER_EP="${ROOT}/distro/golden-image/docker-entrypoint.sh"
ACTIVATE_SH="${ENR}/activate/vacti-activate"
DROPIN="${ENR}/ssh/10-vacti-appliance.conf"
KEYCMD="${ENR}/ssh/vacti-operator-keys"
BG="${ROOT}/distro/golden-image/build-golden.sh"

pass=0; fail=0
ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no()   { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
check(){ local d="$1"; shift; if "$@"; then ok "$d"; else no "$d"; fi; }
has()  { grep -Eq -e "$2" "$1" 2>/dev/null; }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

echo "== B2/B3: sshd drop-in =="
check "exists: distro/enroll/ssh/10-vacti-appliance.conf" test -f "$DROPIN"
check "exists: distro/enroll/ssh/vacti-operator-keys" test -f "$KEYCMD"
check "drop-in re-enables PasswordAuthentication" has "$DROPIN" '^PasswordAuthentication yes$'
check "drop-in scopes the key helper to arparp (Match User arparp)" has "$DROPIN" '^Match User arparp$'
check "drop-in AuthorizedKeysCommand points at the helper with %u" \
  has "$DROPIN" 'AuthorizedKeysCommand /usr/local/libexec/vacti-operator-keys %u$'
check "drop-in runs the helper as the engine user (least privilege)" \
  has "$DROPIN" 'AuthorizedKeysCommandUser vacti-engine$'
check "global directives precede the Match block" \
  bash -c 'awk "/^PasswordAuthentication/{p=NR} /^Match/{m=NR} END{exit !(p&&m&&p<m)}" "'"$DROPIN"'"'

SSHD="$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)"
if [[ -x "$SSHD" ]] && command -v ssh-keygen >/dev/null 2>&1; then
  mkdir -p "${TMPD}/sshd/d"
  ssh-keygen -q -t ed25519 -N '' -f "${TMPD}/sshd/hk" >/dev/null 2>&1
  cp "$DROPIN" "${TMPD}/sshd/d/10-vacti-appliance.conf"
  # Mirror the Debian cloud base: Include at the top, PasswordAuthentication no later.
  printf 'Include %s/sshd/d/*.conf\nHostKey %s/sshd/hk\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nX11Forwarding yes\n' \
    "$TMPD" "$TMPD" > "${TMPD}/sshd/sshd_config"
  check "sshd -t accepts the drop-in" "$SSHD" -t -f "${TMPD}/sshd/sshd_config"
  T_ARP="$("$SSHD" -T -f "${TMPD}/sshd/sshd_config" -C user=arparp,host=h,addr=192.0.2.1 2>/dev/null)"
  T_OTH="$("$SSHD" -T -f "${TMPD}/sshd/sshd_config" -C user=someone,host=h,addr=192.0.2.1 2>/dev/null)"
  check "effective: password auth ON despite base 'PasswordAuthentication no'" \
    grep -qi '^passwordauthentication yes' <<<"$T_ARP"
  check "effective: arparp gets the AuthorizedKeysCommand" \
    grep -qi '^authorizedkeyscommand /usr/local/libexec/vacti-operator-keys %u' <<<"$T_ARP"
  check "effective: other users do NOT get the key helper" \
    grep -qi '^authorizedkeyscommand none' <<<"$T_OTH"
  check "effective: Match does not swallow later main-config lines (X11Forwarding still applies)" \
    grep -qi '^x11forwarding yes' <<<"$T_OTH"
else
  echo "SKIP  sshd -t/-T functional checks (sshd/ssh-keygen unavailable)"
fi

echo "== B3: key helper emits ONLY the engine-managed block, validated =="
FAKEHOME="${TMPD}/home"; mkdir -p "${FAKEHOME}/.ssh"
cat > "${FAKEHOME}/.ssh/authorized_keys" <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOUTSIDEOUTSIDEOUTSIDEOUTSIDEOUTSIDE human-outside
# BEGIN vacti-operator-managed (do not edit)
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGOODGOODGOODGOODGOODGOODGOODGOODGOOD cp-operator
command="/bin/sh" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEVILEVILEVILEVILEVILEVILEVILEVILEVIL evil
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCrsaRSArsaRSA==
not-a-key at all
# END vacti-operator-managed
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAFTERAFTERAFTERAFTERAFTERAFTERAFTER human-after
EOF
mkdir -p "${TMPD}/bin"
# Stub getent/id so the helper resolves the fake home without touching /etc/passwd.
printf '#!/bin/sh\necho "eng:x:999:999::%s:/usr/sbin/nologin"\n' "$FAKEHOME" > "${TMPD}/bin/getent"
printf '#!/bin/sh\necho eng\n' > "${TMPD}/bin/id"
chmod +x "${TMPD}/bin/getent" "${TMPD}/bin/id"
OUT="$(PATH="${TMPD}/bin:${PATH}" sh "$KEYCMD" arparp)"
check "helper prints the managed cp-operator key" grep -q 'cp-operator' <<<"$OUT"
check "helper prints the managed bare ssh-rsa key" grep -q '^ssh-rsa AAAAB3' <<<"$OUT"
check "helper drops a key carrying command= options" bash -c '! grep -q evil <<<"$1"' _ "$OUT"
check "helper drops non-key garbage" bash -c '! grep -q "not-a-key" <<<"$1"' _ "$OUT"
check "helper ignores keys OUTSIDE the managed block" bash -c '! grep -Eq "human-(outside|after)" <<<"$1"' _ "$OUT"
check "helper prints exactly 2 lines" test "$(grep -c . <<<"$OUT")" -eq 2
rm -f "${FAKEHOME}/.ssh/authorized_keys"
OUT2="$(PATH="${TMPD}/bin:${PATH}" sh "$KEYCMD" arparp; echo "rc=$?")"
check "helper with no file prints nothing and exits 0" test "$OUT2" = "rc=0"

echo "== B2/B3/B4: golden build wiring =="
check "build-golden stages the sshd drop-in" has "$BG" 'ssh/10-vacti-appliance\.conf'
check "build-golden stages the key helper into /usr/local/libexec" has "$BG" '/usr/local/libexec/vacti-operator-keys'
check "provision pins helper ownership to root" has "$BG" 'chown root:root /usr/local/libexec/vacti-operator-keys'
check "provision re-owns the copy-in tree from the build uid" has "$BG" 'find /etc /usr /opt /boot -xdev'
check "ownership fix runs BEFORE the arparp account is created" \
  bash -c 'awk "/find \/etc \/usr \/opt \/boot -xdev/{f=NR} /useradd -m -s \/bin\/bash/{u=NR} END{exit !(f&&u&&f<u)}" "'"$BG"'"'

echo "== B1/B6: firstboot writes ENGINE_ID + joins with --reset (functional) =="
check "firstboot regenerates missing ssh host keys before starting sshd" \
  bash -c 'awk "/ssh-keygen -A/{k=NR} /systemctl enable --now ssh/{s=NR} END{exit !(k&&s&&k<s)}" "'"$FIRSTBOOT_SH"'"'
check "firstboot tailscale up uses --reset" has "$FIRSTBOOT_SH" 'tailscale up --reset '
SB="${TMPD}/fb"; mkdir -p "${SB}/etc" "${SB}/run" "${SB}/bin"
sed -e "s#/etc/vacti-engine#${SB}/etc#g" -e "s#/run/#${SB}/run/#g" "$FIRSTBOOT_SH" > "${SB}/firstboot"
printf 'tok-123\nhttps://cp.example\n' > "${SB}/etc/enroll.token"
# curl stub: write the enroll response the CP returns (token-bound engine_id) + 200.
cat > "${SB}/bin/curl" <<EOF
#!/bin/bash
out=""; while [[ \$# -gt 0 ]]; do [[ "\$1" == "-o" ]] && { out="\$2"; shift; }; shift; done
printf '%s' '{"producer":"P1","verifier":"V1","gatekeeper":"G1","engine_id":"lab-appliance-7","engineSharedSecret":"S1","headscale_preauth_key":"hk","headscale_login_server":"https://hs.example"}' > "\$out"
printf 200
EOF
printf '#!/bin/sh\nexit 0\n' > "${SB}/bin/systemctl"
printf '#!/bin/sh\nexit 0\n' > "${SB}/bin/shred"
printf '#!/bin/sh\nexit 0\n' > "${SB}/bin/ssh-keygen"
printf '#!/bin/sh\n[ "$1" = status ] && { echo "{}"; exit 0; }\necho "$@" >> "%s/ts-args"\n' "$SB" > "${SB}/bin/tailscale"
printf '#!/bin/sh\necho appliance\n' > "${SB}/bin/hostname"
chmod +x "${SB}/bin/"*
if PATH="${SB}/bin:${PATH}" VACTI_PROGRESS_LOG="${SB}/progress.log" bash "${SB}/firstboot" >"${SB}/out.log" 2>&1; then
  ok "firstboot sandbox run exits 0"
else
  no "firstboot sandbox run exits 0 (see log below)"; sed 's/^/    /' "${SB}/out.log"
fi
check "engine.env carries ENGINE_ID from the CP-bound engine_id" has "${SB}/etc/engine.env" '^ENGINE_ID=lab-appliance-7$'
check "engine.env still carries VACTI_TOKEN" has "${SB}/etc/engine.env" '^VACTI_TOKEN=P1$'
check "engine.env still carries the edge shared secret" has "${SB}/etc/engine.env" '^VACTI_ENGINE_SHARED_SECRET=S1$'
check "tailnet join used --reset" has "${SB}/ts-args" '(^| )--reset( |$)'
check "tailnet join hostname = CP-bound engine id (not the OS hostname)" has "${SB}/ts-args" '--hostname=lab-appliance-7( |$)'

echo "== B1/B6: docker entrypoint persists + exports ENGINE_ID =="
check "entrypoint persists ENGINE_ID into the state engine.env" has "$DOCKER_EP" "printf 'ENGINE_ID=%s"
check "entrypoint exports ENGINE_ID before exec" has "$DOCKER_EP" '^export ENGINE_ID$'
check "entrypoint tailscale up uses --reset" has "$DOCKER_EP" 'tailscale up --reset '

echo "== B5: kiosk exchange prints the token even when tailscale up hangs (functional) =="
check "ts_join is bounded (timeout + --timeout)" has "$ACTIVATE_SH" 'timeout [0-9]+ tailscale up .*--timeout='
KB="${TMPD}/kiosk"; mkdir -p "${KB}/bin"
cat > "${KB}/bin/curl" <<'EOF'
#!/bin/bash
out=""; while [[ $# -gt 0 ]]; do [[ "$1" == "-o" ]] && { out="$2"; shift; }; shift; done
printf '%s' '{"token":"FULL-TOKEN-XYZ","tsAuthKey":"tskey-abc"}' > "$out"
printf 200
EOF
printf '#!/bin/sh\n[ "$1" = status ] && exit 1\n[ "$1" = ip ] && exit 1\nsleep 30\n' > "${KB}/bin/tailscale"
chmod +x "${KB}/bin/"*
# Pull just the functions resolve_exchange needs out of the shipped script.
{
  echo 'log() { :; }'
  for fn in resolve_exchange ts_join ts_connected ts_join_auto; do
    sed -n "/^${fn}() {/,/^}/p" "$ACTIVATE_SH"
  done
} > "${KB}/fns.sh"
start=$(date +%s)
TOK="$(PATH="${KB}/bin:${PATH}" timeout 20 bash -c '. "$1"; resolve_exchange https://cp.example ABCD-EFGH' _ "${KB}/fns.sh")"
el=$(( $(date +%s) - start ))
check "exchange returns the full token" test "$TOK" = "FULL-TOKEN-XYZ"
check "exchange returns promptly (<10s) while tailscale up is still hanging (took ${el}s)" test "$el" -lt 10
pkill -f "${KB}/bin/tailscale" 2>/dev/null || true

echo
echo "appliance-ssh-enroll-contract: ${pass} passed, ${fail} failed"
[[ $fail -eq 0 ]]
