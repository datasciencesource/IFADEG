#!/bin/bash
# 1hadoop.sh - IFADEG Stage S1: Java, SSH and Hadoop
# Usage:  ./1hadoop.sh
#
# PART 0 (runs first): Network bandwidth, latency, packet loss, free disk
# PART 1 (then S1):    Start, End, Duration (s), Download time (s), Data downloaded (MB),
#                      Attempts, Recovery time (s), Outcome (2/1/0),
#                      Peak CPU (%), Mean CPU (%), Peak RAM (GB), Error / log
# Outcome: 2 = success on 1st attempt, 1 = success after retry, 0 = failed
# Success = all 5 Hadoop daemons running (jps), not only exit code 0.
# Output:  ~/ifadeg_logs/S1_<date_time>.log, one row in part0.csv and one row in part1.csv

RUN_TS="$(date +%Y%m%d_%H%M%S)"   # log name; Run ID is recorded manually
STAGE="S1"
MAX_ATTEMPTS=3
LOG_DIR="$HOME/ifadeg_logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${STAGE}_${RUN_TS}.log"
CSV="$LOG_DIR/part1.csv"
SAMPLES="$LOG_DIR/.${STAGE}_${RUN_TS}.samples"
: > "$SAMPLES"
: > "$LOG"

# Ask for the sudo password now, so waiting for it is not counted in Duration
sudo -v

# Run start time (Part 0): the beginning of the whole run
RUN_START_HMS=$(date '+%H:%M:%S')

# Send all output to screen + log, with a timestamp on every line
exec > >(while IFS= read -r l; do printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$l"; done | tee -a "$LOG") 2>&1

# ############################################################
# PART 0: Run header - bandwidth, latency, packet loss, free disk
# (measured first, NOT counted in S1 time or data)
# ############################################################
sudo apt-get install -y speedtest-cli iputils-ping >/dev/null 2>&1
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
rx_bytes() { awk -F'[: ]+' 'NR>2 && $2!="lo"{s+=$3} END{print s+0}' /proc/net/dev; }

# S1 verification: all 5 Hadoop daemons must be running (wait up to 30 s)
verify_s1() {
    for k in 1 2 3 4 5 6; do
        ok=1
        for p in NameNode DataNode SecondaryNameNode ResourceManager NodeManager; do
            jps 2>/dev/null | grep -qw "$p" || ok=0
        done
        [ "$ok" -eq 1 ] && return 0
        sleep 5
    done
    return 1
}

# ================= ORIGINAL S1 INSTALLATION (unchanged) =================
install_s1() {
sudo apt-get update -y
sudo apt install openjdk-11-jdk openssh-server wget -y

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

if [ ! -f "$HOME/.ssh/id_rsa" ]; then
  yes "" | ssh-keygen -t rsa -P ""
fi

cat "$HOME/.ssh/id_rsa.pub" >> "$HOME/.ssh/authorized_keys"
ssh-keyscan -H localhost >> "$HOME/.ssh/known_hosts"
ssh-keyscan -H 0.0.0.0 >> "$HOME/.ssh/known_hosts"

sudo systemctl restart ssh

cd /opt || exit

WGET_T0=$(date +%s.%N)
sudo wget -O hadoop-2.10.2.tar.gz https://archive.apache.org/dist/hadoop/common/hadoop-2.10.2/hadoop-2.10.2.tar.gz
echo "[IFADEG] wget_seconds=$(awk -v a="$WGET_T0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')"

sudo tar -zxvf hadoop-2.10.2.tar.gz
sudo rm -rf hadoop-2.10.2.tar.gz

sudo rm -rf /usr/local/hadoop
sudo mkdir -p /usr/local/hadoop
sudo mv hadoop-2.10.2/* /usr/local/hadoop/
sudo rm -rf hadoop-2.10.2

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

hadoop namenode -format -force

start-all.sh

jps
hadoop version
}
# ================= END ORIGINAL S1 INSTALLATION =================

# ---------- run S1 with measurement (S1 clock starts here) ----------
START_EPOCH=$(date +%s); START_HMS=$(date '+%H:%M:%S')
RX0=$(rx_bytes)
sampler & SAMPLER_PID=$!
trap 'kill $SAMPLER_PID 2>/dev/null' EXIT

ATTEMPTS=0; PASSED=0; FIRST_FAIL_EPOCH=""
while [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
    ATTEMPTS=$((ATTEMPTS+1))
    echo "===== IFADEG $STAGE attempt $ATTEMPTS ====="
    if [ "$ATTEMPTS" -gt 1 ] && [ -x /usr/local/bin/stop-all.sh ]; then
        stop-all.sh >/dev/null 2>&1     # clean up half-started daemons before retry
    fi
    ( install_s1 )                      # subshell: "cd" and "exit" stay inside
    if verify_s1; then
        PASSED=1; echo "[IFADEG] verify PASS (all 5 Hadoop daemons running)"
        break
    fi
    echo "[IFADEG] verify FAIL"
    [ -z "$FIRST_FAIL_EPOCH" ] && FIRST_FAIL_EPOCH=$(date +%s)
done

kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null
END_EPOCH=$(date +%s); END_HMS=$(date '+%H:%M:%S')
RX1=$(rx_bytes)
DURATION=$((END_EPOCH - START_EPOCH))

# Outcome and recovery time
if   [ "$PASSED" -eq 1 ] && [ "$ATTEMPTS" -eq 1 ]; then OUTCOME=2; RECOVERY=0
elif [ "$PASSED" -eq 1 ]; then OUTCOME=1; RECOVERY=$((END_EPOCH - FIRST_FAIL_EPOCH))
else OUTCOME=0; RECOVERY="NA"
fi

# Data downloaded (MB): network bytes received during S1
DATA_MB=$(awk -v a="$RX0" -v b="$RX1" 'BEGIN{printf "%.1f",(b-a)/1048576}')

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

# Error / log: log name, plus first error line if not a clean first-attempt success
ERR_LOG="$(basename "$LOG")"
if [ "$OUTCOME" -ne 2 ]; then
    FIRST_ERR=$(grep -iE 'error|failed|fatal|exception|cannot|unable|refused' "$LOG" \
        | grep -viE 'libgpg-error|IFADEG' | head -1 | sed -E 's/^\[[^]]*\] //' | cut -c1-120 | tr -d '",')
    [ -n "$FIRST_ERR" ] && ERR_LOG="$ERR_LOG: $FIRST_ERR"
fi

# Save one row to part1.csv
[ -f "$CSV" ] || echo "date,stage,start,end,duration_s,download_time_s,data_downloaded_mb,attempts,recovery_time_s,outcome,peak_cpu_pct,mean_cpu_pct,peak_ram_gb,error_log" > "$CSV"
echo "$(date +%Y-%m-%d),$STAGE,$START_HMS,$END_HMS,$DURATION,$DL_TIME,$DATA_MB,$ATTEMPTS,$RECOVERY,$OUTCOME,$PEAK_CPU,$MEAN_CPU,$PEAK_RAM,\"$ERR_LOG\"" >> "$CSV"

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
echo "-----------------------------------------------"
echo "Saved: $CSV"
