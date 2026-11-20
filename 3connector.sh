#!/bin/bash
# 3connector.sh - IFADEG Stage S3: MySQL Connector/J for NiFi
# Usage:  sudo ./3connector.sh        (must run as root: writes to /opt without sudo)
#
# PART 1 (S3): Start, End, Duration (s), Download time (s), Data downloaded (MB),
#              Attempts, Recovery time (s), Outcome (2/1/0/NR),
#              Peak CPU (%), Mean CPU (%), Peak RAM (GB), Error / log
# Outcome: 2 = success on 1st attempt, 1 = success after retry, 0 = failed,
#          NR = not reached (S2 failed or was not reached, so S3 is not run)
# Success = D3: /opt/nifi/mysql-connector-j-8.4.0/mysql-connector-j-8.4.0.jar exists (and is not empty)
# Item score: 2 = passed on attempt 1, 1 = passed on a later attempt, 0 = not passed at the end, NR = not reached
# Recovery time: 0 if no failure; failure -> success if recovered; time spent retrying if failed (I_REC = 0).
# Output:  <user home>/ifadeg_logs/S3_<date_time>.log, one row in part1.csv, D3 row in items.csv

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root:  sudo ./3connector.sh"
    exit 1
fi

RUN_TS="$(date +%Y%m%d_%H%M%S)"   # log name; Run ID is recorded manually
STAGE="S3"
MAX_ATTEMPTS=3
JAR="/opt/nifi/mysql-connector-j-8.4.0/mysql-connector-j-8.4.0.jar"
# Same log folder as S1/S2: the home of the user who called sudo (or root's home if run as root)
if [ -n "${SUDO_USER:-}" ]; then
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    USER_HOME="$HOME"
fi
LOG_DIR="$USER_HOME/ifadeg_logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${STAGE}_${RUN_TS}.log"
CSV="$LOG_DIR/part1.csv"
ITEMS_CSV="$LOG_DIR/items.csv"
SAMPLES="$LOG_DIR/.${STAGE}_${RUN_TS}.samples"
: > "$SAMPLES"
: > "$LOG"

# Send all output to screen + log, with a timestamp on every line
exec > >(while IFS= read -r l; do printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$l"; done | tee -a "$LOG") 2>&1

[ -f "$CSV" ] || echo "date,stage,start,end,duration_s,download_time_s,data_downloaded_mb,attempts,recovery_time_s,outcome,peak_cpu_pct,mean_cpu_pct,peak_ram_gb,error_log" > "$CSV"
[ -f "$ITEMS_CSV" ] || echo "date,stage,stage_start,item,result,score,evidence" > "$ITEMS_CSV"

fix_owner() { [ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER": "$LOG_DIR" 2>/dev/null; }

# ---------- NR check: was the previous stage (S2) successful? ----------
LAST_S2_OUTCOME=$(awk -F',' '$2=="S2"{o=$10} END{print o}' "$CSV")
if [ "$LAST_S2_OUTCOME" = "0" ] || [ "$LAST_S2_OUTCOME" = "NR" ]; then
    echo "[IFADEG] S2 outcome = $LAST_S2_OUTCOME, so S3 is not reached (NR)"
    echo "$(date +%Y-%m-%d),$STAGE,NA,NA,NA,NA,NA,0,NA,NR,NA,NA,NA,\"Not reached: S2 failed or not reached - $(basename "$LOG")\"" >> "$CSV"
    echo "----- Part 1: $STAGE (3connector.sh) -----"
    echo "Outcome (2/1/0)      : NR (not reached, S2 failed or not reached)"
    echo "$(date +%Y-%m-%d),$STAGE,NA,D3,NR,NR,\"Not reached: S2 failed or not reached\"" >> "$ITEMS_CSV"
    echo "Deployment items     : D3 NR"
    echo "Item scores          : D3 = NR"
    echo "-----------------------------------------------"
    sleep 1; rm -f "$SAMPLES"; fix_owner
    exit 1
fi
[ -z "$LAST_S2_OUTCOME" ] && echo "[IFADEG] note: no S2 row found in part1.csv, running S3 anyway"

# ############################################################
# PART 1: Deployment evaluation - S3 Connector/J
# ############################################################

# ---------- CPU / RAM sampler (every 1 s, whole VM) ----------
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

# S3 verification: D3 (from Instrument 1)
# Sets D3_OK (1/0), D3_EV (evidence), ITEMS (summary) and FAIL_MSG (empty if pass)
verify_s3() {
    FAIL_MSG=""
    if [ -s "$JAR" ]; then
        D3_OK=1; D3_EV="file exists ($(du -h "$JAR" | cut -f1))"
        ITEMS="D3 PASS ($D3_EV)"
        return 0
    fi
    D3_OK=0; D3_EV="JAR missing or empty"
    ITEMS="D3 FAIL ($D3_EV)"
    FAIL_MSG="D3 Connector/J JAR missing in /opt/nifi/mysql-connector-j-8.4.0"
    return 1
}

# ================= ORIGINAL S3 INSTALLATION =================
# Changes: wget is timed. Nothing else changed.
install_s3() {
cd /opt || exit

# Download MySQL Connector/J
WGET_T0=$(date +%s.%N)
wget -O mysql-connector-j-8.4.0.tar.gz https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-j-8.4.0.tar.gz
echo "[IFADEG] wget_seconds=$(awk -v a="$WGET_T0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')"

# Extract
tar -xzf mysql-connector-j-8.4.0.tar.gz

# Create NiFi JDBC driver directory
mkdir -p /opt/nifi/mysql-connector-j-8.4.0

# Copy JAR file
cp mysql-connector-j-8.4.0/mysql-connector-j-8.4.0.jar /opt/nifi/mysql-connector-j-8.4.0/

# Set permissions
chmod 644 /opt/nifi/mysql-connector-j-8.4.0/mysql-connector-j-8.4.0.jar

# Verify
ls -lh /opt/nifi/mysql-connector-j-8.4.0/mysql-connector-j-8.4.0.jar
}
# ================= END ORIGINAL S3 INSTALLATION =================

# ---------- run S3 with measurement (S3 clock starts here) ----------
START_EPOCH=$(date +%s); START_HMS=$(date '+%H:%M:%S')
RX0=$(rx_bytes)
sampler & SAMPLER_PID=$!
trap 'kill $SAMPLER_PID 2>/dev/null' EXIT

ATTEMPTS=0; PASSED=0; FIRST_FAIL_EPOCH=""; FIRST_FAIL_MSG=""; LAST_FAIL_MSG=""; D3_FIRST=""
while [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
    ATTEMPTS=$((ATTEMPTS+1))
    echo "===== IFADEG $STAGE attempt $ATTEMPTS ====="
    if [ "$ATTEMPTS" -gt 1 ]; then
        # Clean up before retry: remove a partial/broken download and extract
        rm -rf /opt/mysql-connector-j-8.4.0.tar.gz /opt/mysql-connector-j-8.4.0
        echo "[IFADEG] retry cleanup done (partial download removed)"
    fi
    ( install_s3 )                      # subshell: "cd" and "exit" stay inside
    verify_s3; VRC=$?
    [ "$D3_OK" -eq 1 ] && [ -z "$D3_FIRST" ] && D3_FIRST=$ATTEMPTS
    if [ "$VRC" -eq 0 ]; then
        PASSED=1; echo "[IFADEG] verify PASS: $ITEMS"
        break
    fi
    echo "[IFADEG] verify FAIL: $FAIL_MSG"
    LAST_FAIL_MSG="$FAIL_MSG"
    if [ -z "$FIRST_FAIL_EPOCH" ]; then FIRST_FAIL_EPOCH=$(date +%s); FIRST_FAIL_MSG="$FAIL_MSG"; fi
done

sleep 1   # S3 is short: give the sampler at least one CPU/RAM sample
kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null
END_EPOCH=$(date +%s); END_HMS=$(date '+%H:%M:%S')
RX1=$(rx_bytes)
DURATION=$((END_EPOCH - START_EPOCH))

# Outcome and recovery time
if   [ "$PASSED" -eq 1 ] && [ "$ATTEMPTS" -eq 1 ]; then OUTCOME=2; RECOVERY=0
elif [ "$PASSED" -eq 1 ]; then OUTCOME=1; RECOVERY=$((END_EPOCH - FIRST_FAIL_EPOCH))
else OUTCOME=0; RECOVERY=$((END_EPOCH - FIRST_FAIL_EPOCH))   # time spent on retries; I_REC = 0 in Part 4
fi

# Data downloaded (MB, 1 MB = 1,000,000 bytes, same base as speedtest Mbit/s)
DATA_MB=$(awk -v a="$RX0" -v b="$RX1" 'BEGIN{printf "%.1f",(b-a)/1000000}')

# Download time (s): measured wget time (S3 has no apt step)
sleep 1   # let the log catch up
DL_TIME=$(grep -oE '\[IFADEG\] wget_seconds=[0-9.]+' "$LOG" | sed -E 's/.*=//' | awk '{t+=$1} END{printf "%.1f", t+0}')

# CPU / RAM
read -r PEAK_CPU MEAN_CPU PEAK_RAM < <(awk '{c+=$1; n++; if($1>pc)pc=$1; if($2>pr)pr=$2}
    END{ if(n) printf "%.1f %.1f %.2f\n",pc,c/n,pr; else print "NA NA NA" }' "$SAMPLES")
rm -f "$SAMPLES"

# Error / log: always filled
#   2 -> "No error - <log>"
#   1 -> "Recovered: <first failure> (attempt 1) - <log>"
#   0 -> "Failed: <last failure> | first log error: <line> - <log>"
LOGNAME_ONLY="$(basename "$LOG")"
first_log_error() {
    grep -iE 'error|failed|fatal|exception|cannot|unable|refused|not found' "$LOG" \
        | grep -viE 'IFADEG|WARN' \
        | head -1 | sed -E 's/^\[[^]]*\] //' | cut -c1-100 | tr -d '",'
}
if [ "$OUTCOME" -eq 2 ]; then
    ERR_LOG="No error - $LOGNAME_ONLY"
elif [ "$OUTCOME" -eq 1 ]; then
    ERR_LOG="Recovered: $FIRST_FAIL_MSG (attempt 1) - $LOGNAME_ONLY"
else
    FE="$(first_log_error)"
    ERR_LOG="Failed: $LAST_FAIL_MSG${FE:+ | first log error: $FE} - $LOGNAME_ONLY"
fi

# Save one row to part1.csv
echo "$(date +%Y-%m-%d),$STAGE,$START_HMS,$END_HMS,$DURATION,$DL_TIME,$DATA_MB,$ATTEMPTS,$RECOVERY,$OUTCOME,$PEAK_CPU,$MEAN_CPU,$PEAK_RAM,\"$ERR_LOG\"" >> "$CSV"

# Item score (2 = passed on attempt 1, 1 = passed later, 0 = not passed at the end)
item_score() {  # $1 = passes now (1/0), $2 = first attempt it passed
    if [ "$1" -eq 1 ]; then [ "$2" = "1" ] && echo 2 || echo 1; else echo 0; fi
}
D3_SCORE=$(item_score "$D3_OK" "$D3_FIRST")
echo "$(date +%Y-%m-%d),$STAGE,$START_HMS,D3,$( [ "$D3_OK" -eq 1 ] && echo PASS || echo FAIL ),$D3_SCORE,\"$(echo "$D3_EV" | tr -d '",')\"" >> "$ITEMS_CSV"

echo ""
echo "----- Part 1: $STAGE (3connector.sh) -----"
echo "Start / End          : $START_HMS / $END_HMS"
echo "Duration (s)         : $DURATION"
echo "Download time (s)    : $DL_TIME"
echo "Data downloaded (MB) : $DATA_MB"
echo "Attempts             : $ATTEMPTS"
echo "Recovery time (s)    : $RECOVERY"
echo "Outcome (2/1/0)      : $OUTCOME"
echo "Peak / Mean CPU (%)  : $PEAK_CPU / $MEAN_CPU"
echo "Peak RAM (GB)        : $PEAK_RAM"
echo "Error / log          : $ERR_LOG"
echo "Deployment items     : $ITEMS"
echo "Item scores          : D3 = $D3_SCORE"
echo "-----------------------------------------------"
echo "Saved: $CSV and $ITEMS_CSV"
sleep 1; fix_owner
