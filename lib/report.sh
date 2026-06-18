#!/usr/bin/env bash
# lib/report.sh — report.json (machine-readable) + report.txt (operator) + tarball.
# generate_report VERDICT NOTE   (VERDICT: ACCEPTED|REJECTED|SEE_CHECKS)

generate_report() {
  local verdict="$1" note="${2:-}"
  local checks="$RESULTS_DIR/checks.tsv"
  [[ -f "$checks" ]] || touch "$checks"

  python3 - "$RESULTS_DIR" "$verdict" "$note" "$SERIAL" "$CONFIG_FILE" <<'PY'
import sys, os, json, csv, glob, statistics, datetime
rd, verdict, note, serial, cfg = sys.argv[1:6]
checks = []
cf = os.path.join(rd, "checks.tsv")
if os.path.exists(cf):
    with open(cf) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2:
                checks.append({"status": parts[0], "name": parts[1],
                               "detail": parts[2] if len(parts) > 2 else ""})

n_fail = sum(1 for c in checks if c["status"] == "FAIL")
n_warn = sum(1 for c in checks if c["status"] == "WARN")
n_pass = sum(1 for c in checks if c["status"] == "PASS")

# Telemetry summary (peak temps / power) if present.
tele = {}
tf = os.path.join(rd, "telemetry.csv")
if os.path.exists(tf):
    cols = {}
    with open(tf) as fh:
        r = csv.DictReader(fh)
        for row in r:
            for k in ("junction_temp","memory_temp","power_draw_w","fan_rpm"):
                try: cols.setdefault(k, []).append(float(row[k]))
                except Exception: pass
    def peak(k): return round(max(cols[k]),1) if cols.get(k) else None
    def avg(k):  return round(statistics.mean(cols[k]),1) if cols.get(k) else None
    tele = {"peak_junction_c": peak("junction_temp"),
            "peak_memory_c": peak("memory_temp"),
            "peak_power_w": peak("power_draw_w"),
            "avg_power_w": avg("power_draw_w"),
            "fan_rpm_max": peak("fan_rpm")}

events = []
ef = os.path.join(rd, "events.log")
if os.path.exists(ef):
    events = [l.rstrip() for l in open(ef)][:50]

report = {
    "serial": serial,
    "verdict": verdict,
    "note": note,
    "generated": datetime.datetime.now().isoformat(timespec="seconds"),
    "config": cfg,
    "summary": {"pass": n_pass, "fail": n_fail, "warn": n_warn},
    "telemetry": tele,
    "events": events,
    "checks": checks,
}
with open(os.path.join(rd, "report.json"), "w") as fh:
    json.dump(report, fh, indent=2)

# Operator-readable text.
lines = []
lines.append("="*64)
lines.append(f" ACCEPTANCE REPORT   serial: {serial}")
lines.append(f" VERDICT: {verdict}    ({note})")
lines.append(f" generated: {report['generated']}")
lines.append("="*64)
lines.append(f" checks:  PASS={n_pass}  FAIL={n_fail}  WARN={n_warn}")
if tele:
    lines.append(f" peak junction: {tele.get('peak_junction_c')} C   "
                 f"peak memory: {tele.get('peak_memory_c')} C")
    lines.append(f" peak power: {tele.get('peak_power_w')} W   "
                 f"avg power: {tele.get('avg_power_w')} W")
lines.append("-"*64)
for c in checks:
    if c["status"] == "FAIL":
        lines.append(f" [FAIL] {c['name']}  {c['detail']}")
for c in checks:
    if c["status"] == "WARN":
        lines.append(f" [WARN] {c['name']}  {c['detail']}")
lines.append("-"*64)
lines.append(f" PASSED checks: {n_pass} (see report.json for full list)")
if events:
    lines.append(f" EVENTS flagged: {len(events)} (see events.log)")
lines.append("="*64)
lines.append(f" {'>>> ACCEPTED <<<' if verdict=='ACCEPTED' else '>>> REJECTED <<<' if verdict=='REJECTED' else verdict}")
lines.append("="*64)
open(os.path.join(rd, "report.txt"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY

  # Tarball the whole results dir as the shippable QA artifact.
  local base; base="$(basename "$RESULTS_DIR")"
  tar -czf "$RESULTS_DIR/../${base}.tar.gz" -C "$RESULTS_DIR/.." "$base" 2>/dev/null \
    && info "QA artifact: $(cd "$RESULTS_DIR/.." && pwd)/${base}.tar.gz"
}
