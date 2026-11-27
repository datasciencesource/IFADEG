#!/bin/bash
# =====================================================================
# e3_show.sh - show the recorded tables of one Experiment 3 run in the terminal
#   Part 0, Part 1, Deployment items, Part 2, Part 3 (+ workflow time), Summary
#   in the order of Instrument 3. Read-only: it changes nothing.
#
# Usage:  ./e3_show.sh              (reads /ifadeg_logs)
#         ./e3_show.sh <folder>     (e.g. a copied run folder on the host: ./e3_show.sh E3-R01)
# =====================================================================

DIR="${1:-/ifadeg_logs}"
[ -d "$DIR" ] || { echo "Folder $DIR not found."; exit 1; }

# Print a CSV file as an aligned table (quotes removed; dates and run_start columns hidden)
show() {   # $1 = title, $2 = csv file, $3 = note shown when the file is missing
    echo ""
    echo "===== $1 ====="
    if [ ! -s "$DIR/$2" ]; then echo "  ($2 not found - ${3:-not recorded in this run})"; return; fi
    awk -F',' '
        { gsub(/"/, "") }
        NR==1 { for (i=1; i<=NF; i++) if ($i=="date" || $i=="run_start") skip[i]=1 }
        { n=0; for (i=1; i<=NF; i++) if (!skip[i]) { n++; cell[NR,n]=$i; if (length($i)>w[n]) w[n]=length($i) }
          cols=(n>cols)?n:cols; rows=NR }
        END {
            for (r=1; r<=rows; r++) {
                line=""
                for (c=1; c<=cols; c++) line=line sprintf("%-" w[c] "s", cell[r,c]) (c<cols?" | ":"")
                print line
                if (r==1) { sep=""; for (c=1; c<=cols; c++) { s=sprintf("%" w[c] "s",""); gsub(/ /,"-",s); sep=sep s (c<cols?"-+-":"") }; print sep }
            }
        }' "$DIR/$2"
}

RUN_START=$(awk -F',' 'NR==2{print $2}' "$DIR/part1.csv" 2>/dev/null)
RUN_DATE=$(awk -F',' 'NR==2{print $1}' "$DIR/part1.csv" 2>/dev/null)
echo "################ Instrument 3 - FADTESE run ${RUN_DATE:+$RUN_DATE }${RUN_START:+(run started $RUN_START)} ################"
echo "Folder: $DIR"

show "Part 0: Run header"                        part0.csv
show "Part 1: Deployment evaluation (Hadoop part / Connector/J / Total)" part1.csv "FADTESE run not recorded"
show "Deployment items (D1, D3, D6)"             items.csv
show "Part 2: Component verification (C1, C2)"   part2.csv
show "Part 3: Workflow validation (W1, W2, W6, W7)" part3.csv "the run did not reach Part 3"
show "Part 3: Workflow execution time and throughput" e3_workflow.csv "the run did not reach Part 3"
show "Summary"                                   summary.csv "the run did not reach the Summary"

LOGF=$(ls -1 "$DIR"/fadtese_*.log 2>/dev/null | tail -1)
echo ""
echo "Full FADTESE output: ${LOGF:-not found}"
