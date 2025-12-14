#!/usr/bin/env bash
set -euo pipefail

# =========================
# 0) Inputs / paths
# =========================
APP="${APP:-./app_linux_amd64}"
TARGETS_FILE="${1:-targets.txt}"
OUTDIR="${2:-./vegeta_runs_full/$(date +%Y%m%d_%H%M%S)}"

DIR_APP="$OUTDIR/app"
DIR_MON="$OUTDIR/mon"
DIR_LOAD="$OUTDIR/vegeta"
mkdir -p "$DIR_APP" "$DIR_MON" "$DIR_LOAD"

# =========================
# Sampling / intervals
# =========================
INTERVAL_SEC="${INTERVAL_SEC:-1}"
NET_SNAPSHOT_INTERVAL_SEC="${NET_SNAPSHOT_INTERVAL_SEC:-5}"
SOFTIRQ_SNAPSHOT_INTERVAL_SEC="${SOFTIRQ_SNAPSHOT_INTERVAL_SEC:-5}"
SNAPSHOT_INTERVAL_SEC="${SNAPSHOT_INTERVAL_SEC:-10}"          # free/meminfo
HEAVY_SNAPSHOT_INTERVAL_SEC="${HEAVY_SNAPSHOT_INTERVAL_SEC:-60}" # status/smaps_rollup/pmap
THREAD_SUMMARY_INTERVAL_SEC="${THREAD_SUMMARY_INTERVAL_SEC:-1}"
THREAD_DUMP_INTERVAL_SEC="${THREAD_DUMP_INTERVAL_SEC:-1}"

# =========================
# Vegeta scenario
# =========================
TIMEOUT="${TIMEOUT:-5s}"

COLD_IDLE="${COLD_IDLE:-120s}"
COOLDOWN_IDLE="${COOLDOWN_IDLE:-120s}"

WARMUP_RATE="${WARMUP_RATE:-20/1s}"
WARMUP_DURATION="${WARMUP_DURATION:-120s}"

STEP_DURATION="${STEP_DURATION:-90s}"
STRESS_DURATION="${STRESS_DURATION:-60s}"

SOAK_RATE="${SOAK_RATE:-200/1s}"
SOAK_DURATION="${SOAK_DURATION:-5m}"

HIST_BUCKETS="${HIST_BUCKETS:-hist[0ms,1ms,2ms,5ms,10ms,20ms,50ms,100ms,200ms,500ms,1s,2s,5s]}"

# Rates: fixed arrays by default
STEP_RATES_DEFAULT=("50/1s" "100/1s" "150/1s" "200/1s" "250/1s")
STRESS_RATES_DEFAULT=("350/1s")

# Optional override (comma-separated, no spaces):
# STEP_RATES_STR="50/1s,100/1s" STRESS_RATES_STR="1200/1s,1600/1s" ./vegeta_full.sh ...
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

log()      { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
log_meta() { echo "timestamp=$(date -Is) $*" >> "$OUTDIR/timeline.txt"; }

# =========================
# 1) Checks
# =========================
command -v vegeta >/dev/null 2>&1 || { echo "ERROR: vegeta not found in PATH" >&2; exit 1; }
[[ -f "$TARGETS_FILE" ]] || { echo "ERROR: targets file not found: $TARGETS_FILE" >&2; exit 1; }
[[ -x "$APP" ]] || { echo "ERROR: $APP not found or not executable" >&2; exit 1; }

# =========================
# 2) Cleanup / trap
# =========================
cleanup() {
  log_meta "cleanup: stopping load/monitors/app"

  if [[ -n "${LOAD_PID:-}" ]] && kill -0 "$LOAD_PID" 2>/dev/null; then
    kill "$LOAD_PID" 2>/dev/null || true
  fi

  jobs -p | xargs -r kill 2>/dev/null || true

  if [[ -n "${APP_PID:-}" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
  fi

  wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# =========================
# 3) Meta
# =========================
{
  echo "date=$(date -Is)"
  echo "outdir=$OUTDIR"
  echo "app=$APP"
  echo "targets=$TARGETS_FILE"
  echo
  echo "interval_sec=$INTERVAL_SEC"
  echo "net_snapshot_interval_sec=$NET_SNAPSHOT_INTERVAL_SEC"
  echo "softirq_snapshot_interval_sec=$SOFTIRQ_SNAPSHOT_INTERVAL_SEC"
  echo "snapshot_interval_sec=$SNAPSHOT_INTERVAL_SEC"
  echo "heavy_snapshot_interval_sec=$HEAVY_SNAPSHOT_INTERVAL_SEC"
  echo
  echo "timeout=$TIMEOUT"
  echo "hist=$HIST_BUCKETS"
  echo "COLD_IDLE=$COLD_IDLE COOLDOWN_IDLE=$COOLDOWN_IDLE"
  echo "WARMUP_RATE=$WARMUP_RATE WARMUP_DURATION=$WARMUP_DURATION"
  echo "STEP_DURATION=$STEP_DURATION STEP_RATES=${STEP_RATES[*]}"
  echo "STRESS_DURATION=$STRESS_DURATION STRESS_RATES=${STRESS_RATES[*]}"
  echo "SOAK_RATE=$SOAK_RATE SOAK_DURATION=$SOAK_DURATION"
  echo
  echo "uname=$(uname -a)"
  echo "nproc=$(nproc)"
  echo "vegeta_version=$(vegeta -version 2>/dev/null || true)"
} > "$OUTDIR/meta.txt"

# =========================
# 4) Start app
# =========================
log_meta "start app"
"$APP" > "$DIR_APP/app_stdout.log" 2> "$DIR_APP/app_stderr.log" &
APP_PID=$!
echo "$APP_PID" > "$DIR_APP/app.pid"
log_meta "app pid=$APP_PID"

# =========================
# 5) Monitors
# =========================
start_monitor() {
  local name="$1"; shift
  local outfile="$DIR_MON/${name}.log"

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

  ( exec "$@" >> "$outfile" 2>&1 ) &
}

# L1
start_monitor "mpstat" mpstat -P ALL "$INTERVAL_SEC"
start_monitor "vmstat" vmstat "$INTERVAL_SEC"
start_monitor "sar_q" sar -q "$INTERVAL_SEC"
start_monitor "pidstat_cpu_threads" pidstat -u -t -p "$APP_PID" "$INTERVAL_SEC"
start_monitor "pidstat_ctx_threads" pidstat -w -t -p "$APP_PID" "$INTERVAL_SEC"

# L2
start_monitor "sar_mem" sar -r "$INTERVAL_SEC"
start_monitor "sar_paging" sar -B "$INTERVAL_SEC"
start_monitor "pidstat_mem_proc" pidstat -r -p "$APP_PID" "$INTERVAL_SEC"
start_monitor "iostat_xz" iostat -xz "$INTERVAL_SEC"
start_monitor "sar_blockio" sar -b "$INTERVAL_SEC"
start_monitor "pidstat_io_proc" pidstat -d -p "$APP_PID" "$INTERVAL_SEC"

# L3
start_monitor "sar_net_dev"  sar -n DEV  "$INTERVAL_SEC"
start_monitor "sar_net_edev" sar -n EDEV "$INTERVAL_SEC"
start_monitor "sar_net_tcp"  sar -n TCP,ETCP "$INTERVAL_SEC"
start_monitor "sar_irq_all"  sar -I ALL "$INTERVAL_SEC"

if command -v nstat >/dev/null 2>&1; then
  start_monitor "nstat" nstat -az "$NET_SNAPSHOT_INTERVAL_SEC"
else
  echo "SKIP: nstat not installed" | tee -a "$OUTDIR/monitors_skipped.txt" >/dev/null
fi

log_meta "monitors started"

# =========================
# 5b) Snapshot loops
# =========================
thread_summary_monitor() {
  local out="$DIR_MON/threads_summary.log"
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
  local out="$DIR_MON/threads_dump.log"
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
  local out="$DIR_MON/snapshots_mem.log"
  {
    echo "# started_at=$(date -Is)"
    echo "# periodic snapshots: free -h and /proc/meminfo (head)"
    echo
  } > "$out"
  while kill -0 "$APP_PID" 2>/dev/null; do
    echo "### ts=$(date -Is)" >> "$out"
    free -h >> "$out" 2>&1 || true
    echo "--- /proc/meminfo (head) ---" >> "$out"
    head -n 30 /proc/meminfo >> "$out" 2>&1 || true
    echo >> "$out"
    sleep "$SNAPSHOT_INTERVAL_SEC"
  done
}

mem_layout_monitor() {
  local out="$DIR_MON/mem_layout.log"
  {
    echo "# started_at=$(date -Is)"
    echo "# /proc/PID/status (filtered) + smaps_rollup + pmap -x"
    echo
  } > "$out"
  while kill -0 "$APP_PID" 2>/dev/null; do
    echo "### ts=$(date -Is)" >> "$out"
    echo "--- /proc/$APP_PID/status (filtered) ---" >> "$out"
    egrep '^(VmRSS|VmSize|RssAnon|RssFile|RssShmem|VmSwap):' "/proc/$APP_PID/status" >> "$out" 2>&1 || true
    echo "--- /proc/$APP_PID/smaps_rollup ---" >> "$out"
    cat "/proc/$APP_PID/smaps_rollup" >> "$out" 2>&1 || true
    if command -v pmap >/dev/null 2>&1; then
      echo "--- pmap -x ---" >> "$out"
      pmap -x "$APP_PID" >> "$out" 2>&1 || true
    else
      echo "--- pmap -x ---" >> "$out"
      echo "SKIP: pmap not installed" >> "$out"
    fi
    echo >> "$out"
    sleep "$HEAVY_SNAPSHOT_INTERVAL_SEC"
  done
}

ss_snapshot_monitor() {
  local out="$DIR_MON/ss_sockets.log"
  {
    echo "# started_at=$(date -Is)"
    echo "# ss -ntpi (established) and ss -lntpi (listening) snapshots"
    echo
  } > "$out"
  if ! command -v ss >/dev/null 2>&1; then
    echo "SKIP: ss not installed" | tee -a "$OUTDIR/monitors_skipped.txt" >/dev/null
    return 0
  fi
  while kill -0 "$APP_PID" 2>/dev/null; do
    echo "### ts=$(date -Is)" >> "$out"
    ss -ntpi >> "$out" 2>&1 || true
    echo "---" >> "$out"
    ss -lntpi >> "$out" 2>&1 || true
    echo >> "$out"
    sleep "$NET_SNAPSHOT_INTERVAL_SEC"
  done
}

softirqs_snapshot_monitor() {
  local out="$DIR_MON/softirqs.log"
  {
    echo "# started_at=$(date -Is)"
    echo "# /proc/softirqs snapshots"
    echo
  } > "$out"
  while kill -0 "$APP_PID" 2>/dev/null; do
    echo "### ts=$(date -Is)" >> "$out"
    cat /proc/softirqs >> "$out" 2>&1 || true
    echo >> "$out"
    sleep "$SOFTIRQ_SNAPSHOT_INTERVAL_SEC"
  done
}

thread_summary_monitor &
thread_dump_monitor &
snapshots_monitor &
mem_layout_monitor &
ss_snapshot_monitor &
softirqs_snapshot_monitor &
log_meta "snapshot loops started"

# =========================
# 6) Vegeta phases + reports
# =========================
run_phase() {
  local name="$1"
  local rate="$2"
  local duration="$3"

  local bin_gz="${DIR_LOAD}/${name}.bin.gz"
  local rpt_txt="${DIR_LOAD}/${name}.report.txt"
  local rpt_json="${DIR_LOAD}/${name}.report.json"
  local rpt_hist="${DIR_LOAD}/${name}.hist.txt"
  local plot_html="${DIR_LOAD}/${name}.plot.html"

  log "PHASE ${name}: rate=${rate}, duration=${duration}"
  log_meta "load phase start name=${name} rate=${rate} duration=${duration}"

  vegeta attack \
    -targets="$TARGETS_FILE" \
    -rate="$rate" \
    -duration="$duration" \
    -timeout="$TIMEOUT" \
  | tee >(gzip -c > "$bin_gz") \
  | vegeta report \
  | tee "$rpt_txt" >/dev/null

  gzip -dc "$bin_gz" | vegeta report -type=json > "$rpt_json"
  gzip -dc "$bin_gz" | vegeta report -type="$HIST_BUCKETS" > "$rpt_hist"
  gzip -dc "$bin_gz" | vegeta plot -title "$name" > "$plot_html"

  log_meta "load phase end name=${name}"
}

load_scenario() {
  log "Output dir: $OUTDIR"

  log_meta "cold idle start duration=$COLD_IDLE"
  sleep "$COLD_IDLE"
  log_meta "cold idle end"

  run_phase "01_warmup" "$WARMUP_RATE" "$WARMUP_DURATION"

  local i=0 r
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

load_scenario &
LOAD_PID=$!
echo "$LOAD_PID" > "$DIR_LOAD/load.pid"
log_meta "load scenario pid=$LOAD_PID"

wait "$LOAD_PID"
exit 0
