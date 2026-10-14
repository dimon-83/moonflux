#!/bin/bash
# resource-watch.sh <outfile> [interval_s] — sample system resources until killed.
#
# Why (decision 103): a run that crashes its own caller cannot be diagnosed from
# the run's output — the output dies with the caller. So the evidence has to be
# sampled OUT OF PROCESS, by something whose only job is to keep writing numbers
# while the run does whatever it does.
#
# It watches the CLIENT as well as the workload on purpose. The suspicion is that
# what runs out is an Electron renderer's own heap rather than system memory, and
# a monitor that only counts moonflux processes would miss exactly that.
#
# One TSV line per sample:
#   epoch  load1  mem_free_MB  swap_used_MB  procs  workload_procs  workload_RSS_MB
#   client_procs  client_RSS_MB  top_RSS_MB  top_command
#
# Usage:
#   scripts/resource-watch.sh /tmp/rw.log 2 &
#   … run the thing under investigation …
#   kill %1
set -uo pipefail

OUT="${1:?usage: resource-watch.sh <outfile> [interval_s]}"
INTERVAL="${2:-2}"
# "workload" = the platform processes this repository starts; "client" = the
# editor/harness the operator is watching from. Keep them separate: the whole
# question is which one grows.
WORKLOAD_PATTERN="${MOONFLUX_WATCH_WORKLOAD:-cli.exe|moon |moonc|wasmtime}"
CLIENT_PATTERN="${MOONFLUX_WATCH_CLIENT:-DeepSeek|dsh|Electron|ZCode}"

printf 'epoch\tload1\tmem_free_MB\tswap_used_MB\tprocs\tworkload_procs\tworkload_RSS_MB\tclient_procs\tclient_RSS_MB\ttop_RSS_MB\ttop_command\n' > "$OUT"

# macOS vm_stat reports pages; the page size is 16 KiB on Apple silicon and 4 KiB
# on Intel, so read it from the kernel rather than assuming.
PAGE_SIZE="$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)"

rss_mb() { # $1 = pgrep pattern -> total RSS in MB, and the count
  local pattern="$1"
  ps -Ao rss=,command= 2>/dev/null |
    grep -E "$pattern" 2>/dev/null |
    grep -v grep |
    awk -v ps="$PAGE_SIZE" '{sum += $1} END {printf "%.0f", sum / 1024}'
}
count_of() {
  ps -Ao command= 2>/dev/null | grep -E "$1" | grep -vc grep
}

while true; do
  epoch="$(date +%s)"
  load1="$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')"
  mem_free_mb="$(vm_stat 2>/dev/null | awk -v ps="$PAGE_SIZE" '
    /Pages free/ {gsub(/\./, "", $3); free = $3}
    /Pages inactive/ {gsub(/\./, "", $3); inact = $3}
    END {printf "%.0f", (free + inact) * ps / 1048576}')"
  swap_used_mb="$(sysctl -n vm.swapusage 2>/dev/null |
    sed -E 's/.*used = ([0-9.]+)M.*/\1/' | awk '{printf "%.0f", $1}')"
  procs="$(ps -Ao pid= 2>/dev/null | wc -l | tr -d ' ')"
  w_procs="$(count_of "$WORKLOAD_PATTERN")"
  w_rss="$(rss_mb "$WORKLOAD_PATTERN")"
  c_procs="$(count_of "$CLIENT_PATTERN")"
  c_rss="$(rss_mb "$CLIENT_PATTERN")"
  top="$(ps -Ao rss=,command= 2>/dev/null | sort -rn | head -1)"
  top_rss="$(printf '%s' "$top" | awk '{printf "%.0f", $1 / 1024}')"
  top_cmd="$(printf '%s' "$top" | cut -c8-60)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$epoch" "$load1" "$mem_free_mb" "$swap_used_mb" "$procs" \
    "$w_procs" "$w_rss" "$c_procs" "$c_rss" "$top_rss" "$top_cmd" >> "$OUT"
  sleep "$INTERVAL"
done
