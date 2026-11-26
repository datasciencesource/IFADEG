#!/bin/bash
# =====================================================================
# 1part0.sh - Instrument Part 0: run header values
# Records: Network bandwidth (Mbit/s), Network latency (ms) / packet loss (%),
#          Free disk before run (GB), Date.
# Run ID is entered manually on the form.
# Run start / end time is recorded by the run step (next script).
#
# Usage (as root, in /):  ./1part0.sh
# Output: values on screen + one row in /ifadeg_logs/part0.csv
# =====================================================================

[ "$(id -u)" -ne 0 ] && { echo "Please run as root: sudo -i"; exit 1; }

LOG_DIR="/ifadeg_logs"
CSV="$LOG_DIR/part0.csv"
mkdir -p "$LOG_DIR"

# Date
DATE=$(date +%F)
TIME=$(date +%T)

# Network bandwidth (Mbit/s): speedtest-cli --simple (Download)
if command -v speedtest-cli >/dev/null 2>&1; then
    BW=$(speedtest-cli --simple 2>/dev/null | awk '/^Download:/{print $2}')
fi
BW="${BW:-NA}"

# Network latency (ms) / packet loss (%): ping -c 20 8.8.8.8 (avg rtt / loss)
PING_OUT=$(ping -c 20 8.8.8.8 2>/dev/null)
LAT=$(echo "$PING_OUT" | awk -F'/' '/rtt/{print $5}')
LOSS=$(echo "$PING_OUT" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+')
LAT="${LAT:-NA}"; LOSS="${LOSS:-NA}"

# Free disk before run (GB): df -BG / (Avail)
FREE=$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')

# Save
[ -f "$CSV" ] || echo "date,time,bandwidth_mbps,latency_ms,packet_loss_pct,free_disk_gb" > "$CSV"
echo "$DATE,$TIME,$BW,$LAT,$LOSS,$FREE" >> "$CSV"

# Show
echo "----- Part 0: run header -----"
echo "Network bandwidth (Mbit/s)             : $BW"
echo "Network latency (ms) / packet loss (%) : $LAT / $LOSS"
echo "Free disk before run (GB)              : $FREE"
echo "Run ID                                 : (manual input on the form)"
echo "Date                                   : $DATE"
echo "Run start time / end time              : (recorded by the run step)"
echo "------------------------------"
echo "Saved: $CSV"
