#!/bin/bash
# 1hadoop.sh - IFADEG Stage S1: Java, SSH and Hadoop
# Usage:  ./1hadoop.sh
#
# PART 0 (runs first): Network bandwidth, latency, packet loss, free disk
# PART 1 (then S1):    Start, End, Duration (s), Download time (s), Data downloaded (MB),
#                      Attempts, Recovery time (s), Outcome (2/1/0),
#                      Peak CPU (%), Mean CPU (%), Peak RAM (GB), Error / log
# Outcome: 2 = success on 1st attempt, 1 = success after retry, 0 = failed
# Success = D1 + D6 both pass (not only exit code 0):
#   D1  hadoop version prints "Hadoop 2.10.2" and /usr/local/hadoop exists
#   D6  jps lists NameNode, DataNode, SecondaryNameNode, ResourceManager, NodeManager
# Item score: 2 = passed on attempt 1, 1 = passed on a later attempt, 0 = not passed at the end
# Recovery time: 0 if no failure; failure -> success if recovered; time spent retrying if failed (I_REC = 0).
# Output:  ~/ifadeg_logs/S1_<date_time>.log, one row in part0.csv, one row in part1.csv, D1 + D6 rows in items.csv

RUN_TS="$(date +%Y%m%d_%H%M%S)"   # log name; Run ID is recorded manually
STAGE="S1"
MAX_ATTEMPTS=3
LOG_DIR="$HOME/ifadeg_logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${STAGE}_${RUN_TS}.log"
CSV="$LOG_DIR/part1.csv"
ITEMS_CSV="$LOG_DIR/items.csv"
SAMPLES="$LOG_DIR/.${STAGE}_${RUN_TS}.samples"
: > "$SAMPLES"
: > "$LOG"

# Ask for the sudo password now, so waiting for it is not counted in Duration
sudo -v

# Terminal for live progress bars. Bars go to the terminal only, NOT to the log,
# so the log and the CSV parsing stay clean. Empty if there is no terminal (e.g. nohup).
if { : > /dev/tty; } 2>/dev/null; then TTY=/dev/tty; else TTY=""; fi

# Run start time (Part 0): the beginning of the whole run
RUN_START_HMS=$(date '+%H:%M:%S')

# Send all output to screen + log, with a timestamp on every line
exec > >(while IFS= read -r l; do printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$l"; done | tee -a "$LOG") 2>&1

# ############################################################
# PART 0: Run header - bandwidth, latency, packet loss, free disk
# (measured first, NOT counted in S1 time or data)
# ############################################################
# speedtest-cli should be pre-installed in the base VM snapshot; install only if missing
command -v speedtest-cli >/dev/null 2>&1 || sudo apt-get install -y speedtest-cli >/dev/null 2>&1
BW=$(speedtest-cli --simple 2>/dev/null | awk '/^Download:/{print $2}')
PING_OUT=$(ping -c 20 8.8.8.8)
LAT=$(echo "$PING_OUT" | awk -F'/' '/rtt/{print $5}')
LOSS=$(echo "$PING_OUT" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+')
DISK=$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')
P0_CSV="$LOG_DIR/part0.csv"
[ -f "$P0_CSV" ] || echo "date,run_start,bandwidth_mbps,latency_ms,packet_loss_pct,free_disk_gb" > "$P0_CSV"
echo "$(date +%Y-%m-%d),$RUN_START_HMS,${BW:-NA},${LAT:-NA},${LOSS:-NA},$DISK" >> "$P0_CSV"
echo "----- Part 0 -----"
echo "Run start time                         : $RUN_START_HMS"
echo "Network bandwidth (Mbit/s)             : ${BW:-NA}"
echo "Network latency (ms) / packet loss (%) : ${LAT:-NA} / ${LOSS:-NA}"
echo "Free disk before run (GB)              : $DISK"
echo "------------------"
# ################ END PART 0 ################

# ############################################################
# PART 1: Deployment evaluation - S1 Java, SSH and Hadoop
# ############################################################

# ---------- CPU / RAM sampler (every 1 s, whole VM) ----------
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

# Bytes received on all network interfaces except lo
rx_bytes() {
    awk 'NR>2 { line=$0; sub(/^[ \t]+/, "", line); split(line, a, ":")
                if (a[1] != "lo") { split(a[2], b, " "); s += b[1] } }
         END { printf "%.0f", s+0 }' /proc/net/dev
}

# ---------- Progress display (screen only; does not change any measurement) ----------
S1_TOTAL=9

# Overall stage progress (% of steps completed), e.g.
#   [IFADEG] S1 [######..............]  33%  step 4/9: Download Hadoop
# (goes to screen + log; contains "IFADEG" so first_log_error ignores it)
s1_step() {
    local n=$1; shift
    local done=$(( n-1 )) w=20 f stepinfo
    f=$(( done*w/S1_TOTAL ))
    if [ "$n" -le "$S1_TOTAL" ]; then stepinfo="step $n/$S1_TOTAL: $*"; else stepinfo="$*"; fi
    printf '[IFADEG] S1 [%s%s] %3d%%  %s\n' \
        "$(printf '%*s' "$f" '' | tr ' ' '#')" "$(printf '%*s' $((w-f)) '' | tr ' ' '.')" \
        $(( done*100/S1_TOTAL )) "$stepinfo"
}

# One bar line: label, current bytes, total bytes (0 = unknown), elapsed seconds
draw_bar() {
    local label=$1 cur=$2 total=$3 el=$4 w=30 pct f mb tmb spd
    mb=$(awk -v b="$cur" 'BEGIN{printf "%.1f", b/1000000}')
    spd=$(awk -v b="$cur" -v t="$el" 'BEGIN{printf "%.1f", (t>0) ? b/1000000/t : 0}')
    if [ "$total" -gt 0 ]; then
        pct=$(( cur*100/total )); [ "$pct" -gt 100 ] && pct=100
        f=$(( pct*w/100 ))
        tmb=$(awk -v b="$total" 'BEGIN{printf "%.1f", b/1000000}')
        printf '\r\033[K  %-16s [%s%s] %3d%%  %s/%s MB  %s MB/s  %ds' "$label" \
            "$(printf '%*s' "$f" '' | tr ' ' '#')" "$(printf '%*s' $((w-f)) '' | tr ' ' '-')" \
            "$pct" "$mb" "$tmb" "$spd" "$el"
    else
        printf '\r\033[K  %-16s %s MB  %s MB/s  %ds' "$label" "$mb" "$spd" "$el"
    fi
}

# Background watcher: redraws the bar from the size of $2 until killed
# (also stops by itself if the owning shell $4 is gone, e.g. after Ctrl+C)
progress_watch() {
    local label=$1 path=$2 total=$3 owner=$4 t0 cur
    t0=$(date +%s); sleep 0.3          # let the log pipe print the step line first
    while kill -0 "$owner" 2>/dev/null; do
        cur=$(du -sb "$path" 2>/dev/null | cut -f1)
        draw_bar "$label" "${cur:-0}" "$total" $(( $(date +%s) - t0 ))
        sleep 0.5
    done
}

# with_progress LABEL PATH TOTAL_BYTES -- command ...
# Runs the command in the FOREGROUND exactly as before; only the watcher is in the background.
with_progress() {
    local label=$1 path=$2 total=${3:-0} wp="" rc t0 cur
    shift 3; [ "$1" = "--" ] && shift
    t0=$(date +%s)
    if [ -n "$TTY" ]; then
        progress_watch "$label" "$path" "$total" "$BASHPID" > "$TTY" 2>/dev/null &
        wp=$!
    fi
    "$@"; rc=$?
    if [ -n "$wp" ]; then
        { kill "$wp"; wait "$wp"; } 2>/dev/null
        cur=$(du -sb "$path" 2>/dev/null | cut -f1); cur=${cur:-0}
        [ "$rc" -eq 0 ] && [ "$total" -gt 0 ] && cur=$total
        { draw_bar "$label" "$cur" "$total" $(( $(date +%s) - t0 ))
          [ "$rc" -eq 0 ] && printf '  done\n' || printf '  FAILED (exit %d)\n' "$rc"; } > "$TTY"
    fi
    return $rc
}

# Size of a remote file in bytes (0 if unknown) - one HEAD request, a few KB
url_size() {
    wget --spider -S "$1" 2>&1 | awk 'tolower($1)=="content-length:"{n=$2} END{print n+0}'
}

# S1 verification: D1 + D6 (from Instrument 1)
# Sets D1_OK, D6_OK (1/0), D1_EV, D6_EV (evidence), ITEMS (summary) and FAIL_MSG (empty if all pass)
verify_s1() {
    FAIL_MSG=""
    # D1: hadoop version prints Hadoop 2.10.2; /usr/local/hadoop exists
    HV=$(hadoop version 2>/dev/null | grep -m1 '^Hadoop ')
    if [ "$HV" = "Hadoop 2.10.2" ] && [ -d /usr/local/hadoop ]; then
        D1_OK=1; D1_EV="$HV; /usr/local/hadoop exists"
    else
        D1_OK=0; D1_EV="${HV:-hadoop version not found}"
        FAIL_MSG="D1 Hadoop 2.10.2 not installed"
    fi
    # D6: all 5 Hadoop daemons in jps (wait up to 30 s)
    for k in 1 2 3 4 5 6; do
        MISSING=""
        for p in NameNode DataNode SecondaryNameNode ResourceManager NodeManager; do
            jps 2>/dev/null | grep -qw "$p" || MISSING="$MISSING $p"
        done
        MISSING="${MISSING# }"
        [ -z "$MISSING" ] && break
        echo "[IFADEG] D6 check $k/6: waiting for $MISSING"
        sleep 5
    done
    if [ -z "$MISSING" ]; then
        D6_OK=1; D6_EV="5/5 daemons"
    else
        D6_OK=0; D6_EV="missing $MISSING"
        FAIL_MSG="${FAIL_MSG:+$FAIL_MSG; }D6 missing $MISSING"
    fi
    ITEMS="D1 $( [ $D1_OK -eq 1 ] && echo PASS || echo FAIL ) ($D1_EV) · D6 $( [ $D6_OK -eq 1 ] && echo PASS || echo FAIL ) ($D6_EV)"
    [ "$D1_OK" -eq 1 ] && [ "$D6_OK" -eq 1 ]
}

# ================= ORIGINAL S1 INSTALLATION =================
# Changes: wget is timed; tar runs without -v (shorter log); step markers and
# progress bars added; wget runs without sudo into a temp folder (see step 4).
install_s1() {
s1_step 1 "Install Java 11, OpenSSH, wget (apt)"
sudo apt-get update -y
sudo apt install openjdk-11-jdk openssh-server wget -y

s1_step 2 "Set JAVA_HOME and environment"
JAVA_HOME_PATH=$(ls -d /usr/lib/jvm/java-11-openjdk-* 2>/dev/null | head -n 1)

echo "JAVA_HOME=\"$JAVA_HOME_PATH\"" | sudo tee /etc/environment

export JAVA_HOME=$JAVA_HOME_PATH
export HADOOP_INSTALL=/usr/local/hadoop
export HADOOP_HOME=/usr/local/hadoop
export PATH=$PATH:$HADOOP_INSTALL/bin:$HADOOP_INSTALL/sbin
export HADOOP_MAPRED_HOME=$HADOOP_INSTALL
export HADOOP_COMMON_HOME=$HADOOP_INSTALL
export HADOOP_HDFS_HOME=$HADOOP_INSTALL
export YARN_HOME=$HADOOP_INSTALL
export HADOOP_COMMON_LIB_NATIVE_DIR=$HADOOP_INSTALL/lib/native
export HADOOP_OPTS="-Djava.library.path=$HADOOP_INSTALL/lib"
export HADOOP_PREFIX=$HADOOP_INSTALL
export HADOOP_CONF_DIR=$HADOOP_PREFIX/etc/hadoop
export SSH_OPTS="-o StrictHostKeyChecking=no"

s1_step 3 "SSH keys for localhost"
if [ ! -f "$HOME/.ssh/id_rsa" ]; then
  yes "" | ssh-keygen -t rsa -P ""
fi

cat "$HOME/.ssh/id_rsa.pub" >> "$HOME/.ssh/authorized_keys"
ssh-keyscan -H localhost >> "$HOME/.ssh/known_hosts"
ssh-keyscan -H 0.0.0.0 >> "$HOME/.ssh/known_hosts"

sudo systemctl restart ssh

cd /opt || exit

s1_step 4 "Download Hadoop 2.10.2"
# wget runs WITHOUT sudo. With "sudo wget" on Ubuntu 24.04, sudo puts wget in its own
# pseudo-terminal; wget then thinks it is a background job and sends everything to
# /opt/wget-log ("Redirecting output to 'wget-log'"), so the screen looked frozen.
HADOOP_URL=https://archive.apache.org/dist/hadoop/common/hadoop-2.10.2/hadoop-2.10.2.tar.gz
DL_DIR=$(mktemp -d /tmp/ifadeg_dl.XXXXXX)
TGZ="$DL_DIR/hadoop-2.10.2.tar.gz"
TGZ_SIZE=$(url_size "$HADOOP_URL")
WGET_T0=$(date +%s.%N)
with_progress "Downloading" "$TGZ" "$TGZ_SIZE" -- wget -nv -O "$TGZ" "$HADOOP_URL"
echo "[IFADEG] wget_seconds=$(awk -v a="$WGET_T0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')"

s1_step 5 "Extract Hadoop to /usr/local/hadoop"
TAR_SIZE=$(gzip -l "$TGZ" 2>/dev/null | awk 'NR==2{print $2+0}')
sudo rm -rf /opt/hadoop-2.10.2
with_progress "Extracting" /opt/hadoop-2.10.2 "${TAR_SIZE:-0}" -- sudo tar -zxf "$TGZ" -C /opt
rm -rf "$DL_DIR"

sudo rm -rf /usr/local/hadoop
sudo mkdir -p /usr/local/hadoop
sudo mv hadoop-2.10.2/* /usr/local/hadoop/
sudo rm -rf hadoop-2.10.2

s1_step 6 "Environment files and command wrappers"
sed -i '/# HADOOP_ENV_START/,/# HADOOP_ENV_END/d' ~/.bashrc

cat <<EOF >> ~/.bashrc

# HADOOP_ENV_START
export JAVA_HOME=$JAVA_HOME_PATH
export HADOOP_INSTALL=/usr/local/hadoop
export HADOOP_HOME=/usr/local/hadoop
export PATH=\$PATH:\$HADOOP_INSTALL/bin:\$HADOOP_INSTALL/sbin
export HADOOP_MAPRED_HOME=\$HADOOP_INSTALL
export HADOOP_COMMON_HOME=\$HADOOP_INSTALL
export HADOOP_HDFS_HOME=\$HADOOP_INSTALL
export YARN_HOME=\$HADOOP_INSTALL
export HADOOP_COMMON_LIB_NATIVE_DIR=\$HADOOP_INSTALL/lib/native
export HADOOP_OPTS="-Djava.library.path=\$HADOOP_INSTALL/lib"
export HADOOP_PREFIX=\$HADOOP_INSTALL
export HADOOP_CONF_DIR=\$HADOOP_PREFIX/etc/hadoop
# HADOOP_ENV_END
EOF

sudo tee /etc/profile.d/hadoop.sh > /dev/null <<EOF
export JAVA_HOME=$JAVA_HOME_PATH
export HADOOP_INSTALL=/usr/local/hadoop
export HADOOP_HOME=/usr/local/hadoop
export PATH=\$PATH:\$HADOOP_INSTALL/bin:\$HADOOP_INSTALL/sbin
export HADOOP_MAPRED_HOME=\$HADOOP_INSTALL
export HADOOP_COMMON_HOME=\$HADOOP_INSTALL
export HADOOP_HDFS_HOME=\$HADOOP_INSTALL
export YARN_HOME=\$HADOOP_INSTALL
export HADOOP_COMMON_LIB_NATIVE_DIR=\$HADOOP_INSTALL/lib/native
export HADOOP_OPTS="-Djava.library.path=\$HADOOP_INSTALL/lib"
export HADOOP_PREFIX=\$HADOOP_INSTALL
export HADOOP_CONF_DIR=\$HADOOP_PREFIX/etc/hadoop
EOF

sudo chmod +x /etc/profile.d/hadoop.sh

sudo rm -f /usr/local/bin/hadoop
sudo rm -f /usr/local/bin/hdfs
sudo rm -f /usr/local/bin/yarn
sudo rm -f /usr/local/bin/start-all.sh
sudo rm -f /usr/local/bin/stop-all.sh
sudo rm -f /usr/local/bin/start-dfs.sh
sudo rm -f /usr/local/bin/stop-dfs.sh
sudo rm -f /usr/local/bin/start-yarn.sh
sudo rm -f /usr/local/bin/stop-yarn.sh

sudo tee /usr/local/bin/hadoop > /dev/null <<EOF
#!/bin/bash
export JAVA_HOME=$JAVA_HOME_PATH
export HADOOP_INSTALL=/usr/local/hadoop
export HADOOP_HOME=/usr/local/hadoop
export HADOOP_PREFIX=/usr/local/hadoop
export HADOOP_CONF_DIR=/usr/local/hadoop/etc/hadoop
export HADOOP_MAPRED_HOME=/usr/local/hadoop
export HADOOP_COMMON_HOME=/usr/local/hadoop
export HADOOP_HDFS_HOME=/usr/local/hadoop
export YARN_HOME=/usr/local/hadoop
export PATH=/usr/local/hadoop/bin:/usr/local/hadoop/sbin:\$PATH
exec /usr/local/hadoop/bin/hadoop "\$@"
EOF

sudo tee /usr/local/bin/hdfs > /dev/null <<EOF
#!/bin/bash
export JAVA_HOME=$JAVA_HOME_PATH
export HADOOP_INSTALL=/usr/local/hadoop
export HADOOP_HOME=/usr/local/hadoop
export HADOOP_PREFIX=/usr/local/hadoop
export HADOOP_CONF_DIR=/usr/local/hadoop/etc/hadoop
export HADOOP_MAPRED_HOME=/usr/local/hadoop
export HADOOP_COMMON_HOME=/usr/local/hadoop
export HADOOP_HDFS_HOME=/usr/local/hadoop
export YARN_HOME=/usr/local/hadoop
export PATH=/usr/local/hadoop/bin:/usr/local/hadoop/sbin:\$PATH
exec /usr/local/hadoop/bin/hdfs "\$@"
EOF

sudo tee /usr/local/bin/yarn > /dev/null <<EOF
#!/bin/bash
export JAVA_HOME=$JAVA_HOME_PATH
export HADOOP_INSTALL=/usr/local/hadoop
export HADOOP_HOME=/usr/local/hadoop
export HADOOP_PREFIX=/usr/local/hadoop
export HADOOP_CONF_DIR=/usr/local/hadoop/etc/hadoop
export HADOOP_MAPRED_HOME=/usr/local/hadoop
export HADOOP_COMMON_HOME=/usr/local/hadoop
export HADOOP_HDFS_HOME=/usr/local/hadoop
export YARN_HOME=/usr/local/hadoop
export PATH=/usr/local/hadoop/bin:/usr/local/hadoop/sbin:\$PATH
exec /usr/local/hadoop/bin/yarn "\$@"
EOF

sudo tee /usr/local/bin/start-all.sh > /dev/null <<EOF
#!/bin/bash
export JAVA_HOME=$JAVA_HOME_PATH
export HADOOP_INSTALL=/usr/local/hadoop
export HADOOP_HOME=/usr/local/hadoop
export HADOOP_PREFIX=/usr/local/hadoop
export HADOOP_CONF_DIR=/usr/local/hadoop/etc/hadoop
export HADOOP_MAPRED_HOME=/usr/local/hadoop
export HADOOP_COMMON_HOME=/usr/local/hadoop
export HADOOP_HDFS_HOME=/usr/local/hadoop
export YARN_HOME=/usr/local/hadoop
export PATH=/usr/local/hadoop/bin:/usr/local/hadoop/sbin:\$PATH
exec /usr/local/hadoop/sbin/start-all.sh "\$@"
EOF

sudo tee /usr/local/bin/stop-all.sh > /dev/null <<EOF
#!/bin/bash
export JAVA_HOME=$JAVA_HOME_PATH
export HADOOP_INSTALL=/usr/local/hadoop
export HADOOP_HOME=/usr/local/hadoop
export HADOOP_PREFIX=/usr/local/hadoop
export HADOOP_CONF_DIR=/usr/local/hadoop/etc/hadoop
export HADOOP_MAPRED_HOME=/usr/local/hadoop
export HADOOP_COMMON_HOME=/usr/local/hadoop
export HADOOP_HDFS_HOME=/usr/local/hadoop
export YARN_HOME=/usr/local/hadoop
export PATH=/usr/local/hadoop/bin:/usr/local/hadoop/sbin:\$PATH
exec /usr/local/hadoop/sbin/stop-all.sh "\$@"
EOF

sudo tee /usr/local/bin/start-dfs.sh > /dev/null <<EOF
#!/bin/bash
export JAVA_HOME=$JAVA_HOME_PATH
export HADOOP_INSTALL=/usr/local/hadoop
export HADOOP_HOME=/usr/local/hadoop
export HADOOP_PREFIX=/usr/local/hadoop
export HADOOP_CONF_DIR=/usr/local/hadoop/etc/hadoop
export HADOOP_MAPRED_HOME=/usr/local/hadoop
export HADOOP_COMMON_HOME=/usr/local/hadoop
export HADOOP_HDFS_HOME=/usr/local/hadoop
export YARN_HOME=/usr/local/hadoop
export PATH=/usr/local/hadoop/bin:/usr/local/hadoop/sbin:\$PATH
exec /usr/local/hadoop/sbin/start-dfs.sh "\$@"
EOF

sudo tee /usr/local/bin/stop-dfs.sh > /dev/null <<EOF
#!/bin/bash
export JAVA_HOME=$JAVA_HOME_PATH
export HADOOP_INSTALL=/usr/local/hadoop
export HADOOP_HOME=/usr/local/hadoop
export HADOOP_PREFIX=/usr/local/hadoop
export HADOOP_CONF_DIR=/usr/local/hadoop/etc/hadoop
export HADOOP_MAPRED_HOME=/usr/local/hadoop
export HADOOP_COMMON_HOME=/usr/local/hadoop
export HADOOP_HDFS_HOME=/usr/local/hadoop
export YARN_HOME=/usr/local/hadoop
export PATH=/usr/local/hadoop/bin:/usr/local/hadoop/sbin:\$PATH
exec /usr/local/hadoop/sbin/stop-dfs.sh "\$@"
EOF

sudo tee /usr/local/bin/start-yarn.sh > /dev/null <<EOF
#!/bin/bash
export JAVA_HOME=$JAVA_HOME_PATH
export HADOOP_INSTALL=/usr/local/hadoop
export HADOOP_HOME=/usr/local/hadoop
export HADOOP_PREFIX=/usr/local/hadoop
export HADOOP_CONF_DIR=/usr/local/hadoop/etc/hadoop
export HADOOP_MAPRED_HOME=/usr/local/hadoop
export HADOOP_COMMON_HOME=/usr/local/hadoop
export HADOOP_HDFS_HOME=/usr/local/hadoop
export YARN_HOME=/usr/local/hadoop
export PATH=/usr/local/hadoop/bin:/usr/local/hadoop/sbin:\$PATH
exec /usr/local/hadoop/sbin/start-yarn.sh "\$@"
EOF

sudo tee /usr/local/bin/stop-yarn.sh > /dev/null <<EOF
#!/bin/bash
export JAVA_HOME=$JAVA_HOME_PATH
export HADOOP_INSTALL=/usr/local/hadoop
export HADOOP_HOME=/usr/local/hadoop
export HADOOP_PREFIX=/usr/local/hadoop
export HADOOP_CONF_DIR=/usr/local/hadoop/etc/hadoop
export HADOOP_MAPRED_HOME=/usr/local/hadoop
export HADOOP_COMMON_HOME=/usr/local/hadoop
export HADOOP_HDFS_HOME=/usr/local/hadoop
export YARN_HOME=/usr/local/hadoop
export PATH=/usr/local/hadoop/bin:/usr/local/hadoop/sbin:\$PATH
exec /usr/local/hadoop/sbin/stop-yarn.sh "\$@"
EOF

sudo chmod +x /usr/local/bin/hadoop
sudo chmod +x /usr/local/bin/hdfs
sudo chmod +x /usr/local/bin/yarn
sudo chmod +x /usr/local/bin/start-all.sh
sudo chmod +x /usr/local/bin/stop-all.sh
sudo chmod +x /usr/local/bin/start-dfs.sh
sudo chmod +x /usr/local/bin/stop-dfs.sh
sudo chmod +x /usr/local/bin/start-yarn.sh
sudo chmod +x /usr/local/bin/stop-yarn.sh

s1_step 7 "Hadoop configuration (HDFS, core, MapReduce, YARN)"
sudo mkdir -p /usr/local/hadoop_store/hdfs/namenode
sudo mkdir -p /usr/local/hadoop_store/hdfs/datanode
sudo mkdir -p /app/hadoop/tmp

sudo tee /usr/local/hadoop/etc/hadoop/hadoop-env.sh > /dev/null <<EOF
export JAVA_HOME=$JAVA_HOME_PATH
EOF

sudo tee /usr/local/hadoop/etc/hadoop/hdfs-site.xml > /dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
<property>
<name>dfs.replication</name>
<value>1</value>
</property>
<property>
<name>dfs.permissions</name>
<value>false</value>
</property>
<property>
<name>dfs.namenode.name.dir</name>
<value>file:/usr/local/hadoop_store/hdfs/namenode</value>
</property>
<property>
<name>dfs.datanode.data.dir</name>
<value>file:/usr/local/hadoop_store/hdfs/datanode</value>
</property>
</configuration>
EOF

sudo tee /usr/local/hadoop/etc/hadoop/core-site.xml > /dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
<property>
<name>hadoop.tmp.dir</name>
<value>/app/hadoop/tmp</value>
</property>
<property>
<name>fs.defaultFS</name>
<value>hdfs://localhost:54310</value>
</property>
</configuration>
EOF

sudo cp /usr/local/hadoop/etc/hadoop/mapred-site.xml.template /usr/local/hadoop/etc/hadoop/mapred-site.xml

sudo tee /usr/local/hadoop/etc/hadoop/mapred-site.xml > /dev/null <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
<property>
<name>mapreduce.framework.name</name>
<value>yarn</value>
</property>
</configuration>
EOF

sudo tee /usr/local/hadoop/etc/hadoop/yarn-site.xml > /dev/null <<EOF
<?xml version="1.0"?>
<configuration>
<property>
<name>yarn.nodemanager.aux-services</name>
<value>mapreduce_shuffle</value>
</property>
<property>
<name>yarn.nodemanager.auxservices.mapreduce.shuffle.class</name>
<value>org.apache.hadoop.mapred.ShuffleHandler</value>
</property>
</configuration>
EOF

s1_step 8 "Format NameNode"
hadoop namenode -format -force

s1_step 9 "Start Hadoop daemons"
start-all.sh

jps
hadoop version
s1_step 10 "Installation finished - verifying D1 + D6"
}
# ================= END ORIGINAL S1 INSTALLATION =================

# ---------- run S1 with measurement (S1 clock starts here) ----------
START_EPOCH=$(date +%s); START_HMS=$(date '+%H:%M:%S')
RX0=$(rx_bytes)
sampler & SAMPLER_PID=$!
trap 'kill $SAMPLER_PID 2>/dev/null' EXIT

ATTEMPTS=0; PASSED=0; FIRST_FAIL_EPOCH=""; FIRST_FAIL_MSG=""; LAST_FAIL_MSG=""; D1_FIRST=""; D6_FIRST=""
while [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
    ATTEMPTS=$((ATTEMPTS+1))
    echo "===== IFADEG $STAGE attempt $ATTEMPTS ====="
    if [ "$ATTEMPTS" -gt 1 ]; then
        # Clean up before retry: stop Hadoop, clear DataNode data
        # (a re-format gives a new clusterID; old DataNode data would block DataNode)
        [ -x /usr/local/bin/stop-all.sh ] && stop-all.sh >/dev/null 2>&1
        sudo rm -rf /usr/local/hadoop_store/hdfs/datanode/*
        echo "[IFADEG] retry cleanup done (Hadoop stopped, DataNode data cleared)"
    fi
    ( install_s1 )                      # subshell: "cd" and "exit" stay inside
    verify_s1; VRC=$?
    [ "$D1_OK" -eq 1 ] && [ -z "$D1_FIRST" ] && D1_FIRST=$ATTEMPTS
    [ "$D6_OK" -eq 1 ] && [ -z "$D6_FIRST" ] && D6_FIRST=$ATTEMPTS
    if [ "$VRC" -eq 0 ]; then
        PASSED=1; echo "[IFADEG] verify PASS: $ITEMS"
        break
    fi
    echo "[IFADEG] verify FAIL: $FAIL_MSG ($ITEMS)"
    LAST_FAIL_MSG="$FAIL_MSG"
    if [ -z "$FIRST_FAIL_EPOCH" ]; then FIRST_FAIL_EPOCH=$(date +%s); FIRST_FAIL_MSG="$FAIL_MSG"; fi
done

kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null
END_EPOCH=$(date +%s); END_HMS=$(date '+%H:%M:%S')
RX1=$(rx_bytes)
DURATION=$((END_EPOCH - START_EPOCH))

# Outcome and recovery time
if   [ "$PASSED" -eq 1 ] && [ "$ATTEMPTS" -eq 1 ]; then OUTCOME=2; RECOVERY=0
elif [ "$PASSED" -eq 1 ]; then OUTCOME=1; RECOVERY=$((END_EPOCH - FIRST_FAIL_EPOCH))
else OUTCOME=0; RECOVERY=$((END_EPOCH - FIRST_FAIL_EPOCH))   # time spent on retries; I_REC = 0 in Part 4
fi

# Data downloaded (MB, 1 MB = 1,000,000 bytes, same base as speedtest Mbit/s)
DATA_MB=$(awk -v a="$RX0" -v b="$RX1" 'BEGIN{printf "%.1f",(b-a)/1000000}')

# Download time (s): apt "Fetched ... in Xs" + measured wget time
sleep 1   # let the log catch up
DL_TIME=$( { grep -oE 'Fetched .* in [0-9]+(h|min|s)( [0-9]+(min|s))?' "$LOG" | sed -E 's/.* in //; s/min/m/g'
             grep -oE '\[IFADEG\] wget_seconds=[0-9.]+' "$LOG" | sed -E 's/.*=//; s/$/s/'; } |
    awk '{s=$0; while (match(s,/[0-9.]+[hms]/)) { tok=substr(s,RSTART,RLENGTH); n=substr(tok,1,length(tok)-1)+0; u=substr(tok,length(tok));
          t += (u=="h")?n*3600:(u=="m")?n*60:n; s=substr(s,RSTART+RLENGTH) } } END{printf "%.1f", t+0}')

# CPU / RAM
read -r PEAK_CPU MEAN_CPU PEAK_RAM < <(awk '{c+=$1; n++; if($1>pc)pc=$1; if($2>pr)pr=$2}
    END{ if(n) printf "%.1f %.1f %.2f\n",pc,c/n,pr; else print "NA NA NA" }' "$SAMPLES")
rm -f "$SAMPLES"

# Error / log: always filled
#   2 -> "No error - <log>"
#   1 -> "Recovered: <first failure> (attempt 1) - <log>"
#   0 -> "Failed: <last failure> | first log error: <line> - <log>"
LOGNAME_ONLY="$(basename "$LOG")"
first_log_error() {
    grep -iE 'error|failed|fatal|exception|cannot|unable|refused' "$LOG" \
        | grep -viE 'libgpg-error|IFADEG|NativeCodeLoader|debconf|WARN' \
        | grep -vE '\] hadoop-2\.10\.2/' \
        | head -1 | sed -E 's/^\[[^]]*\] //' | cut -c1-100 | tr -d '",'
}
if [ "$OUTCOME" -eq 2 ]; then
    ERR_LOG="No error - $LOGNAME_ONLY"
elif [ "$OUTCOME" -eq 1 ]; then
    ERR_LOG="Recovered: $FIRST_FAIL_MSG (attempt 1) - $LOGNAME_ONLY"
else
    FE="$(first_log_error)"
    ERR_LOG="Failed: $LAST_FAIL_MSG${FE:+ | first log error: $FE} - $LOGNAME_ONLY"
fi

# Save one row to part1.csv
[ -f "$CSV" ] || echo "date,stage,start,end,duration_s,download_time_s,data_downloaded_mb,attempts,recovery_time_s,outcome,peak_cpu_pct,mean_cpu_pct,peak_ram_gb,error_log" > "$CSV"
echo "$(date +%Y-%m-%d),$STAGE,$START_HMS,$END_HMS,$DURATION,$DL_TIME,$DATA_MB,$ATTEMPTS,$RECOVERY,$OUTCOME,$PEAK_CPU,$MEAN_CPU,$PEAK_RAM,\"$ERR_LOG\"" >> "$CSV"

# Item scores (2 = passed on attempt 1, 1 = passed later, 0 = not passed at the end)
item_score() {  # $1 = passes now (1/0), $2 = first attempt it passed
    if [ "$1" -eq 1 ]; then [ "$2" = "1" ] && echo 2 || echo 1; else echo 0; fi
}
D1_SCORE=$(item_score "$D1_OK" "$D1_FIRST")
D6_SCORE=$(item_score "$D6_OK" "$D6_FIRST")
[ -f "$ITEMS_CSV" ] || echo "date,stage,stage_start,item,result,score,evidence" > "$ITEMS_CSV"
echo "$(date +%Y-%m-%d),$STAGE,$START_HMS,D1,$( [ $D1_OK -eq 1 ] && echo PASS || echo FAIL ),$D1_SCORE,\"$(echo "$D1_EV" | tr -d '",')\"" >> "$ITEMS_CSV"
echo "$(date +%Y-%m-%d),$STAGE,$START_HMS,D6,$( [ $D6_OK -eq 1 ] && echo PASS || echo FAIL ),$D6_SCORE,\"$(echo "$D6_EV" | tr -d '",')\"" >> "$ITEMS_CSV"

echo ""
echo "----- Part 1: $STAGE (1hadoop.sh) -----"
echo "Start / End          : $START_HMS / $END_HMS"
echo "Duration (s)         : $DURATION"
echo "Download time (s)    : $DL_TIME"
echo "Data downloaded (MB) : $DATA_MB"
echo "Attempts             : $ATTEMPTS"
echo "Recovery time (s)    : $RECOVERY"
echo "Outcome (2/1/0)      : $OUTCOME"
echo "Peak / Mean CPU (%)  : $PEAK_CPU / $MEAN_CPU"
echo "Peak RAM (GB)        : $PEAK_RAM"
echo "Error / log          : $ERR_LOG"
echo "Deployment items     : $ITEMS"
echo "Item scores          : D1 = $D1_SCORE · D6 = $D6_SCORE"
echo "-----------------------------------------------"
echo "Saved: $CSV and $ITEMS_CSV"
