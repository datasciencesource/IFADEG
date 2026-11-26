#!/bin/bash
# =====================================================================
# precheck.sh - run BEFORE each FADTESE run (Experiment 3, Instrument 3)
# Checks that the VM is clean, is the same VM spec as Experiment 4, and
# that FADTESE is the unchanged published script. It only downloads FADTESE into /
# if it is missing; it installs nothing and does not wait for apt.
#
# Usage (as root):  ./1precheck.sh E3-R01
# (Run ID is recorded manually on the form; an optional label can be given: ./precheck.sh E3-R01)
# Exit code 0 = READY, 1 = NOT READY (fix the FAIL items first)
#
# Output: Part 0 values on screen + /root/ifadeg_logs/.part0_pending
#         (run_fadtese.sh turns this into one row of part0.csv, same columns as ADS)
#
# Experiment 3 kit, rev 2 (2026-11-26). Run order (as root, all 4 kit files in one folder):
#   1precheck.sh E3-Rxx (must say READY) -> 2run_fadtese.sh -> 3verify_fadtese.sh -> 4sqoop_check.sh
#   (plain names precheck.sh, run_fadtese.sh, ... also work). Give the Run ID only to precheck.
#   FADTESE (install_big_data_utilities.sh) is downloaded into / ; results go to /root/ifadeg_logs.
# =====================================================================

RUN_ID="${1:-E3_$(date +%Y%m%d_%H%M%S)}"   # label for file names; Run ID is recorded manually
SCRIPT="${FADTESE_SCRIPT:-/install_big_data_utilities.sh}"
FADTESE_URL="${FADTESE_URL:-https://raw.githubusercontent.com/datasciencesource/bash-script/main/install_big_data_utilities.sh}"
# Download the published FADTESE script into / if it is not there yet (not timed: done before the clock starts)
get_fadtese() {
    [ -f "$SCRIPT" ] && return 0
    echo "[IFADEG] downloading FADTESE script to $SCRIPT"
    wget -q -O "$SCRIPT" "$FADTESE_URL" || { rm -f "$SCRIPT"; echo "[IFADEG] download failed: $FADTESE_URL"; return 1; }
    head -1 "$SCRIPT" | grep -q '^#!' || { rm -f "$SCRIPT"; echo "[IFADEG] downloaded file is not a script (check the URL)"; return 1; }
    chmod +x "$SCRIPT"
}

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Kit file by plain or numbered name (run_fadtese.sh or 2run_fadtese.sh)
kit_file() { for c in "$KIT_DIR/$1" "$KIT_DIR"/[0-9]"$1"; do [ -f "$c" ] && { echo "$c"; return 0; }; done; return 1; }
kit_cmd()  { local c; c=$(kit_file "$1") && echo "./$(basename "$c")" || echo "./$1"; }
LOG_DIR="/root/ifadeg_logs"

# SHA-256 of the published FADTESE script.
# If the GitHub copy gives a different value, run: sha256sum install_big_data_utilities.sh
# on the official copy and paste that value here.
EXPECTED_SHA="faa5f5ed325a9a6c2f028c015d072490b1b79dc6d97426aa5fbec60011a72216"

# Expected VM spec (same VM as Experiment 4: 4 vCPU, 4 GB RAM, 64 GB disk)
EXP_VCPU=4
EXP_RAM_MIN=3.5; EXP_RAM_MAX=4.2      # GB seen by the guest for a 4 GB VM
EXP_DISK_MIN=55; EXP_DISK_MAX=70      # GB size of / (this VM shows 68 GB)

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }

echo "=============================================="
echo " FADTESE pre-check  $RUN_ID  $(date '+%F %T')"
echo "=============================================="

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
    && ok "Disk: ${DISK_GB} GB" || bad "Disk: ${DISK_GB} GB (expected a 64 GB disk, same as Experiment 4)"

FREE=$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')     # same command as ADS (1hadoop.sh)
[ "$FREE" -ge 5 ] && ok "Free disk: ${FREE} GB" || bad "Free disk: ${FREE} GB (need at least 5 GB)"

echo "2. Clean VM (FADTESE cannot be re-run on the same VM)"
for p in /usr/local/hadoop /usr/local/sqoop /usr/local/hadoop_store /app/hadoop/tmp; do
    [ -e "$p" ] && bad "$p already exists - restore the clean snapshot" || ok "$p not present"
done
[ -f /root/.ssh/id_rsa ] && bad "/root/.ssh/id_rsa exists - ssh-keygen would stop FADTESE (set -e)" \
                         || ok "No existing root SSH key"
grep -q "HADOOP_INSTALL" /root/.bashrc 2>/dev/null && bad "/root/.bashrc already has Hadoop lines - not a clean VM" \
                                                   || ok "/root/.bashrc clean"
grep -q "JAVA_HOME" /etc/environment && bad "/etc/environment already has JAVA_HOME - not a clean VM" \
                                     || ok "/etc/environment clean"
pgrep -f "org.apache.hadoop" >/dev/null && bad "Hadoop processes already running" || ok "No Hadoop processes running"
if [ -f "$LOG_DIR/part1.csv" ] && grep -q ',FADTESE,' "$LOG_DIR/part1.csv"; then
    bad "$LOG_DIR/part1.csv already has a FADTESE row - copy the old results to the host and restore the snapshot"
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
for f in run_fadtese.sh verify_fadtese.sh sqoop_check.sh; do
    if p=$(kit_file "$f"); then
        [ -x "$p" ] && ok "Kit file present: $(basename "$p")" || bad "Kit file not executable: chmod +x $p"
    else
        bad "Kit file missing: $f (or numbered name) in $KIT_DIR"
    fi
done

echo "4. Tools needed by FADTESE and the evaluation kit"
for t in bash apt-get wget tar ping python3 sha256sum awk; do
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

echo "=============================================="
echo " Result: $PASS passed, $WARN warnings, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
    mkdir -p "$LOG_DIR"
    # date,bandwidth,latency,loss,free_disk,run_id,measured_epoch  (read by run_fadtese.sh)
    echo "$DATE,${BW:-NA},${LAT:-NA},${LOSS:-NA},$FREE,$RUN_ID,$(date +%s)" > "$LOG_DIR/.part0_pending"
    echo " READY - start FADTESE now (Part 0 was just measured):"
    echo "   $(kit_cmd run_fadtese.sh)"
    echo " Then: $(kit_cmd verify_fadtese.sh)   and   $(kit_cmd sqoop_check.sh)"
    exit 0
else
    echo " NOT READY - fix the FAIL items (usually: restore the clean snapshot)."
    exit 1
fi
