#!/usr/bin/env bash
set -euo pipefail

TARGETS_FILE="${1:-targets.txt}"
OUTDIR="${2:-./vegeta_runs/$(date +%Y%m%d_%H%M%S)}"

TIMEOUT="5s"

COLD_IDLE="180s"
COOLDOWN_IDLE="180s"

WARMUP_RATE="20/1s"
WARMUP_DURATION="60s"

STEP_DURATION="60s"
STEP_RATES=("50/1s" "100/1s" "200/1s" "400/1s" "800/1s")

STRESS_DURATION="60s"
STRESS_RATES=("1200/1s" "1600/1s" "2000/1s")

SOAK_RATE="400/1s"
SOAK_DURATION="15m"

# Гистограмма латентности (подстрой под ожидаемые времена ответа)
HIST_BUCKETS='hist[0ms,1ms,2ms,5ms,10ms,20ms,50ms,100ms,200ms,500ms,1s,2s,5s]'

command -v vegeta >/dev/null 2>&1 || { echo "ERROR: vegeta not found in PATH"; exit 1; }
[[ -f "$TARGETS_FILE" ]] || { echo "ERROR: targets file not found: $TARGETS_FILE"; exit 1; }

mkdir -p "$OUTDIR"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

write_meta () {
  {
    echo "date: $(date -Is)"
    echo "targets: $TARGETS_FILE"
    echo "timeout: $TIMEOUT"
    echo "hist: $HIST_BUCKETS"
    echo "vegeta: $(vegeta -version 2>/dev/null || true)"
  } > "${OUTDIR}/meta.txt"
}

run_phase () {
  local name="$1"
  local rate="$2"
  local duration="$3"

  local bin="${OUTDIR}/${name}.bin"
  local rpt_txt="${OUTDIR}/${name}.report.txt"
  local rpt_json="${OUTDIR}/${name}.report.json"
  local rpt_hist="${OUTDIR}/${name}.hist.txt"
  local plot_html="${OUTDIR}/${name}.plot.html"

  log "PHASE ${name}: rate=${rate}, duration=${duration}"

  # 1) Собираем результаты атаки в .bin (gob) и параллельно печатаем сводку в терминал
  vegeta attack \
    -targets="$TARGETS_FILE" \
    -rate="$rate" \
    -duration="$duration" \
    -timeout="$TIMEOUT" \
    | tee "$bin" \
    | vegeta report \
    | tee "$rpt_txt" >/dev/null

  # 2) Машиночитаемый отчёт (JSON) — удобно для последующего парсинга/графиков
  vegeta report -type=json "$bin" > "$rpt_json"

  # 3) Гистограмма распределения латентности
  vegeta report -type="$HIST_BUCKETS" "$bin" > "$rpt_hist"

  # 4) HTML plot (временной ряд латентности)
  vegeta plot -title "$name" "$bin" > "$plot_html"

  log "Artifacts: $(basename "$bin"), $(basename "$rpt_txt"), $(basename "$rpt_json"), $(basename "$rpt_hist"), $(basename "$plot_html")"
}

write_meta

log "Output dir: $OUTDIR"
log "COLD (no load) for ${COLD_IDLE}"
sleep "$COLD_IDLE"

run_phase "01_warmup" "$WARMUP_RATE" "$WARMUP_DURATION"

i=0
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

log "COOLDOWN (no load) for ${COOLDOWN_IDLE}"
sleep "$COOLDOWN_IDLE"

log "DONE. All reports saved to: $OUTDIR"
