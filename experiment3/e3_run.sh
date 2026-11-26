#!/bin/bash
# =====================================================================
# e3_run.sh - Experiment 3 (Instrument 3): one script for one FADTESE run
#
#   Part 0  Run header       bandwidth, latency / packet loss, free disk, date   (before the run)
#   Part 1  Deployment       downloads the published FADTESE and runs it UNCHANGED, measured as
#                            three rows: Hadoop part (vs IFADEG S1), Connector/J (vs IFADEG's
#                            Connector/J step), Total (whole pipeline); + SHA-256 of the script
#   Items   D1, D3, D6       Hadoop installed, Connector/J in Sqoop lib, Hadoop services started
#   Part 2  C1, C2           HDFS healthy, HDFS read/write (2 = first time, 1 = after a 30 s wait)
#   Part 3  W1, W2, W6, W7   Sqoop import of the same MySQL table as Experiment 4 into HDFS:
#                            records ingested, data in HDFS, record count, MD5 checksum
#                            (skipped -> NR if D1, D3 or D6 did not pass)
#   Summary                  workflow time / throughput, part totals, final FADTESE Outcome, SHA-256
#
# FADTESE source: https://github.com/datasciencesource/bash-script/blob/main/install_big_data_utilities.sh
# Run ID is entered manually on the form.
#
# Usage (as root, in /, on a freshly restored clean snapshot):  ./e3_run.sh
#   It asks for the remote MySQL password first (not stored), then runs about 12 minutes
#   without input. Or give it in advance: REMOTE_PW='...' ./e3_run.sh
# Output (in /ifadeg_logs): part0.csv, part1.csv, items.csv, part2.csv, part3.csv, e3_workflow.csv, summary.csv,
#                           <label>_sqoop.log,
#                           fadtese_<date_time>.log (full FADTESE output, timestamped)
# =====================================================================

[ "$(id -u)" -ne 0 ] && { echo "Please run as root: sudo -i"; exit 1; }

LOG_DIR="/ifadeg_logs"
mkdir -p "$LOG_DIR"
P0_CSV="$LOG_DIR/part0.csv"
ITEMS_CSV="$LOG_DIR/items.csv"
P2_CSV="$LOG_DIR/part2.csv"
SUM_CSV="$LOG_DIR/summary.csv"
CONNECTOR_JAR="mysql-connector-java-5.1.34-bin.jar"
TODAY=$(date +%F)

# Part 3 source: the same remote MySQL table as Experiment 4
REMOTE_HOST="${REMOTE_HOST:-69.175.69.34}"   # cPanel MySQL host (same as Experiment 4)
REMOTE_PORT="${REMOTE_PORT:-3306}"
REMOTE_USER="${REMOTE_USER:-sumrachna_hd}"
REMOTE_DB="${REMOTE_DB:-sumrachna_hd}"
REMOTE_TABLE="${REMOTE_TABLE:-table_stock}"
EXPECTED_RECORDS="${EXPECTED_RECORDS:-125}"
TARGET_DIR="/big_data/sqoop_${REMOTE_TABLE}"
# Password is never stored in this file (the repository is public): typed now, or given as REMOTE_PW=...
[ -z "$REMOTE_PW" ] && { read -r -s -p "Password for remote MySQL user $REMOTE_USER@$REMOTE_HOST (Part 3): " REMOTE_PW; echo; }
echo "Thank you - the run now continues without input (about 12 minutes)."

# ############################################################
# PART 0: run header (measured before FADTESE starts)
# ############################################################
# Date
DATE=$(date +%F)
TIME=$(date +%T)

# Network bandwidth (Mbit/s): speedtest-cli --simple (Download)
if command -v speedtest-cli >/dev/null 2>&1; then
    BW=$(speedtest-cli --simple 2>/dev/null | awk '/^Download:/{print $2}')
fi
BW="${BW:-NA}"

# Network latency (ms) / packet loss (%): ping -c 20 8.8.8.8 (avg rtt / loss)
PING_OUT=$(ping -c 20 8.8.8.8 2>/dev/null)
LAT=$(echo "$PING_OUT" | awk -F'/' '/rtt/{print $5}')
LOSS=$(echo "$PING_OUT" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+')
LAT="${LAT:-NA}"; LOSS="${LOSS:-NA}"

# Free disk before run (GB): df -BG / (Avail)
FREE=$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')

# Save
[ -f "$P0_CSV" ] || echo "date,time,bandwidth_mbps,latency_ms,packet_loss_pct,free_disk_gb" > "$P0_CSV"
echo "$DATE,$TIME,$BW,$LAT,$LOSS,$FREE" >> "$P0_CSV"

# Show Part 0
echo "----- Part 0: run header -----"
echo "Network bandwidth (Mbit/s)             : $BW"
echo "Network latency (ms) / packet loss (%) : $LAT / $LOSS"
echo "Free disk before run (GB)              : $FREE"
echo "Run ID                                 : (manual input on the form)"
echo "Date                                   : $DATE"
echo "Run start time / end time              : (recorded by the run step)"
echo "------------------------------"
echo "Saved: $P0_CSV"

# ############################################################
# PART 1: download and run FADTESE, measured (Hadoop part, Connector/J, Total)
# ############################################################
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
P0_CSV="$LOG_DIR/part0.csv"

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

# ############################################################
# DEPLOYMENT ITEMS: D1, D3, D6
# ############################################################
# FADTESE's environment (set here; ~/.bashrc is not read by scripts)
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
export HADOOP_HOME=/usr/local/hadoop HADOOP_INSTALL=/usr/local/hadoop HADOOP_PREFIX=/usr/local/hadoop
export HADOOP_CONF_DIR=/usr/local/hadoop/etc/hadoop HADOOP_COMMON_HOME=/usr/local/hadoop
export HADOOP_HDFS_HOME=/usr/local/hadoop HADOOP_MAPRED_HOME=/usr/local/hadoop YARN_HOME=/usr/local/hadoop
export PATH="$PATH:$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin"
EXIT_CODE="$RC"
echo ""
# ---------- D1: Hadoop installed ----------
HV=$(hadoop version 2>/dev/null | grep -m1 '^Hadoop ')
if [ "$HV" = "Hadoop 2.10.2" ] && [ -d /usr/local/hadoop ]; then
    D1=2; D1_EV="$HV; /usr/local/hadoop exists"
else
    D1=0; D1_EV="${HV:-hadoop version not found}"
fi

# ---------- D3: Connector/J in Sqoop lib ----------
if ls /usr/local/sqoop/lib 2>/dev/null | grep -q "$CONNECTOR_JAR"; then
    D3=2; D3_EV="$CONNECTOR_JAR present"
else
    D3=0; D3_EV="$CONNECTOR_JAR missing in /usr/local/sqoop/lib"
fi

# ---------- D6: Hadoop services started (up to 30 s) ----------
for k in 1 2 3 4 5 6 7; do
    MISSING=""
    for p in NameNode DataNode SecondaryNameNode ResourceManager NodeManager; do
        jps 2>/dev/null | grep -qw "$p" || MISSING="$MISSING $p"
    done
    MISSING="${MISSING# }"
    [ -z "$MISSING" ] && break
    [ "$k" -lt 7 ] && sleep 5
done
if [ -z "$MISSING" ]; then D6=2; D6_EV="all 5 daemons running"; else D6=0; D6_EV="missing: $MISSING"; fi

# ---------- NR: FADTESE stopped before it got there ----------
if [ -n "$EXIT_CODE" ] && [ "$EXIT_CODE" != "0" ]; then
    [ "$D1" = "0" ] && { D1=NR; D1_EV="not reached (FADTESE stopped, exit $EXIT_CODE)"; }
    [ "$D3" = "0" ] && { D3=NR; D3_EV="not reached (FADTESE stopped, exit $EXIT_CODE)"; }
    [ "$D6" = "0" ] && { D6=NR; D6_EV="not reached (FADTESE stopped, exit $EXIT_CODE)"; }
fi

num() { case "$1" in 2|1|0) echo "$1" ;; *) echo 0 ;; esac; }   # NR counts as 0
P1_TOTAL=$(( $(num "$D1") + $(num "$D3") + $(num "$D6") ))

# ---------- save ----------
[ -f "$ITEMS_CSV" ] || echo "date,run_start,item,score,notes" > "$ITEMS_CSV"
for it in D1 D3 D6; do
    sc="$it"; ev="${it}_EV"
    echo "$(date +%F),$START_HMS,$it,${!sc},\"$(echo "${!ev}" | tr -d '",')\"" >> "$ITEMS_CSV"
done
echo "$(date +%F),$START_HMS,D2 D4 D5 D7-D10,NA,\"not in FADTESE scope\"" >> "$ITEMS_CSV"

# ---------- show ----------
echo "----- Deployment items (run started $START_HMS) -----"
printf '%-18s | %-26s | %-5s | %s\n' "No." "Item" "Score" "Notes"
printf '%-18s | %-26s | %-5s | %s\n' "D1" "Hadoop installed" "$D1" "$D1_EV"
printf '%-18s | %-26s | %-5s | %s\n' "D3" "Connector/J in Sqoop lib" "$D3" "$D3_EV"
printf '%-18s | %-26s | %-5s | %s\n' "D6" "Hadoop services started" "$D6" "$D6_EV"
printf '%-18s | %-26s | %-5s | %s\n' "D2, D4, D5, D7-D10" "NiFi, MySQL, phpMyAdmin" "NA" "not in FADTESE scope"
echo "Deployment items total (FADTESE scope): $P1_TOTAL / 6"
echo "-----------------------------------------------------------"
echo "Saved: $ITEMS_CSV"

# ############################################################
# PART 2: C1, C2
# ############################################################
echo ""
check_c1() {
    REPORT=$(hdfs dfsadmin -report 2>/dev/null)
    LIVE=$(echo "$REPORT" | grep -oE 'Live datanodes \([0-9]+\)' | grep -oE '[0-9]+')
    SAFE=$(hdfs dfsadmin -safemode get 2>/dev/null | grep -oE 'OFF|ON' | head -1)
    C1_EV="Live DataNodes=${LIVE:-0}; safe mode=${SAFE:-unknown}"
    [ "${LIVE:-0}" -ge 1 ] && [ "$SAFE" = "OFF" ]
}
check_c2() {
    C2_OUT=$(hdfs dfs -mkdir -p /big_data 2>/dev/null && echo ok | hdfs dfs -put -f - /big_data/_check.txt 2>/dev/null \
             && hdfs dfs -cat /big_data/_check.txt 2>/dev/null)
    if [ "$C2_OUT" = "ok" ]; then C2_EV="Prints ok"; else C2_EV="read/write failed"; fi
    [ "$C2_OUT" = "ok" ]
}

# Reached only if Hadoop is installed and its NameNode and DataNode are running
if [ -x /usr/local/hadoop/bin/hdfs ] && jps 2>/dev/null | grep -qw NameNode && jps 2>/dev/null | grep -qw DataNode; then
    if check_c1; then C1=2; else sleep 30; if check_c1; then C1=1; C1_EV="$C1_EV (passed after 30 s)"; else C1=0; fi; fi
    if check_c2; then C2=2; else sleep 30; if check_c2; then C2=1; C2_EV="$C2_EV (passed after 30 s)"; else C2=0; fi; fi
else
    C1=NR; C1_EV="not reached (Hadoop not installed or not running)"
    C2=NR; C2_EV="not reached (Hadoop not installed or not running)"
fi

P2_TOTAL=$(( $(num "$C1") + $(num "$C2") ))

# ---------- save ----------
[ -f "$P2_CSV" ] || echo "date,run_start,item,score,notes" > "$P2_CSV"
echo "$(date +%F),$START_HMS,C1,$C1,\"$(echo "$C1_EV" | tr -d '",')\"" >> "$P2_CSV"
echo "$(date +%F),$START_HMS,C2,$C2,\"$(echo "$C2_EV" | tr -d '",')\"" >> "$P2_CSV"
echo "$(date +%F),$START_HMS,C3-C8,NA,\"not in FADTESE scope\"" >> "$P2_CSV"

# ---------- show ----------
echo "----- Part 2: Component verification (run started $START_HMS) -----"
printf '%-6s | %-24s | %-5s | %s\n' "No." "Item" "Score" "Notes"
printf '%-6s | %-24s | %-5s | %s\n' "C1" "HDFS is healthy" "$C1" "$C1_EV"
printf '%-6s | %-24s | %-5s | %s\n' "C2" "HDFS read/write works" "$C2" "$C2_EV"
printf '%-6s | %-24s | %-5s | %s\n' "C3-C8" "NiFi, MySQL, phpMyAdmin" "NA" "not in FADTESE scope"
echo "Part 2 total (FADTESE scope): $P2_TOTAL / 4"
echo "-----------------------------------------------------------"
echo "Saved: $P2_CSV"

# ############################################################
# PART 3: Sqoop workflow (same dataset as Experiment 4)
# ############################################################
export SQOOP_HOME=/usr/local/sqoop
export PATH="$PATH:$SQOOP_HOME/bin"
RUN_ID="$TS"
P3_CSV="$LOG_DIR/part3.csv"; WF_CSV="$LOG_DIR/e3_workflow.csv"
SQLOG="$LOG_DIR/${RUN_ID}_sqoop.log"
res() { case "$1" in 2|1) echo PASS ;; NR) echo NR ;; NA) echo NA ;; *) echo FAIL ;; esac; }
echo ""
# Workflow only if FADTESE deployed what it needs (Hadoop, Connector/J, daemons)
SKIP_WF=""; { [ "$D1" = 2 ] && [ "$D3" = 2 ] && [ "$D6" = 2 ]; } || SKIP_WF=1
[ -n "$SKIP_WF" ] && echo "[IFADEG] Part 3 skipped: FADTESE deployment incomplete (D1/D3/D6 not all 2) - W items recorded as NR"
PWFILE=/root/.ifadeg_sqoop_pw
printf '%s' "$REMOTE_PW" > "$PWFILE"; chmod 400 "$PWFILE"
trap 'rm -f "$PWFILE" "$SAMPLES"; rm -rf /tmp/ifadeg_sqoop_out /tmp/ifadeg_sqoop_bin' EXIT
myq() { MYSQL_PWD="$REMOTE_PW" mysql -h "$REMOTE_HOST" -P "$REMOTE_PORT" -u "$REMOTE_USER" -N -B -r -e "$1" 2>>"$SQLOG"; }
for it in W1 W2 W6 W7; do eval "${it}=NR; ${it}_EV='not reached'"; done
WF_START=NA; WF_END=NA; WF_S=NA; THROUGHPUT=NA; SRC_COUNT=NA; TGT_COUNT=NA
: > "$SQLOG"

# ---------- mysql client (evaluation only; installed here, after FADTESE was measured) ----------
if [ -z "$SKIP_WF" ] && ! command -v mysql >/dev/null 2>&1; then
    echo "[IFADEG] installing mysql-client (evaluation only, after FADTESE measurement)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y mysql-client >>"$SQLOG" 2>&1 \
        || { apt-get update >>"$SQLOG" 2>&1 && apt-get install -y mysql-client >>"$SQLOG" 2>&1; }
    command -v mysql >/dev/null 2>&1 && echo "[IFADEG] mysql-client installed: $(mysql --version)" \
        || echo "[IFADEG] WARNING: mysql-client install failed - see $SQLOG"
fi

# ---------- Preconditions: Sqoop installed, HDFS up, source readable ----------
PRE_OK=1
[ -n "$SKIP_WF" ] && { PRE_OK=0; PRE_MSG="FADTESE deployment incomplete (D1/D3/D6 not all 2)"; }
[ "$PRE_OK" -eq 1 ] && [ ! -x "$SQOOP_HOME/bin/sqoop" ] && { PRE_OK=0; PRE_MSG="Sqoop not installed (FADTESE did not finish)"; }
if [ "$PRE_OK" -eq 1 ] && ! hdfs dfs -ls / >/dev/null 2>&1; then PRE_OK=0; PRE_MSG="HDFS not reachable"; fi
if [ "$PRE_OK" -eq 1 ]; then
    COLS=$(myq "SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$REMOTE_DB' AND TABLE_NAME='$REMOTE_TABLE' ORDER BY ORDINAL_POSITION")
    [ -z "$COLS" ] && { PRE_OK=0; PRE_MSG="cannot read $REMOTE_DB.$REMOTE_TABLE with the mysql client (check host/user/password)"; }
fi

if [ "$PRE_OK" -eq 1 ]; then
    # Every column as text, NULL written as 'NULL', so source and HDFS rows are compared as the same strings
    EXPR=$(echo "$COLS" | awk '{printf "%sCOALESCE(CAST(`%s` AS CHAR),'"'"'NULL'"'"') AS `%s`", (NR>1?", ":""), $1, $1}')
    SRC_COUNT=$(myq "SELECT COUNT(*) FROM \`$REMOTE_DB\`.\`$REMOTE_TABLE\`")
    SRC_MD5=$(myq "SELECT $EXPR FROM \`$REMOTE_DB\`.\`$REMOTE_TABLE\`" | tr '\t' ',' | LC_ALL=C sort | md5sum | cut -d' ' -f1)

    # ---------- W1: Sqoop import (timed: workflow execution time) ----------
    WF_START=$(date '+%H:%M:%S'); T0=$(date +%s)
    sqoop import \
        --connect "jdbc:mysql://$REMOTE_HOST:$REMOTE_PORT/$REMOTE_DB?useSSL=false" \
        --username "$REMOTE_USER" --password-file "file://$PWFILE" \
        --query "SELECT $EXPR FROM \`$REMOTE_TABLE\` WHERE \$CONDITIONS" \
        -m 1 --target-dir "$TARGET_DIR" --delete-target-dir \
        --fields-terminated-by ',' \
        --outdir /tmp/ifadeg_sqoop_out --bindir /tmp/ifadeg_sqoop_bin >>"$SQLOG" 2>&1
    SQ_RC=$?
    T1=$(date +%s); WF_END=$(date '+%H:%M:%S'); WF_S=$((T1 - T0))
    RETRIEVED=$(grep -oE 'Retrieved [0-9]+ records' "$SQLOG" | tail -1 | grep -oE '[0-9]+')
    if [ "$SQ_RC" -eq 0 ] && [ -n "$RETRIEVED" ]; then
        W1=2; W1_EV="sqoop import OK; Retrieved $RETRIEVED records in ${WF_S} s"
        THROUGHPUT=$(awk -v n="$RETRIEVED" -v t="$WF_S" 'BEGIN{ if (t>0) printf "%.2f", n/t; else print "NA" }')
    else
        W1=0; W1_EV="sqoop import failed (exit $SQ_RC): $(grep -iE 'error|exception' "$SQLOG" | grep -v WARN | head -1 | cut -c1-90 | tr -d '",')"
    fi

    if [ "$W1" -eq 2 ]; then
        # ---------- W2: data written to HDFS ----------
        NFILES=$(hdfs dfs -ls "$TARGET_DIR" 2>/dev/null | awk '$NF ~ /part-/ && $5>0' | wc -l)
        [ "$NFILES" -ge 1 ] && { W2=2; W2_EV="$NFILES non-empty file(s) in $TARGET_DIR"; } \
                            || { W2=0; W2_EV="no non-empty file in $TARGET_DIR"; }
        # ---------- W6: record count ----------
        TGT_COUNT=$(hdfs dfs -cat "$TARGET_DIR/part-*" 2>/dev/null | wc -l)
        if [ "$SRC_COUNT" = "$TGT_COUNT" ]; then W6=2; else W6=0; fi
        W6_EV="source=$SRC_COUNT target=$TGT_COUNT (expected $EXPECTED_RECORDS)"
        # ---------- W7: checksum ----------
        TGT_MD5=$(hdfs dfs -cat "$TARGET_DIR/part-*" 2>/dev/null | LC_ALL=C sort | md5sum | cut -d' ' -f1)
        if [ "$SRC_MD5" = "$TGT_MD5" ]; then W7=2; else W7=0; fi
        W7_EV="source=$SRC_MD5 target=$TGT_MD5"
    else
        for it in W2 W6 W7; do eval "${it}_EV='not reached (import failed)'"; done
    fi
else
    for it in W1 W2 W6 W7; do eval "${it}_EV='not reached: $PRE_MSG'"; done
fi


# ---------- save Part 3 ----------
[ -f "$P3_CSV" ] || echo "date,run_id,item,result,score,evidence" > "$P3_CSV"
for it in W1 W2 W6 W7; do
    ev_var="${it}_EV"
    echo "$TODAY,$RUN_ID,$it,$(res "${!it}"),${!it},\"$(echo "${!ev_var}" | tr -d '",')\"" >> "$P3_CSV"
done
for it in W3 W4 W5 W8; do
    echo "$TODAY,$RUN_ID,$it,NA,NA,\"NiFi-specific - not in FADTESE scope\"" >> "$P3_CSV"
done
[ -f "$WF_CSV" ] || echo "date,run_id,tool,start,end,duration_s,records,throughput_rps" > "$WF_CSV"
echo "$TODAY,$RUN_ID,sqoop,$WF_START,$WF_END,$WF_S,${RETRIEVED:-NA},$THROUGHPUT" >> "$WF_CSV"
P3_TOTAL=$(( $(num "$W1") + $(num "$W2") + $(num "$W6") + $(num "$W7") ))

{
echo "----- Part 3: Workflow validation (Sqoop, run started $START_HMS) -----"
printf '%-5s | %-32s | %-5s | %s\n' "No." "Item" "Score" "Notes"
echo "------+----------------------------------+-------+------------------------------"
printf '%-5s | %-32s | %-5s | %s\n' "W1" "Source records ingested (Sqoop)" "$W1" "$W1_EV"
printf '%-5s | %-32s | %-5s | %s\n' "W2" "Data written to HDFS" "$W2" "$W2_EV"
printf '%-5s | %-32s | %-5s | %s\n' "W6" "Record count matches" "$W6" "$W6_EV"
printf '%-5s | %-32s | %-5s | %s\n' "W7" "Data accuracy (checksum)" "$W7" "$W7_EV"
printf '%-5s | %-32s | %-5s | %s\n' "W3-5,8" "NiFi processors / bulletins" "NA" "not in FADTESE scope"
echo "------+----------------------------------+-------+------------------------------"
echo "Part 3 total (FADTESE scope): $P3_TOTAL / 8"
echo "Workflow execution time (s) and throughput (records/s): $WF_START / $WF_END = $WF_S s; ${THROUGHPUT} records/s"
echo "Saved: $P3_CSV, $WF_CSV; Sqoop log $SQLOG"
} | tee -a "$LOG"

# ############################################################
# SUMMARY
# ############################################################
# Final FADTESE Outcome: 2 only if FADTESE exited 0 AND D1, D3 and D6 passed
if [ "$RC" -eq 0 ] && [ "$D1" = 2 ] && [ "$D3" = 2 ] && [ "$D6" = 2 ]; then FINAL=2; else FINAL=0; fi
[ -f "$SUM_CSV" ] || echo "date,run_start,workflow_s,throughput_rps,part1_items_of_6,part2_of_4,part3_of_8,final_outcome,exit_code,sha256_12" > "$SUM_CSV"
echo "$(date +%F),$START_HMS,$WF_S,$THROUGHPUT,$P1_TOTAL,$P2_TOTAL,$P3_TOTAL,$FINAL,$RC,$SHA" >> "$SUM_CSV"
{
echo ""
echo "===== Summary for Instrument 3 (run started $START_HMS) ====="
echo "Workflow execution time / throughput: ${WF_S} s; ${THROUGHPUT} records/s"
echo "Part totals (FADTESE scope): Part 1 items $P1_TOTAL / 6; Part 2 $P2_TOTAL / 4; Part 3 $P3_TOTAL / 8"
echo "Final FADTESE Outcome (2/0): $FINAL   (2 = FADTESE finished and D1, D3, D6 passed)"
echo "FADTESE SHA-256 (first 12) : $SHA"
echo "Run ID: write it on the form. Copy /ifadeg_logs to the host before restoring the snapshot."
} | tee -a "$LOG"
exit "$RC"
