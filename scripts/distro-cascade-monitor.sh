#!/usr/bin/env bash
# distro-cascade-monitor.sh
# -----------------------------------------------------------------------------
# Polls GitHub Actions for anggipradana/vacti-distro and alerts the operator on
# Telegram when the distro cascade pipeline misbehaves. Designed to run every
# 10 min from a systemd user timer (distro-cascade-monitor.timer).
#
# WATCHED WORKFLOWS (by workflow FILE, the stable key; display name in parens):
#   build-arm64.yml        (build-images-arm64)  ARM64 OVA
#   build-docker.yml       (build-docker)        GHCR multi-arch image
#   build.yml              (build-images)        AMD64 OVA
#   watch-engine-apt.yml   (watch-engine-apt)    scheduled apt pool sweep
#   publish-images-hf.yml  (publish-images-hf)   Hugging Face publish
#
# ALERT CONDITIONS
#   1. FAILURE   - newest completed run concluded failure/timed_out/startup_failure
#                  -> run URL + name + duration + failed job/step.
#   2. QUEUED    - a run sat queued/waiting >30min without starting.
#   3. ESCALATION- the two newest completed runs both failed (consecutive).
#   4. RECOVERY  - newest completed run SUCCEEDED and the prior one had failed.
#
# Conclusions are computed from the API each run; the state file only dedupes
# which run IDs have already been alerted, so the monitor is resilient to being
# down for a while (it re-derives the real sequence from GitHub, not from state).
#
# AUTH: uses ~/.vacti-ci/gh_ci_token if present (read-only CI token), else falls
#       back to the logged-in `gh` session.
#
# STATE: ~/.vacti-ci/distro-monitor.state.json
#
# USAGE:
#   distro-cascade-monitor.sh [--dry-run] [--verbose]
#     --dry-run  print what WOULD be sent to Telegram; send nothing; no state write.
#     --verbose  extra diagnostic output to stderr.
# -----------------------------------------------------------------------------
set -uo pipefail

# --- config ------------------------------------------------------------------
REPO="anggipradana/vacti-distro"
CI_TOKEN_FILE="${HOME}/.vacti-ci/gh_ci_token"
TG_ENV_FILE="/home/vacti/.claude/channels/telegram/.env"
TG_CHAT_ID="619847037"
STATE_FILE="${HOME}/.vacti-ci/distro-monitor.state.json"
LOCK_FILE="${HOME}/.vacti-ci/distro-monitor.lock"

# workflow FILE basenames to watch (order = report order)
WORKFLOWS=(build-arm64.yml build-docker.yml build.yml watch-engine-apt.yml publish-images-hf.yml)

QUEUED_THRESHOLD_SECS=$((30 * 60))     # queued-without-starting alert threshold
RUNS_PER_WF=15                         # how many recent runs to inspect per workflow
DEDUP_KEEP=25                          # how many alerted run IDs to retain per bucket

DRY_RUN=0
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --verbose|-v) VERBOSE=1 ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

log()  { echo "[distro-monitor] $*" >&2; }
vlog() { [ "$VERBOSE" = 1 ] && echo "[distro-monitor][v] $*" >&2 || true; }

command -v jq   >/dev/null 2>&1 || { log "FATAL: jq not found";   exit 3; }
command -v curl >/dev/null 2>&1 || { log "FATAL: curl not found"; exit 3; }
command -v gh   >/dev/null 2>&1 || { log "FATAL: gh not found";   exit 3; }

# --- single-instance lock (never block the timer; just skip if overlapping) --
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another instance is running; skipping this poll"
  exit 0
fi

# --- auth --------------------------------------------------------------------
if [ -r "$CI_TOKEN_FILE" ]; then
  GH_TOKEN="$(tr -d '[:space:]' < "$CI_TOKEN_FILE")"
  export GH_TOKEN
  vlog "using CI token from $CI_TOKEN_FILE"
else
  unset GH_TOKEN GITHUB_TOKEN 2>/dev/null || true
  vlog "no CI token file; relying on logged-in gh session"
fi

# gh api wrapper (returns empty + nonzero on failure, never aborts the script)
gh_api() { gh api -H "Accept: application/vnd.github+json" "$@" 2>/dev/null; }

# --- Telegram ----------------------------------------------------------------
TG_BOT_TOKEN=""
if [ -r "$TG_ENV_FILE" ]; then
  TG_BOT_TOKEN="$(grep -E '^TELEGRAM_BOT_TOKEN=' "$TG_ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"'"'"'[:space:]')"
fi

# escape dynamic text for Telegram legacy Markdown (parse_mode=Markdown)
md_escape() { printf '%s' "$1" | sed -e 's/[][_*`]/\\&/g'; }

# send_telegram <text>  (respects --dry-run)
send_telegram() {
  local text="$1"
  if [ "$DRY_RUN" = 1 ]; then
    echo "----- WOULD SEND TO TELEGRAM (chat ${TG_CHAT_ID}) -----"
    echo "$text"
    echo "-------------------------------------------------------"
    return 0
  fi
  if [ -z "$TG_BOT_TOKEN" ]; then
    log "ERROR: no TELEGRAM_BOT_TOKEN available; cannot send alert"
    return 1
  fi
  local http
  http="$(curl -fsS --max-time 30 -o /dev/null -w '%{http_code}' \
      "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "parse_mode=Markdown" \
      --data-urlencode "disable_web_page_preview=true" \
      --data-urlencode "text=${text}" 2>/dev/null || true)"
  if [ "$http" = "200" ]; then
    vlog "telegram send ok"
    return 0
  fi
  log "telegram send FAILED (http=${http:-none})"
  return 1
}

# --- state helpers -----------------------------------------------------------
STATE='{}'
if [ -r "$STATE_FILE" ]; then
  STATE="$(cat "$STATE_FILE" 2>/dev/null)"
  echo "$STATE" | jq -e . >/dev/null 2>&1 || STATE='{}'
fi

# was this run id already alerted for <wf> in <bucket>?
already_alerted() { # wf bucket runid
  echo "$STATE" | jq -e --arg wf "$1" --arg b "$2" --arg id "$3" \
    '((.workflows[$wf][$b] // []) | map(tostring) | index($id)) != null' >/dev/null 2>&1
}

# record run id as alerted for <wf> in <bucket> (kept bounded)
mark_alerted() { # wf bucket runid
  STATE="$(echo "$STATE" | jq --arg wf "$1" --arg b "$2" --arg id "$3" --argjson keep "$DEDUP_KEEP" '
    .workflows[$wf][$b] = (((.workflows[$wf][$b] // []) + [($id|tonumber)]) | unique_by(.) | sort | .[(- $keep):])
  ')"
}

# --- time / formatting helpers ----------------------------------------------
to_epoch() { date -u -d "$1" +%s 2>/dev/null || echo 0; }

fmt_duration() { # start_iso end_iso
  local s e d
  s="$(to_epoch "$1")"; e="$(to_epoch "$2")"
  d=$((e - s))
  [ "$d" -lt 0 ] && d=0
  printf '%dh %dm %ds' $((d/3600)) $(((d%3600)/60)) $((d%60))
}

# --- failed job/step for a run ----------------------------------------------
failed_job_reason() { # runid  -> "job: X / step: Y"
  local id="$1" jobs jobname stepname
  jobs="$(gh_api "repos/${REPO}/actions/runs/${id}/jobs?per_page=50")"
  [ -z "$jobs" ] && { echo "unknown (jobs API unavailable)"; return; }
  jobname="$(echo "$jobs" | jq -r '
    [.jobs[]? | select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="startup_failure") | .name] | .[0] // ""')"
  stepname="$(echo "$jobs" | jq -r '
    [.jobs[]? | select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="startup_failure")
             | .steps[]? | select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="startup_failure") | .name] | .[0] // ""')"
  if [ -n "$jobname" ] && [ -n "$stepname" ]; then
    echo "job: ${jobname} / step: ${stepname}"
  elif [ -n "$jobname" ]; then
    echo "job: ${jobname}"
  else
    echo "unknown (no failed job reported)"
  fi
}

# --- main loop ---------------------------------------------------------------
NOW_EPOCH="$(date -u +%s)"
FAIL_SET=(failure timed_out startup_failure)
is_fail() { case "$1" in failure|timed_out|startup_failure) return 0 ;; *) return 1 ;; esac; }

ALERTS_SENT=0

for wf in "${WORKFLOWS[@]}"; do
  vlog "== workflow ${wf} =="
  runs="$(gh_api "repos/${REPO}/actions/workflows/${wf}/runs?per_page=${RUNS_PER_WF}")"
  if [ -z "$runs" ] || ! echo "$runs" | jq -e '.workflow_runs' >/dev/null 2>&1; then
    log "WARN: could not fetch runs for ${wf}; skipping"
    continue
  fi
  wf_name="$(echo "$runs" | jq -r '.workflow_runs[0].name // ""')"
  [ -z "$wf_name" ] && wf_name="$wf"

  # ---- 1 & 2: queued-too-long check (any not-yet-started run) ----
  while IFS=$'\t' read -r qid qcreated qurl; do
    [ -z "$qid" ] && continue
    qage=$(( NOW_EPOCH - $(to_epoch "$qcreated") ))
    if [ "$qage" -gt "$QUEUED_THRESHOLD_SECS" ]; then
      if already_alerted "$wf" "queued" "$qid"; then
        vlog "queued ${qid} already alerted"
      else
        mins=$(( qage / 60 ))
        msg="$(printf '%s\n%s\n%s\n%s' \
          "⏳ *Distro CI: run STUCK IN QUEUE*" \
          "Workflow: $(md_escape "$wf_name")  (\`$(md_escape "$wf")\`)" \
          "Queued for ${mins} min without starting." \
          "Run: $(md_escape "$qurl")")"
        if send_telegram "$msg"; then mark_alerted "$wf" "queued" "$qid"; ALERTS_SENT=$((ALERTS_SENT+1)); fi
      fi
    fi
  done < <(echo "$runs" | jq -r '
    .workflow_runs[] | select(.status=="queued" or .status=="waiting" or .status=="requested" or .status=="pending")
    | [ (.id|tostring), .created_at, .html_url ] | @tsv')

  # ---- build the "meaningful completed" sequence (success / failure-family) ----
  meaningful="$(echo "$runs" | jq -c '
    [ .workflow_runs[]
      | select(.status=="completed" and (.conclusion=="success" or .conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="startup_failure"))
    ] | sort_by(.created_at) | reverse')"

  count="$(echo "$meaningful" | jq 'length')"
  [ "$count" -eq 0 ] && { vlog "no meaningful completed runs for ${wf}"; continue; }

  latest="$(echo "$meaningful" | jq -c '.[0]')"
  l_id="$(echo "$latest" | jq -r '.id')"
  l_concl="$(echo "$latest" | jq -r '.conclusion')"
  l_name="$(echo "$latest" | jq -r '.display_title // .name')"
  l_url="$(echo "$latest" | jq -r '.html_url')"
  l_start="$(echo "$latest" | jq -r '.run_started_at // .created_at')"
  l_end="$(echo "$latest" | jq -r '.updated_at')"
  l_dur="$(fmt_duration "$l_start" "$l_end")"

  prev_concl=""
  if [ "$count" -gt 1 ]; then
    prev_concl="$(echo "$meaningful" | jq -r '.[1].conclusion')"
  fi

  if is_fail "$l_concl"; then
    # ---- 1: immediate failure alert ----
    if already_alerted "$wf" "failure" "$l_id"; then
      vlog "failure ${l_id} already alerted"
    else
      reason="$(failed_job_reason "$l_id")"
      msg="$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
        "🔴 *Distro CI: workflow FAILED*" \
        "Workflow: $(md_escape "$wf_name")  (\`$(md_escape "$wf")\`)" \
        "Run: $(md_escape "$l_name")" \
        "Conclusion: ${l_concl}  ·  Duration: ${l_dur}" \
        "Reason: $(md_escape "$reason")" \
        "URL: $(md_escape "$l_url")")"
      if send_telegram "$msg"; then mark_alerted "$wf" "failure" "$l_id"; ALERTS_SENT=$((ALERTS_SENT+1)); fi
    fi
    # ---- 3: escalation on 2 consecutive failures ----
    if [ -n "$prev_concl" ] && is_fail "$prev_concl"; then
      if already_alerted "$wf" "escalation" "$l_id"; then
        vlog "escalation ${l_id} already alerted"
      else
        prev_url="$(echo "$meaningful" | jq -r '.[1].html_url')"
        msg="$(printf '%s\n%s\n%s\n%s\n%s' \
          "🚨 *Distro CI: ESCALATION — 2 consecutive failures*" \
          "Workflow: $(md_escape "$wf_name")  (\`$(md_escape "$wf")\`)" \
          "This pipeline has failed twice in a row — likely a real regression, not a flake." \
          "Latest:  $(md_escape "$l_url")" \
          "Previous: $(md_escape "$prev_url")")"
        if send_telegram "$msg"; then mark_alerted "$wf" "escalation" "$l_id"; ALERTS_SENT=$((ALERTS_SENT+1)); fi
      fi
    fi
  elif [ "$l_concl" = "success" ]; then
    # ---- 4: recovery alert (success after a prior failure) ----
    if [ -n "$prev_concl" ] && is_fail "$prev_concl"; then
      if already_alerted "$wf" "recovery" "$l_id"; then
        vlog "recovery ${l_id} already alerted"
      else
        msg="$(printf '%s\n%s\n%s\n%s' \
          "✅ *Distro CI: RECOVERED*" \
          "Workflow: $(md_escape "$wf_name")  (\`$(md_escape "$wf")\`)" \
          "Succeeded after a previous failure — issue resolved.  Duration: ${l_dur}" \
          "Run: $(md_escape "$l_url")")"
        if send_telegram "$msg"; then mark_alerted "$wf" "recovery" "$l_id"; ALERTS_SENT=$((ALERTS_SENT+1)); fi
      fi
    fi
  fi
done

# --- persist state (skip on dry-run) ----------------------------------------
STATE="$(echo "$STATE" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.updated_at=$ts')"
if [ "$DRY_RUN" = 1 ]; then
  vlog "dry-run: state NOT written"
else
  mkdir -p "$(dirname "$STATE_FILE")"
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  echo "$STATE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  vlog "state written to $STATE_FILE"
fi

log "poll complete — alerts sent/would-send this run: ${ALERTS_SENT}$([ "$DRY_RUN" = 1 ] && echo ' (dry-run)')"
exit 0
