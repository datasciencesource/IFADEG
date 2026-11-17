#!/usr/bin/env python3
"""
IFADEG: turn one run's logs into the numbers for Instrument 1, Part 1.

Run inside the VM after run_ads.sh (so /proc/meminfo is the VM's memory):
    python3 summarize_run.py logs/E1-R01 <bandwidth_mbps>
e.g.
    python3 summarize_run.py logs/E1-R01 95.4

Prints the stage log table (with peak/mean CPU and peak RAM per stage) and
the Part 1 summary, and writes part1_summary.csv into the run folder.
"""
import csv
import sys
from datetime import datetime
from pathlib import Path

FMT = "%Y-%m-%d %H:%M:%S"


def mem_total_kb():
    for line in open("/proc/meminfo"):
        if line.startswith("MemTotal:"):
            return int(line.split()[1])
    raise SystemExit("cannot read MemTotal from /proc/meminfo")


def read_vmstat(path, total_kb):
    rows, hdr = [], None
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if "us" in p and "id" in p:          # column header line
            hdr = p
            continue
        if hdr and p[0].isdigit() and len(p) >= len(hdr) + 1:
            d = dict(zip(hdr, p))
            ts = datetime.strptime(" ".join(p[-2:]), FMT)
            cpu = 100 - int(d["id"])
            used = total_kb - int(d["free"]) - int(d["buff"]) - int(d["cache"])
            rows.append((ts, cpu, used / 1048576))   # RAM in GB
    return rows


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    run = Path(sys.argv[1])
    bw = float(sys.argv[2]) if len(sys.argv) > 2 else None
    total_kb = mem_total_kb()
    vm = read_vmstat(run / "vmstat.log", total_kb)
    stages = list(csv.DictReader(open(run / "stages.csv")))

    out = []
    print(f"Run folder: {run}   VM RAM: {total_kb/1048576:.1f} GB\n")
    hdr = ["stage", "start", "end", "duration_s", "download_s", "data_mb", "exit_code",
           "attempts", "recovery_s", "outcome", "peak_cpu", "mean_cpu", "peak_ram_gb"]
    print(" | ".join(hdr))
    for s in stages:
        a = datetime.strptime(s["start"], FMT)
        b = datetime.strptime(s["end"], FMT)
        win = [r for r in vm if a <= r[0] <= b]
        pk = max((r[1] for r in win), default=0)
        mn = sum(r[1] for r in win) / len(win) if win else 0
        ram = max((r[2] for r in win), default=0)
        row = [s["stage"], s["start"][11:], s["end"][11:], s["duration_s"], s["download_s"],
               s["rx_mb"], s["last_exit_code"], s["attempts"], s["recovery_s"],
               s["outcome_2_1_0"], f"{pk}", f"{mn:.1f}", f"{ram:.2f}"]
        out.append(dict(zip(hdr, row)))
        print(" | ".join(row))

    t0 = datetime.strptime(stages[0]["start"], FMT)
    t1 = datetime.strptime(stages[-1]["end"], FMT)
    T = (t1 - t0).total_seconds()
    dl = sum(float(s["download_s"]) for s in stages)
    mb = sum(float(s["rx_mb"]) for s in stages)
    thr = mb * 8 / dl if dl > 0 else 0
    util = 100 * thr / bw if bw else None
    retries = sum(int(s["retries"]) for s in stages)
    ttr = sum(float(s["recovery_s"]) for s in stages)
    allw = [r for r in vm if t0 <= r[0] <= t1]
    mean_cpu = sum(r[1] for r in allw) / len(allw) if allw else 0
    peak_cpu = max((r[1] for r in allw), default=0)
    peak_ram = max((r[2] for r in allw), default=0)

    summary = [
        ("Total deployment time, T (s)", f"{T:.0f}"),
        ("Total download time (s)", f"{dl:.1f}"),
        ("Install and configure time = T - download (s)", f"{T - dl:.1f}"),
        ("Total data downloaded (MB)", f"{mb:.1f}"),
        ("Download throughput (Mbps)", f"{thr:.1f}"),
        ("Bandwidth utilisation (%)", f"{util:.1f}" if util is not None else "give bandwidth as 2nd argument"),
        ("Total retries", str(retries)),
        ("Total error recovery time, TTR (s)", f"{ttr:.1f}"),
        ("Mean CPU (%) / peak CPU (%)", f"{mean_cpu:.1f} / {peak_cpu}"),
        ("Peak RAM (GB) / RAM allocated (GB)", f"{peak_ram:.2f} / {total_kb/1048576:.1f}"),
    ]
    print("\nPart 1 summary")
    for k, v in summary:
        print(f"  {k}: {v}")

    with open(run / "part1_summary.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(hdr)
        for r in out:
            w.writerow([r[h] for h in hdr])
        w.writerow([])
        for k, v in summary:
            w.writerow([k, v])
    print(f"\nSaved: {run / 'part1_summary.csv'}")


if __name__ == "__main__":
    main()
