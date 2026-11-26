#!/bin/bash
# =====================================================================
# 2verify_fadtese.sh - Experiment 3 (Instrument 3): verification + Sqoop workflow, in one script
#   Part 1 deployment items : D1 Hadoop installed, D3 Connector/J, D6 Hadoop services started
#                             (D2, D4, D5, D7-D10 = NA: NiFi, MySQL, phpMyAdmin are not in FADTESE)
#   Part 2 component checks : C1 HDFS healthy, C2 HDFS read/write   (C3-C8 = NA)
#   Part 3 workflow (Sqoop) : W1 records ingested, W2 data in HDFS, W6 record count, W7 checksum
#                             (W3-W5, W8 = NA: NiFi-specific). Same source table as Experiment 4.
#                             Runs only if D1, D3 and D6 are 2; otherwise W items = NR (no password asked).
# Scores: 2 = pass; 0 = fail; NR = not reached. Part 2 only: 1 = passed after a 30 s wait.
# Final FADTESE Outcome (part1.csv) = 2 only if the script exited 0 AND D1, D3, D6 pass.
#
# Usage (as root, right after 1run_fadtese.sh, no argument):  ./2verify_fadtese.sh
#   MySQL source: host 69.175.69.34, user and database sumrachna_hd, table table_stock (defaults below)
#   The password is always asked for (not stored). mysql-client is installed if missing (evaluation only).
#
# Output (in /root/ifadeg_logs): items.csv, part2.csv, part3.csv, e3_workflow.csv, <RUN_ID>_sqoop.log
#        (+ Outcome update in part1.csv); /root/ifadeg_runs/<RUN_ID>_verify.txt and <RUN_ID>_part3.txt
#
# Experiment 3 kit, rev 4 (2026-11-26). Run order (as root, both kit files in one folder):
#   1run_fadtese.sh E3-Rxx [--no-check]  ->  2verify_fadtese.sh
#   FADTESE (install_big_data_utilities.sh) is downloaded into / ; results go to /root/ifadeg_logs.
# =====================================================================

RUN_ID="${1:-$(awk -F',' 'NR>1{r=$2} END{print r}' /root/ifadeg_logs/e3_split.csv 2>/dev/null)}"   # latest run; Run ID is recorded manually
[ -z "$RUN_ID" ] && { echo "No run found in /root/ifadeg_logs/e3_split.csv - run 1run_fadtese.sh first"; exit 1; }
[ "$(id -u)" -ne 0 ] && { echo "Please run as root: sudo -i"; exit 1; }

LOG_DIR="/root/ifadeg_logs"; RUNS_DIR="/root/ifadeg_runs"
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Kit file by plain or numbered name (run_fadtese.sh or 2run_fadtese.sh)
kit_file() { for c in "$KIT_DIR/$1" "$KIT_DIR"/[0-9]"$1"; do [ -f "$c" ] && { echo "$c"; return 0; }; done; return 1; }
kit_cmd()  { local c; c=$(kit_file "$1") && echo "./$(basename "$c")" || echo "./$1"; }
mkdir -p "$LOG_DIR" "$RUNS_DIR"
CSV="$LOG_DIR/part1.csv"; ITEMS_CSV="$LOG_DIR/items.csv"; P2_CSV="$LOG_DIR/part2.csv"
SPLIT_CSV="$LOG_DIR/e3_split.csv"
OUT="$RUNS_DIR/${RUN_ID}_verify.txt"
CONNECTOR_JAR="mysql-connector-java-5.1.34-bin.jar"

# FADTESE's environment (set here explicitly; ~/.bashrc is not read by non-interactive shells)
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
export HADOOP_HOME=/usr/local/hadoop HADOOP_INSTALL=/usr/local/hadoop HADOOP_PREFIX=/usr/local/hadoop
export HADOOP_CONF_DIR=/usr/local/hadoop/etc/hadoop HADOOP_COMMON_HOME=/usr/local/hadoop
export HADOOP_HDFS_HOME=/usr/local/hadoop HADOOP_MAPRED_HOME=/usr/local/hadoop YARN_HOME=/usr/local/hadoop
export PATH="$PATH:$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin"

TODAY=$(date +%Y-%m-%d)
STAGE_START=$(awk -F',' '$2=="FADTESE"{s=$3} END{print s}' "$CSV" 2>/dev/null)
EXIT_CODE=$(awk -F',' -v r="$RUN_ID" '$2==r{e=$7} END{print e}' "$SPLIT_CSV" 2>/dev/null)
[ -z "$STAGE_START" ] && echo "[IFADEG] note: no FADTESE row in part1.csv - was run_fadtese.sh used?"
grep -q ",$RUN_ID," "$SPLIT_CSV" 2>/dev/null || echo "[IFADEG] WARNING: Run ID $RUN_ID not found in e3_split.csv - give the Run ID only to 1run_fadtese.sh and run this script with no argument"

clean() { echo "$1" | tr -d '",'; }

# ---------------- Part 1: deployment items ----------------
# D1: hadoop version prints Hadoop 2.10.2; /usr/local/hadoop exists
HV=$(hadoop version 2>/dev/null | grep -m1 '^Hadoop ')
if [ "$HV" = "Hadoop 2.10.2" ] && [ -d /usr/local/hadoop ]; then D1=2; D1_EV="$HV; /usr/local/hadoop exists"
else D1=0; D1_EV="${HV:-hadoop version not found}"; fi

# D3: Connector/J JAR in Sqoop's lib folder
if ls /usr/local/sqoop/lib 2>/dev/null | grep -q "$CONNECTOR_JAR"; then D3=2; D3_EV="$CONNECTOR_JAR present"
else D3=0; D3_EV="$CONNECTOR_JAR missing in /usr/local/sqoop/lib"; fi

# D6: all 5 Hadoop daemons in jps (checked for up to 30 s, same tolerance as ADS)
for k in 1 2 3 4 5 6; do
    MISSING=""
    for p in NameNode DataNode SecondaryNameNode ResourceManager NodeManager; do
        jps 2>/dev/null | grep -qw "$p" || MISSING="$MISSING $p"
    done
    MISSING="${MISSING# }"
    [ -z "$MISSING" ] && break
    sleep 5
done
if [ -z "$MISSING" ]; then D6=2; D6_EV="all 5 daemons running"; else D6=0; D6_EV="missing $MISSING"; fi

# ---------------- Part 2: component verification ----------------
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
    [ "$C2_OUT" = "ok" ] && C2_EV="Prints ok" || C2_EV="read/write failed"
    [ "$C2_OUT" = "ok" ]
}
# Part 2 score: 2 = pass first time; 1 = pass after a 30 s wait; 0 = fail
if [ "$D1" -eq 2 ] && [ "$D6" -eq 2 ]; then
    if check_c1; then C1=2; else sleep 30; if check_c1; then C1=1; else C1=0; fi; fi
    if check_c2; then C2=2; else sleep 30; if check_c2; then C2=1; else C2=0; fi; fi
else
    C1=NR; C1_EV="not reached (Hadoop not installed or not running)"
    C2=NR; C2_EV="not reached (Hadoop not installed or not running)"
fi

# If FADTESE stopped early (exit code not 0) and an item failed, the item was not reached
if [ -n "$EXIT_CODE" ] && [ "$EXIT_CODE" != "0" ]; then
    [ "$D1" = "0" ] && { D1=NR; D1_EV="not reached (FADTESE stopped, exit $EXIT_CODE)"; }
    [ "$D3" = "0" ] && { D3=NR; D3_EV="not reached (FADTESE stopped, exit $EXIT_CODE)"; }
    [ "$D6" = "0" ] && { D6=NR; D6_EV="not reached (FADTESE stopped, exit $EXIT_CODE)"; }
fi

res() { case "$1" in 2|1) echo PASS ;; NR) echo NR ;; NA) echo NA ;; *) echo FAIL ;; esac; }
num() { case "$1" in 2|1|0) echo "$1" ;; *) echo 0 ;; esac; }   # NR counts as 0

# ---------------- Save items.csv and part2.csv ----------------
[ -f "$ITEMS_CSV" ] || echo "date,stage,stage_start,item,result,score,evidence" > "$ITEMS_CSV"
for it in D1 D3 D6; do
    sc_var="$it"; ev_var="${it}_EV"
    echo "$TODAY,FADTESE,${STAGE_START:-NA},$it,$(res "${!sc_var}"),${!sc_var},\"$(clean "${!ev_var}")\"" >> "$ITEMS_CSV"
done
for it in D2 D4 D5 D7 D8 D9 D10; do
    echo "$TODAY,FADTESE,${STAGE_START:-NA},$it,NA,NA,\"not in FADTESE scope\"" >> "$ITEMS_CSV"
done
[ -f "$P2_CSV" ] || echo "date,run_id,item,result,score,evidence" > "$P2_CSV"
echo "$TODAY,$RUN_ID,C1,$(res "$C1"),$C1,\"$(clean "$C1_EV")\"" >> "$P2_CSV"
echo "$TODAY,$RUN_ID,C2,$(res "$C2"),$C2,\"$(clean "$C2_EV")\"" >> "$P2_CSV"
for it in C3 C4 C5 C6 C7 C8; do
    echo "$TODAY,$RUN_ID,$it,NA,NA,\"not in FADTESE scope\"" >> "$P2_CSV"
done

# ---------------- Final FADTESE Outcome in part1.csv ----------------
OUTCOME_NOTE=""
if [ -f "$CSV" ] && [ -n "$STAGE_START" ]; then
    CUR=$(awk -F',' '$2=="FADTESE"{o=$10} END{print o}' "$CSV")
    if [ "$CUR" = "2" ] && { [ "$(num "$D1")" -ne 2 ] || [ "$(num "$D3")" -ne 2 ] || [ "$(num "$D6")" -ne 2 ]; }; then
        # script exited 0 but a deployment item failed -> Outcome 0
        awk -F',' 'BEGIN{OFS=","} { if ($2=="FADTESE") last=NR; line[NR]=$0 }
             END { for (i=1;i<=NR;i++) { if (i==last) { n=split(line[i],f,","); f[10]="0"; sub(/No error/,"Failed: script finished but a deployment item failed",f[14]); s=f[1];
                   for (j=2;j<=n;j++) s=s "," f[j]; print s } else print line[i] } }' "$CSV" > "$CSV.tmp" && mv "$CSV.tmp" "$CSV"
        OUTCOME_NOTE="Outcome changed 2 -> 0: script finished but a deployment item failed"
        CUR=0
    fi
    FINAL_OUTCOME="$CUR"
else
    FINAL_OUTCOME="NA"
fi

P1_TOTAL=$(( $(num "$D1") + $(num "$D3") + $(num "$D6") ))
P2_TOTAL=$(( $(num "$C1") + $(num "$C2") ))

# ---------------- Summary (screen + file) ----------------
{
echo "IFADEG Instrument 3 - FADTESE verification | Run: $RUN_ID | $(date '+%F %T %z')"
printf '%-6s | %-34s | %-5s | %s\n' "No." "Item" "Score" "Notes"
echo "-------+------------------------------------+-------+------------------------------"
printf '%-6s | %-34s | %-5s | %s\n' "D1" "Hadoop installed" "$D1" "$D1_EV"
printf '%-6s | %-34s | %-5s | %s\n' "D3" "Connector/J in Sqoop lib" "$D3" "$D3_EV"
printf '%-6s | %-34s | %-5s | %s\n' "D6" "Hadoop services started" "$D6" "$D6_EV"
printf '%-6s | %-34s | %-5s | %s\n' "D2,D4,D5,D7-D10" "" "NA" "not in FADTESE scope"
echo "-------+------------------------------------+-------+------------------------------"
printf '%-6s | %-34s | %-5s | %s\n' "C1" "HDFS is healthy" "$C1" "$C1_EV"
printf '%-6s | %-34s | %-5s | %s\n' "C2" "HDFS read/write works" "$C2" "$C2_EV"
printf '%-6s | %-34s | %-5s | %s\n' "C3-C8" "" "NA" "not in FADTESE scope"
echo "-------+------------------------------------+-------+------------------------------"
echo "Part 1 items total (FADTESE scope): $P1_TOTAL / 6"
echo "Part 2 total (FADTESE scope)      : $P2_TOTAL / 4"
echo "Final FADTESE Outcome (2/0)       : $FINAL_OUTCOME ${OUTCOME_NOTE:+($OUTCOME_NOTE)}"
echo "Saved: $ITEMS_CSV, $P2_CSV; summary $OUT"
} | tee "$OUT"

# ---------- Source table: the same table as Experiment 4 ----------
REMOTE_HOST="${REMOTE_HOST:-69.175.69.34}"   # cPanel MySQL host (same as Experiment 4)
REMOTE_PORT="${REMOTE_PORT:-3306}"
REMOTE_USER="${REMOTE_USER:-sumrachna_hd}"
REMOTE_DB="${REMOTE_DB:-sumrachna_hd}"
REMOTE_TABLE="${REMOTE_TABLE:-table_stock}"
EXPECTED_RECORDS="${EXPECTED_RECORDS:-125}"
TARGET_DIR="/big_data/sqoop_${REMOTE_TABLE}"

P3_CSV="$LOG_DIR/part3.csv"; WF_CSV="$LOG_DIR/e3_workflow.csv"
SQLOG="$LOG_DIR/${RUN_ID}_sqoop.log"
OUT3="$RUNS_DIR/${RUN_ID}_part3.txt"

# FADTESE's environment (set explicitly; ~/.bashrc is not read by non-interactive shells)
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
export HADOOP_HOME=/usr/local/hadoop HADOOP_INSTALL=/usr/local/hadoop HADOOP_PREFIX=/usr/local/hadoop
export HADOOP_CONF_DIR=/usr/local/hadoop/etc/hadoop HADOOP_COMMON_HOME=/usr/local/hadoop
export HADOOP_HDFS_HOME=/usr/local/hadoop HADOOP_MAPRED_HOME=/usr/local/hadoop YARN_HOME=/usr/local/hadoop
export SQOOP_HOME=/usr/local/sqoop
export PATH="$PATH:$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$SQOOP_HOME/bin"

# Workflow only if FADTESE deployed what it needs (Hadoop, Connector/J, daemons)
SKIP_WF=""; { [ "$D1" = 2 ] && [ "$D3" = 2 ] && [ "$D6" = 2 ]; } || SKIP_WF=1
echo ""
if [ -n "$SKIP_WF" ]; then
echo "[IFADEG] Part 3 skipped: FADTESE deployment incomplete (D1/D3/D6 not all 2) - W items recorded as NR"
else
echo "----- Part 3: Sqoop workflow (same dataset as Experiment 4) -----"
[ -z "$REMOTE_HOST" ] && read -r -p "Remote MySQL host: " REMOTE_HOST
[ -z "$REMOTE_USER" ] && read -r -p "Remote MySQL user: " REMOTE_USER
# Password is never stored in this file (the repository is public): typed here, or given as REMOTE_PW=...
[ -z "$REMOTE_PW" ] && { read -r -s -p "Password for remote MySQL user $REMOTE_USER@$REMOTE_HOST: " REMOTE_PW; echo; }

PWFILE=/root/.ifadeg_sqoop_pw
printf '%s' "$REMOTE_PW" > "$PWFILE"; chmod 400 "$PWFILE"
trap 'rm -f "$PWFILE"; rm -rf /tmp/ifadeg_sqoop_out /tmp/ifadeg_sqoop_bin' EXIT
fi
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


# ---------- Save ----------
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
echo "IFADEG Instrument 3 - Part 3 (Sqoop, same dataset) | Run: $RUN_ID | $(date '+%F %T %z')"
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
echo "Saved: $P3_CSV, $WF_CSV; Sqoop log $SQLOG; summary $OUT3"
} | tee "$OUT3"

# ---------- Overall summary for the form ----------
{
echo ""
echo "===== Summary for Instrument 3: $RUN_ID ====="
echo "Part totals (FADTESE scope): Part 1 items $P1_TOTAL / 6; Part 2 $P2_TOTAL / 4; Part 3 $P3_TOTAL / 8"
echo "Workflow execution time / throughput: ${WF_S} s; ${THROUGHPUT} records/s"
echo "Final FADTESE Outcome (2/0): $FINAL_OUTCOME"
echo "Before restoring the snapshot: copy /root/ifadeg_logs and /root/ifadeg_runs to the host."
} | tee -a "$OUT3"
