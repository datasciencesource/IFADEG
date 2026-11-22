#!/bin/bash
# IFADEG Instrument 1 - Part 2: Component verification (C1-C8)
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
PMA_URL=http://localhost/phpmyadmin/

export MYSQL_PWD="$DB_PASS"          # avoids the mysql "password on command line" warning
TOTAL=0
declare -a ROWS

record() {   # record <No> <Item> <Score> <Notes>
  ROWS+=("$(printf '%-4s| %-30s| %-5s| %s' "$1" "$2" "$3" "$4")")
  [[ "$3" =~ ^[0-9]+$ ]] && TOTAL=$((TOTAL + $3))
}
num() { echo "$1" | grep -oP "\"$2\":\K[0-9]+" | head -1; }

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
TOKEN=""
if   [ "$CODE" = "201" ]; then S=2; TOKEN=$(cat /tmp/nifi_token.txt)
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

# ---- C7 phpMyAdmin login works ----
JAR=/tmp/pma_cookies.txt; rm -f $JAR
HTTP=$(curl -s -o /tmp/pma_page.html -w "%{http_code}" -c $JAR -b $JAR "$PMA_URL")
TOK=$(grep -oP 'name="token" value="\K[^"]+' /tmp/pma_page.html | head -1)
SES=$(grep -oP 'name="set_session" value="\K[^"]+' /tmp/pma_page.html | head -1)
RESP=$(curl -s -c $JAR -b $JAR -L "$PMA_URL" \
  --data-urlencode "pma_username=$DB_USER" --data-urlencode "pma_password=$DB_PASS" \
  --data-urlencode "server=1" --data-urlencode "token=$TOK" --data-urlencode "set_session=$SES")
if   echo "$RESP" | grep -qiE 'logout|server_status|db_structure'; then S=2; N="Dashboard shown (curl login)"
elif [ "$HTTP" = "200" ]; then S=1; N="Page loads, login failed"
else S=0; N="HTTP $HTTP"; fi
record C7 "phpMyAdmin login works" $S "$N"

# ---- C8 NiFi flow loaded and valid ----
# Lists every processor (all process groups) with its run status and validation errors.
c8_check() {
  curl -sk -H "Authorization: Bearer $TOKEN" \
    "$NIFI_HOST/nifi-api/flow/process-groups/root/status?recursive=true" > /tmp/c8_status.json
  python3 - /tmp/c8_status.json "$NIFI_HOST" "$TOKEN" <<'PYC'
import json, sys, ssl, urllib.request
status = json.load(open(sys.argv[1])); host, token = sys.argv[2], sys.argv[3]
ctx = ssl._create_unverified_context()
def get(path):
    req = urllib.request.Request(host + path, headers={"Authorization": "Bearer " + token})
    return json.load(urllib.request.urlopen(req, context=ctx))
procs = []
def walk(snap):
    for p in snap.get("processorStatusSnapshots", []):
        procs.append(p["processorStatusSnapshot"])
    for g in snap.get("processGroupStatusSnapshots", []):
        walk(g["processGroupStatusSnapshot"])
walk(status["processGroupStatus"]["aggregateSnapshot"])
invalid = []
for p in procs:
    if p.get("runStatus") == "Invalid":
        try:
            errs = get("/nifi-api/processors/" + p["id"])["component"].get("validationErrors") or []
        except Exception:
            errs = []
        invalid.append("{}: {}".format(p.get("name"), (errs[0] if errs else "invalid")[:120]))
print("{}|{}".format(len(procs), len(invalid)))
for i in invalid:
    print(i)
PYC
}
if [ -z "$TOKEN" ]; then
  record C8 "NiFi flow loaded and valid" NR "No NiFi token (C3 failed)"
else
  OUT=$(c8_check)
  COMP=$(echo "$OUT" | head -1 | cut -d'|' -f1); INV=$(echo "$OUT" | head -1 | cut -d'|' -f2)
  COMP=${COMP:-0}; INV=${INV:-0}
  # Flow not imported yet: ask the evaluator to import it (as the form's run procedure says), then re-check once
  if [ "$COMP" -eq 0 ] && [ -t 0 ]; then
    echo ""
    echo ">>> C8: no processors on the NiFi canvas."
    echo ">>> Import the NiFi template, add it to the canvas and enable the controller services,"
    read -rp ">>> then press Enter to re-check C8 (or type s + Enter to skip): " ANS
    if [ "$ANS" != "s" ]; then
      OUT=$(c8_check)
      COMP=$(echo "$OUT" | head -1 | cut -d'|' -f1); INV=$(echo "$OUT" | head -1 | cut -d'|' -f2)
      COMP=${COMP:-0}; INV=${INV:-0}
    fi
  fi
  if   [ "$COMP" -eq 0 ]; then S=0; N="no processors on canvas (template not imported)"
  elif [ "$INV" -eq 0 ]; then S=2; N="$COMP processors, 0 invalid"
  else S=1; N="$COMP processors, $INV invalid: $(echo "$OUT" | tail -n +2 | paste -sd ';' -)"; fi
  record C8 "NiFi flow loaded and valid" $S "$N"
fi

# ---- Output ----
{
  echo "IFADEG Instrument 1 - Part 2 | Run: $RUN_ID | $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "No. | Item                          | Score| Notes"
  echo "----+-------------------------------+------+------------------------------"
  printf '%s\n' "${ROWS[@]}"
  echo "----+-------------------------------+------+------------------------------"
  echo "Part 2 total: $TOTAL / 16"
} | tee "$LOG"
echo "Saved to $LOG"
