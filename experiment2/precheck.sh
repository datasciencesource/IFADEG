#!/bin/bash
# =====================================================================
# precheck.sh - run BEFORE each FADTESE run (Experiment 3, Instrument 3)
# Checks that the VM is clean and ready. It does not change anything.
#
# Usage (as root, in /root):  ./precheck.sh
# Default script checked: /root/install_big_data_utilities.sh
# Exit code 0 = READY, 1 = NOT READY (fix the FAIL items first)
# =====================================================================

SCRIPT="${1:-/root/install_big_data_utilities.sh}"
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
# SHA-256 of the published FADTESE script (as attached in chat).
# If the GitHub copy gives a different value, run: sha256sum install_big_data_utilities.sh
# on the downloaded official copy and paste that value here.
EXPECTED_SHA="faa5f5ed325a9a6c2f028c015d072490b1b79dc6d97426aa5fbec60011a72216"

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }

echo "=============================================="
echo " FADTESE pre-check  $(date '+%F %T')"
echo "=============================================="

echo "1. User and system"
[ "$(id -u)" -eq 0 ] && ok "Running as root" || bad "Not root - run: sudo su -"

OS=$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
echo "$OS" | grep -q "Ubuntu 24.04" && ok "Guest OS: $OS" || bad "Guest OS is '$OS' (FADTESE needs Ubuntu 24.04)"

ARCH=$(uname -m)
[ "$ARCH" = "x86_64" ] && ok "Architecture: x86_64 (matches FADTESE's amd64 JAVA_HOME)" \
                       || bad "Architecture: $ARCH - FADTESE hard-codes java-11-openjdk-amd64"

echo "   vCPU: $(nproc) | RAM: $(awk '/MemTotal/{printf "%.1f GB", $2/1048576}' /proc/meminfo) | Disk: $(df -BG --output=size / | tail -1 | tr -d ' ')"
FREE=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
[ "$FREE" -ge 10 ] && ok "Free disk: ${FREE} GB" || bad "Free disk: ${FREE} GB (need at least 10 GB)"

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
if pgrep -x apt-get >/dev/null || pgrep -x apt >/dev/null || pgrep -x unattended-upgr >/dev/null || pgrep -f unattended-upgrade >/dev/null; then
    bad "apt / unattended-upgrades is running - wait until it finishes (it would lock apt)"
else
    ok "apt is free (no lock holder)"
fi

echo "3. FADTESE script and verification script"
if [ -f "$SCRIPT" ]; then
    SHA=$(sha256sum "$SCRIPT" | cut -d' ' -f1)
    [ "$SHA" = "$EXPECTED_SHA" ] && ok "FADTESE script unchanged (SHA-256 matches)" \
                                 || bad "SHA-256 mismatch: $SHA (copy differs from the published script)"
    bash -n "$SCRIPT" 2>/dev/null && ok "FADTESE syntax valid" || bad "FADTESE syntax error"
    file "$SCRIPT" 2>/dev/null | grep -q CRLF && bad "Script has Windows (CRLF) line endings"
else
    bad "FADTESE script not found: $SCRIPT"
fi
for f in verify_fadtese.sh; do
    [ -f "$KIT_DIR/$f" ] && ok "Kit file present: $f" || bad "Kit file missing: $KIT_DIR/$f"
done

echo "4. Tools needed by FADTESE and the recorder"
for t in bash apt-get wget tar ping bc python3 sha256sum; do
    command -v "$t" >/dev/null 2>&1 && ok "$t available" || bad "$t missing (install it in the clean snapshot)"
done
command -v speedtest-cli >/dev/null 2>&1 && ok "speedtest-cli available" \
    || warn "speedtest-cli missing - bandwidth will be recorded as NA"

echo "5. Network and download links"
ping -c 1 -W 2 downloads.apache.org >/dev/null 2>&1 \
    && ok "ping downloads.apache.org works (FADTESE ADRI check will pass)" \
    || bad "ping downloads.apache.org fails - FADTESE ADRI check will FAIL (ICMP may be blocked)"
for u in https://downloads.apache.org/hadoop/common/hadoop-2.10.2/hadoop-2.10.2.tar.gz \
         https://archive.apache.org/dist/sqoop/1.4.7/sqoop-1.4.7.bin__hadoop-2.6.0.tar.gz \
         https://dlcdn.apache.org/commons/lang/binaries/commons-lang-2.6-bin.tar.gz \
         https://cdn.mysql.com/archives/mysql-connector-java-5.1/mysql-connector-java-5.1.34.tar.gz; do
    wget -q --spider --timeout=15 --tries=2 "$u" && ok "Link OK: ${u##*/}" || bad "Link DEAD/unreachable: $u"
done
apt-cache policy openjdk-11-jdk 2>/dev/null | grep -q Candidate && ok "openjdk-11-jdk available in apt sources" \
    || warn "openjdk-11-jdk not found in apt cache (FADTESE runs apt-get update first, usually fine)"

echo "6. Part 0 values for the form (copy these into Instrument 3)"
echo "   Date                     : $(date +%F)"
echo "   Guest OS / kernel / arch : $OS / $(uname -r) / $ARCH"
echo "   VM spec                  : $(nproc) vCPU, $(awk '/MemTotal/{printf "%.1f GB", $2/1048576}' /proc/meminfo), $(df -BG --output=size / | tail -1 | tr -d ' ') disk"
[ -f "$SCRIPT" ] && echo "   FADTESE SHA-256 (first 12): $(sha256sum "$SCRIPT" | cut -c1-12)"
if command -v speedtest-cli >/dev/null 2>&1; then
    BW=$(speedtest-cli --simple 2>/dev/null | awk '/^Download/{print $2}')
    echo "   Network bandwidth (Mbit/s): ${BW:-NA}"
else
    echo "   Network bandwidth (Mbit/s): NA (speedtest-cli not installed)"
fi
PING_OUT=$(ping -c 20 8.8.8.8 2>/dev/null)
LAT=$(echo "$PING_OUT" | awk -F'/' '/rtt|round-trip/{print $5}')
LOSS=$(echo "$PING_OUT" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+')
echo "   Latency (ms) / loss (%)  : ${LAT:-NA} / ${LOSS:-NA}"
echo "   Free disk before run (GB): $FREE"

echo "=============================================="
echo " Result: $PASS passed, $WARN warnings, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
    echo " READY - now run:  date +%T; time ./install_big_data_utilities.sh 2>&1 | tee <RUN_ID>.log; date +%T"
    exit 0
else
    echo " NOT READY - fix the FAIL items (usually: restore the clean snapshot)."
    exit 1
fi
