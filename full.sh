#!/usr/bin/env bash
set -euo pipefail

APP="./app_linux_amd64"

# ===== Параметры эксперимента =====
DURATION_SEC="${1:-900}"      # общая длительность эксперимента (сек)
INTERVAL_SEC="${2:-1}"        # интервал mpstat/pidstat/vmstat/sar (сек)

# ===== Нагрузка (HTTP) =====
URL="${3:-http://localhost:8080/}"
LOAD_DELAY_SEC=120            # нагрузка стартует через 3 минуты после старта приложения
LOAD_TOTAL_SEC=480            # длительность нагрузки 8 минут
PHASE_SEC=120                 # каждые 2 минуты меняем метод
CURL_MAX_TIME=2               # таймаут одного запроса (сек)

# Частота нагрузки: 2 запроса/сек (один запрос каждые 0.5 сек)
REQ_INTERVAL_SEC=0.01

# ===== Мониторинг потоков (пункт 2) =====
THREAD_SUMMARY_INTERVAL_SEC="${4:-1}"   # частота summary: счетчики потоков и состояний
THREAD_DUMP_INTERVAL_SEC="${5:-1}"     # частота dump: полный список потоков

# ===== Мониторинг "снимков" системы (пункт 3) =====
SNAPSHOT_INTERVAL_SEC="${6:-10}"        # как часто делать free/meminfo (сек)

OUTDIR="full_logs_lvl1_$(date +%F_%H%M%S)"
mkdir -p "$OUTDIR"

log_meta() { echo "timestamp=$(date -Is) $*" >> "$OUTDIR/timeline.txt"; }

cleanup() {
  log_meta "cleanup: stopping monitors/load/app"

  # 1) Остановить генератор нагрузки (если жив)
  if [[ -n "${LOAD_PID:-}" ]] && kill -0 "$LOAD_PID" 2>/dev/null; then
    kill "$LOAD_PID" 2>/dev/null || true
  fi

  # 2) Остановить все фоновые job'ы, запущенные этим скриптом
  # (мониторы sysstat + thread monitors + snapshots + др.)
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
  echo "load_delay_sec=$LOAD_DELAY_SEC load_total_sec=$LOAD_TOTAL_SEC phase_sec=$PHASE_SEC"
  echo "load_rate=2rps req_interval_sec=$REQ_INTERVAL_SEC curl_max_time=$CURL_MAX_TIME"
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

# 3.1 Память как временной ряд
start_monitor "sar_mem"   sar -r "$INTERVAL_SEC"
start_monitor "sar_paging" sar -B "$INTERVAL_SEC"

# 3.2 Ввод-вывод (общая картина)
start_monitor "iostat_xz" iostat -xz "$INTERVAL_SEC"
start_monitor "sar_blockio" sar -b "$INTERVAL_SEC"

# 3.3 Снимки "до/во время/после" (free/meminfo) — полезно для отчёта
snapshots_monitor() {
  local out="$OUTDIR/snapshots_mem.log"
  {
    echo "# started_at=$(date -Is)"
    echo "# periodic snapshots: free -h and /proc/meminfo (first lines)"
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

# ===== Генератор нагрузки (2 rps, фазы по методам) =====
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
    echo "# rate=2rps req_interval_sec=$REQ_INTERVAL_SEC curl_max_time=$CURL_MAX_TIME"
  } > "$load_log"

  sleep "$LOAD_DELAY_SEC"
  log_meta "load start (2 rps, phased methods)"

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
LOAD_PID=$!
echo "$LOAD_PID" > "$OUTDIR/load.pid"
log_meta "load generator pid=$LOAD_PID"

# ===== Держим эксперимент заданное время =====
sleep "$DURATION_SEC"
log_meta "duration reached, exiting"
exit 0
