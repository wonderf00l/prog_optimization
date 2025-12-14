#!/usr/bin/env bash
set -euo pipefail

APP="./app_linux_amd64"

# ===== Параметры эксперимента =====
DURATION_SEC="${1:-900}"    # общая длительность эксперимента (сек)
INTERVAL_SEC="${2:-1}"      # интервал mpstat/pidstat/vmstat/sar (сек)

# ===== Нагрузка (HTTP) =====
URL="${3:-http://localhost:8080/}"

# Профиль нагрузки по ТЗ:
# - старт нагрузки через 3 минуты после запуска бинаря
# - далее частота нагрузки: 1 -> 6 -> 11 -> 16 -> 21 rps (шаг +5), каждая ступень 3 минуты
# - после достижения 21 держим 21 rps ещё 3 минуты
# - далее 5 минут без нагрузки
LOAD_DELAY_SEC=$((3*60))         # 3 минуты
LOAD_STEP_SEC=$((3*60))          # 3 минуты
LOAD_HOLD_TOP_SEC=$((3*60))      # 3 минуты
LOAD_COOLDOWN_SEC=$((5*60))      # 5 минут

LOAD_RATES=(1 6 11 16 21)

CURL_MAX_TIME=2                  # таймаут одного запроса (сек)
LOAD_METHOD="${LOAD_METHOD:-GET}"  # GET по умолчанию; для POST/PUT/PATCH будет JSON

# Минимальная длительность эксперимента, чтобы профиль нагрузки успел отработать целиком
REQUIRED_DURATION_SEC=$((LOAD_DELAY_SEC + (${#LOAD_RATES[@]} * LOAD_STEP_SEC) + LOAD_HOLD_TOP_SEC + LOAD_COOLDOWN_SEC))
if (( DURATION_SEC < REQUIRED_DURATION_SEC )); then
  DURATION_SEC="$REQUIRED_DURATION_SEC"
fi

# ===== Мониторинг потоков (пункт 2) =====
THREAD_SUMMARY_INTERVAL_SEC="${4:-1}" # частота summary: счетчики потоков и состояний
THREAD_DUMP_INTERVAL_SEC="${5:-1}"    # частота dump: полный список потоков

# ===== Мониторинг "снимков" системы (пункт 3) =====
SNAPSHOT_INTERVAL_SEC="${6:-10}"      # как часто делать free/meminfo (сек)

OUTDIR="upd_full_logs_lvl1_$(date +%F_%H%M%S)"
mkdir -p "$OUTDIR"

log_meta() { echo "timestamp=$(date -Is) $*" >> "$OUTDIR/timeline.txt"; }

cleanup() {
  log_meta "cleanup: stopping monitors/load/app"

  # 1) Остановить генератор нагрузки (если жив)
  if [[ -n "${LOAD_PID:-}" ]] && kill -0 "$LOAD_PID" 2>/dev/null; then
    kill "$LOAD_PID" 2>/dev/null || true
  fi

  # 2) Остановить все фоновые job'ы, запущенные этим скриптом
  jobs -p | xargs -r kill 2>/dev/null || true

  # 3) Остановить приложение (если живо)
  if [[ -n "${APP_PID:-}" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
  fi

  # 4) Дождаться завершения
  wait 2>/dev/null || true
}

trap cleanup INT TERM EXIT

# ===== Окружение =====
{
  echo "date=$(date -Is)"
  uname -a
  command -v lscpu >/dev/null 2>&1 && lscpu || true
  echo "nproc=$(nproc)"

  echo "url=$URL"
  echo "duration_sec=$DURATION_SEC interval_sec=$INTERVAL_SEC"

  echo "load_delay_sec=$LOAD_DELAY_SEC step_sec=$LOAD_STEP_SEC hold_top_sec=$LOAD_HOLD_TOP_SEC cooldown_sec=$LOAD_COOLDOWN_SEC"
  echo "load_rates=${LOAD_RATES[*]} load_method=$LOAD_METHOD curl_max_time=$CURL_MAX_TIME"
  echo "required_duration_sec=$REQUIRED_DURATION_SEC (duration auto-increased if needed)"

  echo "thread_summary_interval_sec=$THREAD_SUMMARY_INTERVAL_SEC thread_dump_interval_sec=$THREAD_DUMP_INTERVAL_SEC"
  echo "snapshot_interval_sec=$SNAPSHOT_INTERVAL_SEC"
} > "$OUTDIR/env.txt"

# ===== Проверки =====
if [[ ! -x "$APP" ]]; then
  echo "ERROR: $APP not found or not executable" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl not installed" >&2
  exit 1
fi

# ===== Старт приложения =====
log_meta "start app"
"$APP" > "$OUTDIR/app_stdout.log" 2> "$OUTDIR/app_stderr.log" &
APP_PID=$!
echo "$APP_PID" > "$OUTDIR/app.pid"
log_meta "app pid=$APP_PID"

# ===== Хелпер запуска мониторов (каждый в свой файл) =====
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

  # Запускаем команду в фоне и пишем весь вывод в файл
  bash -c "$* >> '$outfile' 2>&1" &
}

# =========================
# Уровень 1 — пункт 1 (CPU)
# =========================
start_monitor "mpstat" mpstat -P ALL "$INTERVAL_SEC"
start_monitor "vmstat" vmstat "$INTERVAL_SEC"
start_monitor "sar_q"  sar -q "$INTERVAL_SEC"

# ============================
# Уровень 1 — пункт 2 (потоки)
# ============================
start_monitor "pidstat_cpu_threads" pidstat -u -t -p "$APP_PID" "$INTERVAL_SEC"
start_monitor "pidstat_ctx_threads" pidstat -w -t -p "$APP_PID" "$INTERVAL_SEC"
log_meta "sysstat monitors (cpu/threads basics) started"

# ---- Доп. мониторинг потоков (кол-во, состояния, активные TID) ----
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

    printf "ts=%s total=%s R=%s S=%s D=%s other=%s\n" \
      "$(date -Is)" "$total" "$r" "$s" "$d" "$other" >> "$out"

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

thread_summary_monitor &
thread_dump_monitor &
log_meta "thread monitors started"

# =====================================
# Уровень 1 — пункт 3 (общие метрики)
# =====================================
start_monitor "sar_mem"    sar -r "$INTERVAL_SEC"
start_monitor "sar_paging" sar -B "$INTERVAL_SEC"
start_monitor "iostat_xz"  iostat -xz "$INTERVAL_SEC"
start_monitor "sar_blockio" sar -b "$INTERVAL_SEC"

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

snapshots_monitor &
log_meta "system metrics monitors (mem/io) started"

# ===== Генератор нагрузки (curl, rps по ступеням) =====
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
  local method="$LOAD_METHOD"

  {
    echo "# started_at=$(date -Is)"
    echo "# url=$URL"
    echo "# start_after_sec=$LOAD_DELAY_SEC"
    echo "# step_sec=$LOAD_STEP_SEC rates=${LOAD_RATES[*]}"
    echo "# hold_top_sec=$LOAD_HOLD_TOP_SEC cooldown_sec=$LOAD_COOLDOWN_SEC"
    echo "# method=$method curl_max_time=$CURL_MAX_TIME"
  } > "$load_log"

  sleep "$LOAD_DELAY_SEC"
  log_meta "load start (ramped rps schedule) method=$method"

  run_stage() {
    local rps="$1"
    local duration_sec="$2"
    local label="$3"

    log_meta "load stage start label=$label rps=$rps duration_sec=$duration_sec"

    local t
    for ((t=0; t<duration_sec; t++)); do
      # если приложение завершилось — прекращаем нагрузку
      if ! kill -0 "$APP_PID" 2>/dev/null; then
        log_meta "load aborted: app exited"
        return 0
      fi

      local sec_start_ns sec_end_ns elapsed_ns sleep_ns
      sec_start_ns="$(date +%s%N)"

      local i
      for ((i=0; i<rps; i++)); do
        run_one_curl "$method" "$payload" >> "$load_log" 2>> "$err_log" || true &
      done
      wait

      sec_end_ns="$(date +%s%N)"
      elapsed_ns=$((sec_end_ns - sec_start_ns))
      sleep_ns=$((1000000000 - elapsed_ns))
      if (( sleep_ns > 0 )); then
        sleep "$(awk "BEGIN{print ${sleep_ns}/1000000000}")"
      fi
    done

    log_meta "load stage end label=$label rps=$rps"
  }

  # Ступени: 1 -> 6 -> 11 -> 16 -> 21 (каждая по 3 минуты)
  local rps
  for rps in "${LOAD_RATES[@]}"; do
    run_stage "$rps" "$LOAD_STEP_SEC" "rps_${rps}"
  done

  # Держим верхнюю ступень 21 rps ещё 3 минуты
  run_stage 21 "$LOAD_HOLD_TOP_SEC" "rps_21_hold"

  # 5 минут без нагрузки
  log_meta "load cooldown start duration_sec=$LOAD_COOLDOWN_SEC"
  sleep "$LOAD_COOLDOWN_SEC"
  log_meta "load cooldown end"

  log_meta "load end"
}

load_generator &
LOAD_PID=$!
echo "$LOAD_PID" > "$OUTDIR/load.pid"
log_meta "load generator pid=$LOAD_PID"

# ===== Держим эксперимент заданное время =====
sleep "$DURATION_SEC"
log_meta "duration reached, exiting"
exit 0
