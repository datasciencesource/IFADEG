#!/bin/bash
# =====================================================================
# 2run.sh - Instrument Part 1: Deployment evaluation (FADTESE)
#
# FADTESE source (published, used unchanged):
#   https://github.com/datasciencesource/bash-script/blob/main/install_big_data_utilities.sh
#
# Steps:
#   1. Download a fresh copy of install_big_data_utilities.sh into /   (not timed)
#   2. Start recording   (clock; every 1 s: CPU, RAM, network bytes)
#   3. Run install_big_data_utilities.sh unchanged, from /, output timestamped into a log
#   4. End recording     (clock, stop sampler, exit code)
#   5. Calculate every Part 1 value for three rows:
#        Hadoop part  run start -> first output line after "starting nodemanager" (same work as IFADEG S1)
#        Connector/J  first -> last FADTESE output line about mysql-connector-java (download,
#                     extract, copy into Sqoop lib, JAR check); compared with IFADEG
#        Total        run start -> end (whole pipeline)
#
# Columns (same as the IFADEG stage table):
#   Start/End, Duration (s), Download time (s), Data downloaded (MB), Attempts (1),
#   Recovery time (0), Outcome (2/0/NR), Peak / Mean CPU (%), Peak RAM (GB), Error / log
#   Comparison with IFADEG (Instrument 4): Hadoop part vs S1, Connector/J vs Connector/J,
#   Total vs IFADEG total (S1-S4); Mann-Whitney U over 10 runs each
#   + exit code and SHA-256 (first 12) of the script that was run
#
# Usage (as root, in /):  ./2run.sh
# Output (in /ifadeg_logs):
#   part1.csv                   three rows per run (Hadoop part, Connector/J, Total)
#   fadtese_<date_time>.log     full FADTESE output (timestamped) + summary
# =====================================================================

[ "$(id -u)" -ne 0 ] && { echo "Please run as root: sudo -i"; exit 1; }

# ---------- settings ----------
WORK_DIR="/"
SCRIPT="/install_big_data_utilities.sh"
URL="https://raw.githubusercontent.com/datasciencesource/bash-script/main/install_big_data_utilities.sh"
LOG_DIR="/ifadeg_logs"
CSV="$LOG_DIR/part1.csv"
TS=$(date +%Y%m%d_%H%M%S)
LOG="$LOG_DIR/fadtese_${TS}.log"
SAMPLES="$LOG_DIR/.samples_${TS}"
mkdir -p "$LOG_DIR"

# ---------- 1. download a fresh copy of FADTESE (not timed) ----------
echo "Downloading FADTESE: $URL"
rm -f "$SCRIPT"
if ! wget -q -O "$SCRIPT" "$URL"; then
    rm -f "$SCRIPT"; echo "Download failed - check the network and the link above."; exit 1
fi
if ! head -1 "$SCRIPT" | grep -q '^#!'; then
    rm -f "$SCRIPT"; echo "Downloaded file is not a script - check the link above."; exit 1
fi
chmod +x "$SCRIPT"
SHA=$(sha256sum "$SCRIPT" | cut -c1-12)
echo "Saved to $SCRIPT ($(wc -l < "$SCRIPT") lines, SHA-256 $SHA)"

# ---------- helpers ----------
# Bytes received on all network interfaces except lo
rx_bytes() {
    awk 'NR>2 { line=$0; sub(/^[ \t]+/, "", line); split(line, a, ":")
                if (a[1] != "lo") { split(a[2], b, " "); s += b[1] } }
         END { printf "%.0f", s+0 }' /proc/net/dev
}

# Sampler: every 1 s, whole VM -> "epoch cpu% ram_gb rx_bytes"
sampler() {
    read -r _ u n s i w q sq st _ < /proc/stat
    pt=$((u+n+s+i+w+q+sq+st)); pi=$((i+w))
    while :; do
        sleep 1
        read -r _ u n s i w q sq st _ < /proc/stat
        t=$((u+n+s+i+w+q+sq+st)); id=$((i+w))
        dt=$((t-pt)); di=$((id-pi)); pt=$t; pi=$id
        ram=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%.3f",(t-a)/1048576}' /proc/meminfo)
        [ "$dt" -gt 0 ] && echo "$(date +%s) $(awk -v dt="$dt" -v di="$di" 'BEGIN{printf "%.1f",(dt-di)*100/dt}') $ram $(rx_bytes)" >> "$SAMPLES"
    done
}

# Download time (s) from log lines between two epochs: apt "Fetched ... in X" + wget "100% ...=X"
dl_time() {   # $1 = from epoch, $2 = to epoch
    grep -E 'Fetched .* in [0-9]|100%.*=[0-9.]+[hms]' "$LOG" | while IFS= read -r l; do
        e=$(date -d "$(echo "$l" | sed -E 's/^\[([^]]*)\].*/\1/')" +%s 2>/dev/null) || continue
        # window [from, to): the line at "to" belongs to the next part, except at the very end of the run
        [ "$e" -ge "$1" ] || continue
        [ "$e" -lt "$2" ] || { [ "$2" -eq "$END_EPOCH" ] && [ "$e" -le "$2" ]; } || continue
        if echo "$l" | grep -q 'Fetched'; then
            echo "$l" | grep -oE ' in [0-9]+(h|min|s)( [0-9]+(min|s))?' | sed -E 's/ in //; s/min/m/g'
        else
            echo "$l" | sed -E 's/.*=([0-9hms.]+)[[:space:]]*$/\1/'
        fi
    done | awk 'NF{ s=$0; while (match(s,/[0-9.]+[hms]/)) { tok=substr(s,RSTART,RLENGTH);
          n=substr(tok,1,length(tok)-1)+0; u=substr(tok,length(tok)); t += (u=="h")?n*3600:(u=="m")?n*60:n;
          s=substr(s,RSTART+RLENGTH) }; f=1 } END{ if(f) printf "%.1f", t+0; else print "0.0" }'
}

# Data (MB), peak/mean CPU, peak RAM between two epochs (rx at the start is the first sample >= from)
part_stats() {   # $1 = from epoch, $2 = to epoch, $3 = rx bytes at the start, $4 = rx bytes at the end
    awk -v a="$1" -v b="$2" -v r0="$3" -v r1="$4" '$1>=a && $1<=b { c+=$2; n++; if($2>pc)pc=$2; if($3>pr)pr=$3 }
        END{ if(n) printf "%.1f %.1f %.1f %.2f\n",(r1-r0)/1000000,pc,c/n,pr; else printf "%.1f NA NA NA\n",(r1-r0)/1000000 }' "$SAMPLES"
}
rx_at() { awk -v e="$1" '$1<=e {r=$4} END{print r+0}' "$SAMPLES"; }   # last rx sample at or before epoch

# ---------- 2. start recording ----------
: > "$SAMPLES"
START_EPOCH=$(date +%s); START_HMS=$(date '+%H:%M:%S')
RX0=$(rx_bytes)
sampler & SAMPLER_PID=$!
trap 'kill $SAMPLER_PID 2>/dev/null; rm -f "$SAMPLES"' EXIT
trap 'echo; echo "Interrupted - this run is NOT valid: restore the clean snapshot and redo it."; exit 130' INT
echo "===== Recording started $START_HMS - running FADTESE (do not touch the keyboard) ====="

# ---------- 3. run FADTESE unchanged (every output line timestamped) ----------
cd "$WORK_DIR" || exit 1
"$SCRIPT" 2>&1 | while IFS= read -r l; do printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$l"; done | tee "$LOG"
RC=${PIPESTATUS[0]}

# ---------- 4. end recording ----------
kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null
END_EPOCH=$(date +%s); END_HMS=$(date '+%H:%M:%S')
RX1=$(rx_bytes)

# ---------- 5. split and calculate ----------
# Split point: first output line after the last "starting nodemanager"
H_EPOCH=""
NM_LINE=$(grep -niE 'starting nodemanager' "$LOG" | tail -1 | cut -d: -f1)
if [ -n "$NM_LINE" ]; then
    NEXT=$(sed -n "$((NM_LINE+1))p" "$LOG"); [ -z "$NEXT" ] && NEXT=$(sed -n "${NM_LINE}p" "$LOG")
    H_EPOCH=$(date -d "$(echo "$NEXT" | sed -E 's/^\[([^]]*)\].*/\1/')" +%s 2>/dev/null)
fi

# First error line (for Error / log), with its time
LOGNAME_ONLY=$(basename "$LOG")
ERR_LINE=$(grep -iE 'error|failed|fatal|exception|cannot|unable|refused|denied' "$LOG" \
           | grep -viE 'libgpg-error|debconf|WARN|NativeCodeLoader' | head -1)
ERR_TXT=$(echo "$ERR_LINE" | sed -E 's/^\[[^]]*\] //' | cut -c1-100 | tr -d '",')

# Row values: Start/End, Duration, Download time, Data, Attempts, Recovery, Outcome, CPU, RAM, Error/log
#   Outcome: Hadoop part = 2 if Hadoop was started, 0 if FADTESE stopped before that
#            Connector/J = 2 if its JAR check line appears and FADTESE finished, 0 if not, NR if not reached
#            Total       = 2 if FADTESE finished (exit 0), 0 otherwise
make_row() {   # $1 name, $2 from, $3 to, $4 outcome, $5 error text
    local from=$1 to=$2 name=$3 out=$4 err=$5
    local s_hms e_hms dur dl r0 r1 st
    s_hms=$(date -d "@$from" '+%H:%M:%S'); e_hms=$(date -d "@$to" '+%H:%M:%S')
    dur=$((to - from)); dl=$(dl_time "$from" "$to")
    if [ "$from" -eq "$START_EPOCH" ]; then r0=$RX0; else r0=$(rx_at "$from"); fi
    if [ "$to" -eq "$END_EPOCH" ]; then r1=$RX1; else r1=$(rx_at "$to"); fi
    read -r data pcpu mcpu pram < <(part_stats "$from" "$to" "$r0" "$r1")
    echo "$name|$s_hms / $e_hms|$dur|$dl|$data|1|0|$out|$pcpu / $mcpu|$pram|$err"
}

if [ "$RC" -eq 0 ]; then ERR_TOTAL="No error - $LOGNAME_ONLY"; else ERR_TOTAL="Failed: exit $RC${ERR_TXT:+ | $ERR_TXT} - $LOGNAME_ONLY"; fi

if [ -n "$H_EPOCH" ]; then
    ROW_H=$(make_row "$START_EPOCH" "$H_EPOCH" "Hadoop part" 2 "No error")
else
    # Hadoop was never started: the whole run belongs to the Hadoop part
    ROW_H=$(make_row "$START_EPOCH" "$END_EPOCH" "Hadoop part" 0 "Failed: exit $RC${ERR_TXT:+ | $ERR_TXT}")
fi
# Connector/J window: first -> last output line that mentions mysql-connector-java
CJ_FIRST=$(grep -n 'mysql-connector-java' "$LOG" | head -1 | cut -d: -f1)
CJ_LAST=$(grep -n 'mysql-connector-java' "$LOG" | tail -1 | cut -d: -f1)
ts_of_line() { date -d "$(sed -n "${1}p" "$LOG" | sed -E 's/^\[([^]]*)\].*/\1/')" +%s 2>/dev/null; }
if [ -n "$CJ_FIRST" ]; then
    CJ_S=$(ts_of_line "$CJ_FIRST"); CJ_E=$(ts_of_line "$CJ_LAST")
    if grep -q 'mysql-connector-java-5.1.34-bin.jar' "$LOG" && [ "$RC" -eq 0 ]; then CJ_OUT=2; CJ_ERR="No error"
    else CJ_OUT=0; CJ_ERR="Failed: exit $RC${ERR_TXT:+ | $ERR_TXT}"; fi
    ROW_C=$(make_row "$CJ_S" "$CJ_E" "Connector/J" "$CJ_OUT" "$CJ_ERR")
else
    ROW_C="Connector/J|NR|NR|NR|NR|NR|NR|NR|NR|NR|Not reached (FADTESE stopped before Connector/J)"
fi

[ "$RC" -eq 0 ] && OUT_T=2 || OUT_T=0
ROW_T=$(make_row "$START_EPOCH" "$END_EPOCH" "Total" "$OUT_T" "$ERR_TOTAL")

# ---------- save ----------
[ -f "$CSV" ] || echo "date,run_start,part,start_end,duration_s,download_time_s,data_downloaded_mb,attempts,recovery_time_s,outcome,peak_mean_cpu_pct,peak_ram_gb,error_log,exit_code,sha256_12" > "$CSV"
for r in "$ROW_H" "$ROW_C" "$ROW_T"; do
    IFS='|' read -r p se du dl da at rc oc cpu ram er <<< "$r"
    echo "$(date +%F),$START_HMS,$p,$se,$du,$dl,$da,$at,$rc,$oc,$cpu,$ram,\"$(echo "$er" | tr -d '",')\",$RC,$SHA" >> "$CSV"
done

# ---------- show (summary for the form) ----------
{
echo ""
echo "----- Part 1: FADTESE (install_big_data_utilities.sh) -----"
printf '%-12s | %-19s | %-8s | %-8s | %-8s | %-4s | %-4s | %-3s | %-13s | %-6s | %s\n' \
       "Stage" "Start / End" "Dur (s)" "DL (s)" "Data MB" "Att" "Rec" "Out" "CPU pk/mean %" "RAM GB" "Error / log"
for r in "$ROW_H" "$ROW_C" "$ROW_T"; do
    IFS='|' read -r p se du dl da at rc oc cpu ram er <<< "$r"
    printf '%-12s | %-19s | %-8s | %-8s | %-8s | %-4s | %-4s | %-3s | %-13s | %-6s | %s\n' "$p" "$se" "$du" "$dl" "$da" "$at" "$rc" "$oc" "$cpu" "$ram" "$er"
done
echo "Hadoop part = start -> Hadoop daemons started (compare with IFADEG S1)"
echo "Connector/J = download, extract, copy into Sqoop lib and JAR check (compare with IFADEG's Connector/J step)"
echo "Exit code / SHA-256  : $RC / $SHA   (0 = script finished)"
echo "-----------------------------------------------------------"
echo "Saved: $CSV and $LOG"
} | tee -a "$LOG"
exit "$RC"
