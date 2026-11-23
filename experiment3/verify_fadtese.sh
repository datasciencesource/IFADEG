#!/bin/bash
# =====================================================================
# verify_fadtese.sh - scores the Instrument items for one FADTESE run
# Usage (as root, in /root, right after install_big_data_utilities.sh):
#   ./verify_fadtese.sh E3-R01
#
# Scoring follows Instrument 1:
#   2 = passed first time; 1 = passed only after a wait (Part 2);
#   0 = failed; NR = not reached; NA = not in FADTESE scope (excluded,
#   NOT counted as 0 - FADTESE never installs these components).
# Writes items.csv (deployment items) and part2.csv (component items).
# =====================================================================
RUN_ID="${1:?Usage: $0 RUN_ID}"
OUT="/root/fadtese_runs/$RUN_ID"
mkdir -p "$OUT"
# keep the FADTESE terminal log with the results, if it was saved as <RUN_ID>.log
[ -f "/root/$RUN_ID.log" ] && cp "/root/$RUN_ID.log" "$OUT/"
LOG="$OUT/verify.log"; : > "$LOG"

# .bashrc is not read by non-interactive shells, so set the environment here
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
export HADOOP_INSTALL=/usr/local/hadoop HADOOP_HOME=/usr/local/hadoop
export HADOOP_CONF_DIR=/usr/local/hadoop/etc/hadoop SQOOP_HOME=/usr/local/sqoop
export PATH=$PATH:$HADOOP_INSTALL/bin:$HADOOP_INSTALL/sbin:$SQOOP_HOME/bin

# Stop early if FADTESE failed: items after the failure are NR
RC=""
[ -f "$OUT/run_meta.env" ] && RC=$(grep '^EXIT_CODE=' "$OUT/run_meta.env" | cut -d= -f2)

run() {  # run "label" command... ; output to log, returns command output
    echo "### $1" >> "$LOG"; shift
    "$@" >> "$LOG" 2>&1
}
cap() { "$@" 2>&1; }

echo "no,item,method,criterion,score,notes" > "$OUT/items.csv"
item() { echo "$1,\"$2\",\"$3\",\"$4\",$5,\"$6\"" >> "$OUT/items.csv"; printf '  %-6s %-32s %s %s\n' "$1" "$2" "$5" "$6"; }

echo "Deployment items - $RUN_ID"
# D1 Hadoop installed
o=$(cap hadoop version); echo "### D1"$'\n'"$o" >> "$LOG"
if echo "$o" | grep -q "Hadoop 2.10.2" && [ -d /usr/local/hadoop ]; then s=2; else s=0; fi
item D1/S1 "Hadoop installed" "hadoop version; ls -d /usr/local/hadoop" "Prints Hadoop 2.10.2; directory exists" $s ""

# D6 Hadoop services
o=$(cap jps); echo "### D6"$'\n'"$o" >> "$LOG"
miss=""; for d in NameNode DataNode SecondaryNameNode ResourceManager NodeManager; do
    echo "$o" | grep -qw "$d" || miss="$miss $d"; done
[ -z "$miss" ] && s=2 || s=0
item D6/S1 "Hadoop services started" "jps" "5 Hadoop daemons listed" $s "${miss:+missing:$miss}"

# FADTESE-specific items (from Deployment Reliability Metrics checklist)
o=$(cap java -version); echo "### F1"$'\n'"$o" >> "$LOG"
echo "$o" | grep -q 'version "11\.' && s=2 || s=0
item F1 "Java 11 installed" "java -version" "OpenJDK 11 printed" $s "$(echo "$o" | head -1 | tr -d '"')"

o=$(cap systemctl is-active ssh); echo "### F2"$'\n'"$o" >> "$LOG"
[ "$o" = "active" ] && s=2 || s=0
item F2 "SSH service running" "systemctl is-active ssh" "active" $s ""

o=$(cap sqoop version); echo "### F3"$'\n'"$o" >> "$LOG"
echo "$o" | grep -q "Sqoop 1.4.7" && s=2 || s=0
item F3 "Sqoop installed" "sqoop version" "Sqoop 1.4.7" $s ""

ls /usr/local/sqoop/lib 2>/dev/null | grep -q '^commons-lang-2.6.jar$' && s=2 || s=0
item F4 "commons-lang-2.6.jar present" "ls /usr/local/sqoop/lib" "File exists" $s ""

ls /usr/local/sqoop/lib 2>/dev/null | grep -q '^mysql-connector-java-5.1.34-bin.jar$' && s=2 || s=0
item F5 "Connector/J 5.1.34 in Sqoop lib" "ls /usr/local/sqoop/lib" "File exists" $s ""

o=$(cap python3 --version); echo "### F6"$'\n'"$o" >> "$LOG"
echo "$o" | grep -q '^Python 3' && s=2 || s=0
item F6 "Python installed" "python3 --version" "Python 3.x printed" $s "$o"

o=$(cap pip3 --version); echo "### F7"$'\n'"$o" >> "$LOG"
echo "$o" | grep -q '^pip ' && s=2 || s=0
item F7 "pip installed" "pip3 --version" "pip version printed" $s "$(echo "$o" | awk '{print $1, $2}')"

for d in "D2/S2:NiFi installed" "D3/S3:Connector/J in NiFi driver location" "D4/S4:MySQL installed" \
         "D5/S5:phpMyAdmin installed" "D7/S2:NiFi service started" "D8/S4:MySQL service started" \
         "D9/S2:NiFi web interface reachable" "D10/S5:phpMyAdmin reachable"; do
    item "${d%%:*}" "${d#*:}" "-" "-" NA "not in FADTESE scope"
done

echo "no,item,method,criterion,score,notes" > "$OUT/part2.csv"
comp() { echo "$1,\"$2\",\"$3\",\"$4\",$5,\"$6\"" >> "$OUT/part2.csv"; printf '  %-6s %-32s %s %s\n' "$1" "$2" "$5" "$6"; }

echo "Component verification - $RUN_ID"
# C1 HDFS healthy: first check = 2; passes after waiting (poll 15 s, up to 2 min) = 1
hdfs_ok() {
    r=$(hdfs dfsadmin -report 2>&1); m=$(hdfs dfsadmin -safemode get 2>&1)
    echo "### C1"$'\n'"$r"$'\n'"$m" >> "$LOG"
    echo "$r" | grep -Eq 'Live datanodes \(([1-9][0-9]*)\)' && echo "$m" | grep -q "Safe mode is OFF"
}
if hdfs_ok; then s=2; n=""
else
    s=0; n="failed after 2 min"
    for k in 1 2 3 4 5 6 7 8; do sleep 15; if hdfs_ok; then s=1; n="passed after $((k*15)) s wait"; break; fi; done
fi
comp C1 "HDFS is healthy" "hdfs dfsadmin -report; -safemode get" ">=1 live DataNode; safe mode OFF" $s "$n"

# C2 HDFS read/write
o=$(hdfs dfs -mkdir -p /big_data 2>&1 && echo ok | hdfs dfs -put -f - /big_data/_check.txt 2>&1 && hdfs dfs -cat /big_data/_check.txt 2>&1)
echo "### C2"$'\n'"$o" >> "$LOG"
echo "$o" | tail -1 | grep -qx ok && s=2 || s=0
comp C2 "HDFS read/write works" "mkdir; put; cat /big_data/_check.txt" "Prints ok" $s ""

for c in "C3:NiFi accepts login" "C4:MySQL accepts user connections" "C5:Database dbtest exists" \
         "C6:Table table_stock exists" "C7:phpMyAdmin login works" "C8:NiFi login works"; do
    comp "${c%%:*}" "${c#*:}" "-" "-" NA "not in FADTESE scope"
done

if [ -n "$RC" ] && [ "$RC" != "0" ]; then
    echo; echo "NOTE: FADTESE exited with code $RC. Items whose component was never reached"
    echo "should be recorded as NR (see part1.csv for the stage where it stopped)."
fi
echo; echo "Saved: $OUT/items.csv, $OUT/part2.csv, $OUT/verify.log"
