#!/bin/bash
# =============================================================================
# ADS v2 controller for ADEGABDEF
# Runs the five deployment scripts in order, verifies each stage, retries a
# failed stage automatically, and logs timings, attempts, exit codes, network
# bytes and download times for Instruments 1, 2 and 4.
#
# Usage (as root, from the folder that holds the five scripts):
#   sudo bash run_ads.sh <RUN_ID>
#   e.g. sudo bash run_ads.sh E1-R01
#
# Optional settings (environment variables):
#   MAX_ATTEMPTS=3          attempts per stage (1 = no retry)
#   BACKOFF="30 60 120"     seconds to wait before retry 1, 2, 3 ...
#   IFACE=enp0s1            network interface (auto-detected if not set)
#   LOG_ROOT=./logs         where run logs are written
# =============================================================================

RUN_ID="${1:?Usage: sudo bash run_ads.sh <RUN_ID>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
read -r -a BACKOFF_S <<< "${BACKOFF:-30 60 120}"
LOG_ROOT="${LOG_ROOT:-$SCRIPT_DIR/logs}"
LOG_DIR="$LOG_ROOT/$RUN_ID"
WGET_LOG="/tmp/ads_wget_times.log"
WGET_SHIM="/usr/local/sbin/wget"

STAGES=(S1 S2 S3 S4 S5)
declare -A SCRIPT=( [S1]=1hadoop.sh [S2]=2nifi.sh [S3]=3connector.sh [S4]=4mysql.sh [S5]=5myadmin.sh )
declare -A NAME=( [S1]="Java SSH Hadoop" [S2]="NiFi" [S3]="Connector/J" [S4]="MySQL" [S5]="phpMyAdmin" )

# MySQL and phpMyAdmin test account (same as 4mysql.sh)
DB_USER="usertest"
DB_PASS="Admin1111"

if [ "$(id -u)" -ne 0 ]; then
  echo "ADS v2: run as root (sudo bash run_ads.sh $RUN_ID)" >&2
  exit 2
fi
mkdir -p "$LOG_DIR"
MAIN_LOG="$LOG_DIR/ads_main.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [ADS] $*" | tee -a "$MAIN_LOG"; }
now() { date +%s.%N; }
ts()  { date -d "@${1%.*}" '+%Y-%m-%d %H:%M:%S'; }
dur() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }

# ---------- network interface and byte counter -------------------------------
if [ -z "${IFACE:-}" ]; then
  IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [ -z "$IFACE" ] && IFACE="$(ls /sys/class/net | grep -v '^lo$' | head -n 1)"
fi
rx_bytes() { cat "/sys/class/net/$IFACE/statistics/rx_bytes" 2>/dev/null || echo 0; }

# ---------- background monitors ----------------------------------------------
vmstat -t 5 > "$LOG_DIR/vmstat.log" 2>&1 &
VMSTAT_PID=$!
( while sleep 5; do echo "$(date '+%Y-%m-%d %H:%M:%S') $(rx_bytes)"; done ) > "$LOG_DIR/net_rx.log" 2>&1 &
NET_PID=$!

# ---------- wget timing shim (measures download time per stage) --------------
# /usr/local/sbin comes before /usr/bin for root and for sudo's secure_path,
# so the deployment scripts call this shim, which calls the real wget.
cat > "$WGET_SHIM" <<'EOF'
#!/bin/bash
s=$(date +%s.%N)
/usr/bin/wget "$@"
rc=$?
e=$(date +%s.%N)
echo "$s $e $rc" >> /tmp/ads_wget_times.log
exit $rc
EOF
chmod 755 "$WGET_SHIM"

cleanup() {
  kill "$VMSTAT_PID" "$NET_PID" 2>/dev/null
  rm -f "$WGET_SHIM"
}
trap cleanup EXIT

# ---------- helpers -----------------------------------------------------------
wait_apt_lock() {
  local waited=0
  if command -v fuser >/dev/null 2>&1; then
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
      [ "$waited" -eq 0 ] && log "waiting for apt/dpkg lock held by another process"
      sleep 5; waited=$((waited + 5))
      [ "$waited" -ge 600 ] && { log "apt lock still held after 600 s, continuing"; break; }
    done
  fi
}

http_code() { curl -k -s -o /dev/null -m 10 -w '%{http_code}' "$1" 2>/dev/null; }

poll() {  # poll <seconds> <command...>: run command every 15 s until it succeeds
  local limit=$1; shift
  local t=0
  until "$@"; do
    [ "$t" -ge "$limit" ] && return 1
    sleep 15; t=$((t + 15))
  done
}

nifi_up() { local c; c=$(http_code https://localhost:8443/nifi/); [ "$c" = "200" ] || [ "$c" = "302" ]; }
pma_up()  { [ "$(http_code http://localhost/phpmyadmin/)" = "200" ]; }

# ---------- stage verification (same criteria as Instrument 1, D1-D10) --------
check_stage() {
  case "$1" in
    S1) /usr/local/bin/hadoop version 2>/dev/null | grep -q "Hadoop 2.10.2" \
          && jps 2>/dev/null | grep -qw NameNode \
          && jps 2>/dev/null | grep -qw DataNode ;;
    S2) [ -f /opt/nifi/bin/nifi.sh ] && poll 300 nifi_up ;;
    S3) [ -f /opt/nifi/mysql-connector-j-8.4.0/mysql-connector-j-8.4.0.jar ] ;;
    S4) systemctl is-active --quiet mysql \
          && mysql -u"$DB_USER" -p"$DB_PASS" -N -e "SHOW TABLES IN dbtest LIKE 'table_stock'" 2>/dev/null | grep -q table_stock ;;
    S5) dpkg -s phpmyadmin 2>/dev/null | grep -q "install ok installed" && poll 60 pma_up ;;
  esac
}

# ---------- clean-up before a retry ------------------------------------------
before_retry() {
  case "$1" in
    S1) [ -x /usr/local/hadoop/sbin/stop-all.sh ] && /usr/local/hadoop/sbin/stop-all.sh >/dev/null 2>&1 ;;
    S2) [ -x /opt/nifi/bin/nifi.sh ] && /opt/nifi/bin/nifi.sh stop >/dev/null 2>&1 ;;
  esac
  return 0
}

# ---------- CSV outputs -------------------------------------------------------
ATTEMPTS_CSV="$LOG_DIR/attempts.csv"
STAGES_CSV="$LOG_DIR/stages.csv"
echo "run_id,stage,attempt,start,end,duration_s,exit_code,check_passed,rx_mb,download_s,log_file" > "$ATTEMPTS_CSV"
echo "run_id,stage,name,start,end,duration_s,attempts,retries,outcome_2_1_0,recovery_s,rx_mb,download_s,last_exit_code" > "$STAGES_CSV"

log "ADS v2 run $RUN_ID started (interface $IFACE, max attempts $MAX_ATTEMPTS)"
RUN_START=$(now)
FAILED=0

for S in "${STAGES[@]}"; do
  script="$SCRIPT_DIR/${SCRIPT[$S]}"
  if [ ! -f "$script" ]; then
    log "$S: script ${SCRIPT[$S]} not found"
    echo "$RUN_ID,$S,${NAME[$S]},,,0,0,0,0,0,0,0,127" >> "$STAGES_CSV"
    FAILED=1; continue
  fi

  stage_start=""; first_fail_end=""; outcome=0; attempt=0
  stage_rx=0; stage_dl=0; rc=0
  while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 1 ]; then
      wait_s="${BACKOFF_S[$((attempt - 2))]:-${BACKOFF_S[-1]}}"
      log "$S: retry $((attempt - 1)) in $wait_s s"
      sleep "$wait_s"
      before_retry "$S"
    fi
    wait_apt_lock
    : > "$WGET_LOG"
    alog="$LOG_DIR/${S}_${SCRIPT[$S]%.sh}_attempt${attempt}.log"
    rx0=$(rx_bytes); t0=$(now)
    [ -z "$stage_start" ] && stage_start=$t0
    log "$S (${NAME[$S]}): attempt $attempt started"
    ( cd "$SCRIPT_DIR" && bash "$script" ) > "$alog" 2>&1
    rc=$?
    if check_stage "$S"; then ok=1; else ok=0; fi
    t1=$(now); rx1=$(rx_bytes)
    rx_mb=$(awk -v a="$rx0" -v b="$rx1" 'BEGIN{printf "%.1f", (b-a)/1048576}')
    dl=$(awk '{s+=$2-$1} END{printf "%.1f", s+0}' "$WGET_LOG" 2>/dev/null)
    stage_rx=$(awk -v a="$stage_rx" -v b="$rx_mb" 'BEGIN{printf "%.1f", a+b}')
    stage_dl=$(awk -v a="$stage_dl" -v b="$dl" 'BEGIN{printf "%.1f", a+b}')
    echo "$RUN_ID,$S,$attempt,$(ts "$t0"),$(ts "$t1"),$(dur "$t0" "$t1"),$rc,$ok,$rx_mb,$dl,$(basename "$alog")" >> "$ATTEMPTS_CSV"
    if [ "$ok" -eq 1 ]; then
      [ "$attempt" -eq 1 ] && outcome=2 || outcome=1
      log "$S: passed on attempt $attempt (exit code $rc)"
      break
    fi
    log "$S: check failed on attempt $attempt (exit code $rc); see $(basename "$alog")"
    [ -z "$first_fail_end" ] && first_fail_end=$t1
  done

  recovery=0
  if [ "$outcome" -eq 1 ]; then recovery=$(dur "$first_fail_end" "$t1"); fi
  if [ "$outcome" -eq 0 ]; then FAILED=1; log "$S: FAILED after $attempt attempts"; fi
  echo "$RUN_ID,$S,${NAME[$S]},$(ts "$stage_start"),$(ts "$t1"),$(dur "$stage_start" "$t1"),$attempt,$((attempt - 1)),$outcome,$recovery,$stage_rx,$stage_dl,$rc" >> "$STAGES_CSV"
done

RUN_END=$(now)
log "ADS v2 run $RUN_ID finished in $(dur "$RUN_START" "$RUN_END") s; result: $([ $FAILED -eq 0 ] && echo SUCCESS || echo 'FAILED (see stages.csv)')"
log "Outputs: $STAGES_CSV, $ATTEMPTS_CSV, vmstat.log, net_rx.log, one log per stage attempt"
exit $FAILED
