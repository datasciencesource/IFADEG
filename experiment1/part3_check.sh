#!/bin/bash
# IFADEG Instrument 1 - Part 3: Workflow validation (W2, W6, W7 scripted)
# W1, W3, W4, W5 (NiFi processor statistics) and W8 (bulletin board / failure queues)
# are read manually in the NiFi UI.
# Usage:  bash part3_check.sh E1-R01
#   The remote password is asked at the prompt (not stored in this file).
#   Optional: export SRC_PASS='...' before running to skip the prompt.
# Scores: 2 = criterion met | 0 = not met | NR = not run (e.g. remote unreachable)
# Run AFTER the NiFi flow has finished and BEFORE restoring the snapshot.

RUN_ID=${1:-E1-RXX}
OUT_DIR=/root/ifadeg_runs
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/${RUN_ID}_part3.txt"

# ---- Remote source (same as the NiFi source connection) ----
SRC_HOST=69.175.69.34
SRC_USER=sumrachna_hd
SRC_DB=sumrachna_hd
# ---- Local target ----
TGT_USER=usertest
TGT_PASS=Admin1111
TGT_DB=dbtest
TABLE=table_stock
EXPECTED=125
HDFS_DIR=/big_data

# Hadoop may not be on PATH in a non-interactive shell
export PATH=$PATH:/usr/local/hadoop/bin

if [ -z "$SRC_PASS" ]; then
  read -r -s -p "Password for remote MySQL user $SRC_USER@$SRC_HOST: " SRC_PASS; echo
fi

TOTAL=0
declare -a ROWS
record() {   # record <No> <Item> <Score> <Notes>
  ROWS+=("$(printf '%-4s| %-30s| %-5s| %s' "$1" "$2" "$3" "$4")")
  [[ "$3" =~ ^[0-9]+$ ]] && TOTAL=$((TOTAL + $3))
}

# Same query on both sides: record count + MD5 of all rows in id order
Q="SET SESSION group_concat_max_len=1000000;
SELECT COUNT(*), MD5(GROUP_CONCAT(CONCAT_WS('|',id,product_id,purchasing_price,quantity,\`datetime\`)
ORDER BY id SEPARATOR '\n')) FROM $TABLE;"

SRC=$(MYSQL_PWD="$SRC_PASS" mysql -h "$SRC_HOST" -u "$SRC_USER" -N "$SRC_DB" -e "$Q" 2>&1)
SRC_RC=$?
TGT=$(MYSQL_PWD="$TGT_PASS" mysql -u "$TGT_USER" -N "$TGT_DB" -e "$Q" 2>&1)
TGT_RC=$?
read -r SRC_N SRC_SUM <<< "$SRC"
read -r TGT_N TGT_SUM <<< "$TGT"

# ---- W2 Data written to HDFS ----
HF=$(hdfs dfs -ls "$HDFS_DIR" 2>/dev/null | awk '$1 ~ /^-/ && $8 !~ /_check\.txt$/ && $5 > 0' | wc -l)
[ "$HF" -ge 1 ] && S=2 || S=0
record W2 "Data written to HDFS" $S "$HF non-empty file(s) in $HDFS_DIR"

# ---- W6 Record count matches ----
if [ $SRC_RC -ne 0 ]; then
  record W6 "Record count matches" NR "remote query failed: ${SRC:0:80}"
elif [ $TGT_RC -ne 0 ]; then
  record W6 "Record count matches" 0 "local query failed: ${TGT:0:80}"
else
  [ "$SRC_N" = "$TGT_N" ] && [ "$TGT_N" = "$EXPECTED" ] && S=2 || S=0
  record W6 "Record count matches" $S "source=$SRC_N target=$TGT_N (expected $EXPECTED)"
fi

# ---- W7 Data accuracy (full-table checksum) ----
if [ $SRC_RC -ne 0 ]; then
  record W7 "Data accuracy (checksum)" NR "remote query failed"
elif [ $TGT_RC -ne 0 ]; then
  record W7 "Data accuracy (checksum)" 0 "local query failed"
else
  [ -n "$SRC_SUM" ] && [ "$SRC_SUM" = "$TGT_SUM" ] && S=2 || S=0
  record W7 "Data accuracy (checksum)" $S "source=$SRC_SUM target=$TGT_SUM"
fi

# ---- Output ----
{
  echo "IFADEG Instrument 1 - Part 3 | Run: $RUN_ID | $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "No. | Item                          | Score| Notes"
  echo "----+-------------------------------+------+------------------------------"
  printf '%s\n' "${ROWS[@]}"
  echo "----+-------------------------------+------+------------------------------"
  echo "Scripted total (W2, W6, W7): $TOTAL / 6"
  echo "Manual in NiFi UI: W1 ingestion, W3 FetchHDFS, W4 QueryRecord, W5 PutDatabaseRecord (processor statistics),"
  echo "W8 bulletin board / failure queues -> add to form; Part 3 total = $TOTAL + W1 + W3 + W4 + W5 + W8 (out of 16)"
} | tee "$LOG"
echo "Saved to $LOG"
