#!/usr/bin/env bash
set -euo pipefail

APP="./app_linux_amd64"

# Мониторинг
DURATION_SEC="${1:-900}"      # общая длительность всего эксперимента (по умолчанию 15 мин)
INTERVAL_SEC="${2:-1}"        # интервал mpstat/pidstat/vmstat/sar (сек)

# Нагрузка
URL="${3:-http://localhost:8080/}"
LOAD_DELAY_SEC=0            # старт нагрузки через 3 минуты после старта приложения
LOAD_TOTAL_SEC=480            # общая длительность нагрузки 8 минут
PHASE_SEC=120                 # 2 минуты на метод

TICK_SEC=5                    # “окно” подачи нагрузки (5 секунд)
REQ_PER_TICK="${4:-20}"        # постоянная частота: N запросов на каждые 5 секунд
CURL_MAX_TIME=2               # таймаут одного запроса (сек)
OUTDIR="logs_lvl1_$(date +%F_%H%M%S)"

mkdir -p "$OUTDIR"

log_meta() { echo "timestamp=$(date -Is) $*" >> "$OUTDIR/timeline.txt"; }

cleanup() {
  log_meta "cleanup: stopping monitors/load/app"

  # Остановить генератор нагрузки (он же остановит свои циклы)
  if [[ -n "${LOAD_PID:-}" ]] && kill -0 "$LOAD_PID" 2>/dev/null; then
    kill "$LOAD_PID" 2>/dev/null || true
  fi

  # Остановить мониторы (и их оболочки, если были)
  if [[ -n "${MONITOR_PIDS:-}" ]]; then
    kill $MONITOR_PIDS 2>/dev/null || true
  fi

  # Остановить приложение
  if [[ -n "${APP_PID:-}" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
  fi

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
  echo "load_delay_sec=$LOAD_DELAY_SEC load_total_sec=$LOAD_TOTAL_SEC req_per_tick=$REQ_PER_TICK tick_sec=$TICK_SEC"
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

# Хелпер для мониторов
MONITOR_PIDS=""

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

  # Пишем в файл, запускаем в фоне
  bash -c "$* >> '$outfile' 2>&1" &
  MONITOR_PIDS="$MONITOR_PIDS $!"
}

# Мониторинг (каждый в свой файл)
start_monitor "mpstat" mpstat -P ALL "$INTERVAL_SEC"
start_monitor "pidstat_cpu_threads" pidstat -u -t -p "$APP_PID" "$INTERVAL_SEC"
start_monitor "pidstat_ctx_threads" pidstat -w -t -p "$APP_PID" "$INTERVAL_SEC"
start_monitor "vmstat" vmstat "$INTERVAL_SEC"
start_monitor "sar_q" sar -q "$INTERVAL_SEC"

log_meta "monitors started"

# --- генератор нагрузки ---
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

  {
    echo "# started_at=$(date -Is)"
    echo "# url=$URL"
    echo "# start_after_sec=$LOAD_DELAY_SEC total_sec=$LOAD_TOTAL_SEC phase_sec=$PHASE_SEC"
    echo "# tick_sec=$TICK_SEC req_per_tick=$REQ_PER_TICK curl_max_time=$CURL_MAX_TIME"
  } > "$load_log"

  sleep "$LOAD_DELAY_SEC"
  log_meta "load start (phased methods)"

  local start_ts now_ts end_ts
  start_ts=$(date +%s)
  end_ts=$((start_ts + LOAD_TOTAL_SEC))

  # 4 фазы по 2 минуты
  local methods=("GET" "POST" "PATCH" "PUT")
  local payload='{"demo":"load"}'

  for method in "${methods[@]}"; do
    local phase_start phase_end
    phase_start=$(date +%s)
    phase_end=$((phase_start + PHASE_SEC))

    log_meta "load phase start method=$method"

    while true; do
      now_ts=$(date +%s)
      [[ "$now_ts" -ge "$end_ts" ]] && return 0
      [[ "$now_ts" -ge "$phase_end" ]] && break

      local tick_begin elapsed
      tick_begin=$(date +%s)

      # Постоянная частота: REQ_PER_TICK запросов каждые TICK_SEC секунд
      for ((i=1; i<=REQ_PER_TICK; i++)); do
        ( run_one_curl "$method" "$payload" >> "$load_log" 2>> "$err_log" ) &
      done
      wait

      elapsed=$(( $(date +%s) - tick_begin ))
      if [[ "$elapsed" -lt "$TICK_SEC" ]]; then
        sleep $((TICK_SEC - elapsed))
      fi
    done

    log_meta "load phase end method=$method"
  done

  log_meta "load end"
}

load_generator &
LOAD_PID=$!
echo "$LOAD_PID" > "$OUTDIR/load.pid"
log_meta "load generator pid=$LOAD_PID"

# Держим эксперимент заданное время
sleep "$DURATION_SEC"
log_meta "duration reached, exiting"
exit 0
