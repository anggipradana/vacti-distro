#!/usr/bin/env bash
# arsenal-parity.sh - the per-arch half of the cross-arch install-parity gate. It
# proves, for the ONE arch it runs on, which apt packages the engine arsenal
# manifest declares are actually installable on the real image base (Debian 13
# "trixie" + the pinned Kali rolling source). Meant to run INSIDE a
# debian:trixie-slim container on each arch runner (amd64 on ubuntu-latest, arm64
# on ubuntu-24.04-arm) so the apt resolution is the TARGET base's resolution,
# native per-arch, no QEMU and no Ubuntu-noble skew from the host runner.
#
# This script is DATA COLLECTION only: it records installable yes/no (and whether an
# apt candidate even exists) for every manifest package and writes a per-arch JSON +
# markdown report. It does NOT by itself fail the build on a missing package, because
# the operator's question - and the gate's name - is about cross-ARCHITECTURE PARITY,
# which can only be decided by comparing the two arch reports. That comparison, and
# the hard pass/fail, live in arsenal-parity-diff.sh.
#
# WHY NOT "fail if any grant/core package is uninstallable on this arch": empirically
# a handful of grant/core packages have NO apt package at all on EITHER arch (Go
# tools like gau / interactsh-client installed at runtime via `go install`, and a few
# Kali-only tools unsatisfiable under the priority-100 pin). Those are arch-CONSISTENT
# (absent on both) and covered by the engine's runtime self-heal, so they are a
# runtime-self-heal fact, not an arch-parity defect. A per-arch "either arch
# uninstallable" fail would be permanently red and un-mergeable without editing the
# engine-generated manifest (which this repo must not touch). The parity gate
# therefore fails on arch DIVERGENCE (installable on one arch but not the other) and
# reports both-arch-absent required packages as a loud, non-fatal delta. (Judgment
# confirmed via Jev: gate_semantics=divergence_only p=0.99; report_absent loudly 0.95.)
#
# Classification per package:
#   gate     = apt.grant U apt.core          (required arsenal)
#   optional = apt.verticals.* U apt.ctf     (allowed to be arch-divergent)
#
# EXIT: 0 on success (report written). 1 only on a hard error (apt sources could not
#       be prepared, or the manifest could not be enumerated).
#
# Usage:
#   arsenal-parity.sh <arch-label> <manifest.json> <kali-repo-dir> <out.json>
set -uo pipefail

ARCH="${1:?arch label required (amd64|arm64)}"
MANIFEST="${2:?manifest path required}"
KALI_DIR="${3:?kali-repo dir required}"
OUT_JSON="${4:?output json path required}"
OUT_MD="${OUT_JSON%.json}.md"

export DEBIAN_FRONTEND=noninteractive

log() { echo "[parity][$ARCH] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
[ -d "$KALI_DIR" ] || die "kali-repo dir not found: $KALI_DIR"

# --- toolchain: jq + the apt source prerequisites ----------------------------
log "installing parity prerequisites (ca-certificates curl gnupg jq)"
apt-get update -qq >/dev/null 2>&1 || die "initial apt-get update failed"
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg jq >/dev/null 2>&1 \
  || die "could not install parity prerequisites"

# --- the pinned Kali source, from the EXISTING repo files --------------------
log "adding the pinned Kali source (same files the image build uses)"
curl -fsSL https://archive.kali.org/archive-key.asc \
  | gpg --dearmor -o /usr/share/keyrings/kali-archive-keyring.gpg 2>/dev/null \
  || die "could not fetch/dearmor the Kali archive key"
install -m0644 "${KALI_DIR}/kali.list"     /etc/apt/sources.list.d/kali.list
install -m0644 "${KALI_DIR}/kali-pin.pref" /etc/apt/preferences.d/kali-pin
apt-get update -qq >/dev/null 2>&1 || die "apt-get update after adding Kali failed"

# --- flat package list with gate/optional class ------------------------------
FLAT="$(jq -r '
  .apt as $a
  | ([$a.grant[], $a.core[]] | unique) as $gate
  | ([$a.verticals[][], $a.ctf[]] | unique) as $optall
  | (($gate + $optall) | unique) as $all
  | $all[]
  | [ ., (if ($gate | index(.)) != null then "gate" else "optional" end) ]
  | @tsv
' "$MANIFEST")" || die "could not enumerate the manifest apt sets"

[ -n "$FLAT" ] || die "manifest enumeration produced an empty package list"

# --- simulate each install ---------------------------------------------------
RESULTS="$(mktemp)"
errf="$(mktemp)"
total=0
inst=0
absent=0
while IFS=$'\t' read -r pkg cls; do
  [ -z "$pkg" ] && continue
  total=$((total + 1))
  # One apt call per package (the required per-package --simulate). has_apt_candidate
  # is derived from the failure reason rather than a second apt-cache call: an
  # installable package obviously has a candidate; a failure whose reason is "unable
  # to locate" / "no installation candidate" has none; any other failure (a broken
  # dependency, a held package, a conflict) means a candidate exists but is unsatisfiable.
  if apt-get install -y --no-install-recommends --simulate "$pkg" >/dev/null 2>"$errf"; then
    printf '%s\t%s\ttrue\ttrue\t\n' "$pkg" "$cls" >>"$RESULTS"
    inst=$((inst + 1))
  else
    reason="$(grep -hoE 'Unable to locate package[^\n]*|has no installation candidate|but it is not (installable|going to be installed)|Depends:[^\n]*but it is not (installable|going to be installed)|Conflicts:[^\n]*|held broken packages' "$errf" 2>/dev/null | head -1)"
    [ -z "$reason" ] && reason="$(tr -d '\r' <"$errf" | grep -vE '^[[:space:]]*$' | tail -1)"
    reason="$(printf '%s' "$reason" | tr '\t\n' '  ' | cut -c1-240)"
    [ -z "$reason" ] && reason="apt-get --simulate returned non-zero"
    if printf '%s' "$reason" | grep -qE 'Unable to locate package|has no installation candidate'; then
      has_cand="false"
    else
      has_cand="true"
    fi
    printf '%s\t%s\tfalse\t%s\t%s\n' "$pkg" "$cls" "$has_cand" "$reason" >>"$RESULTS"
    absent=$((absent + 1))
    log "miss: $pkg ($cls, candidate=$has_cand) - $reason"
  fi
done <<<"$FLAT"
rm -f "$errf"

# --- JSON report: [{package, arch, class, installable, has_apt_candidate, reason_if_not}]
mkdir -p "$(dirname "$OUT_JSON")"
jq -R -s --arg arch "$ARCH" '
  split("\n")
  | map(select(length > 0))
  | map(split("\t"))
  | map({
      package: .[0],
      arch: $arch,
      class: .[1],
      installable: (.[2] == "true"),
      has_apt_candidate: (.[3] == "true"),
      reason_if_not: (if .[2] == "true" then null else (.[4] // "") end)
    })
' "$RESULTS" >"$OUT_JSON" || die "could not write JSON report"

# --- markdown summary --------------------------------------------------------
{
  echo "### Arsenal parity (data) - ${ARCH}"
  echo
  echo "- base: Debian trixie + pinned Kali rolling"
  echo "- packages simulated: ${total}"
  echo "- installable: ${inst}"
  echo "- not installable on ${ARCH}: ${absent}"
  echo
  if [ "$absent" -gt 0 ]; then
    echo "| package | class | apt candidate | reason |"
    echo "| --- | --- | --- | --- |"
    awk -F'\t' '$3=="false" {printf "| %s | %s | %s | %s |\n", $1, $2, $4, $5}' "$RESULTS"
    echo
  else
    echo "All ${total} packages installable on ${ARCH}."
  fi
} >"$OUT_MD"

rm -f "$RESULTS"
log "wrote $OUT_JSON and $OUT_MD (installable=$inst absent=$absent total=$total)"
exit 0
