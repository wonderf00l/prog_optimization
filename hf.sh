#!/usr/bin/env bash
set -euo pipefail

APP="./app_linux_amd64"

# Мониторинг
DURATION_SEC="${1:-10}"      # общая длительность всего эксперимента (например, 15 мин)
INTERVAL_SEC="${2:-1}"        # интервал mpstat/pidstat/vmstat/sar

# Нагрузка
URL="${3:-http://localhost:8080/}"
LOAD_DELAY_SEC=180            # старт нагрузки через 3 минуты
LOAD_TOTAL_SEC=480            # нагрузка 8 минут
PHASE_SEC=120                 # 2 минуты на метод
CURL_MAX_TIME=2               # таймаут одного запроса (сек)

# Частота: 2 запроса/сек => пауза 0.5 сек между запросами
REQ_INTERVAL_SEC=0.5

OUTDIR="logs_lvl1_$(date +%F_%H%M%S)"
mkdir -p "$OUTDIR"

log_meta() { echo "timestamp=$(date -Is) $*" >> "$OUTDIR/timeline.txt"; }

cleanup() {
  log_meta "cleanup: stopping process group"

  # Самый надёжный способ: остановить всю группу процессов скрипта
  # (мониторы, генератор нагрузки, curl'ы, приложение и т.п.)
  kill -TERM -- -$$ 2>/dev/null || true
  sleep 1
  kill -KILL -- -$$ 2>/dev/null || true

  wait 2>/dev/null || true
}

trap cleanup INT TERM EXIT

# Окружение
{
  echo "date=$(date -Is)"
  uname -a
  command -v lscpu >/dev/null 2>&1 && lscpu || true
  echo "nproc=$(nproc)"
  echo "url=$URL"
  echo "duration_sec=$DURATION_SEC interval_sec=$INTERVAL_SEC"
  echo "load_delay_sec=$LOAD_DELAY_SEC load_total_sec=$LOAD_TOTAL_SEC phase_sec=$PHASE_SEC"
  echo "load_rate=2_requests_per_second req_interval_sec=$REQ_INTERVAL_SEC curl_max_time=$CURL_MAX_TIME"
} > "$OUTDIR/env.txt"

if [[ ! -x "$APP" ]]; then
  echo "ERROR: $APP not found or not executable" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl not installed" >&2
  exit 1
fi

# Старт приложения
log_meta "start app"
"$APP" > "$OUTDIR/app_stdout.log" 2> "$OUTDIR/app_stderr.log" &
APP_PID=$!
echo "$APP_PID" > "$OUTDIR/app.pid"
log_meta "app pid=$APP_PID"

# Мониторы
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

  bash -c "$* >> '$outfile' 2>&1" &
}

start_monitor "mpstat" mpstat -P ALL "$INTERVAL_SEC"
start_monitor "pidstat_cpu_threads" pidstat -u -t -p "$APP_PID" "$INTERVAL_SEC"
start_monitor "pidstat_ctx_threads" pidstat -w -t -p "$APP_PID" "$INTERVAL_SEC"
start_monitor "vmstat" vmstat "$INTERVAL_SEC"
start_monitor "sar_q" sar -q "$INTERVAL_SEC"

log_meta "monitors started"

# --- генератор нагрузки 2 req/sec ---
run_one_curl() {
  local method="$1"
  local payload="$2"

  if [[ "$method" == "GET" ]]; then
    curl -sS -o /dev/null --max-time "$CURL_MAX_TIME" \
      -w "ts=$(date -Is) method=${method} http_code=%{http_code} time_total=%{time_total}\n" \
      "$URL"
  else
    curl -sS -o /dev/null --max-time "$CURL_MAX_TIME" \
      -X "$method" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      -w "ts=$(date -Is) method=${method} http_code=%{http_code} time_total=%{time_total}\n" \
      "$URL"
  fi
}

load_generator() {
  local load_log="$OUTDIR/load_curl.log"
  local err_log="$OUTDIR/load_curl_errors.log"
  local payload='{"demo":"load"}'
  local methods=("GET" "POST" "PATCH" "PUT")

  {
    echo "# started_at=$(date -Is)"
    echo "# url=$URL"
    echo "# start_after_sec=$LOAD_DELAY_SEC total_sec=$LOAD_TOTAL_SEC phase_sec=$PHASE_SEC"
    echo "# rate=2_requests_per_second req_interval_sec=$REQ_INTERVAL_SEC curl_max_time=$CURL_MAX_TIME"
  } > "$load_log"

  sleep "$LOAD_DELAY_SEC"
  log_meta "load start (2 req/sec, phased methods)"

  local global_start end now
  global_start=$(date +%s)
  end=$((global_start + LOAD_TOTAL_SEC))

  for method in "${methods[@]}"; do
    local phase_start phase_end
    phase_start=$(date +%s)
    phase_end=$((phase_start + PHASE_SEC))

    log_meta "load phase start method=$method"

    while true; do
      now=$(date +%s)
      [[ "$now" -ge "$end" ]] && { log_meta "load end"; return 0; }
      [[ "$now" -ge "$phase_end" ]] && break

      run_one_curl "$method" "$payload" >> "$load_log" 2>> "$err_log" || true
      sleep "$REQ_INTERVAL_SEC"
    done

    log_meta "load phase end method=$method"
  done

  log_meta "load end"
}

load_generator &
echo "$!" > "$OUTDIR/load.pid"
log_meta "load generator pid=$(cat "$OUTDIR/load.pid")"

sleep "$DURATION_SEC"
log_meta "duration reached, exiting"
exit 0
