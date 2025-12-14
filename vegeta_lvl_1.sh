#!/usr/bin/env bash
set -euo pipefail

# =========================
# 0) Inputs / paths
# =========================
APP="${APP:-./app_linux_amd64}"
TARGETS_FILE="${1:-targets.txt}"
OUTDIR="${2:-./vegeta_runs/$(date +%Y%m%d_%H%M%S)}"

# Sysstat / sampling
INTERVAL_SEC="${INTERVAL_SEC:-1}"
THREAD_SUMMARY_INTERVAL_SEC="${THREAD_SUMMARY_INTERVAL_SEC:-1}"
THREAD_DUMP_INTERVAL_SEC="${THREAD_DUMP_INTERVAL_SEC:-1}"
SNAPSHOT_INTERVAL_SEC="${SNAPSHOT_INTERVAL_SEC:-10}"

# Vegeta core
TIMEOUT="${TIMEOUT:-5s}"

# Phases
COLD_IDLE="${COLD_IDLE:-5s}"         # idle до warmup
COOLDOWN_IDLE="${COOLDOWN_IDLE:-120s}" # idle после soak

WARMUP_RATE="${WARMUP_RATE:-20/1s}"
WARMUP_DURATION="${WARMUP_DURATION:-5s}"

STEP_DURATION="${STEP_DURATION:-5s}"

# FIX: нормальные массивы по умолчанию (не строка!)
STEP_RATES_DEFAULT=("50/1s" "100/1s" "200/1s" "300/1s" "500/1s")
STRESS_DURATION="${STRESS_DURATION:-5s}"
STRESS_RATES_DEFAULT=("700/1s" "900/1s" "1200/1s")

# Возможность переопределения через env с запятыми (без пробелов):
#   STEP_RATES_STR="50/1s,100/1s" STRESS_RATES_STR="1200/1s,1600/1s" ./vegeta_full.sh ...
STEP_RATES_STR="${STEP_RATES_STR:-}"
STRESS_RATES_STR="${STRESS_RATES_STR:-}"

if [[ -n "$STEP_RATES_STR" ]]; then
  IFS=',' read -r -a STEP_RATES <<< "$STEP_RATES_STR"
else
  STEP_RATES=("${STEP_RATES_DEFAULT[@]}")
fi

if [[ -n "$STRESS_RATES_STR" ]]; then
  IFS=',' read -r -a STRESS_RATES <<< "$STRESS_RATES_STR"
else
  STRESS_RATES=("${STRESS_RATES_DEFAULT[@]}")
fi

SOAK_RATE="${SOAK_RATE:-400/1s}"
SOAK_DURATION="${SOAK_DURATION:-5s}"

# Histogram buckets
HIST_BUCKETS="${HIST_BUCKETS:-hist[0ms,1ms,2ms,5ms,10ms,20ms,50ms,100ms,200ms,500ms,1s,2s,5s]}"

mkdir -p "$OUTDIR"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
log_meta() { echo "timestamp=$(date -Is) $*" >> "$OUTDIR/timeline.txt"; }

# =========================
# 1) Checks
# =========================
command -v vegeta >/dev/null 2>&1 || { echo "ERROR: vegeta not found in PATH" >&2; exit 1; }
[[ -f "$TARGETS_FILE" ]] || { echo "ERROR: targets file not found: $TARGETS_FILE" >&2; exit 1; }
if [[ ! -x "$APP" ]]; then
  echo "ERROR: $APP not found or not executable" >&2
  exit 1
fi

# =========================
# 2) Cleanup / trap (оставляем алгоритм как был)
# =========================
cleanup() {
  log_meta "cleanup: stopping load/monitors/app"

  # stop load scenario if any (best-effort)
  if [[ -n "${LOAD_PID:-}" ]] && kill -0 "$LOAD_PID" 2>/dev/null; then
    kill "$LOAD_PID" 2>/dev/null || true
  fi

  # stop all background monitors started by this script
  jobs -p | xargs -r kill 2>/dev/null || true

  # stop app
  if [[ -n "${APP_PID:-}" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
  fi

  wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# =========================
# 3) Meta / env info
# =========================
{
  echo "date=$(date -Is)"
  uname -a
  command -v lscpu >/dev/null 2>&1 && lscpu || true
  echo "nproc=$(nproc)"
  echo
  echo "app=$APP"
  echo "targets=$TARGETS_FILE"
  echo "outdir=$OUTDIR"
  echo
  echo "interval_sec=$INTERVAL_SEC"
  echo "thread_summary_interval_sec=$THREAD_SUMMARY_INTERVAL_SEC"
  echo "thread_dump_interval_sec=$THREAD_DUMP_INTERVAL_SEC"
  echo "snapshot_interval_sec=$SNAPSHOT_INTERVAL_SEC"
  echo
  echo "timeout=$TIMEOUT"
  echo "hist=$HIST_BUCKETS"
  echo "COLD_IDLE=$COLD_IDLE COOLDOWN_IDLE=$COOLDOWN_IDLE"
  echo "WARMUP_RATE=$WARMUP_RATE WARMUP_DURATION=$WARMUP_DURATION"
  echo "STEP_DURATION=$STEP_DURATION STEP_RATES=${STEP_RATES[*]}"
  echo "STRESS_DURATION=$STRESS_DURATION STRESS_RATES=${STRESS_RATES[*]}"
  echo "SOAK_RATE=$SOAK_RATE SOAK_DURATION=$SOAK_DURATION"
  echo
  echo "vegeta_version=$(vegeta -version 2>/dev/null || true)"
} > "$OUTDIR/meta.txt"

# =========================
# 4) Start app
# =========================
log_meta "start app"
"$APP" > "$OUTDIR/app_stdout.log" 2> "$OUTDIR/app_stderr.log" &
APP_PID=$!
echo "$APP_PID" > "$OUTDIR/app.pid"
log_meta "app pid=$APP_PID"

# =========================
# 5) Diagnostics: monitors (Level 1)
# =========================
start_monitor() {
  local name="$1"; shift
  local outfile="$OUTDIR/${name}.log"

  if ! command -v "$1" >/dev/null 2>&1; then
    echo "SKIP: $1 not installed" | tee -a "$OUTDIR/monitors_skipped.txt" >/dev/null
    return 0
  fi

  {
    echo "# started_at=$(date -Is)"
    echo "# cmd: $*"
    echo "# app_pid=$APP_PID"
    echo
  } > "$outfile"

  bash -c "exec $* >> '$outfile' 2>&1" &
}

start_monitor "mpstat" mpstat -P ALL "$INTERVAL_SEC"
start_monitor "vmstat" vmstat "$INTERVAL_SEC"
start_monitor "sar_q" sar -q "$INTERVAL_SEC"

start_monitor "pidstat_cpu_threads" pidstat -u -t -p "$APP_PID" "$INTERVAL_SEC"
start_monitor "pidstat_ctx_threads" pidstat -w -t -p "$APP_PID" "$INTERVAL_SEC"

start_monitor "sar_mem" sar -r "$INTERVAL_SEC"
start_monitor "sar_paging" sar -B "$INTERVAL_SEC"
start_monitor "iostat_xz" iostat -xz "$INTERVAL_SEC"
start_monitor "sar_blockio" sar -b "$INTERVAL_SEC"

log_meta "sysstat monitors started"

thread_summary_monitor() {
  local out="$OUTDIR/threads_summary.log"
  {
    echo "# started_at=$(date -Is)"
    echo "# columns: ts total_threads R runnable S sleeping D uninterruptible other"
    echo
  } > "$out"

  while kill -0 "$APP_PID" 2>/dev/null; do
    local total r s d other
    total=$(ls "/proc/$APP_PID/task" 2>/dev/null | wc -l | tr -d ' ')
    r=$(ps -T -p "$APP_PID" -o stat= 2>/dev/null | awk '{c=substr($1,1,1); if(c=="R") n++} END{print n+0}')
    s=$(ps -T -p "$APP_PID" -o stat= 2>/dev/null | awk '{c=substr($1,1,1); if(c=="S") n++} END{print n+0}')
    d=$(ps -T -p "$APP_PID" -o stat= 2>/dev/null | awk '{c=substr($1,1,1); if(c=="D") n++} END{print n+0}')
    other=$(( total - r - s - d ))
    printf "ts=%s total=%s R=%s S=%s D=%s other=%s\n" "$(date -Is)" "$total" "$r" "$s" "$d" "$other" >> "$out"
    sleep "$THREAD_SUMMARY_INTERVAL_SEC"
  done
}

thread_dump_monitor() {
  local out="$OUTDIR/threads_dump.log"
  {
    echo "# started_at=$(date -Is)"
    echo "# columns: ts SPID PSR STAT %CPU COMMAND"
    echo
  } > "$out"

  while kill -0 "$APP_PID" 2>/dev/null; do
    echo "### ts=$(date -Is)" >> "$out"
    ps -T -p "$APP_PID" -o spid=,psr=,stat=,pcpu=,comm= >> "$out" 2>/dev/null || true
    echo >> "$out"
    sleep "$THREAD_DUMP_INTERVAL_SEC"
  done
}

snapshots_monitor() {
  local out="$OUTDIR/snapshots_mem.log"
  {
    echo "# started_at=$(date -Is)"
    echo "# periodic snapshots: free -h and /proc/meminfo (head)"
    echo
  } > "$out"

  while kill -0 "$APP_PID" 2>/dev/null; do
    echo "### ts=$(date -Is)" >> "$out"
    free -h >> "$out" 2>&1 || true
    echo "--- /proc/meminfo (head) ---" >> "$out"
    head -n 20 /proc/meminfo >> "$out" 2>&1 || true
    echo >> "$out"
    sleep "$SNAPSHOT_INTERVAL_SEC"
  done
}

thread_summary_monitor &
thread_dump_monitor &
snapshots_monitor &
log_meta "thread + snapshots monitors started"

# =========================
# 6) Vegeta phases + reports
# =========================
run_phase() {
  local name="$1"
  local rate="$2"
  local duration="$3"

  local bin="${OUTDIR}/${name}.bin"
  local rpt_txt="${OUTDIR}/${name}.report.txt"
  local rpt_json="${OUTDIR}/${name}.report.json"
  local rpt_hist="${OUTDIR}/${name}.hist.txt"
  local plot_html="${OUTDIR}/${name}.plot.html"

  log "PHASE ${name}: rate=${rate}, duration=${duration}"
  log_meta "load phase start name=${name} rate=${rate} duration=${duration}"

  vegeta attack \
    -targets="$TARGETS_FILE" \
    -rate="$rate" \
    -duration="$duration" \
    -timeout="$TIMEOUT" \
  | tee "$bin" \
  | vegeta report \
  | tee "$rpt_txt" >/dev/null

  vegeta report -type=json "$bin" > "$rpt_json"
  vegeta report -type="$HIST_BUCKETS" "$bin" > "$rpt_hist"
  vegeta plot -title "$name" "$bin" > "$plot_html"

  log_meta "load phase end name=${name}"
}

load_scenario() {
  log "Output dir: $OUTDIR"

  log_meta "cold idle start duration=$COLD_IDLE"
  sleep "$COLD_IDLE"
  log_meta "cold idle end"

  run_phase "01_warmup" "$WARMUP_RATE" "$WARMUP_DURATION"

  local i=0
  local r
  for r in "${STEP_RATES[@]}"; do
    i=$((i+1))
    run_phase "$(printf '02_step_%02d_%s' "$i" "${r//\//_}")" "$r" "$STEP_DURATION"
  done

  i=0
  for r in "${STRESS_RATES[@]}"; do
    i=$((i+1))
    run_phase "$(printf '03_stress_%02d_%s' "$i" "${r//\//_}")" "$r" "$STRESS_DURATION"
  done

  run_phase "04_soak_${SOAK_RATE//\//_}" "$SOAK_RATE" "$SOAK_DURATION"

  log_meta "cooldown idle start duration=$COOLDOWN_IDLE"
  sleep "$COOLDOWN_IDLE"
  log_meta "cooldown idle end"

  log_meta "done"
  log "DONE. All artifacts saved to: $OUTDIR"
}

# run load in background so cleanup can stop it via LOAD_PID
load_scenario &
LOAD_PID=$!
echo "$LOAD_PID" > "$OUTDIR/load.pid"
log_meta "load scenario pid=$LOAD_PID"

wait "$LOAD_PID"
exit 0
