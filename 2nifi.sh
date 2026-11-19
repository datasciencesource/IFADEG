#!/bin/bash
# 2nifi.sh - IFADEG Stage S2: NiFi
# Usage:  sudo ./2nifi.sh        (must run as root: the install uses apt without sudo)
#
# PART 1 (S2): Start, End, Duration (s), Download time (s), Data downloaded (MB),
#              Attempts, Recovery time (s), Outcome (2/1/0/NR),
#              Peak CPU (%), Mean CPU (%), Peak RAM (GB), Error / log
# Outcome: 2 = success on 1st attempt, 1 = success after retry, 0 = failed,
#          NR = not reached (S1 failed, so S2 is not run)
# Success = D2 + D7 + D9 all pass:
#   D2  /opt/nifi/bin/nifi.sh and /opt/nifi/lib/nifi-api-1.28.1.jar exist
#   D7  nifi.sh status reports running (polled every 15 s, up to 5 min)
#   D9  https://localhost:8443/nifi/ returns 200 or 302 (polled every 15 s, up to 5 min)
# Recovery time: 0 if no failure; failure -> success if recovered; time spent retrying if failed (I_REC = 0).
# Output:  <user home>/ifadeg_logs/S2_<date_time>.log and one row in part1.csv

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root:  sudo ./2nifi.sh"
    exit 1
fi

RUN_TS="$(date +%Y%m%d_%H%M%S)"   # log name; Run ID is recorded manually
STAGE="S2"
MAX_ATTEMPTS=3
# Same log folder as S1: the home of the user who called sudo (or root's home if run as root)
if [ -n "${SUDO_USER:-}" ]; then
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    USER_HOME="$HOME"
fi
LOG_DIR="$USER_HOME/ifadeg_logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${STAGE}_${RUN_TS}.log"
CSV="$LOG_DIR/part1.csv"
SAMPLES="$LOG_DIR/.${STAGE}_${RUN_TS}.samples"
: > "$SAMPLES"
: > "$LOG"

# Send all output to screen + log, with a timestamp on every line
exec > >(while IFS= read -r l; do printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$l"; done | tee -a "$LOG") 2>&1

[ -f "$CSV" ] || echo "date,stage,start,end,duration_s,download_time_s,data_downloaded_mb,attempts,recovery_time_s,outcome,peak_cpu_pct,mean_cpu_pct,peak_ram_gb,error_log" > "$CSV"

fix_owner() { [ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER": "$LOG_DIR" 2>/dev/null; }

# ---------- NR check: was S1 successful? ----------
LAST_S1_OUTCOME=$(awk -F',' '$2=="S1"{o=$10} END{print o}' "$CSV")
if [ "$LAST_S1_OUTCOME" = "0" ] || [ "$LAST_S1_OUTCOME" = "NR" ]; then
    echo "[IFADEG] S1 outcome = $LAST_S1_OUTCOME, so S2 is not reached (NR)"
    echo "$(date +%Y-%m-%d),$STAGE,NA,NA,NA,NA,NA,0,NA,NR,NA,NA,NA,\"Not reached: S1 failed - $(basename "$LOG")\"" >> "$CSV"
    echo "----- Part 1: $STAGE (2nifi.sh) -----"
    echo "Outcome (2/1/0)      : NR (not reached, S1 failed)"
    echo "-----------------------------------------------"
    sleep 1; rm -f "$SAMPLES"; fix_owner
    exit 1
fi
[ -z "$LAST_S1_OUTCOME" ] && echo "[IFADEG] note: no S1 row found in part1.csv, running S2 anyway"

# ############################################################
# PART 1: Deployment evaluation - S2 NiFi
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

# HTTP status code of a URL (curl if installed, otherwise wget); 000 = no answer
http_code() {
    if command -v curl >/dev/null 2>&1; then
        curl -k -s -o /dev/null -w "%{http_code}" --max-time 10 "$1"
    else
        c=$(wget --no-check-certificate --max-redirect=0 --timeout=10 --tries=1 -S -O /dev/null "$1" 2>&1 \
            | awk '/^  HTTP\//{print $2; exit}')
        echo "${c:-000}"
    fi
}

# S2 verification: D2, D7, D9 (from Instrument 1)
# Sets ITEMS (per-item results) and FAIL_MSG (empty if all pass)
verify_s2() {
    ITEMS=""; FAIL_MSG=""
    # D2: files exist
    if ls /opt/nifi/bin/nifi.sh /opt/nifi/lib/nifi-api-1.28.1.jar >/dev/null 2>&1; then
        ITEMS="D2 PASS"
    else
        ITEMS="D2 FAIL"; FAIL_MSG="D2 NiFi files missing"
        return 1
    fi
    # D7: nifi.sh status reports running (every 15 s, up to 5 min)
    T0=$(date +%s); D7=0
    while [ $(( $(date +%s) - T0 )) -le 300 ]; do
        if /opt/nifi/bin/nifi.sh status 2>/dev/null | grep -q "is currently running"; then D7=1; break; fi
        sleep 15
    done
    if [ "$D7" -eq 1 ]; then
        ITEMS="$ITEMS · D7 PASS (after $(( $(date +%s) - T0 )) s)"
    else
        ITEMS="$ITEMS · D7 FAIL"; FAIL_MSG="D7 NiFi not running after 5 min"
        return 1
    fi
    # D9: web UI returns 200 or 302 (every 15 s, up to 5 min)
    T0=$(date +%s); CODE="000"
    while [ $(( $(date +%s) - T0 )) -le 300 ]; do
        CODE=$(http_code https://localhost:8443/nifi/)
        case "$CODE" in 200|302) break ;; esac
        sleep 15
    done
    case "$CODE" in
        200|302) ITEMS="$ITEMS · D9 PASS (HTTP $CODE after $(( $(date +%s) - T0 )) s)"; return 0 ;;
        *)       ITEMS="$ITEMS · D9 FAIL (HTTP $CODE)"; FAIL_MSG="D9 web UI not reachable (HTTP $CODE)"; return 1 ;;
    esac
}

# ================= ORIGINAL S2 INSTALLATION =================
# Changes: wget is timed; unzip runs with -q (shorter log). Nothing else changed.
install_s2() {
source ~/.bashrc
apt update -y
apt install unzip wget -y

cd /opt

rm -rf nifi nifi-1.28.1 nifi-1.28.1-bin.zip

WGET_T0=$(date +%s.%N)
wget https://archive.apache.org/dist/nifi/1.28.1/nifi-1.28.1-bin.zip
echo "[IFADEG] wget_seconds=$(awk -v a="$WGET_T0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')"

unzip -q nifi-1.28.1-bin.zip

mv nifi-1.28.1 nifi

chmod -R 755 /opt/nifi

cd /opt/nifi

./bin/nifi.sh set-single-user-credentials admin Admin123456789

source ~/.bashrc

./bin/nifi.sh start

./bin/nifi.sh status
}
# ================= END ORIGINAL S2 INSTALLATION =================

# ---------- run S2 with measurement (S2 clock starts here) ----------
START_EPOCH=$(date +%s); START_HMS=$(date '+%H:%M:%S')
RX0=$(rx_bytes)
sampler & SAMPLER_PID=$!
trap 'kill $SAMPLER_PID 2>/dev/null' EXIT

ATTEMPTS=0; PASSED=0; FIRST_FAIL_EPOCH=""; FIRST_FAIL_MSG=""; LAST_FAIL_MSG=""
while [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
    ATTEMPTS=$((ATTEMPTS+1))
    echo "===== IFADEG $STAGE attempt $ATTEMPTS ====="
    if [ "$ATTEMPTS" -gt 1 ]; then
        # Clean up before retry: stop NiFi so port 8443 is free for the new start
        [ -x /opt/nifi/bin/nifi.sh ] && /opt/nifi/bin/nifi.sh stop >/dev/null 2>&1
        pkill -f 'org.apache.nifi' 2>/dev/null; sleep 5
        echo "[IFADEG] retry cleanup done (NiFi stopped)"
    fi
    ( install_s2 )                      # subshell: "cd" and "exit" stay inside
    if verify_s2; then
        PASSED=1; echo "[IFADEG] verify PASS: $ITEMS"
        break
    fi
    echo "[IFADEG] verify FAIL: $FAIL_MSG ($ITEMS)"
    LAST_FAIL_MSG="$FAIL_MSG"
    if [ -z "$FIRST_FAIL_EPOCH" ]; then FIRST_FAIL_EPOCH=$(date +%s); FIRST_FAIL_MSG="$FAIL_MSG"; fi
done

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

# Download time (s): apt "Fetched ... in Xs" + measured wget time
sleep 1   # let the log catch up
DL_TIME=$( { grep -oE 'Fetched .* in [0-9]+(h|min|s)( [0-9]+(min|s))?' "$LOG" | sed -E 's/.* in //; s/min/m/g'
             grep -oE '\[IFADEG\] wget_seconds=[0-9.]+' "$LOG" | sed -E 's/.*=//; s/$/s/'; } |
    awk '{s=$0; while (match(s,/[0-9.]+[hms]/)) { tok=substr(s,RSTART,RLENGTH); n=substr(tok,1,length(tok)-1)+0; u=substr(tok,length(tok));
          t += (u=="h")?n*3600:(u=="m")?n*60:n; s=substr(s,RSTART+RLENGTH) } } END{printf "%.1f", t+0}')

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
    grep -iE 'error|failed|fatal|exception|cannot|unable|refused' "$LOG" \
        | grep -viE 'libgpg-error|IFADEG|debconf|WARN' \
        | grep -vE '\] nifi-1\.28\.1/' \
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

echo ""
echo "----- Part 1: $STAGE (2nifi.sh) -----"
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
echo "-----------------------------------------------"
echo "Saved: $CSV"
sleep 1; fix_owner
