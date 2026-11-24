#!/usr/bin/env bash
# .ci/check-forbidden.sh
#
# Pre-publish forbidden-pattern guard for RELEASE-NOTE CONTENT.
#
# Scans a "release-note corpus" (CHANGELOG section, commit-range messages, the
# GitHub Release body, packaging/arsenal-manifest.json, and an optional rendered
# release-drafter output) for the patterns in .ci/forbidden-patterns.txt. Any
# match is a HARD FAIL (exit 2) unless it is waived by a valid override.
#
# This is deliberately NARROWER and DIFFERENT from secret-scan.yml (gitleaks /
# trufflehog over git history): this guard protects the human-written release
# surface (naming-discipline + client-scrub) that history scanners do not model.
#
# ---------------------------------------------------------------------------
# Override contract (operator-only in practice; two keys required):
#   1. An entry in .ci/forbidden-overrides.json:
#        { "sha256": "<64-hex>", "justification": "<plaintext>",
#          "patterns": ["<regex>", ...]  // or "*" for any pattern
#          , "expires": "YYYY-MM-DD"      // optional
#        }
#      The guard recomputes sha256(justification) and REJECTS the entry unless it
#      equals the sha256 field - so the entry cannot be forged without the exact
#      justification text.
#   2. A footer token in the commit range OR PR body (FORBIDDEN_PR_BODY env):
#        [allow-forbidden: <sha256>]
#      referencing that same entry.
#   A match is waived only when BOTH exist and the override's "patterns" cover the
#   matched pattern (or is "*") and the override is not expired.
#
# Exit codes: 0 = clean (or all matches waived), 2 = unwaived match(es),
#             3 = usage / config error.
#
# Portable bash + grep -E + python3 (for JSON + sha256; both are present on every
# GitHub-hosted runner and on the engine/distro boxes). No jq dependency.
set -uo pipefail

REPO_ROOT="${FORBIDDEN_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PATTERNS_FILE="${FORBIDDEN_PATTERNS_FILE:-$REPO_ROOT/.ci/forbidden-patterns.txt}"
OVERRIDES_FILE="${FORBIDDEN_OVERRIDES_FILE:-$REPO_ROOT/.ci/forbidden-overrides.json}"

# Release-note corpus inputs (all optional; the guard scans whichever exist):
CHANGELOG="${FORBIDDEN_CHANGELOG:-$REPO_ROOT/CHANGELOG.md}"
MANIFEST="${FORBIDDEN_MANIFEST:-$REPO_ROOT/packaging/arsenal-manifest.json}"
DRAFTER_RENDER="${FORBIDDEN_DRAFTER_RENDER:-}"   # path to a rendered release-drafter body, if produced
RELEASE_BODY="${FORBIDDEN_RELEASE_BODY:-}"       # path to the GH release body text, if produced
GIT_RANGE="${FORBIDDEN_GIT_RANGE:-}"             # e.g. v0.2.480..HEAD ; empty => auto (last tag..HEAD)
PR_BODY="${FORBIDDEN_PR_BODY:-}"                 # PR body text (for [allow-forbidden:] tokens)

err()  { printf '%s\n' "$*" >&2; }
note() { printf '%s\n' "$*"; }

[ -f "$PATTERNS_FILE" ] || { err "FATAL: patterns file not found: $PATTERNS_FILE"; exit 3; }
command -v python3 >/dev/null 2>&1 || { err "FATAL: python3 required"; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CORPUS_DIR="$WORK/corpus"; mkdir -p "$CORPUS_DIR"

# --- 1. Assemble the release-note corpus into named files -------------------
# CHANGELOG: only the [Unreleased] block + the top (newest) version section, since
# that is what a release publishes; older sections are already-shipped history.
if [ -f "$CHANGELOG" ]; then
  awk '
    /^## / { sec++ }
    sec <= 2 { print }        # header preamble (sec 0), [Unreleased] (sec 1), newest (sec 2)
    sec > 2 { exit }
  ' "$CHANGELOG" > "$CORPUS_DIR/CHANGELOG.md" 2>/dev/null || cp "$CHANGELOG" "$CORPUS_DIR/CHANGELOG.md"
fi

# Commit-range messages since the last tag (the --generate-notes / auto-notes source).
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  range="$GIT_RANGE"
  if [ -z "$range" ]; then
    last_tag="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
    if [ -n "$last_tag" ]; then range="${last_tag}..HEAD"; else range="HEAD"; fi
  fi
  git -C "$REPO_ROOT" log --no-merges --format='%H%n%s%n%b' "$range" 2>/dev/null \
    > "$CORPUS_DIR/commit-range.txt" || true
fi

[ -n "$RELEASE_BODY" ]   && [ -f "$RELEASE_BODY" ]   && cp "$RELEASE_BODY"   "$CORPUS_DIR/release-body.txt"
[ -n "$DRAFTER_RENDER" ] && [ -f "$DRAFTER_RENDER" ] && cp "$DRAFTER_RENDER" "$CORPUS_DIR/release-drafter.txt"
[ -f "$MANIFEST" ]       && cp "$MANIFEST" "$CORPUS_DIR/arsenal-manifest.json"

if [ -z "$(ls -A "$CORPUS_DIR" 2>/dev/null)" ]; then
  note "forbidden-guard: no release-note corpus found to scan (nothing to do)."
  exit 0
fi

# --- 2. Load patterns ------------------------------------------------------
# Each entry: "<flags>\t<pattern>" where flags is "" or "i".
mapfile -t RAW_PATTERNS < <(grep -vE '^\s*(#|$)' "$PATTERNS_FILE" || true)
if [ "${#RAW_PATTERNS[@]}" -eq 0 ]; then
  note "forbidden-guard: patterns file has no active patterns; nothing to enforce."
  exit 0
fi

# --- 3. Scan ----------------------------------------------------------------
MATCH_LOG="$WORK/matches.tsv"   # pattern<TAB>file<TAB>lineno<TAB>linetext
: > "$MATCH_LOG"
for raw in "${RAW_PATTERNS[@]}"; do
  pat="$raw"; gflags=(-nE)
  if [[ "$pat" == '(?i)'* ]]; then pat="${pat#'(?i)'}"; gflags=(-niE); fi
  while IFS= read -r corpus_file; do
    [ -f "$corpus_file" ] || continue
    # grep: -n lineno. Redact nothing here; the corpus is already release-note text
    # the operator is about to publish, and the whole point is to show WHAT leaked.
    while IFS= read -r hit; do
      ln="${hit%%:*}"; txt="${hit#*:}"
      printf '%s\t%s\t%s\t%s\n' "$raw" "$(basename "$corpus_file")" "$ln" "$txt" >> "$MATCH_LOG"
    done < <(grep "${gflags[@]}" -- "$pat" "$corpus_file" 2>/dev/null || true)
  done < <(find "$CORPUS_DIR" -type f)
done

if [ ! -s "$MATCH_LOG" ]; then
  note "forbidden-guard: OK - no forbidden patterns in the release-note corpus."
  exit 0
fi

# --- 4. Collect referenced override hashes ---------------------------------
# From commit-range footers + PR body: [allow-forbidden: <64-hex>]
REFERENCED="$WORK/referenced.txt"; : > "$REFERENCED"
{
  [ -f "$CORPUS_DIR/commit-range.txt" ] && cat "$CORPUS_DIR/commit-range.txt"
  [ -n "$PR_BODY" ] && printf '%s\n' "$PR_BODY"
} 2>/dev/null \
  | grep -oiE '\[allow-forbidden:[[:space:]]*[0-9a-f]{64}\]' \
  | grep -oiE '[0-9a-f]{64}' | tr 'A-F' 'a-f' | sort -u > "$REFERENCED" || true

# --- 5. Decide waived vs. unwaived (python3: JSON + sha256 + regex cover) ---
VERDICT="$WORK/verdict.txt"
python3 -I - "$OVERRIDES_FILE" "$MATCH_LOG" "$REFERENCED" > "$VERDICT" <<'PY'
import hashlib, json, re, sys, datetime
ovr_path, match_path, ref_path = sys.argv[1], sys.argv[2], sys.argv[3]

overrides = []
try:
    with open(ovr_path, encoding="utf-8") as f:
        overrides = json.load(f).get("overrides", [])
except FileNotFoundError:
    overrides = []
except Exception as e:
    print("CONFIG\toverrides JSON invalid: %s" % e); sys.exit(0)

referenced = set()
try:
    with open(ref_path, encoding="utf-8") as f:
        referenced = {l.strip().lower() for l in f if l.strip()}
except FileNotFoundError:
    pass

today = datetime.date.today()
# Build the set of VALID, referenced overrides -> map pattern -> True ("*" => all)
valid = []  # list of (patterns_list_or_star, sha)
for o in overrides:
    sha = str(o.get("sha256", "")).lower().strip()
    just = o.get("justification")
    if not sha or just is None:
        continue
    if sha not in referenced:
        continue  # not invoked this run
    if hashlib.sha256(str(just).encode("utf-8")).hexdigest() != sha:
        print("REJECT\toverride %s: sha256(justification) mismatch (forged/edited)" % sha[:12])
        continue
    exp = o.get("expires")
    if exp:
        try:
            if datetime.date.fromisoformat(str(exp)) < today:
                print("REJECT\toverride %s: expired %s" % (sha[:12], exp)); continue
        except ValueError:
            print("REJECT\toverride %s: bad expires date %r" % (sha[:12], exp)); continue
    pats = o.get("patterns", "*")
    valid.append((pats, sha))

def waived(pattern):
    for pats, sha in valid:
        if pats == "*" or (isinstance(pats, list) and (pattern in pats or "*" in pats)):
            return sha
    return None

unwaived = 0
with open(match_path, encoding="utf-8") as f:
    for line in f:
        parts = line.rstrip("\n").split("\t", 3)
        if len(parts) < 4:
            continue
        pattern, fname, lineno, text = parts
        sha = waived(pattern)
        if sha:
            print("WAIVED\t%s\t%s\t%s\t%s\t%s" % (sha[:12], pattern, fname, lineno, text))
        else:
            unwaived += 1
            print("FAIL\t%s\t%s\t%s\t%s" % (pattern, fname, lineno, text))
print("SUMMARY\tunwaived=%d" % unwaived)
PY

# --- 6. Report + exit -------------------------------------------------------
unwaived="$(grep '^SUMMARY' "$VERDICT" | sed -E 's/.*unwaived=//')"
unwaived="${unwaived:-0}"

if grep -qE '^(REJECT|CONFIG)' "$VERDICT"; then
  err "::group::forbidden-guard override problems"
  grep -E '^(REJECT|CONFIG)' "$VERDICT" | sed -E 's/^(REJECT|CONFIG)[[:space:]]+/  [\1] /' >&2
  err "::endgroup::"
fi

if grep -q '^WAIVED' "$VERDICT"; then
  note "forbidden-guard: the following matches are WAIVED by a valid override:"
  grep '^WAIVED' "$VERDICT" \
    | awk -F'\t' '{printf "  [waived by %s] %s:%s  pattern=%s\n      %s\n",$2,$4,$5,$3,$6}'
fi

if [ "$unwaived" -gt 0 ]; then
  err ""
  err "forbidden-guard: FAIL - $unwaived forbidden pattern match(es) in release-note content."
  err "Each line below is: <corpus-file>:<line>  pattern=<regex>"
  grep '^FAIL' "$VERDICT" \
    | awk -F'\t' '{printf "  ::error file=%s,line=%s::forbidden pattern [%s] -> %s\n",$3,$4,$2,$5}' >&2
  grep '^FAIL' "$VERDICT" \
    | awk -F'\t' '{printf "  %s:%s  pattern=%s\n      %s\n",$3,$4,$2,$5}' >&2
  err ""
  err "To publish anyway (operator only): scrub the content, OR add a justified entry to"
  err ".ci/forbidden-overrides.json and reference it with a [allow-forbidden: <sha256>] footer."
  exit 2
fi

note "forbidden-guard: OK - all matches waived by valid overrides."
exit 0
