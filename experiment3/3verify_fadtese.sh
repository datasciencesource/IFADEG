#!/bin/bash
# =====================================================================
# verify_fadtese.sh - post-deployment verification for FADTESE (Experiment 3)
# Same items, commands and success criteria as Instrument 1 / ADS, limited to
# what FADTESE installs. Items outside FADTESE's scope are NA (not counted as 0).
#
# Usage (as root, right after run_fadtese.sh, no argument):  ./3verify_fadtese.sh
#
# Part 1 deployment items : D1 Hadoop installed, D3 Connector/J, D6 Hadoop services started
#                           (D2, D4, D5, D7-D10 = NA: NiFi, MySQL, phpMyAdmin are not in FADTESE)
# Part 2 component checks : C1 HDFS healthy, C2 HDFS read/write   (C3-C8 = NA)
# Scores: 2 = pass; 0 = fail; NR = not reached (FADTESE stopped before this part).
#         Part 2 only: 1 = passed when the check was repeated after a 30 s wait.
# Final FADTESE Outcome (part1.csv) = 2 only if the script exited 0 AND D1, D3, D6 pass.
#
# Output (in /root/ifadeg_logs): items.csv, part2.csv (+ Outcome update in part1.csv)
#        /root/ifadeg_runs/<RUN_ID>_verify.txt  (summary for the form)
#
# Experiment 3 kit, rev 2 (2026-11-26). Run order (as root, all 4 kit files in one folder):
#   1precheck.sh E3-Rxx (must say READY) -> 2run_fadtese.sh -> 3verify_fadtese.sh -> 4sqoop_check.sh
#   (plain names precheck.sh, run_fadtese.sh, ... also work). Give the Run ID only to precheck.
#   FADTESE (install_big_data_utilities.sh) is downloaded into / ; results go to /root/ifadeg_logs.
# =====================================================================

RUN_ID="${1:-$(awk -F',' 'NR>1{r=$2} END{print r}' /root/ifadeg_logs/e3_split.csv 2>/dev/null)}"   # latest run; Run ID is recorded manually
[ -z "$RUN_ID" ] && { echo "No run found in /root/ifadeg_logs/e3_split.csv - run run_fadtese.sh first"; exit 1; }
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
grep -q ",$RUN_ID," "$SPLIT_CSV" 2>/dev/null || echo "[IFADEG] WARNING: Run ID $RUN_ID not found in e3_split.csv - give the Run ID only to precheck and run this script with no argument"

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
echo "Next:  $(kit_cmd sqoop_check.sh)"
} | tee "$OUT"
