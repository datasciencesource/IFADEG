#!/bin/bash
# =====================================================================
# 2run.sh - Instrument Part 1: Deployment evaluation (FADTESE)
# Starts recording, runs install_big_data_utilities.sh UNCHANGED, ends recording.
#
# Records: Start/End, Duration (s), Download time (s), Data downloaded (MB),
#          Attempts (1), Recovery time (0), Outcome (2/0),
#          Peak / Mean CPU (%), Peak RAM (GB), Error / log
#
# Usage (as root, after ./1part0.sh):  ./2run.sh
# Output: summary on screen + one row in /root/ifadeg_logs/part1.csv
#         full FADTESE output in /root/ifadeg_logs/fadtese_<date_time>.log
# =====================================================================

[ "$(id -u)" -ne 0 ] && { echo "Please run as root: sudo -i"; exit 1; }

SCRIPT="/install_big_data_utilities.sh"
URL="https://raw.githubusercontent.com/datasciencesource/bash-script/main/install_big_data_utilities.sh"
LOG_DIR="/root/ifadeg_logs"
CSV="$LOG_DIR/part1.csv"
TS=$(date +%Y%m%d_%H%M%S)
LOG="$LOG_DIR/fadtese_${TS}.log"
SAMPLES="$LOG_DIR/.samples_${TS}"
mkdir -p "$LOG_DIR"

# Get the published FADTESE script into / if it is not there (before the clock starts)
if [ ! -f "$SCRIPT" ]; then
    echo "Downloading FADTESE script to $SCRIPT"
    wget -q -O "$SCRIPT" "$URL" || { echo "Download failed: $URL"; exit 1; }
fi
chmod +x "$SCRIPT"

# CPU / RAM sampler: whole VM, every 1 s
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

# Bytes received on all network interfaces except lo
rx_bytes() {
    awk 'NR>2 { line=$0; sub(/^[ \t]+/, "", line); split(line, a, ":")
                if (a[1] != "lo") { split(a[2], b, " "); s += b[1] } }
         END { printf "%.0f", s+0 }' /proc/net/dev
}

# ================= START RECORD =================
: > "$SAMPLES"
START_EPOCH=$(date +%s); START_HMS=$(date '+%H:%M:%S')
RX0=$(rx_bytes)
sampler & SAMPLER_PID=$!
trap 'kill $SAMPLER_PID 2>/dev/null; rm -f "$SAMPLES"' EXIT
echo "===== Recording started $START_HMS - running FADTESE ====="

# ================= RUN FADTESE (unchanged) =================
cd /root || exit 1
"$SCRIPT" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}

# ================= END RECORD =================
kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null
END_EPOCH=$(date +%s); END_HMS=$(date '+%H:%M:%S')
RX1=$(rx_bytes)

# Duration (s)
DURATION=$((END_EPOCH - START_EPOCH))

# Data downloaded (MB, 1 MB = 1,000,000 bytes)
DATA_MB=$(awk -v a="$RX0" -v b="$RX1" 'BEGIN{printf "%.1f",(b-a)/1000000}')

# Download time (s): apt "Fetched ... in Xs" lines + wget "100% ...=Xs" lines
DL_TIME=$( {
    grep -oE 'Fetched .* in [0-9]+(h|min|s)( [0-9]+(min|s))?' "$LOG" | sed -E 's/.* in //; s/min/m/g'
    grep -E '100%.*=[0-9.]+[hms]' "$LOG" | sed -E 's/.*=([0-9hms.]+)[[:space:]]*$/\1/'
} | awk 'NF{ s=$0; while (match(s,/[0-9.]+[hms]/)) { tok=substr(s,RSTART,RLENGTH);
          n=substr(tok,1,length(tok)-1)+0; u=substr(tok,length(tok)); t += (u=="h")?n*3600:(u=="m")?n*60:n;
          s=substr(s,RSTART+RLENGTH) }; found=1 } END{ if(found) printf "%.1f", t+0; else print "NA" }')

# Attempts / Recovery time: FADTESE has no retry
ATTEMPTS=1; RECOVERY=0

# Outcome: 2 = FADTESE finished (exit 0), 0 = FADTESE stopped with an error
[ "$RC" -eq 0 ] && OUTCOME=2 || OUTCOME=0

# Peak / Mean CPU (%), Peak RAM (GB)
read -r PEAK_CPU MEAN_CPU PEAK_RAM < <(awk '{c+=$1; n++; if($1>pc)pc=$1; if($2>pr)pr=$2}
    END{ if(n) printf "%.1f %.1f %.2f\n",pc,c/n,pr; else print "NA NA NA" }' "$SAMPLES")

# Error / log
LOGNAME_ONLY=$(basename "$LOG")
if [ "$OUTCOME" -eq 2 ]; then
    ERR_LOG="No error - $LOGNAME_ONLY"
else
    FE=$(grep -iE 'error|failed|fatal|exception|cannot|unable|refused|denied' "$LOG" \
         | grep -viE 'libgpg-error|debconf|WARN|NativeCodeLoader' | head -1 | cut -c1-100 | tr -d '",')
    ERR_LOG="Failed: exit $RC${FE:+ | $FE} - $LOGNAME_ONLY"
fi

# Save
[ -f "$CSV" ] || echo "date,start,end,duration_s,download_time_s,data_downloaded_mb,attempts,recovery_time_s,outcome,peak_cpu_pct,mean_cpu_pct,peak_ram_gb,exit_code,error_log" > "$CSV"
echo "$(date +%F),$START_HMS,$END_HMS,$DURATION,$DL_TIME,$DATA_MB,$ATTEMPTS,$RECOVERY,$OUTCOME,$PEAK_CPU,$MEAN_CPU,$PEAK_RAM,$RC,\"$ERR_LOG\"" >> "$CSV"

# Show (summary for the form)
{
echo ""
echo "----- Part 1: FADTESE (install_big_data_utilities.sh) -----"
echo "Start / End          : $START_HMS / $END_HMS"
echo "Duration (s)         : $DURATION"
echo "Download time (s)    : $DL_TIME"
echo "Data downloaded (MB) : $DATA_MB"
echo "Attempts             : $ATTEMPTS"
echo "Recovery time (s)    : $RECOVERY"
echo "Outcome (2/0)        : $OUTCOME   (exit code $RC)"
echo "Peak / Mean CPU (%)  : $PEAK_CPU / $MEAN_CPU"
echo "Peak RAM (GB)        : $PEAK_RAM"
echo "Error / log          : $ERR_LOG"
echo "-----------------------------------------------------------"
echo "Saved: $CSV"
} | tee -a "$LOG"
exit "$RC"
