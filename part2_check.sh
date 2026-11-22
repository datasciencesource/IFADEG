#!/bin/bash
# IFADEG Instrument 1 - Part 3: Workflow validation (W1-W8 + summary)
# Workflow: Remote MySQL -> NiFi ingestion -> HDFS -> NiFi processing -> local MySQL -> phpMyAdmin
#
# Usage:  bash part3_check.sh <RUN_ID> [WORKFLOW_SECONDS]
#   e.g.  bash part3_check.sh E1-R01 184
#
# Run it RIGHT AFTER the workflow finishes: NiFi processor statistics cover only the last 5 minutes,
# and bulletins are kept for about 5 minutes.
# Scores: 2 = criterion fully met | 1 = partly met | 0 = failed | NR = not run / processor not found

RUN_ID=${1:-E1-RXX}
WF_SECONDS=${2:-}
OUT_DIR=/root/ifadeg_runs
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/${RUN_ID}_part3.txt"

# ---------------- Configuration ----------------
# Source (remote MySQL) - use the same values as NiFi's DBCPConnectionPool for the remote side
SRC_HOST=69.175.69.34
SRC_PORT=3306
SRC_USER=sumrachna_hd
SRC_TABLE=sumrachna_hd.table_stock
SRC_PASS='RootAdmin11!!'      # do NOT upload this file to the public GitHub repo

# Target (local MySQL)
TGT_HOST=localhost
TGT_PORT=3306
TGT_USER=usertest
TGT_PASS=Admin1111
TGT_TABLE=dbtest.table_stock

# NiFi
NIFI_HOST=https://localhost:8443
NIFI_USER=admin
NIFI_PASS=Admin123456789

# HDFS output folder written by PutHDFS
HDFS_DIR=/big_data

# NiFi processor types for each step (comma-separated; first match wins, all matches are summed)
INGEST_TYPES="QueryDatabaseTable,QueryDatabaseTableRecord,ExecuteSQL,ExecuteSQLRecord,GenerateTableFetch"
# -----------------------------------------------

TMP=$(mktemp -d)
TOTAL=0
declare -a ROWS
record() {
  ROWS+=("$(printf '%-4s| %-32s| %-5s| %s' "$1" "$2" "$3" "$4")")
  [[ "$3" =~ ^[0-9]+$ ]] && TOTAL=$((TOTAL + $3))
}
sql() {  # sql <src|tgt> "<query>"
  if [ "$1" = src ]; then
    MYSQL_PWD="$SRC_PASS" mysql -h "$SRC_HOST" -P "$SRC_PORT" -u "$SRC_USER" -N -B -e "$2" 2>"$TMP/sql_err"
  else
    MYSQL_PWD="$TGT_PASS" mysql -h "$TGT_HOST" -P "$TGT_PORT" -u "$TGT_USER" -N -B -e "$2" 2>"$TMP/sql_err"
  fi
}

# ---- NiFi login + statistics ----
CODE=$(curl -sk -o "$TMP/token" -w "%{http_code}" -X POST "$NIFI_HOST/nifi-api/access/token" \
  --data-urlencode "username=$NIFI_USER" --data-urlencode "password=$NIFI_PASS")
NIFI_OK=0
if [ "$CODE" = "201" ]; then
  NIFI_OK=1
  AUTH="Authorization: Bearer $(cat "$TMP/token")"
  curl -sk -H "$AUTH" "$NIFI_HOST/nifi-api/flow/process-groups/root/status?recursive=true" > "$TMP/status.json"
  curl -sk -H "$AUTH" "$NIFI_HOST/nifi-api/flow/bulletin-board?limit=1000" > "$TMP/bulletins.json"
fi

# Python helper: per-type stats -> "found|out|fail" ; plus W8 data
nifi_stats() {  # nifi_stats "<Type1,Type2>"
  python3 - "$TMP/status.json" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
types = [t.strip() for t in sys.argv[2].split(",") if t.strip()]
procs, conns = [], []
def walk(snap):
    procs.extend(p["processorStatusSnapshot"] for p in snap.get("processorStatusSnapshots", []))
    conns.extend(c["connectionStatusSnapshot"] for c in snap.get("connectionStatusSnapshots", []))
    for g in snap.get("processGroupStatusSnapshots", []):
        walk(g["processGroupStatusSnapshot"])
walk(data["processGroupStatus"]["aggregateSnapshot"])
match = [p for p in procs if p.get("type", "").split(".")[-1] in types]
ids = {p["id"] for p in match}
out = sum(p.get("flowFilesOut", 0) for p in match)
fail = sum(c.get("flowFilesIn", 0) + c.get("flowFilesQueued", 0) for c in conns
           if c.get("sourceId") in ids and "failure" in (c.get("name") or "").lower())
names = ",".join(p.get("name", "?") for p in match)
print(f"{len(match)}|{out}|{fail}|{names}")
PY
}

score_proc() {  # score_proc <No> <Item> <Types> [extra-condition 0/1]
  if [ $NIFI_OK -ne 1 ]; then record "$1" "$2" NR "NiFi login failed (HTTP $CODE)"; return; fi
  IFS='|' read -r FOUND OUT FAIL NAMES <<< "$(nifi_stats "$3")"
  if [ "${FOUND:-0}" -eq 0 ]; then record "$1" "$2" NR "No processor of type: $3"; return; fi
  EXTRA=${4:-1}
  if   [ "$OUT" -gt 0 ] && [ "$FAIL" -eq 0 ] && [ "$EXTRA" -eq 1 ]; then S=2
  elif [ "$OUT" -gt 0 ]; then S=1
  else S=0; fi
  record "$1" "$2" $S "$NAMES: out=$OUT, failure=$FAIL${5:+; $5}"
}

# ---- W1-W5 ----
score_proc W1 "Source records ingested into NiFi" "$INGEST_TYPES"

HDFS_BYTES=$(hdfs dfs -du -s "$HDFS_DIR" 2>/dev/null | awk '{print $1}')
HDFS_FILES=$(hdfs dfs -ls "$HDFS_DIR" 2>/dev/null | grep -c '^-')
HDFS_BYTES=${HDFS_BYTES:-0}
[ "$HDFS_FILES" -gt 0 ] && [ "$HDFS_BYTES" -gt 0 ] && HOK=1 || HOK=0
score_proc W2 "Data written to HDFS" "PutHDFS" $HOK "HDFS $HDFS_DIR: $HDFS_FILES file(s), $HDFS_BYTES bytes"

score_proc W3 "Data read back from HDFS" "FetchHDFS"
score_proc W4 "Data processed in NiFi" "QueryRecord"
score_proc W5 "Data exported to local MySQL" "PutDatabaseRecord"

# ---- W6 record counts ----
SRC_N=$(sql src "SELECT COUNT(*) FROM $SRC_TABLE")
TGT_N=$(sql tgt "SELECT COUNT(*) FROM $TGT_TABLE")
if   [ -n "$SRC_N" ] && [ "$SRC_N" = "$TGT_N" ]; then S=2
elif [ -n "$TGT_N" ] && [ "${TGT_N:-0}" -gt 0 ]; then S=1
else S=0; fi
record W6 "Record count matches" $S "source=${SRC_N:-error} / target=${TGT_N:-error}"

# ---- W7 checksum ----
CK="SET SESSION group_concat_max_len = 1073741824;
SELECT MD5(GROUP_CONCAT(CONCAT_WS('|', product_id, ROUND(purchasing_price, 2), quantity, stock_date)
       ORDER BY product_id, stock_date, purchasing_price, quantity SEPARATOR '\n'))"
SRC_CK=$(sql src "$CK FROM $SRC_TABLE;")
TGT_CK=$(sql tgt "$CK FROM $TGT_TABLE;")
if [ -n "$SRC_CK" ] && [ "$SRC_CK" = "$TGT_CK" ] && [ "$SRC_CK" != "NULL" ]; then S=2; else S=0; fi
record W7 "Data accuracy (full-table checksum)" $S "source=${SRC_CK:-error} / target=${TGT_CK:-error}"

# ---- W8 bulletins + failure queues ----
if [ $NIFI_OK -ne 1 ]; then
  record W8 "No processor errors" NR "NiFi login failed (HTTP $CODE)"
else
  IFS='|' read -r ERR QUEUED <<< "$(python3 - "$TMP/bulletins.json" "$TMP/status.json" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
err = sum(1 for x in b.get("bulletinBoard", {}).get("bulletins", [])
          if (x.get("bulletin") or {}).get("level") == "ERROR")
s = json.load(open(sys.argv[2]))
conns = []
def walk(snap):
    conns.extend(c["connectionStatusSnapshot"] for c in snap.get("connectionStatusSnapshots", []))
    for g in snap.get("processGroupStatusSnapshots", []):
        walk(g["processGroupStatusSnapshot"])
walk(s["processGroupStatus"]["aggregateSnapshot"])
q = sum(c.get("flowFilesQueued", 0) for c in conns if "failure" in (c.get("name") or "").lower())
print(f"{err}|{q}")
PY
)"
  if   [ "$ERR" -eq 0 ] && [ "$QUEUED" -eq 0 ]; then S=2
  elif [ "$ERR" -eq 0 ] || [ "$QUEUED" -eq 0 ]; then S=1
  else S=0; fi
  record W8 "No processor errors" $S "ERROR bulletins=$ERR; FlowFiles in failure queues=$QUEUED"
fi

# ---- Summary: time + throughput ----
if [ -n "$WF_SECONDS" ] && [ -n "$TGT_N" ]; then
  TPUT=$(python3 -c "print(round($TGT_N/$WF_SECONDS, 2))")
  SUMMARY="$WF_SECONDS s / $TPUT records/s"
else
  SUMMARY="not given (pass workflow seconds as 2nd argument)"
fi

# ---- Output ----
{
  echo "IFADEG Instrument 1 - Part 3 | Run: $RUN_ID | $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "No. | Item                            | Score| Notes"
  echo "----+---------------------------------+------+--------------------------------------"
  printf '%s\n' "${ROWS[@]}"
  echo "----+---------------------------------+------+--------------------------------------"
  echo "Part 3 total: $TOTAL / 16"
  echo "Workflow execution time / throughput: $SUMMARY"
} | tee "$LOG"
echo "Saved to $LOG"
rm -rf "$TMP"
