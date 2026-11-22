#!/bin/bash
# IFADEG Instrument 1 - Part 2: Component verification (C1-C6, scripted)
# C7 (phpMyAdmin login) and C8 (NiFi login) are checked manually in the web browser.
# Usage:  bash ifadeg_part2_check.sh E1-R01
# Scores: 2 = criterion fully met | 1 = component up, criterion partly met | 0 = failed | NR = not run

RUN_ID=${1:-E1-RXX}
OUT_DIR=/root/ifadeg_runs
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/${RUN_ID}_part2.txt"

# ---- Test accounts (from the deployment scripts) ----
DB_USER=usertest
DB_PASS=Admin1111
NIFI_USER=admin
NIFI_PASS=Admin123456789
NIFI_HOST=https://localhost:8443

export MYSQL_PWD="$DB_PASS"          # avoids the mysql "password on command line" warning
TOTAL=0
declare -a ROWS

record() {   # record <No> <Item> <Score> <Notes>
  ROWS+=("$(printf '%-4s| %-30s| %-5s| %s' "$1" "$2" "$3" "$4")")
  [[ "$3" =~ ^[0-9]+$ ]] && TOTAL=$((TOTAL + $3))
}

# ---- C1 HDFS is healthy ----
LIVE=$(hdfs dfsadmin -report 2>/dev/null | grep -oP 'Live datanodes \(\K[0-9]+')
SAFE=$(hdfs dfsadmin -safemode get 2>/dev/null | grep -oE 'ON|OFF' | head -1)
LIVE=${LIVE:-0}
if   [ "$LIVE" -ge 1 ] && [ "$SAFE" = "OFF" ]; then S=2
elif [ "$LIVE" -ge 1 ] || [ "$SAFE" = "OFF" ]; then S=1
else S=0; fi
record C1 "HDFS is healthy" $S "Live DataNodes=$LIVE; safe mode=${SAFE:-unknown}"

# ---- C2 HDFS read/write works ----
R=$(hdfs dfs -mkdir -p /big_data 2>/dev/null && echo ok | hdfs dfs -put -f - /big_data/_check.txt 2>/dev/null \
    && hdfs dfs -cat /big_data/_check.txt 2>/dev/null)
if   [ "$R" = "ok" ]; then S=2; N="Prints ok"
elif hdfs dfs -test -d /big_data 2>/dev/null; then S=1; N="Dir exists, write/read failed"
else S=0; N="mkdir failed"; fi
hdfs dfs -rm -f -skipTrash /big_data/_check.txt >/dev/null 2>&1
record C2 "HDFS read/write works" $S "$N"

# ---- C3 NiFi accepts login ----
CODE=$(curl -sk -o /tmp/nifi_token.txt -w "%{http_code}" -X POST "$NIFI_HOST/nifi-api/access/token" \
  --data-urlencode "username=$NIFI_USER" --data-urlencode "password=$NIFI_PASS")
if   [ "$CODE" = "201" ]; then S=2
elif [ "$CODE" != "000" ]; then S=1
else S=0; fi
record C3 "NiFi accepts login" $S "HTTP $CODE"

# ---- C4 MySQL accepts user connections ----
R=$(mysql -u "$DB_USER" -N -e "SELECT 1" 2>/dev/null)
[ "$R" = "1" ] && S=2 || S=0
record C4 "MySQL accepts user connections" $S "Returned: ${R:-error}"

# ---- C5 Database dbtest exists ----
R=$(mysql -u "$DB_USER" -N -e "SHOW DATABASES LIKE 'dbtest'" 2>/dev/null | wc -l)
[ "$R" -eq 1 ] && S=2 || S=0
record C5 "Database dbtest exists" $S "$R row(s)"

# ---- C6 Table table_stock exists ----
R=$(mysql -u "$DB_USER" -N -e "SHOW TABLES IN dbtest LIKE 'table_stock'" 2>/dev/null | wc -l)
[ "$R" -eq 1 ] && S=2 || S=0
record C6 "Table table_stock exists" $S "$R row(s)"

# ---- Output ----
{
  echo "IFADEG Instrument 1 - Part 2 | Run: $RUN_ID | $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "No. | Item                          | Score| Notes"
  echo "----+-------------------------------+------+------------------------------"
  printf '%s\n' "${ROWS[@]}"
  echo "----+-------------------------------+------+------------------------------"
  echo "Scripted total (C1-C6): $TOTAL / 12"
  echo "Manual in browser: C7 phpMyAdmin login (usertest) | C8 NiFi login (admin) -> add to form; Part 2 total = $TOTAL + C7 + C8 (out of 16)"
} | tee "$LOG"
echo "Saved to $LOG"
