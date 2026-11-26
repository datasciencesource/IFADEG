#!/bin/bash
# =====================================================================
# sqoop_check.sh - same-dataset workflow test for FADTESE (Experiment 3, Part 3)
# Uses the tool FADTESE installs for data movement (Sqoop 1.4.7 + Connector/J 5.1.34)
# to import the SAME source table as IFADEG Experiment 4 into HDFS, then checks
# that the data arrived complete and unchanged. FADTESE itself is not modified.
#
# Usage (as root, after verify_fadtese.sh):  ./sqoop_check.sh
#   Connection details: edit the defaults below, or pass them as variables, e.g.
#   REMOTE_HOST=1.2.3.4 REMOTE_USER=myuser ./sqoop_check.sh
#   The password is always asked for (not stored).
#
# Items (same meaning as Instrument 1 Part 3; scores 2 = pass, 0 = fail, NR = not reached):
#   W1  Source records ingested      sqoop import finished, "Retrieved N records" in the log
#   W2  Data written to HDFS         target folder has non-empty file(s)
#   W6  Record count matches         SELECT COUNT(*) on source = lines in HDFS (expected 125)
#   W7  Data accuracy (checksum)     MD5 of the sorted source rows = MD5 of the sorted HDFS rows
#   W3, W4, W5, W8 = NA (NiFi FetchHDFS / QueryRecord / PutDatabaseRecord / bulletins: not in FADTESE)
# Also records workflow execution time (s) and throughput (records/s), as in the Instrument 1 summary.
#
# Output (in /root/ifadeg_logs): part3.csv, e3_workflow.csv, <RUN_ID>_sqoop.log
#        /root/ifadeg_runs/<RUN_ID>_part3.txt
# Needs: mysql client (installed automatically if missing, only to read the source for W6/W7).
# =====================================================================

RUN_ID="${1:-$(awk -F',' 'NR>1{r=$2} END{print r}' /root/ifadeg_logs/e3_split.csv 2>/dev/null)}"   # latest run; Run ID is recorded manually
[ -z "$RUN_ID" ] && { echo "No run found in /root/ifadeg_logs/e3_split.csv - run ./run_fadtese.sh first"; exit 1; }
[ "$(id -u)" -ne 0 ] && { echo "Please run as root: sudo -i"; exit 1; }

# ---------- Source table: the same table as Experiment 4 ----------
REMOTE_HOST="${REMOTE_HOST:-}"          # e.g. the cPanel MySQL host used in Experiment 4
REMOTE_PORT="${REMOTE_PORT:-3306}"
REMOTE_USER="${REMOTE_USER:-}"
REMOTE_DB="${REMOTE_DB:-remote_hd}"
REMOTE_TABLE="${REMOTE_TABLE:-table_stock}"
EXPECTED_RECORDS="${EXPECTED_RECORDS:-125}"
TARGET_DIR="/big_data/sqoop_${REMOTE_TABLE}"

LOG_DIR="/root/ifadeg_logs"; RUNS_DIR="/root/ifadeg_runs"
mkdir -p "$LOG_DIR" "$RUNS_DIR"
P3_CSV="$LOG_DIR/part3.csv"; WF_CSV="$LOG_DIR/e3_workflow.csv"
SQLOG="$LOG_DIR/${RUN_ID}_sqoop.log"
OUT="$RUNS_DIR/${RUN_ID}_part3.txt"
TODAY=$(date +%Y-%m-%d)

# FADTESE's environment (set explicitly; ~/.bashrc is not read by non-interactive shells)
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
export HADOOP_HOME=/usr/local/hadoop HADOOP_INSTALL=/usr/local/hadoop HADOOP_PREFIX=/usr/local/hadoop
export HADOOP_CONF_DIR=/usr/local/hadoop/etc/hadoop HADOOP_COMMON_HOME=/usr/local/hadoop
export HADOOP_HDFS_HOME=/usr/local/hadoop HADOOP_MAPRED_HOME=/usr/local/hadoop YARN_HOME=/usr/local/hadoop
export SQOOP_HOME=/usr/local/sqoop
export PATH="$PATH:$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$SQOOP_HOME/bin"

[ -z "$REMOTE_HOST" ] && read -r -p "Remote MySQL host: " REMOTE_HOST
[ -z "$REMOTE_USER" ] && read -r -p "Remote MySQL user: " REMOTE_USER
read -r -s -p "Password for remote MySQL user $REMOTE_USER@$REMOTE_HOST: " REMOTE_PW; echo

PWFILE=/root/.ifadeg_sqoop_pw
printf '%s' "$REMOTE_PW" > "$PWFILE"; chmod 400 "$PWFILE"
trap 'rm -f "$PWFILE"; rm -rf /tmp/ifadeg_sqoop_out /tmp/ifadeg_sqoop_bin' EXIT
myq() { MYSQL_PWD="$REMOTE_PW" mysql -h "$REMOTE_HOST" -P "$REMOTE_PORT" -u "$REMOTE_USER" -N -B -r -e "$1" 2>>"$SQLOG"; }

for it in W1 W2 W6 W7; do eval "${it}=NR; ${it}_EV='not reached'"; done
WF_START=NA; WF_END=NA; WF_S=NA; THROUGHPUT=NA; SRC_COUNT=NA; TGT_COUNT=NA
: > "$SQLOG"

# ---------- mysql client (evaluation only; installed here, after FADTESE was measured) ----------
if ! command -v mysql >/dev/null 2>&1; then
    echo "[IFADEG] installing mysql-client (evaluation only, after FADTESE measurement)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y mysql-client >>"$SQLOG" 2>&1 \
        || { apt-get update >>"$SQLOG" 2>&1 && apt-get install -y mysql-client >>"$SQLOG" 2>&1; }
    command -v mysql >/dev/null 2>&1 && echo "[IFADEG] mysql-client installed: $(mysql --version)" \
        || echo "[IFADEG] WARNING: mysql-client install failed - see $SQLOG"
fi

# ---------- Preconditions: Sqoop installed, HDFS up, source readable ----------
PRE_OK=1
[ -x "$SQOOP_HOME/bin/sqoop" ] || { PRE_OK=0; PRE_MSG="Sqoop not installed (FADTESE did not finish)"; }
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

res() { case "$1" in 2|1) echo PASS ;; NR) echo NR ;; NA) echo NA ;; *) echo FAIL ;; esac; }
num() { case "$1" in 2|1|0) echo "$1" ;; *) echo 0 ;; esac; }

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
echo "Saved: $P3_CSV, $WF_CSV; Sqoop log $SQLOG; summary $OUT"
echo "Before restoring the snapshot: copy /root/ifadeg_logs and /root/ifadeg_runs to the host."
} | tee "$OUT"
