#!/bin/bash
# =====================================================================
# 1run_fadtese.sh - Experiment 3 (Instrument 3): precheck + FADTESE run, in one script
#   Part A  precheck : VM spec, FADTESE unchanged (SHA-256), tools, network, apt mirror,
#                      Part 0 values (bandwidth, latency, loss, free disk)
#   Part B  run      : runs FADTESE UNCHANGED and measures it from outside, like ADS
#                      (Part 1: start/end, duration, download time, data, CPU/RAM, outcome,
#                       Hadoop part / Rest split, exit code / SHA-256)
# FADTESE starts only if Part A has no FAIL. Warnings (clean-VM reminders, low bandwidth,
# missing mysql client) do not stop the run.
#
# Usage (as root, after restoring the clean snapshot):
#   ./1run_fadtese.sh E3-R01           precheck, then FADTESE (about 10 min)
#   ./1run_fadtese.sh E3-R01 --check   precheck only (test the VM, installs nothing)
#   ./1run_fadtese.sh E3-R01 --no-check  skip the PASS/FAIL checks: only measure Part 0
#                                        (date, bandwidth, latency, free disk), then run FADTESE
# The Run ID only names the log files; the evaluator records it on the form.
#
# Output (in /root/ifadeg_logs):
#   <RUN_ID>_fadtese.log  full FADTESE output, one timestamp per line
#   part0.csv             date,run_start,bandwidth_mbps,latency_ms,packet_loss_pct,free_disk_gb,run_end
#   part1.csv             same columns as ADS, stage = FADTESE
#   e3_split.csv          date,run_id,run_start,hadoop_end,hadoop_part_s,rest_part_s,exit_code,sha256
#
# Experiment 3 kit, rev 4 (2026-11-26). Run order (as root, both kit files in one folder):
#   1run_fadtese.sh E3-Rxx [--no-check] -> 2verify_fadtese.sh (verification + Sqoop workflow)
#   FADTESE (install_big_data_utilities.sh) is downloaded into / ; results go to /root/ifadeg_logs.
# =====================================================================

[ "$(id -u)" -ne 0 ] && { echo "Please run as root: sudo -i"; exit 1; }

CHECK_ONLY=""; NO_CHECK=""; LABEL_GIVEN=""; RUN_ID=""
for a in "$@"; do
    case "$a" in --check) CHECK_ONLY=1 ;; --no-check) NO_CHECK=1 ;; *) RUN_ID="$a"; LABEL_GIVEN=1 ;; esac
done
[ -z "$RUN_ID" ] && read -r -p "Run ID for this run (e.g. E3-R01, Enter = automatic label): " RUN_ID
[ -n "$RUN_ID" ] && LABEL_GIVEN=1
RUN_ID="${RUN_ID:-E3_$(date +%Y%m%d_%H%M%S)}"

SCRIPT="${FADTESE_SCRIPT:-/install_big_data_utilities.sh}"
FADTESE_URL="${FADTESE_URL:-https://raw.githubusercontent.com/datasciencesource/bash-script/main/install_big_data_utilities.sh}"
# SHA-256 of the published FADTESE script: github.com/datasciencesource/bash-script,
# main branch, last commit b86a889 (188 lines, 6.51 KB). Check on the VM: sha256sum /install_big_data_utilities.sh
EXPECTED_SHA="b7719e30ed191593fa3ec85e7275def0df790e2ada81709951c2496f35122a55"

# Expected VM spec (same VM as Experiment 4: 4 vCPU, 4 GB RAM, disk about 68 GB)
EXP_VCPU=4
EXP_RAM_MIN=3.5; EXP_RAM_MAX=4.2      # GB seen by the guest for a 4 GB VM
EXP_DISK_MIN=55; EXP_DISK_MAX=70      # GB size of / (this VM shows 68 GB)
MIN_BW="${MIN_BW:-5}"                 # Mbit/s: below this a WARNING is shown (the run still continues)

STAGE="FADTESE"
LOG_DIR="/root/ifadeg_logs"
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Kit file by plain or numbered name (verify_fadtese.sh or 2verify_fadtese.sh)
kit_file() { for c in "$KIT_DIR/$1" "$KIT_DIR"/[0-9]"$1"; do [ -f "$c" ] && { echo "$c"; return 0; }; done; return 1; }
kit_cmd()  { local c; c=$(kit_file "$1") && echo "./$(basename "$c")" || echo "./$1"; }

# Download the published FADTESE script into / if it is not there yet (not timed)
get_fadtese() {
    [ -f "$SCRIPT" ] && return 0
    echo "[IFADEG] downloading FADTESE script to $SCRIPT"
    wget -q -O "$SCRIPT" "$FADTESE_URL" || { rm -f "$SCRIPT"; echo "[IFADEG] download failed: $FADTESE_URL"; return 1; }
    head -1 "$SCRIPT" | grep -q '^#!' || { rm -f "$SCRIPT"; echo "[IFADEG] downloaded file is not a script (check the URL)"; return 1; }
    chmod +x "$SCRIPT"
}

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }

# ############################################################
# PART A: precheck
# ############################################################
echo "=============================================="
echo " FADTESE pre-check  $RUN_ID  $(date '+%F %T')"
echo "=============================================="
if [ -n "$NO_CHECK" ]; then
    echo " (--no-check: checks 1-5 skipped; only Part 0 values are measured)"
    get_fadtese || exit 1
    OS=$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
    ARCH=$(uname -m); VCPU=$(nproc)
    RAM_GB=$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)
    DISK_GB=$(df -BG --output=size / | tail -1 | tr -dc '0-9')
    FREE=$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')
else
echo "1. User, system and VM spec"
[ "$(id -u)" -eq 0 ] && ok "Running as root" || bad "Not root - run: sudo -i"

OS=$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
echo "$OS" | grep -q "Ubuntu 24.04" && ok "Guest OS: $OS" || bad "Guest OS is '$OS' (FADTESE needs Ubuntu 24.04)"

ARCH=$(uname -m)
[ "$ARCH" = "x86_64" ] && ok "Architecture: x86_64 (matches FADTESE's amd64 JAVA_HOME)" \
                       || bad "Architecture: $ARCH - FADTESE hard-codes java-11-openjdk-amd64"

VCPU=$(nproc)
RAM_GB=$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)
DISK_GB=$(df -BG --output=size / | tail -1 | tr -dc '0-9')
[ "$VCPU" -eq "$EXP_VCPU" ] && ok "vCPU: $VCPU" || bad "vCPU: $VCPU (expected $EXP_VCPU, same as Experiment 4)"
awk -v r="$RAM_GB" -v a="$EXP_RAM_MIN" -v b="$EXP_RAM_MAX" 'BEGIN{exit !(r>=a && r<=b)}' \
    && ok "RAM: ${RAM_GB} GB" || bad "RAM: ${RAM_GB} GB (expected about 4 GB, same as Experiment 4)"
[ "$DISK_GB" -ge "$EXP_DISK_MIN" ] && [ "$DISK_GB" -le "$EXP_DISK_MAX" ] \
    && ok "Disk: ${DISK_GB} GB" || bad "Disk: ${DISK_GB} GB (expected ${EXP_DISK_MIN}-${EXP_DISK_MAX} GB, same as Experiment 4)"

FREE=$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')     # same command as ADS (1hadoop.sh)
[ "$FREE" -ge 5 ] && ok "Free disk: ${FREE} GB" || bad "Free disk: ${FREE} GB (need at least 5 GB)"

echo "2. Clean VM (reset by the evaluator - warnings only)"
for p in /usr/local/hadoop /usr/local/sqoop /usr/local/hadoop_store /app/hadoop/tmp; do
    [ -e "$p" ] && warn "$p exists - VM not reset? FADTESE will likely fail" || ok "$p not present"
done
[ -f /root/.ssh/id_rsa ] && warn "/root/.ssh/id_rsa exists - VM not reset? (ssh-keygen would stop FADTESE)" \
                         || ok "No existing root SSH key"
grep -q "HADOOP_INSTALL" /root/.bashrc 2>/dev/null && warn "/root/.bashrc has Hadoop lines - VM not reset?" \
                                                   || ok "/root/.bashrc clean"
grep -q "JAVA_HOME" /etc/environment && warn "/etc/environment has JAVA_HOME - VM not reset?" \
                                     || ok "/etc/environment clean"
pgrep -f "org.apache.hadoop" >/dev/null && warn "Hadoop processes running - VM not reset?" || ok "No Hadoop processes running"
if [ -f "$LOG_DIR/part1.csv" ] && grep -q ',FADTESE,' "$LOG_DIR/part1.csv"; then
    warn "$LOG_DIR/part1.csv already has a FADTESE row - copy old results to the host before this run"
else
    ok "No results from an earlier run in $LOG_DIR"
fi

echo "3. FADTESE script and evaluation kit"
get_fadtese
if [ -f "$SCRIPT" ]; then
    SHA=$(sha256sum "$SCRIPT" | cut -d' ' -f1)
    [ "$SHA" = "$EXPECTED_SHA" ] && ok "FADTESE script unchanged (SHA-256 matches)" \
                                 || bad "SHA-256 mismatch: $SHA (copy differs from the published script)"
    bash -n "$SCRIPT" 2>/dev/null && ok "FADTESE syntax valid" || bad "FADTESE syntax error"
    if file "$SCRIPT" 2>/dev/null | grep -q CRLF; then bad "Script has Windows (CRLF) line endings"; else ok "Unix line endings"; fi
    [ -x "$SCRIPT" ] && ok "FADTESE script is executable" || bad "Not executable - run: chmod +x $SCRIPT"
else
    bad "FADTESE script not found: $SCRIPT"
fi
for f in verify_fadtese.sh; do
    if p=$(kit_file "$f"); then
        [ -x "$p" ] && ok "Kit file present: $(basename "$p")" || bad "Kit file not executable: chmod +x $p"
    else
        bad "Kit file missing: $f (or numbered name) in $KIT_DIR"
    fi
done

echo "4. Tools needed by FADTESE and the evaluation kit"
for t in bash apt-get wget tar ping bc python3 sha256sum awk; do   # bc: used by the FADTESE ADRI score
    command -v "$t" >/dev/null 2>&1 && ok "$t available" || bad "$t missing (install it in the clean snapshot)"
done
command -v mysql >/dev/null 2>&1 && ok "mysql client available (used only by sqoop_check.sh for the source checksum)" \
    || warn "mysql client missing - sqoop_check.sh will install it after FADTESE (evaluation only)"
command -v speedtest-cli >/dev/null 2>&1 && ok "speedtest-cli available" \
    || warn "speedtest-cli missing - bandwidth will be recorded as NA"

echo "5. Network and download links"
ping -c 1 -W 2 downloads.apache.org >/dev/null 2>&1 \
    && ok "ping downloads.apache.org works (FADTESE ADRI check will pass)" \
    || bad "ping downloads.apache.org fails - FADTESE ADRI check will FAIL (ICMP may be blocked)"
# apt mirror reachable (read-only test, the way apt would connect; IPv4 only if apt is set to ForceIPv4)
MIRRORS=$(grep -hoE '^(deb|URIs:)[^#]*https?://[^ /]+' /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null \
          | grep -oE 'https?://[^ /]+' | sort -u)
APT_V4=""; apt-config dump 2>/dev/null | grep -qi 'ForceIPv4 "true"' && APT_V4="-4"
for m in $MIRRORS; do
    if wget -q $APT_V4 --spider --timeout=10 --tries=1 "$m/ubuntu/" || wget -q $APT_V4 --spider --timeout=10 --tries=1 "$m/"; then
        ok "apt mirror reachable: ${m#*://}"
    else
        bad "apt mirror NOT reachable: ${m#*://} (FADTESE apt-get would fail; try: echo 'Acquire::ForceIPv4 \"true\";' > /etc/apt/apt.conf.d/99force-ipv4)"
    fi
done
[ -z "$MIRRORS" ] && warn "no apt mirror found in /etc/apt/sources.list*"
# Check the download links that FADTESE itself uses (read from the script, so they always match)
URLS=$(grep -oE 'https?://[^ "'"'"']+\.(tar\.gz|tgz|zip|jar)' "$SCRIPT" 2>/dev/null | sort -u)
if [ -z "$URLS" ]; then
    warn "No download links found in $SCRIPT"
fi
for u in $URLS; do
    wget -q --spider --timeout=15 --tries=2 "$u" && ok "Link OK: ${u##*/}" || bad "Link DEAD/unreachable: $u"
done
apt-cache policy openjdk-11-jdk 2>/dev/null | grep -q Candidate && ok "openjdk-11-jdk available in apt sources" \
    || warn "openjdk-11-jdk not found in apt cache (FADTESE runs apt-get update first, usually fine)"

fi   # end of checks 1-5

echo "6. Part 0 values (same commands as ADS 1hadoop.sh)"
DATE=$(date +%F)
if command -v speedtest-cli >/dev/null 2>&1; then
    BW=$(speedtest-cli --simple 2>/dev/null | awk '/^Download:/{print $2}')
fi
PING_OUT=$(ping -c 20 8.8.8.8 2>/dev/null)
LAT=$(echo "$PING_OUT" | awk -F'/' '/rtt/{print $5}')
LOSS=$(echo "$PING_OUT" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+')
echo "   Run ID                   : $RUN_ID"
echo "   Date                     : $DATE"
echo "   Guest OS / kernel / arch : $OS / $(uname -r) / $ARCH"
echo "   VM spec                  : $VCPU vCPU, $RAM_GB GB RAM, $DISK_GB GB disk"
[ -f "$SCRIPT" ] && echo "   FADTESE SHA-256 (first 12): $(sha256sum "$SCRIPT" | cut -c1-12)"
echo "   Network bandwidth (Mbit/s): ${BW:-NA}"
echo "   Latency (ms) / loss (%)  : ${LAT:-NA} / ${LOSS:-NA}"
echo "   Free disk before run (GB): $FREE"
if [ -z "$BW" ]; then
    warn "bandwidth not measured (speedtest-cli failed or missing)"
elif awk -v b="$BW" -v m="$MIN_BW" 'BEGIN{exit !(b>=m)}'; then
    ok "Bandwidth ${BW} Mbit/s (minimum ${MIN_BW})"
else
    warn "Low bandwidth: ${BW} Mbit/s (below ${MIN_BW}) - the run continues; note it on the form (slower downloads expected)"
fi
[ -z "$LABEL_GIVEN" ] && echo "   (no Run ID given: files use $RUN_ID - write the Run ID on the form)"

echo "=============================================="
echo " Result: $PASS passed, $WARN warnings, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
    echo " NOT READY - fix the FAIL items above, then run again. FADTESE was NOT started."
    exit 1
fi
if [ -n "$CHECK_ONLY" ]; then
    echo " READY (check only) - start the real run with: ./$(basename "$0") $RUN_ID"
    exit 0
fi
echo " READY - starting FADTESE now"
echo ""
mkdir -p "$LOG_DIR"
P0_DATE="$DATE"; P0_BW="${BW:-NA}"; P0_LAT="${LAT:-NA}"; P0_LOSS="${LOSS:-NA}"; P0_FREE="$FREE"

# ############################################################
# PART B: run FADTESE unchanged and measure it
# ############################################################
LOG="$LOG_DIR/${RUN_ID}_fadtese.log"
P0_CSV="$LOG_DIR/part0.csv"
CSV="$LOG_DIR/part1.csv"
SPLIT_CSV="$LOG_DIR/e3_split.csv"
SAMPLES="$LOG_DIR/.${RUN_ID}.samples"
SHA=$(sha256sum "$SCRIPT" | cut -d' ' -f1)
[ "$SHA" = "$EXPECTED_SHA" ] || { echo "SHA-256 mismatch ($SHA) - stopping."; exit 1; }

# ---------- CPU / RAM sampler (every 1 s, whole VM) - same code as ADS ----------
sampler() {
    read -r _ u n s i w q sq st _ < /proc/stat
    pt=$((u+n+s+i+w+q+sq+st)); pi=$((i+w))
    while :; do
        sleep 1
        read -r _ u n s i w q sq st _ < /proc/stat
        t=$((u+n+s+i+w+q+sq+st)); id=$((i+w))
        dt=$((t-pt)); di=$((id-pi)); pt=$t; pi=$id
        ram=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%.3f",(t-a)/1048576}' /proc/meminfo)
        [ "$dt" -gt 0 ] && awk -v dt="$dt" -v di="$di" -v r="$ram" 'BEGIN{printf "%.1f %s\n",(dt-di)*100/dt,r}' >> "$SAMPLES"
    done
}

# Bytes received on all network interfaces except lo - same code as ADS
rx_bytes() {
    awk 'NR>2 { line=$0; sub(/^[ \t]+/, "", line); split(line, a, ":")
                if (a[1] != "lo") { split(a[2], b, " "); s += b[1] } }
         END { printf "%.0f", s+0 }' /proc/net/dev
}

# ---------- run FADTESE with measurement (clock starts here) ----------
: > "$SAMPLES"; : > "$LOG"
START_EPOCH=$(date +%s); START_HMS=$(date '+%H:%M:%S')
RX0=$(rx_bytes)
sampler & SAMPLER_PID=$!
trap 'kill $SAMPLER_PID 2>/dev/null' EXIT
trap 'echo; echo "[IFADEG] interrupted - this run is NOT valid: copy the log if needed, restore the clean snapshot and redo it"; exit 130' INT

echo "===== IFADEG $RUN_ID: FADTESE started $START_HMS ====="
cd /root || exit 1
# Unchanged script; every output line gets "[YYYY-mm-dd HH:MM:SS]" (screen + log)
"$SCRIPT" 2>&1 | while IFS= read -r l; do printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$l"; done | tee -a "$LOG"
RC=${PIPESTATUS[0]}

kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null
END_EPOCH=$(date +%s); END_HMS=$(date '+%H:%M:%S')
RX1=$(rx_bytes)
DURATION=$((END_EPOCH - START_EPOCH))

# ---------- Outcome (no retry in FADTESE: 2 or 0) ----------
ATTEMPTS=1; RECOVERY=0
[ "$RC" -eq 0 ] && OUTCOME=2 || OUTCOME=0

# ---------- Data downloaded (MB, 1 MB = 1,000,000 bytes, same base as ADS) ----------
DATA_MB=$(awk -v a="$RX0" -v b="$RX1" 'BEGIN{printf "%.1f",(b-a)/1000000}')

# ---------- Download time (s): apt "Fetched ... in X" + wget "100% ...=X" lines ----------
# (wget prints dot progress when its output is piped; its last line ends with "=<time>")
DL_LINES=$( {
    sed -E 's/^\[[^]]*\] //' "$LOG" | grep -oE 'Fetched .* in [0-9]+(h|min|s)( [0-9]+(min|s))?' | sed -E 's/.* in //; s/min/m/g'
    sed -E 's/^\[[^]]*\] //' "$LOG" | grep -E '100%.*=[0-9.]+[hms]' | sed -E 's/.*=([0-9hms.]+)[[:space:]]*$/\1/'
} )
DL_TIME=$(echo "$DL_LINES" | awk 'NF{ s=$0; while (match(s,/[0-9.]+[hms]/)) { tok=substr(s,RSTART,RLENGTH);
          n=substr(tok,1,length(tok)-1)+0; u=substr(tok,length(tok)); t += (u=="h")?n*3600:(u=="m")?n*60:n;
          s=substr(s,RSTART+RLENGTH) }; found=1 } END{ if(found) printf "%.1f", t+0; else print "NA" }')

# ---------- Hadoop part (shared scope with IFADEG S1) ----------
# End of the Hadoop part = first output line after Hadoop's start-all.sh started the NodeManager
# (the last daemon). Everything after that is FADTESE's extra scope (Sqoop, connectors, Python).
NM_LINE=$(grep -niE 'starting nodemanager' "$LOG" | tail -1 | cut -d: -f1)
if [ -n "$NM_LINE" ]; then
    NEXT=$(sed -n "$((NM_LINE+1))p" "$LOG")
    [ -z "$NEXT" ] && NEXT=$(sed -n "${NM_LINE}p" "$LOG")
    H_TS=$(echo "$NEXT" | sed -E 's/^\[([^]]*)\].*/\1/')
    H_EPOCH=$(date -d "$H_TS" +%s 2>/dev/null)
fi
if [ -n "$H_EPOCH" ]; then
    HADOOP_END=$(date -d "@$H_EPOCH" '+%H:%M:%S')
    HADOOP_S=$((H_EPOCH - START_EPOCH)); REST_S=$((END_EPOCH - H_EPOCH))
else
    HADOOP_END=NA; HADOOP_S=NA; REST_S=NA
fi

# ---------- CPU / RAM ----------
read -r PEAK_CPU MEAN_CPU PEAK_RAM < <(awk '{c+=$1; n++; if($1>pc)pc=$1; if($2>pr)pr=$2}
    END{ if(n) printf "%.1f %.1f %.2f\n",pc,c/n,pr; else print "NA NA NA" }' "$SAMPLES")
rm -f "$SAMPLES"

# ---------- Error / log (always filled, no commas or quotes) ----------
LOGNAME_ONLY="$(basename "$LOG")"
first_log_error() {
    sed -E 's/^\[[^]]*\] //' "$LOG" \
        | grep -iE 'error|failed|fatal|exception|cannot|unable|refused|denied' \
        | grep -viE 'libgpg-error|debconf|WARN|NativeCodeLoader' \
        | head -1 | cut -c1-100 | tr -d '",'
}
if [ "$OUTCOME" -eq 2 ]; then
    ERR_LOG="No error - $LOGNAME_ONLY"
else
    FE="$(first_log_error)"
    ERR_LOG="Failed: FADTESE stopped (exit $RC)${FE:+ | first log error: $FE} - $LOGNAME_ONLY"
fi

# ---------- Save CSV rows ----------
[ -f "$P0_CSV" ] || echo "date,run_start,bandwidth_mbps,latency_ms,packet_loss_pct,free_disk_gb,run_end" > "$P0_CSV"
echo "$P0_DATE,$START_HMS,$P0_BW,$P0_LAT,$P0_LOSS,$P0_FREE,$END_HMS" >> "$P0_CSV"

[ -f "$CSV" ] || echo "date,stage,start,end,duration_s,download_time_s,data_downloaded_mb,attempts,recovery_time_s,outcome,peak_cpu_pct,mean_cpu_pct,peak_ram_gb,error_log" > "$CSV"
echo "$(date +%Y-%m-%d),$STAGE,$START_HMS,$END_HMS,$DURATION,$DL_TIME,$DATA_MB,$ATTEMPTS,$RECOVERY,$OUTCOME,$PEAK_CPU,$MEAN_CPU,$PEAK_RAM,\"$ERR_LOG\"" >> "$CSV"

[ -f "$SPLIT_CSV" ] || echo "date,run_id,run_start,hadoop_end,hadoop_part_s,rest_part_s,exit_code,sha256" > "$SPLIT_CSV"
echo "$(date +%Y-%m-%d),$RUN_ID,$START_HMS,$HADOOP_END,$HADOOP_S,$REST_S,$RC,${SHA:0:12}" >> "$SPLIT_CSV"

{
echo ""
echo "----- Part 0: $RUN_ID -----"
echo "Date                                   : $P0_DATE"
echo "Run start / end                        : $START_HMS / $END_HMS"
echo "Network bandwidth (Mbit/s)             : $P0_BW"
echo "Network latency (ms) / packet loss (%) : $P0_LAT / $P0_LOSS"
echo "Free disk before run (GB)              : $P0_FREE"
echo "----- Part 1: $STAGE (install_big_data_utilities.sh) -----"
echo "Start / End          : $START_HMS / $END_HMS"
echo "Duration (s)         : $DURATION"
echo "  Hadoop part (s)    : $HADOOP_S   (start -> Hadoop daemons started at $HADOOP_END; compare with IFADEG S1)"
echo "  Rest (s)           : $REST_S   (Sqoop, connectors, Python, version printout)"
echo "Download time (s)    : $DL_TIME"
echo "Data downloaded (MB) : $DATA_MB"
echo "Attempts             : $ATTEMPTS (FADTESE has no retry)"
echo "Recovery time (s)    : $RECOVERY"
echo "Outcome (2/0)        : $OUTCOME (final value is set by verify_fadtese.sh)"
echo "Peak / Mean CPU (%)  : $PEAK_CPU / $MEAN_CPU"
echo "Peak RAM (GB)        : $PEAK_RAM"
echo "Error / log          : $ERR_LOG"
echo "Exit code / SHA-256  : $RC / ${SHA:0:12}   (0 = script finished)"
echo "-----------------------------------------------"
echo "Saved: $P0_CSV, $CSV and $SPLIT_CSV"
if [ "$RC" -eq 0 ]; then
    echo "Next:  $(kit_cmd verify_fadtese.sh)   (verification + Sqoop workflow)"
else
    echo "FADTESE stopped (exit $RC). Next: $(kit_cmd verify_fadtese.sh) (records NR; the Sqoop workflow is skipped automatically)."
    echo "Check the cause in $LOG; if it is the VM or network (not FADTESE), restore the snapshot and redo this run."
fi
} | tee -a "$LOG"
exit "$RC"
