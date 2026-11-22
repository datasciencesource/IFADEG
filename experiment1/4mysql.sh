#!/bin/bash
# 4mysql.sh - IFADEG Stage S4: MySQL server, database dbtest and table_stock
# Usage:  sudo ./4mysql.sh        (must run as root: the install uses apt without sudo)
#
# PART 1 (S4): Start, End, Duration (s), Download time (s), Data downloaded (MB),
#              Attempts, Recovery time (s), Outcome (2/1/0/NR),
#              Peak CPU (%), Mean CPU (%), Peak RAM (GB), Error / log
# Outcome: 2 = success on 1st attempt, 1 = success after retry, 0 = failed,
#          NR = not reached (S3 failed or was not reached, so S4 is not run)
# Success = D4 + D8 + setup check all pass:
#   D4     mysql --version prints the expected version (Ver 8.x; recorded as evidence)
#   D8     systemctl is-active mysql = active (polled up to 30 s)
#   setup  usertest can open dbtest.table_stock (the database setup this script performs)
# Item score: 2 = passed on attempt 1, 1 = passed on a later attempt, 0 = not passed at the end, NR = not reached
# Recovery time: 0 if no failure; failure -> success if recovered; time spent retrying if failed (I_REC = 0).
# Output:  <user home>/ifadeg_logs/S4_<date_time>.log, one row in part1.csv, D4 + D8 rows in items.csv

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root:  sudo ./4mysql.sh"
    exit 1
fi

RUN_TS="$(date +%Y%m%d_%H%M%S)"   # log name; Run ID is recorded manually
STAGE="S4"
MAX_ATTEMPTS=3
# Same log folder as S1-S3: the home of the user who called sudo (or root's home if run as root)
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

# ---------- NR check: was the previous stage (S3) successful? ----------
LAST_S3_OUTCOME=$(awk -F',' '$2=="S3"{o=$10} END{print o}' "$CSV")
if [ "$LAST_S3_OUTCOME" = "0" ] || [ "$LAST_S3_OUTCOME" = "NR" ]; then
    echo "[IFADEG] S3 outcome = $LAST_S3_OUTCOME, so S4 is not reached (NR)"
    echo "$(date +%Y-%m-%d),$STAGE,NA,NA,NA,NA,NA,0,NA,NR,NA,NA,NA,\"Not reached: S3 failed or not reached - $(basename "$LOG")\"" >> "$CSV"
    for it in D4 D8; do
        echo "$(date +%Y-%m-%d),$STAGE,NA,$it,NR,NR,\"Not reached: S3 failed or not reached\"" >> "$ITEMS_CSV"
    done
    echo "----- Part 1: $STAGE (4mysql.sh) -----"
    echo "Outcome (2/1/0)      : NR (not reached, S3 failed or not reached)"
    echo "Item scores          : D4 = NR · D8 = NR"
    echo "-----------------------------------------------"
    sleep 1; rm -f "$SAMPLES"; fix_owner
    exit 1
fi
[ -z "$LAST_S3_OUTCOME" ] && echo "[IFADEG] note: no S3 row found in part1.csv, running S4 anyway"

# ############################################################
# PART 1: Deployment evaluation - S4 MySQL
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

# S4 verification: D4, D8 (from Instrument 1) + setup check
# Sets D4_OK/D8_OK/SETUP_OK (1/0), D4_EV/D8_EV/SETUP_EV (evidence), ITEMS (summary), FAIL_MSG (empty if all pass)
# All three are checked every time (they are quick and independent).
verify_s4() {
    FAIL_MSG=""
    # D4: mysql --version prints the expected version
    MV=$(mysql --version 2>/dev/null)
    if echo "$MV" | grep -q 'Ver 8\.'; then
        D4_OK=1; D4_EV="$(echo "$MV" | grep -oE 'Ver [0-9][^ ]*')"
    else
        D4_OK=0; D4_EV="${MV:-mysql not found}"
        FAIL_MSG="D4 MySQL not installed"
    fi
    # D8: systemctl is-active mysql = active (wait up to 30 s)
    ST="inactive"
    for k in 1 2 3 4 5 6; do
        ST=$(systemctl is-active mysql 2>/dev/null)
        [ "$ST" = "active" ] && break
        sleep 5
    done
    if [ "$ST" = "active" ]; then
        D8_OK=1; D8_EV="active"
    else
        D8_OK=0; D8_EV="${ST:-unknown}"
        FAIL_MSG="${FAIL_MSG:+$FAIL_MSG; }D8 MySQL service $D8_EV"
    fi
    # Setup: usertest can open dbtest.table_stock
    if MYSQL_PWD="Admin1111" mysql -uusertest -e "DESCRIBE dbtest.table_stock" >/dev/null 2>&1; then
        SETUP_OK=1; SETUP_EV="dbtest.table_stock accessible by usertest"
    else
        SETUP_OK=0; SETUP_EV="dbtest.table_stock not accessible by usertest"
        FAIL_MSG="${FAIL_MSG:+$FAIL_MSG; }setup: $SETUP_EV"
    fi
    pf() { [ "$1" -eq 1 ] && echo PASS || echo FAIL; }
    ITEMS="D4 $(pf $D4_OK) ($D4_EV) · D8 $(pf $D8_OK) ($D8_EV) · setup $(pf $SETUP_OK) ($SETUP_EV)"
    [ "$D4_OK" -eq 1 ] && [ "$D8_OK" -eq 1 ] && [ "$SETUP_OK" -eq 1 ]
}

# ================= ORIGINAL S4 INSTALLATION =================
# Unchanged. Your script is already retry-safe (ADS v2: it detects a root password set by an earlier attempt).
install_s4() {
MYSQL_ROOT_PASSWORD="Admin1111"
MYSQL_DB="dbtest"
MYSQL_USER="usertest"
MYSQL_PASSWORD="Admin1111"

# ADS v2: detect a previous attempt (root password already set) so a retry is safe
ROOT_PW_SET=0
if mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1" >/dev/null 2>&1; then
    ROOT_PW_SET=1
fi

apt update -y
apt install mysql-server expect -y

systemctl start mysql
systemctl enable mysql

if [ "$ROOT_PW_SET" -eq 0 ]; then
expect <<'EOF'
set timeout 60

spawn mysql_secure_installation

expect {
    -re "Press y\\|Y for Yes.*No.*:" {
        send "n\r"
        exp_continue
    }
    -re "Remove anonymous users.*:" {
        send "y\r"
        exp_continue
    }
    -re "Disallow root login remotely.*:" {
        send "y\r"
        exp_continue
    }
    -re "Remove test database.*:" {
        send "y\r"
        exp_continue
    }
    -re "Reload privilege tables now.*:" {
        send "y\r"
        exp_continue
    }
    eof
}
EOF
fi

# ADS v2: on a retry, connect with the root password set by the first attempt
if [ "$ROOT_PW_SET" -eq 1 ]; then
    export MYSQL_PWD="${MYSQL_ROOT_PASSWORD}"
    MYSQL_CMD="mysql -uroot"
else
    MYSQL_CMD="mysql"
fi

$MYSQL_CMD <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';

CREATE DATABASE IF NOT EXISTS ${MYSQL_DB};

CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';

GRANT ALL PRIVILEGES ON ${MYSQL_DB}.* TO '${MYSQL_USER}'@'localhost';

FLUSH PRIVILEGES;

USE ${MYSQL_DB};

CREATE TABLE IF NOT EXISTS table_stock (
    id INT AUTO_INCREMENT PRIMARY KEY,
    product_id INT,
    purchasing_price FLOAT,
    quantity DOUBLE,
    stock_date DATETIME
);
EOF

echo "MySQL installed, secured, root password set, and dbtest.table_stock created."
echo "Root login: root / ${MYSQL_ROOT_PASSWORD}"
echo "User login: ${MYSQL_USER} / ${MYSQL_PASSWORD}"
}
# ================= END ORIGINAL S4 INSTALLATION =================

# ---------- run S4 with measurement (S4 clock starts here) ----------
START_EPOCH=$(date +%s); START_HMS=$(date '+%H:%M:%S')
RX0=$(rx_bytes)
sampler & SAMPLER_PID=$!
trap 'kill $SAMPLER_PID 2>/dev/null' EXIT

ATTEMPTS=0; PASSED=0; FIRST_FAIL_EPOCH=""; FIRST_FAIL_MSG=""; LAST_FAIL_MSG=""; D4_FIRST=""; D8_FIRST=""
while [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
    ATTEMPTS=$((ATTEMPTS+1))
    echo "===== IFADEG $STAGE attempt $ATTEMPTS ====="
    if [ "$ATTEMPTS" -gt 1 ]; then
        # No cleanup needed: the install steps are retry-safe (ADS v2). Make sure the service is up.
        systemctl start mysql >/dev/null 2>&1
        echo "[IFADEG] retry: no cleanup needed (install steps are retry-safe)"
    fi
    ( install_s4 )                      # subshell: variables and "exit" stay inside
    verify_s4; VRC=$?
    [ "$D4_OK" -eq 1 ] && [ -z "$D4_FIRST" ] && D4_FIRST=$ATTEMPTS
    [ "$D8_OK" -eq 1 ] && [ -z "$D8_FIRST" ] && D8_FIRST=$ATTEMPTS
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

# Download time (s): apt "Fetched ... in Xs" (S4 has no wget step)
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
        | grep -viE 'libgpg-error|IFADEG|debconf|WARN|libmysqlclient|mysql-common' \
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
D4_SCORE=$(item_score "$D4_OK" "$D4_FIRST")
D8_SCORE=$(item_score "$D8_OK" "$D8_FIRST")
for it in D4 D8; do
    ok_var="${it}_OK"; sc_var="${it}_SCORE"; ev_var="${it}_EV"
    res=$( [ "${!ok_var}" -eq 1 ] && echo PASS || echo FAIL )
    echo "$(date +%Y-%m-%d),$STAGE,$START_HMS,$it,$res,${!sc_var},\"$(echo "${!ev_var}" | tr -d '",')\"" >> "$ITEMS_CSV"
done

echo ""
echo "----- Part 1: $STAGE (4mysql.sh) -----"
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
echo "Item scores          : D4 = $D4_SCORE · D8 = $D8_SCORE"
echo "-----------------------------------------------"
echo "Saved: $CSV and $ITEMS_CSV"
sleep 1; fix_owner
