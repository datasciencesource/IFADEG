#!/bin/bash
# =====================================================================
# run_fadtese.sh - runs FADTESE (Experiment 3) and measures it like ADS
# The FADTESE script is run UNCHANGED (SHA-256 checked); this wrapper only
# timestamps its output and measures from outside.
#
# Usage (as root, right after precheck.sh says READY):
#   ./run_fadtese.sh
# (Run ID is recorded manually on the form; files use the label set by precheck.sh)
#
# Records (same definitions as ADS, Part 0 + Part 1):
#   Run start / end, Duration (s), Download time (s), Data downloaded (MB),
#   Attempts (always 1: FADTESE has no retry), Recovery time (always 0),
#   Outcome (2 = script finished with exit 0, 0 = script stopped with an error;
#            verify_fadtese.sh sets Outcome to 0 if D1, D3 or D6 then fail),
#   Peak / Mean CPU (%), Peak RAM (GB), Error / log
#   + Hadoop part (s): run start -> Hadoop daemons started (shared scope with IFADEG S1)
#
# Output (in /root/ifadeg_logs):
#   <RUN_ID>_fadtese.log  full FADTESE output, one timestamp per line
#   part0.csv             date,run_start,bandwidth_mbps,latency_ms,packet_loss_pct,free_disk_gb,run_end
#   part1.csv             same columns as ADS, stage = FADTESE
#   e3_split.csv          date,run_id,run_start,hadoop_end,hadoop_part_s,rest_part_s,exit_code,sha256
# =====================================================================

[ "$(id -u)" -ne 0 ] && { echo "Please run as root: sudo -i"; exit 1; }

SCRIPT="${FADTESE_SCRIPT:-/install_big_data_utilities.sh}"
FADTESE_URL="${FADTESE_URL:-https://raw.githubusercontent.com/datasciencesource/bash-script/main/install_big_data_utilities.sh}"
# Download the published FADTESE script into / if it is not there yet (not timed: done before the clock starts)
get_fadtese() {
    [ -f "$SCRIPT" ] && return 0
    echo "[IFADEG] downloading FADTESE script to $SCRIPT"
    wget -q -O "$SCRIPT" "$FADTESE_URL" || { rm -f "$SCRIPT"; echo "[IFADEG] download failed: $FADTESE_URL"; return 1; }
    head -1 "$SCRIPT" | grep -q '^#!' || { rm -f "$SCRIPT"; echo "[IFADEG] downloaded file is not a script (check the URL)"; return 1; }
    chmod +x "$SCRIPT"
}

EXPECTED_SHA="faa5f5ed325a9a6c2f028c015d072490b1b79dc6d97426aa5fbec60011a72216"
STAGE="FADTESE"
LOG_DIR="/root/ifadeg_logs"
mkdir -p "$LOG_DIR"
# Label for file names: argument, else the one set by precheck.sh, else date_time
RUN_ID="${1:-$(cut -d, -f6 "$LOG_DIR/.part0_pending" 2>/dev/null)}"
RUN_ID="${RUN_ID:-E3_$(date +%Y%m%d_%H%M%S)}"
LOG="$LOG_DIR/${RUN_ID}_fadtese.log"
P0_CSV="$LOG_DIR/part0.csv"
CSV="$LOG_DIR/part1.csv"
SPLIT_CSV="$LOG_DIR/e3_split.csv"
PENDING="$LOG_DIR/.part0_pending"
SAMPLES="$LOG_DIR/.${RUN_ID}.samples"

# ---------- safety checks ----------
get_fadtese || exit 1
[ -f "$SCRIPT" ] || { echo "FADTESE script not found: $SCRIPT"; exit 1; }
SHA=$(sha256sum "$SCRIPT" | cut -d' ' -f1)
if [ "$SHA" != "$EXPECTED_SHA" ]; then
    echo "SHA-256 mismatch ($SHA) - FADTESE must be the unchanged published script. Stopping."
    exit 1
fi
if [ ! -f "$PENDING" ]; then
    echo "No Part 0 values found. Run ./precheck.sh $RUN_ID first (it must say READY)."
    exit 1
fi
IFS=',' read -r P0_DATE P0_BW P0_LAT P0_LOSS P0_FREE P0_RUN P0_EPOCH < "$PENDING"
[ -n "$1" ] && [ "$P0_RUN" != "$RUN_ID" ] && echo "[IFADEG] note: precheck was run for $P0_RUN, now running $RUN_ID"
AGE=$(( $(date +%s) - ${P0_EPOCH:-0} ))
[ "$AGE" -gt 900 ] && echo "[IFADEG] WARNING: Part 0 was measured $((AGE/60)) min ago - consider re-running precheck.sh"

# ---------- CPU / RAM sampler (every 1 s, whole VM) - same code as ADS ----------
sampler() {
    read -r _ u n s i w q sq st _ < /proc/stat
    pt=$((u+n+s+i+w+q+sq+st)); pi=$((i+w))
    while :; do
        sleep 1
        read -r _ u n s i w q sq st _ < /proc/stat
        t=$((u+n+s+i+w+q+sq+st)); id=$((i+w))
        dt=$((t-pt)); di=$((id-pi)); pt=$t; pi=$id
        ram=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%.3f",(t-a)/1048576}' /proc/meminfo)
        [ "$dt" -gt 0 ] && awk -v dt="$dt" -v di="$di" -v r="$ram" 'BEGIN{printf "%.1f %s\n",(dt-di)*100/dt,r}' >> "$SAMPLES"
    done
}

# Bytes received on all network interfaces except lo - same code as ADS
rx_bytes() {
    awk 'NR>2 { line=$0; sub(/^[ \t]+/, "", line); split(line, a, ":")
                if (a[1] != "lo") { split(a[2], b, " "); s += b[1] } }
         END { printf "%.0f", s+0 }' /proc/net/dev
}

# ---------- run FADTESE with measurement (clock starts here) ----------
: > "$SAMPLES"; : > "$LOG"
START_EPOCH=$(date +%s); START_HMS=$(date '+%H:%M:%S')
RX0=$(rx_bytes)
sampler & SAMPLER_PID=$!
trap 'kill $SAMPLER_PID 2>/dev/null' EXIT

echo "===== IFADEG $RUN_ID: FADTESE started $START_HMS ====="
cd /root || exit 1
# Unchanged script; every output line gets "[YYYY-mm-dd HH:MM:SS]" (screen + log)
"$SCRIPT" 2>&1 | while IFS= read -r l; do printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$l"; done | tee -a "$LOG"
RC=${PIPESTATUS[0]}

kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null
END_EPOCH=$(date +%s); END_HMS=$(date '+%H:%M:%S')
RX1=$(rx_bytes)
DURATION=$((END_EPOCH - START_EPOCH))

# ---------- Outcome (no retry in FADTESE: 2 or 0) ----------
ATTEMPTS=1; RECOVERY=0
[ "$RC" -eq 0 ] && OUTCOME=2 || OUTCOME=0

# ---------- Data downloaded (MB, 1 MB = 1,000,000 bytes, same base as ADS) ----------
DATA_MB=$(awk -v a="$RX0" -v b="$RX1" 'BEGIN{printf "%.1f",(b-a)/1000000}')

# ---------- Download time (s): apt "Fetched ... in X" + wget "100% ...=X" lines ----------
# (wget prints dot progress when its output is piped; its last line ends with "=<time>")
DL_LINES=$( {
    sed -E 's/^\[[^]]*\] //' "$LOG" | grep -oE 'Fetched .* in [0-9]+(h|min|s)( [0-9]+(min|s))?' | sed -E 's/.* in //; s/min/m/g'
    sed -E 's/^\[[^]]*\] //' "$LOG" | grep -E '100%.*=[0-9.]+[hms]' | sed -E 's/.*=([0-9hms.]+)[[:space:]]*$/\1/'
} )
DL_TIME=$(echo "$DL_LINES" | awk 'NF{ s=$0; while (match(s,/[0-9.]+[hms]/)) { tok=substr(s,RSTART,RLENGTH);
          n=substr(tok,1,length(tok)-1)+0; u=substr(tok,length(tok)); t += (u=="h")?n*3600:(u=="m")?n*60:n;
          s=substr(s,RSTART+RLENGTH) }; found=1 } END{ if(found) printf "%.1f", t+0; else print "NA" }')

# ---------- Hadoop part (shared scope with IFADEG S1) ----------
# End of the Hadoop part = first output line after Hadoop's start-all.sh started the NodeManager
# (the last daemon). Everything after that is FADTESE's extra scope (Sqoop, connectors, Python).
NM_LINE=$(grep -niE 'starting nodemanager' "$LOG" | tail -1 | cut -d: -f1)
if [ -n "$NM_LINE" ]; then
    NEXT=$(sed -n "$((NM_LINE+1))p" "$LOG")
    [ -z "$NEXT" ] && NEXT=$(sed -n "${NM_LINE}p" "$LOG")
    H_TS=$(echo "$NEXT" | sed -E 's/^\[([^]]*)\].*/\1/')
    H_EPOCH=$(date -d "$H_TS" +%s 2>/dev/null)
fi
if [ -n "$H_EPOCH" ]; then
    HADOOP_END=$(date -d "@$H_EPOCH" '+%H:%M:%S')
    HADOOP_S=$((H_EPOCH - START_EPOCH)); REST_S=$((END_EPOCH - H_EPOCH))
else
    HADOOP_END=NA; HADOOP_S=NA; REST_S=NA
fi

# ---------- CPU / RAM ----------
read -r PEAK_CPU MEAN_CPU PEAK_RAM < <(awk '{c+=$1; n++; if($1>pc)pc=$1; if($2>pr)pr=$2}
    END{ if(n) printf "%.1f %.1f %.2f\n",pc,c/n,pr; else print "NA NA NA" }' "$SAMPLES")
rm -f "$SAMPLES"

# ---------- Error / log (always filled, no commas or quotes) ----------
LOGNAME_ONLY="$(basename "$LOG")"
first_log_error() {
    sed -E 's/^\[[^]]*\] //' "$LOG" \
        | grep -iE 'error|failed|fatal|exception|cannot|unable|refused|denied' \
        | grep -viE 'libgpg-error|debconf|WARN|NativeCodeLoader' \
        | head -1 | cut -c1-100 | tr -d '",'
}
if [ "$OUTCOME" -eq 2 ]; then
    ERR_LOG="No error - $LOGNAME_ONLY"
else
    FE="$(first_log_error)"
    ERR_LOG="Failed: FADTESE stopped (exit $RC)${FE:+ | first log error: $FE} - $LOGNAME_ONLY"
fi

# ---------- Save CSV rows ----------
[ -f "$P0_CSV" ] || echo "date,run_start,bandwidth_mbps,latency_ms,packet_loss_pct,free_disk_gb,run_end" > "$P0_CSV"
echo "$P0_DATE,$START_HMS,$P0_BW,$P0_LAT,$P0_LOSS,$P0_FREE,$END_HMS" >> "$P0_CSV"
rm -f "$PENDING"

[ -f "$CSV" ] || echo "date,stage,start,end,duration_s,download_time_s,data_downloaded_mb,attempts,recovery_time_s,outcome,peak_cpu_pct,mean_cpu_pct,peak_ram_gb,error_log" > "$CSV"
echo "$(date +%Y-%m-%d),$STAGE,$START_HMS,$END_HMS,$DURATION,$DL_TIME,$DATA_MB,$ATTEMPTS,$RECOVERY,$OUTCOME,$PEAK_CPU,$MEAN_CPU,$PEAK_RAM,\"$ERR_LOG\"" >> "$CSV"

[ -f "$SPLIT_CSV" ] || echo "date,run_id,run_start,hadoop_end,hadoop_part_s,rest_part_s,exit_code,sha256" > "$SPLIT_CSV"
echo "$(date +%Y-%m-%d),$RUN_ID,$START_HMS,$HADOOP_END,$HADOOP_S,$REST_S,$RC,${SHA:0:12}" >> "$SPLIT_CSV"

{
echo ""
echo "----- Part 0: $RUN_ID -----"
echo "Date                                   : $P0_DATE"
echo "Run start / end                        : $START_HMS / $END_HMS"
echo "Network bandwidth (Mbit/s)             : $P0_BW"
echo "Network latency (ms) / packet loss (%) : $P0_LAT / $P0_LOSS"
echo "Free disk before run (GB)              : $P0_FREE"
echo "----- Part 1: $STAGE (install_big_data_utilities.sh) -----"
echo "Start / End          : $START_HMS / $END_HMS"
echo "Duration (s)         : $DURATION"
echo "  Hadoop part (s)    : $HADOOP_S   (start -> Hadoop daemons started at $HADOOP_END; compare with IFADEG S1)"
echo "  Rest (s)           : $REST_S   (Sqoop, connectors, Python, version printout)"
echo "Download time (s)    : $DL_TIME"
echo "Data downloaded (MB) : $DATA_MB"
echo "Attempts             : $ATTEMPTS (FADTESE has no retry)"
echo "Recovery time (s)    : $RECOVERY"
echo "Outcome (2/0)        : $OUTCOME (final value is set by verify_fadtese.sh)"
echo "Peak / Mean CPU (%)  : $PEAK_CPU / $MEAN_CPU"
echo "Peak RAM (GB)        : $PEAK_RAM"
echo "Error / log          : $ERR_LOG"
echo "Exit code / SHA-256  : $RC / ${SHA:0:12}   (0 = script finished)"
echo "-----------------------------------------------"
echo "Saved: $P0_CSV, $CSV and $SPLIT_CSV"
echo "Next:  ./verify_fadtese.sh"
} | tee -a "$LOG"
exit "$RC"
