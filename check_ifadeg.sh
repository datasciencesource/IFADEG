#!/bin/bash
# =============================================================================
# IFADEG Instrument 1 checks: Part 1 (D1-D10) and Part 2 (C1-C7)
# Run inside the VM after run_ads.sh has finished:
#   sudo bash check_ifadeg.sh E1-R01
# Prints PASS / FAIL per item and writes logs/<RUN_ID>/checks.csv
# C7 (phpMyAdmin login) and C8 (NiFi template) are done by hand.
# =============================================================================
RUN_ID="${1:?Usage: sudo bash check_ifadeg.sh <RUN_ID>}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/logs/$RUN_ID/checks.csv"
mkdir -p "$(dirname "$OUT")"
DB_USER="usertest"; DB_PASS="Admin1111"
NIFI_USER="admin";  NIFI_PASS="Admin123456789"
export PATH="/usr/local/bin:$PATH"

echo "item,description,result,detail,checked_at" > "$OUT"
code() { curl -k -s -o /dev/null -m 10 -w '%{http_code}' "$@" 2>/dev/null; }
poll() { local t=0; until "$@"; do [ "$t" -ge 300 ] && return 1; sleep 15; t=$((t+15)); done; }

chk() {
  local id="$1" desc="$2"; shift 2
  local out rc res
  out=$("$@" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && res=PASS || res=FAIL
  out=$(echo "$out" | tr '\n,"' '  ' | sed 's/  */ /g' | cut -c1-110)
  printf "%-4s %-36s %-5s %s\n" "$id" "$desc" "$res" "$out"
  echo "$id,$desc,$res,\"$out\",$(date '+%Y-%m-%d %H:%M:%S')" >> "$OUT"
}

d1()  { hadoop version | head -1 | grep "Hadoop 2.10.2" && ls -d /usr/local/hadoop; }
d2()  { ls /opt/nifi/bin/nifi.sh /opt/nifi/lib/nifi-api-1.28.1.jar; }
d3()  { ls /opt/nifi/mysql-connector-j-8.4.0/mysql-connector-j-8.4.0.jar; }
d4()  { mysql --version; }
d5()  { dpkg -s phpmyadmin | grep "install ok installed"; }
d6()  { jps | grep -w NameNode && jps | grep -w DataNode; }
nifi_running() { /opt/nifi/bin/nifi.sh status 2>&1 | grep -qi "currently running"; }
d7()  { poll nifi_running && echo "NiFi is running"; }
nifi_web() { local c; c=$(code https://localhost:8443/nifi/); [ "$c" = 200 ] || [ "$c" = 302 ]; }
d8()  { systemctl is-active mysql; }
d9()  { poll nifi_web && echo "HTTP $(code https://localhost:8443/nifi/)"; }
d10() { local c; c=$(code http://localhost/phpmyadmin/); echo "HTTP $c"; [ "$c" = 200 ]; }
c1()  { hdfs dfsadmin -report 2>/dev/null | grep -E "Live datanodes \([1-9]" && hdfs dfsadmin -safemode get | grep OFF; }
c2()  { hdfs dfs -mkdir -p /big_data && echo ok | hdfs dfs -put -f - /big_data/_check.txt && hdfs dfs -cat /big_data/_check.txt | grep -x ok; }
c3()  { local c; c=$(code -X POST https://localhost:8443/nifi-api/access/token -d "username=$NIFI_USER&password=$NIFI_PASS"); echo "HTTP $c"; [ "$c" = 201 ]; }
c4()  { mysql -u"$DB_USER" -p"$DB_PASS" -N -e "SELECT 1" | grep -x 1; }
c5()  { mysql -u"$DB_USER" -p"$DB_PASS" -N -e "SHOW DATABASES LIKE 'dbtest'" | grep -x dbtest; }
c6()  { mysql -u"$DB_USER" -p"$DB_PASS" -N -e "SHOW TABLES IN dbtest LIKE 'table_stock'" | grep -x table_stock; }

echo "== Part 1: Deployment items (run $RUN_ID) =="
chk D1  "Hadoop installed"             d1
chk D2  "NiFi installed"               d2
chk D3  "Connector/J in NiFi folder"   d3
chk D4  "MySQL installed"              d4
chk D5  "phpMyAdmin installed"         d5
chk D6  "Hadoop services started"      d6
chk D7  "NiFi service started"         d7
chk D8  "MySQL service started"        d8
chk D9  "NiFi web interface reachable" d9
chk D10 "phpMyAdmin reachable"         d10
echo "== Part 2: Component items =="
chk C1  "HDFS healthy"                 c1
chk C2  "HDFS read/write"              c2
chk C3  "NiFi accepts login"           c3
chk C4  "MySQL accepts connections"    c4
chk C5  "Database dbtest exists"       c5
chk C6  "Table table_stock exists"     c6
echo "C7   phpMyAdmin login                     MANUAL  log in as $DB_USER in the browser"
echo "C8   NiFi template loaded and valid       MANUAL  import template, check 0 invalid processors"
echo
echo "Saved: $OUT"
echo "Scoring: PASS on this first check = 2; FAIL now but PASS when re-checked later = 1; still FAIL = 0."
