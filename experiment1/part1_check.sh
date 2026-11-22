#!/bin/bash
# IFADEG Instrument 1 - Part 1: Deployment items (D1-D10)
# Usage:  bash part1_check.sh E1-R01      (run after 5myadmin.sh finishes)
# Scores: 2 = criterion met | 0 = not met
# Note: the "1 = passed after a retry" score comes from the ADS logs (Attempts column), not from this check.

RUN_ID=${1:-E1-RXX}
OUT_DIR=/root/ifadeg_runs
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/${RUN_ID}_part1.txt"
export PATH=$PATH:/usr/local/hadoop/bin:/usr/local/hadoop/sbin

TOTAL=0
declare -a ROWS
record() {
  ROWS+=("$(printf '%-7s| %-30s| %-5s| %s' "$1" "$2" "$3" "$4")")
  [[ "$3" =~ ^[0-9]+$ ]] && TOTAL=$((TOTAL + $3))
}

# D1/S1 Hadoop installed
V=$(hadoop version 2>/dev/null | head -1)
[[ "$V" == *"2.10.2"* ]] && [ -d /usr/local/hadoop ] && S=2 || S=0
record D1/S1 "Hadoop installed" $S "${V:-hadoop not found}"

# D2/S2 NiFi installed
if [ -f /opt/nifi/bin/nifi.sh ] && [ -f /opt/nifi/lib/nifi-api-1.28.1.jar ]; then S=2; N="nifi.sh and nifi-api-1.28.1.jar present"
else S=0; N="missing: $( [ -f /opt/nifi/bin/nifi.sh ] || echo 'nifi.sh ' )$( [ -f /opt/nifi/lib/nifi-api-1.28.1.jar ] || echo 'nifi-api-1.28.1.jar' )"; fi
record D2/S2 "NiFi installed" $S "$N"

# D3/S3 Connector/J in NiFi driver location
J=/opt/nifi/mysql-connector-j-8.4.0/mysql-connector-j-8.4.0.jar
[ -f "$J" ] && S=2 || S=0
record D3/S3 "Connector/J in NiFi location" $S "$( [ -f "$J" ] && echo present || echo "missing $J" )"

# D4/S4 MySQL installed
V=$(mysql --version 2>/dev/null)
[ -n "$V" ] && S=2 || S=0
record D4/S4 "MySQL installed" $S "$(echo "${V:-mysql not found}" | grep -oE 'Ver [0-9.]+' || echo "${V:-mysql not found}")"

# D5/S5 phpMyAdmin installed
ST=$(dpkg -s phpmyadmin 2>/dev/null | grep '^Status:')
[[ "$ST" == *"install ok installed"* ]] && S=2 || S=0
record D5/S5 "phpMyAdmin installed" $S "${ST:-not installed}"

# D6/S1 Hadoop services started
JPS=$(jps 2>/dev/null)
MISS=""
for d in NameNode DataNode SecondaryNameNode ResourceManager NodeManager; do
  echo "$JPS" | grep -qw "$d" || MISS="$MISS $d"
done
[ -z "$MISS" ] && S=2 || S=0
record D6/S1 "Hadoop services started" $S "$( [ -z "$MISS" ] && echo 'all 5 daemons running' || echo "missing:$MISS" )"

# D7/S2 NiFi service started (poll every 15 s, up to 5 min)
S=0; N="not running after 5 min"
for i in $(seq 1 20); do
  if /opt/nifi/bin/nifi.sh status 2>/dev/null | grep -qi "running"; then S=2; N="running (after $(( (i-1)*15 )) s)"; break; fi
  sleep 15
done
record D7/S2 "NiFi service started" $S "$N"

# D8/S4 MySQL service started
A=$(systemctl is-active mysql 2>/dev/null)
[ "$A" = "active" ] && S=2 || S=0
record D8/S4 "MySQL service started" $S "${A:-unknown}"

# D9/S2 NiFi web interface reachable (poll up to 5 min)
S=0; C=000
for i in $(seq 1 20); do
  C=$(curl -k -s -o /dev/null -w "%{http_code}" https://localhost:8443/nifi/)
  if [ "$C" = "200" ] || [ "$C" = "302" ]; then S=2; break; fi
  sleep 15
done
record D9/S2 "NiFi web interface reachable" $S "HTTP $C"

# D10/S5 phpMyAdmin reachable
C=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/phpmyadmin/)
[ "$C" = "200" ] && S=2 || S=0
record D10/S5 "phpMyAdmin reachable" $S "HTTP $C"

{
  echo "IFADEG Instrument 1 - Part 1 (deployment items) | Run: $RUN_ID | $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "No.    | Item                          | Score| Notes"
  echo "-------+-------------------------------+------+------------------------------"
  printf '%s\n' "${ROWS[@]}"
  echo "-------+-------------------------------+------+------------------------------"
  echo "Part 1 items total: $TOTAL / 20"
  echo "Reminder: if a stage needed a retry (ADS log Attempts > 1), lower its item(s) to 1."
} | tee "$LOG"
echo "Saved to $LOG"
