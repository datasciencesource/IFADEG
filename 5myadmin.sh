#!/bin/bash
# 5myadmin.sh - IFADEG Stage S5: phpMyAdmin (last stage of the pipeline)
# Usage:  sudo ./5myadmin.sh        (must run as root: the install uses apt without sudo)
#
# PART 1 (S5): Start, End, Duration (s), Download time (s), Data downloaded (MB),
#              Attempts, Recovery time (s), Outcome (2/1/0/NR),
#              Peak CPU (%), Mean CPU (%), Peak RAM (GB), Error / log
# Outcome: 2 = success on 1st attempt, 1 = success after retry, 0 = failed,
#          NR = not reached (S4 failed or was not reached, so S5 is not run)
# Success = D5 + D10 both pass:
#   D5   dpkg -s phpmyadmin shows "Status: install ok installed"
#   D10  http://localhost/phpmyadmin/ returns 200 (polled up to 60 s)
# Item score: 2 = passed on attempt 1, 1 = passed on a later attempt, 0 = not passed at the end, NR = not reached
# Recovery time: 0 if no failure; failure -> success if recovered; time spent retrying if failed (I_REC = 0).
#
# Order of work:
#   1. S5 stage: measured exactly like S1-S4 (its own Part 1 row; the S5 clock covers S5 only)
#   2. Run end time of the whole pipeline = S5 End time (if S5 is NR: the moment the pipeline stopped)
#      -> printed and saved in part0.csv (run_end column)
#
# Output:  <user home>/ifadeg_logs/S5_<date_time>.log, one row in part1.csv, D5 + D10 rows in items.csv,
#          run_end in part0.csv

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root:  sudo ./5myadmin.sh"
    exit 1
fi

RUN_TS="$(date +%Y%m%d_%H%M%S)"   # log name; Run ID is recorded manually
STAGE="S5"
MAX_ATTEMPTS=3
# Same log folder as S1-S4: the home of the user who called sudo (or root's home if run as root)
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
P0_CSV="$LOG_DIR/part0.csv"
SAMPLES="$LOG_DIR/.${STAGE}_${RUN_TS}.samples"
: > "$SAMPLES"
: > "$LOG"

# Send all output to screen + log, with a timestamp on every line
exec > >(while IFS= read -r l; do printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$l"; done | tee -a "$LOG") 2>&1

[ -f "$CSV" ] || echo "date,stage,start,end,duration_s,download_time_s,data_downloaded_mb,attempts,recovery_time_s,outcome,peak_cpu_pct,mean_cpu_pct,peak_ram_gb,error_log" > "$CSV"
[ -f "$ITEMS_CSV" ] || echo "date,stage,stage_start,item,result,score,evidence" > "$ITEMS_CSV"

fix_owner() { [ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER": "$LOG_DIR" 2>/dev/null; }

# ############################################################
# END OF PIPELINE: run end time (= S5 end), saved in part0.csv
# ############################################################
save_run_end() {   # $1 = run end time (hh:mm:ss)
    [ -f "$P0_CSV" ] || return
    # add a run_end column to the header if it is not there yet
    head -1 "$P0_CSV" | grep -q 'run_end' || sed -i '1s/$/,run_end/' "$P0_CSV"
    # write run_end into the last (= this run's) Part 0 row
    awk -F',' -v e="$1" 'BEGIN{OFS=","} { lines[NR]=$0; nf[NR]=NF }
        END { for (i=1;i<=NR;i++) { if (i==NR && i>1 && nf[i]==6) print lines[i] "," e; else print lines[i] } }' \
        "$P0_CSV" > "$P0_CSV.tmp" && mv "$P0_CSV.tmp" "$P0_CSV"
}

# ---------- NR check: was the previous stage (S4) successful? ----------
LAST_S4_OUTCOME=$(awk -F',' '$2=="S4"{o=$10} END{print o}' "$CSV")
if [ "$LAST_S4_OUTCOME" = "0" ] || [ "$LAST_S4_OUTCOME" = "NR" ]; then
    echo "[IFADEG] S4 outcome = $LAST_S4_OUTCOME, so S5 is not reached (NR)"
    echo "$(date +%Y-%m-%d),$STAGE,NA,NA,NA,NA,NA,0,NA,NR,NA,NA,NA,\"Not reached: S4 failed or not reached - $(basename "$LOG")\"" >> "$CSV"
    for it in D5 D10; do
        echo "$(date +%Y-%m-%d),$STAGE,NA,$it,NR,NR,\"Not reached: S4 failed or not reached\"" >> "$ITEMS_CSV"
    done
    echo "----- Part 1: $STAGE (5myadmin.sh) -----"
    echo "Outcome (2/1/0)      : NR (not reached, S4 failed or not reached)"
    echo "Item scores          : D5 = NR · D10 = NR"
    echo "-----------------------------------------------"
    RUN_END_HMS=$(date '+%H:%M:%S')            # pipeline stopped before S5: end = now
    echo "RUN END TIME (whole pipeline)            : $RUN_END_HMS (pipeline stopped before S5)"
    save_run_end "$RUN_END_HMS"
    sleep 1; rm -f "$SAMPLES"; fix_owner
    exit 1
fi
[ -z "$LAST_S4_OUTCOME" ] && echo "[IFADEG] note: no S4 row found in part1.csv, running S5 anyway"

# ############################################################
# PART 1: Deployment evaluation - S5 phpMyAdmin
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
        curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$1"
    else
        c=$(wget --max-redirect=0 --timeout=10 --tries=1 -S -O /dev/null "$1" 2>&1 \
            | awk '/^  HTTP\//{print $2; exit}')
        echo "${c:-000}"
    fi
}

# S5 verification: D5, D10 (from Instrument 1)
# Sets D5_OK/D10_OK (1/0), D5_EV/D10_EV (evidence), ITEMS (summary), FAIL_MSG (empty if all pass)
verify_s5() {
    FAIL_MSG=""
    # D5: dpkg -s phpmyadmin -> Status: install ok installed
    if dpkg -s phpmyadmin 2>/dev/null | grep -q '^Status: install ok installed'; then
        D5_OK=1; D5_EV="Status: install ok installed ($(dpkg -s phpmyadmin 2>/dev/null | awk '/^Version:/{print $2}'))"
    else
        D5_OK=0; D5_EV="not installed"
        FAIL_MSG="D5 phpMyAdmin package not installed"
    fi
    # D10: http://localhost/phpmyadmin/ returns 200 (every 10 s, up to 60 s)
    T0=$(date +%s); CODE="000"
    while [ $(( $(date +%s) - T0 )) -le 60 ]; do
        CODE=$(http_code http://localhost/phpmyadmin/)
        [ "$CODE" = "200" ] && break
        sleep 10
    done
    if [ "$CODE" = "200" ]; then
        D10_OK=1; D10_EV="HTTP 200"
    else
        D10_OK=0; D10_EV="HTTP $CODE"
        FAIL_MSG="${FAIL_MSG:+$FAIL_MSG; }D10 phpMyAdmin page not reachable (HTTP $CODE)"
    fi
    pf() { [ "$1" -eq 1 ] && echo PASS || echo FAIL; }
    ITEMS="D5 $(pf $D5_OK) ($D5_EV) · D10 $(pf $D10_OK) ($D10_EV)"
    [ "$D5_OK" -eq 1 ] && [ "$D10_OK" -eq 1 ]
}

# ================= ORIGINAL S5 INSTALLATION =================
# Unchanged.
install_s5() {
PHPMYADMIN_PASSWORD="Admin1111"

apt update -y

# Pre-answer phpMyAdmin installation questions
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections
echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/admin-pass password ${PHPMYADMIN_PASSWORD}" | debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/app-pass password ${PHPMYADMIN_PASSWORD}" | debconf-set-selections
echo "phpmyadmin phpmyadmin/app-password-confirm password ${PHPMYADMIN_PASSWORD}" | debconf-set-selections

DEBIAN_FRONTEND=noninteractive apt install apache2 php libapache2-mod-php php-mysql phpmyadmin -y

systemctl restart apache2

echo "phpMyAdmin installed successfully."
echo "Open: http://localhost/phpmyadmin"
}
# ================= END ORIGINAL S5 INSTALLATION =================

# ---------- run S5 with measurement (S5 clock starts here) ----------
START_EPOCH=$(date +%s); START_HMS=$(date '+%H:%M:%S')
RX0=$(rx_bytes)
sampler & SAMPLER_PID=$!
trap 'kill $SAMPLER_PID 2>/dev/null' EXIT

ATTEMPTS=0; PASSED=0; FIRST_FAIL_EPOCH=""; FIRST_FAIL_MSG=""; LAST_FAIL_MSG=""; D5_FIRST=""; D10_FIRST=""
while [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
    ATTEMPTS=$((ATTEMPTS+1))
    echo "===== IFADEG $STAGE attempt $ATTEMPTS ====="
    if [ "$ATTEMPTS" -gt 1 ]; then
        # Clean up before retry: finish any half-configured packages left by an interrupted apt
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a >/dev/null 2>&1
        echo "[IFADEG] retry cleanup done (dpkg --configure -a)"
    fi
    ( install_s5 )                      # subshell: variables and "exit" stay inside
    verify_s5; VRC=$?
    [ "$D5_OK" -eq 1 ] && [ -z "$D5_FIRST" ] && D5_FIRST=$ATTEMPTS
    [ "$D10_OK" -eq 1 ] && [ -z "$D10_FIRST" ] && D10_FIRST=$ATTEMPTS
    if [ "$VRC" -eq 0 ]; then
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

# Download time (s): apt "Fetched ... in Xs" (S5 has no wget step)
sleep 1   # let the log catch up
DL_TIME=$(grep -oE 'Fetched .* in [0-9]+(h|min|s)( [0-9]+(min|s))?' "$LOG" | sed -E 's/.* in //; s/min/m/g' |
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
    grep -iE 'error|failed|fatal|exception|cannot|unable|refused|denied' "$LOG" \
        | grep -viE 'libgpg-error|IFADEG|debconf|WARN|php.*-error|libapache' \
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

# Item scores (2 = passed on attempt 1, 1 = passed later, 0 = not passed at the end)
item_score() {  # $1 = passes now (1/0), $2 = first attempt it passed
    if [ "$1" -eq 1 ]; then [ "$2" = "1" ] && echo 2 || echo 1; else echo 0; fi
}
D5_SCORE=$(item_score "$D5_OK" "$D5_FIRST")
D10_SCORE=$(item_score "$D10_OK" "$D10_FIRST")
for it in D5 D10; do
    ok_var="${it}_OK"; sc_var="${it}_SCORE"; ev_var="${it}_EV"
    res=$( [ "${!ok_var}" -eq 1 ] && echo PASS || echo FAIL )
    echo "$(date +%Y-%m-%d),$STAGE,$START_HMS,$it,$res,${!sc_var},\"$(echo "${!ev_var}" | tr -d '",')\"" >> "$ITEMS_CSV"
done

echo ""
echo "----- Part 1: $STAGE (5myadmin.sh) -----"
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
echo "Item scores          : D5 = $D5_SCORE · D10 = $D10_SCORE"
echo "-----------------------------------------------"
echo "Saved: $CSV and $ITEMS_CSV"

# ---------- END OF PIPELINE ----------
echo ""
echo "RUN END TIME (whole pipeline = S5 end)   : $END_HMS"
save_run_end "$END_HMS"
echo "Saved: run end time in $P0_CSV"
sleep 1; fix_owner
