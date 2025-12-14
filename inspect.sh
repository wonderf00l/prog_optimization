#!/usr/bin/env bash
set -euo pipefail

APP="./app_linux_amd64"

# Мониторинг
DURATION="${1:-300}"     # общая длительность эксперимента, секунд (по умолчанию 15 минут)
INTERVAL="${2:-1}"       # интервал mpstat/pidstat/vmstat/sar, секунд

# Нагрузка
LOAD_URL="${3:-http://localhost:8080/}"
LOAD_DELAY=180           # через 3 минуты начинаем нагрузку
TICK_SEC=5               # "окно" 5 секунд
STEP_SEC=120             # каждые 2 минуты увеличиваем частоту
START_RPS_PER_TICK=1     # старт: 1 запрос на 5 сек
MAX_RPS_PER_TICK=10      # максимум: 10 запросов на 5 сек
CURL_MAX_TIME=2          # секунды на один запрос (чтобы не висеть)

OUTDIR="logs_lvl1_$(date +%F_%H%M%S)"
mkdir -p "$OUTDIR"

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout --preserve-status ${DURATION}s"
fi

log_meta() {
  echo "timestamp=$(date -Is) $*" >> "$OUTDIR/timeline.txt"
}

cleanup() {
  log_meta "cleanup: stopping everything"

  # Остановить генератор нагрузки
  if [[ -n "${LOAD_PID:-}" ]] && kill -0 "$LOAD_PID" 2>/dev/null; then
    kill "$LOAD_PID" 2>/dev/null || true
  fi

  # Остановить все фоновые jobs (мониторы)
  jobs -p | xargs -r kill 2>/dev/null || true

  # Остановить приложение
  if [[ -n "${APP_PID:-}" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
  fi

  wait 2>/dev/null || true
}

trap cleanup INT TERM EXIT

# Окружение (для отчёта)
{
  echo "date=$(date -Is)"
  uname -a
  command -v lscpu >/dev/null 2>&1 && lscpu || true
  echo "nproc=$(nproc)"
} > "$OUTDIR/env.txt"

if [[ ! -x "$APP" ]]; then
  echo "ERROR: $APP not found or not executable" >&2
  exit 1
fi

# Проверим curl (иначе нагрузка не поедет)
if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl not installed" >&2
  exit 1
fi

log_meta "start app"
"$APP" > "$OUTDIR/app_stdout.log" 2> "$OUTDIR/app_stderr.log" &
APP_PID=$!
echo "$APP_PID" > "$OUTDIR/app.pid"
log_meta "app pid=$APP_PID"

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

  if [[ -n "$TIMEOUT_BIN" ]]; then
    bash -c "$TIMEOUT_BIN $* >> '$outfile' 2>&1" &
  else
    bash -c "$* >> '$outfile' 2>&1" &
  fi
}

# Мониторы (каждый в свой файл)
start_monitor "mpstat" mpstat -P ALL "$INTERVAL"
start_monitor "pidstat_cpu_threads" pidstat -u -t -p "$APP_PID" "$INTERVAL"
start_monitor "pidstat_ctx_threads" pidstat -w -t -p "$APP_PID" "$INTERVAL"
start_monitor "vmstat" vmstat "$INTERVAL"
start_monitor "sar_q" sar -q "$INTERVAL"

log_meta "monitors started (duration=${DURATION}s interval=${INTERVAL}s)"

# ---- генератор нагрузки ----
generate_load() {
  local start_ts end_ts now_ts
  start_ts=$(date +%s)
  end_ts=$((start_ts + DURATION))

  # Ждем 3 минуты до старта нагрузки
  sleep "$LOAD_DELAY"
  log_meta "load start url=$LOAD_URL"

  local rate="$START_RPS_PER_TICK"
  local stage_start stage_end

  # Лог нагрузки: время, rate, http_code, time_total
  local load_log="$OUTDIR/load_curl.log"
  {
    echo "# started_at=$(date -Is)"
    echo "# url=$LOAD_URL"
    echo "# tick_sec=$TICK_SEC step_sec=$STEP_SEC start_rate=$START_RPS_PER_TICK max_rate=$MAX_RPS_PER_TICK"
  } > "$load_log"

  while true; do
    now_ts=$(date +%s)
    [[ "$now_ts" -ge "$end_ts" ]] && break

    stage_start=$(date +%s)
    stage_end=$((stage_start + STEP_SEC))

    log_meta "load stage rate=${rate}req/${TICK_SEC}s"

    while true; do
      now_ts=$(date +%s)
      [[ "$now_ts" -ge "$end_ts" ]] && return 0
      [[ "$now_ts" -ge "$stage_end" ]] && break

      local tick_begin
      tick_begin=$(date +%s)

      # Запускаем rate запросов "за тик" (5 секунд)
      for ((i=1; i<=rate; i++)); do
        (
          # -sS: тихо, но ошибки показывать; -o /dev/null: тело не нужно
          # -w: пишем http_code и time_total
          # --max-time: чтобы не зависнуть на проблемном запросе
          curl -sS -o /dev/null \
            --max-time "$CURL_MAX_TIME" \
            -w "ts=$(date -Is) rate=${rate} http_code=%{http_code} time_total=%{time_total}\n" \
            "$LOAD_URL" >> "$load_log" 2>> "$OUTDIR/load_curl_errors.log"
        ) &
      done
      wait

      # Спим остаток времени тика (чтобы держать примерно "каждые 5 секунд")
      local elapsed
      elapsed=$(( $(date +%s) - tick_begin ))
      if [[ "$elapsed" -lt "$TICK_SEC" ]]; then
        sleep $((TICK_SEC - elapsed))
      fi
    done

    # Увеличиваем частоту каждые 2 минуты, но не выше MAX
    if [[ "$rate" -lt "$MAX_RPS_PER_TICK" ]]; then
      rate=$((rate + 1))
    fi
  done
}

generate_load &
LOAD_PID=$!
echo "$LOAD_PID" > "$OUTDIR/load.pid"

log_meta "load generator pid=$LOAD_PID"

# Держим скрипт живым до конца эксперимента
sleep "$DURATION"
log_meta "duration reached, exiting"
exit 0
