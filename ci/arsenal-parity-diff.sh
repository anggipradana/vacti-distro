#!/usr/bin/env bash
# arsenal-parity-diff.sh - the gate half of the cross-arch install-parity check. It
# ingests the two per-arch reports produced by arsenal-parity.sh (amd64 + arm64) and
# makes the hard pass/fail decision on cross-ARCHITECTURE PARITY, which is what the
# operator actually asked about ("are the required tools the same on every arch?").
#
# DECISION (judgment confirmed via Jev: gate_semantics=divergence_only p=0.99):
#   - GATE (grant/core) DIVERGENCE  -> a required package installable on one arch but
#     NOT the other. This is a real arch-parity defect: an image would ship with a
#     tool on one arch and silently without it on the other. => HARD FAIL.
#   - GATE (grant/core) BOTH-ABSENT -> a required package not apt-installable on either
#     arch (Go tools via `go install`, Kali-only tools unsatisfiable under the pin).
#     Arch-consistent, covered by runtime self-heal. => LOUD, NON-FATAL delta (named).
#   - OPTIONAL (verticals/ctf) anything -> allowed to be arch-divergent. => reported
#     only, never fatal.
#
# Runs on an ordinary host (no container needed): pure JSON comparison with jq.
#
# EXIT: 0 = no grant/core arch divergence. 1 = at least one grant/core package
#       diverges across arches (named), or a hard error (a report is missing/garbled).
#
# Usage:
#   arsenal-parity-diff.sh <amd64.json> <arm64.json> <out-summary.md>
set -uo pipefail

AMD="${1:?amd64 report path required}"
ARM="${2:?arm64 report path required}"
OUT_MD="${3:?output summary md path required}"

log() { echo "[parity-diff] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"
[ -f "$AMD" ] || die "amd64 report not found: $AMD"
[ -f "$ARM" ] || die "arm64 report not found: $ARM"
jq -e . "$AMD" >/dev/null 2>&1 || die "amd64 report is not valid JSON: $AMD"
jq -e . "$ARM" >/dev/null 2>&1 || die "arm64 report is not valid JSON: $ARM"

# Join the two reports by package name and emit one TSV row per package:
#   package \t class \t amd_installable \t arm_installable \t verdict
# verdict: DIVERGE (gate only) | BOTH_ABSENT | OK | OPT_DIVERGE | OPT_ABSENT
JOIN="$(jq -rn \
  --slurpfile a "$AMD" \
  --slurpfile b "$ARM" '
  ($a[0] | map({ (.package): . }) | add) as $am
  | ($b[0] | map({ (.package): . }) | add) as $ar
  | (($a[0] | map(.package)) + ($b[0] | map(.package)) | unique) as $pkgs
  | $pkgs[]
  | . as $p
  | ($am[$p] // null) as $x
  | ($ar[$p] // null) as $y
  | ($x.class // $y.class // "gate") as $cls
  | ((($x.installable) // false)) as $ai
  | ((($y.installable) // false)) as $bi
  | ($cls == "gate") as $isgate
  | (
      if ($ai and $bi) then "OK"
      elif ($ai == $bi) then (if $isgate then "BOTH_ABSENT" else "OPT_ABSENT" end)
      else (if $isgate then "DIVERGE" else "OPT_DIVERGE" end)
      end
    ) as $verdict
  | [ $p, $cls, ($ai|tostring), ($bi|tostring), $verdict ]
  | @tsv
')" || die "could not join the two reports"

diverge=0
both_absent=0
opt_notes=0
tmp="$(mktemp)"
printf '%s\n' "$JOIN" >"$tmp"

while IFS=$'\t' read -r pkg _cls ai bi verdict; do
  [ -z "$pkg" ] && continue
  case "$verdict" in
    DIVERGE)      diverge=$((diverge + 1));     log "GATE DIVERGENCE: $pkg (amd64=$ai arm64=$bi)";;
    BOTH_ABSENT)  both_absent=$((both_absent + 1));;
    OPT_DIVERGE|OPT_ABSENT) opt_notes=$((opt_notes + 1));;
  esac
done <"$tmp"

mkdir -p "$(dirname "$OUT_MD")"
{
  echo "### Arsenal cross-arch parity verdict"
  echo
  echo "- grant/core arch DIVERGENCE (installable on one arch, not the other): ${diverge}"
  echo "- grant/core absent on BOTH arches (runtime self-heal, non-fatal): ${both_absent}"
  echo "- verticals/ctf arch-divergent or absent (allowed): ${opt_notes}"
  echo
  if [ "$diverge" -gt 0 ]; then
    echo "#### GATE DIVERGENCE (FAIL)"
    echo
    echo "| package | class | amd64 | arm64 |"
    echo "| --- | --- | --- | --- |"
    awk -F'\t' '$5=="DIVERGE" {printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4}' "$tmp"
    echo
  fi
  if [ "$both_absent" -gt 0 ]; then
    echo "#### Required tools NOT baked via apt on either arch (runtime self-heal)"
    echo
    echo "These grant/core packages have no usable apt install on Debian trixie + pinned Kali on EITHER arch; the engine provisions them at runtime (go install / binary fetch). Arch-consistent, so not a parity failure - listed so the operator knows which required tools are runtime-provisioned rather than baked."
    echo
    echo "| package | class |"
    echo "| --- | --- |"
    awk -F'\t' '$5=="BOTH_ABSENT" {printf "| %s | %s |\n", $1, $2}' "$tmp"
    echo
  fi
  if [ "$opt_notes" -gt 0 ]; then
    echo "#### Optional (verticals/ctf) arch deltas (allowed)"
    echo
    echo "| package | class | amd64 | arm64 |"
    echo "| --- | --- | --- | --- |"
    awk -F'\t' '$5=="OPT_DIVERGE" || $5=="OPT_ABSENT" {printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4}' "$tmp"
    echo
  fi
  if [ "$diverge" -eq 0 ]; then
    echo "PASS: every grant/core package has identical install availability on amd64 and arm64."
  fi
} >"$OUT_MD"

rm -f "$tmp"
log "wrote $OUT_MD (diverge=$diverge both_absent=$both_absent opt_notes=$opt_notes)"
if [ "$diverge" -gt 0 ]; then
  die "$diverge grant/core package(s) diverge across arches - see report"
fi
log "OK: no grant/core cross-arch divergence"
exit 0
