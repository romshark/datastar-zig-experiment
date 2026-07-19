#!/usr/bin/env bash
#
# Benchmark the Go and Zig server implementations one at a time (never
# concurrently) and print a side-by-side comparison.
#
# Load, throughput, and latency percentiles come from k6. CPU and memory come
# from sampling the server process tree (so the Go server's sqinn child counts
# too). On Linux with `perf`, hardware counters (cycles, instructions, cache
# misses, ...) are added.
#
# Requirements: k6, jq, curl, awk, python3; zig and go to build the servers;
# optionally perf (Linux) for hardware counters.
#
# Usage: ./bench.sh [-d duration] [-c connections] [-w warmup] [-p path]
#                   [-o go|zig] [-P] [--go-dir DIR] [--zig-dir DIR]

set -euo pipefail

SCRIPTDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

DURATION=10s
VUS=50
WARMUP=3s
REQ_PATH=/
ONLY=
USE_PERF=1
GODIR="$SCRIPTDIR/../go"
ZIGDIR="$SCRIPTDIR/../zig"

while [ $# -gt 0 ]; do
	case "$1" in
	-d) DURATION=$2; shift 2 ;;
	-c) VUS=$2; shift 2 ;;
	-w) WARMUP=$2; shift 2 ;;
	-p) REQ_PATH=$2; shift 2 ;;
	-o) ONLY=$2; shift 2 ;;
	-P) USE_PERF=0; shift ;;
	--go-dir) GODIR=$2; shift 2 ;;
	--zig-dir) ZIGDIR=$2; shift 2 ;;
	-h | --help) sed -n '2,20p' "$0"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

for tool in k6 jq curl awk python3; do
	command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done

GODIR=$(cd "$GODIR" && pwd)
ZIGDIR=$(cd "$ZIGDIR" && pwd)
SAMPLE_S=0.1
PERF_EVENTS=task-clock,cycles,instructions,cache-references,cache-misses,branches,branch-misses,context-switches,page-faults

HAVE_PERF=0
if [ "$USE_PERF" = 1 ] && [ "$(uname)" = Linux ] && command -v perf >/dev/null; then
	HAVE_PERF=1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/zigvibe-bench.XXXXXX")
LAUNCH_PID=
SAMPLER_PID=
cleanup() { stop_sampler; stop_server; rm -rf "$WORK"; }
trap cleanup EXIT

now() { python3 -c 'import time; print(time.time())'; }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
tree_usage() { ps -axo pid=,ppid=,rss=,cputime= | awk -v root="$1" -f "$SCRIPTDIR/tree.awk"; }
first_child() { ps -axo pid=,ppid= | awk -v p="$1" '$2==p{print $1; exit}'; }

stop_sampler() {
	[ -n "$SAMPLER_PID" ] || return 0
	kill "$SAMPLER_PID" 2>/dev/null || true
	wait "$SAMPLER_PID" 2>/dev/null || true
	SAMPLER_PID=
}

stop_server() {
	[ -n "$LAUNCH_PID" ] || return 0
	# SIGINT lets perf flush its counters and the server exit cleanly; the
	# sqinn child then sees EOF on its stdin pipe and exits too.
	kill -INT "$LAUNCH_PID" 2>/dev/null || true
	for _ in $(seq 1 30); do kill -0 "$LAUNCH_PID" 2>/dev/null || break; sleep 0.1; done
	kill -KILL "$LAUNCH_PID" 2>/dev/null || true
	wait "$LAUNCH_PID" 2>/dev/null || true
	LAUNCH_PID=
}

wait_ready() {
	local url=$1 code
	for _ in $(seq 1 150); do
		code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "$url" || true)
		[ "$code" = 200 ] && return 0
		kill -0 "$LAUNCH_PID" 2>/dev/null || return 1
		sleep 0.1
	done
	return 1
}

# run_target NAME BIN DB ADDR — start, warm, load, sample, stop; write results.
run_target() {
	local name=$1 bin=$2 db=$3 addr=$4
	local url="http://$addr$REQ_PATH" root_url="http://$addr/"
	local perf_out="$WORK/$name.perf.csv"
	local summary="$WORK/$name.summary.json"
	local rss_samples="$WORK/$name.rss"

	rm -f "$db" "$db-wal" "$db-shm" "$rss_samples"

	if [ "$HAVE_PERF" = 1 ]; then
		perf stat -o "$perf_out" -x , -e "$PERF_EVENTS" -- "$bin" "$addr" "$db" \
			>"$WORK/$name.server.log" 2>&1 &
	else
		"$bin" "$addr" "$db" >"$WORK/$name.server.log" 2>&1 &
	fi
	LAUNCH_PID=$!

	if ! wait_ready "$root_url"; then
		echo "  $name server did not become ready; last log lines:" >&2
		tail -n 5 "$WORK/$name.server.log" >&2 || true
		stop_server
		return 1
	fi

	# The process to sample: the server itself, or perf's child when wrapped.
	local root=$LAUNCH_PID
	if [ "$HAVE_PERF" = 1 ]; then
		root=$(first_child "$LAUNCH_PID")
		[ -n "$root" ] || root=$LAUNCH_PID
	fi

	echo "  warmup ${WARMUP} ..." >&2
	TARGET_URL="$url" VUS="$VUS" DURATION="$WARMUP" SUMMARY_OUT="$WORK/$name.warmup.json" \
		k6 run --quiet "$SCRIPTDIR/load.js" >/dev/null 2>&1 || true

	# Sample RSS of the tree during the measured window; bracket CPU time with
	# precise wall-clock reads for an accurate average.
	local cpu0 t0 cpu1 t1
	cpu0=$(tree_usage "$root" | awk '{print $2}')
	t0=$(now)
	( while :; do tree_usage "$root" | awk '{print $1}'; sleep "$SAMPLE_S"; done ) >"$rss_samples" &
	SAMPLER_PID=$!

	echo "  load ${DURATION} at ${VUS} connections ..." >&2
	TARGET_URL="$url" VUS="$VUS" DURATION="$DURATION" SUMMARY_OUT="$summary" \
		k6 run --quiet "$SCRIPTDIR/load.js" 2>"$WORK/$name.k6.log"

	stop_sampler
	cpu1=$(tree_usage "$root" | awk '{print $2}')
	t1=$(now)
	stop_server

	# --- derive metrics ---
	local reqs rps avg p90 p99 failrate
	reqs=$(jq -r '.metrics.http_reqs.values.count'        "$summary")
	rps=$(jq  -r '.metrics.http_reqs.values.rate'         "$summary")
	avg=$(jq  -r '.metrics.http_req_duration.values.avg'  "$summary")
	p90=$(jq  -r '.metrics.http_req_duration.values["p(90)"]' "$summary")
	p99=$(jq  -r '.metrics.http_req_duration.values["p(99)"]' "$summary")
	failrate=$(jq -r '.metrics.http_req_failed.values.rate // 0' "$summary")

	local cpu_pct mem_avg mem_max
	cpu_pct=$(awk -v a="$cpu0" -v b="$cpu1" -v t0="$t0" -v t1="$t1" \
		'BEGIN{d=t1-t0; printf "%.1f", (d>0)?(b-a)/d*100:0}')
	read -r mem_avg mem_max < <(awk '{s+=$1; if($1>m)m=$1} END{printf "%.0f %.0f", (NR?s/NR:0), m}' "$rss_samples")

	local cycles instructions cache_misses branch_misses task_clock
	if [ "$HAVE_PERF" = 1 ] && [ -f "$perf_out" ]; then
		cycles=$(perf_val "$perf_out" cycles)
		instructions=$(perf_val "$perf_out" instructions)
		cache_misses=$(perf_val "$perf_out" cache-misses)
		branch_misses=$(perf_val "$perf_out" branch-misses)
		task_clock=$(perf_val "$perf_out" task-clock)
	fi

	{
		echo "NAME=$name"
		echo "REQS=$reqs"
		echo "RPS=$rps"
		echo "AVG=$avg"
		echo "P90=$p90"
		echo "P99=$p99"
		echo "FAILRATE=$failrate"
		echo "CPU=$cpu_pct"
		echo "MEMAVG=$mem_avg"
		echo "MEMMAX=$mem_max"
		echo "CYCLES=${cycles:-}"
		echo "INSTRUCTIONS=${instructions:-}"
		echo "CACHE_MISSES=${cache_misses:-}"
		echo "BRANCH_MISSES=${branch_misses:-}"
		echo "TASK_CLOCK=${task_clock:-}"
	} >"$WORK/$name.result"
}

# perf_val FILE EVENT — value for one event from perf's CSV (-x ,) output.
perf_val() { awk -F, -v ev="$2" '$3==ev{gsub(/ /,"",$1); print $1; exit}' "$1"; }

build_go() {
	echo "building Go server (go build) ..." >&2
	( cd "$GODIR" && go build -o "$WORK/go-server" . )
	echo "$WORK/go-server"
}

build_zig() {
	echo "building Zig server (zig build -Doptimize=ReleaseFast) ..." >&2
	( cd "$ZIGDIR" && zig build -Doptimize=ReleaseFast )
	echo "$ZIGDIR/zig-out/bin/zigvibe"
}

targets=(Go Zig)
[ -n "$ONLY" ] && targets=("$(tr '[:lower:]' '[:upper:]' <<<"${ONLY:0:1}")${ONLY:1}")

for name in "${targets[@]}"; do
	echo "=== $name ===" >&2
	case "$name" in
	Go)  bin=$(build_go) ;;
	Zig) bin=$(build_zig) ;;
	*)   echo "unknown target: $name" >&2; exit 2 ;;
	esac
	addr="127.0.0.1:$(free_port)"
	run_target "$name" "$bin" "$WORK/$name.db" "$addr" || echo "  $name skipped" >&2
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

get() { awk -F= -v k="$2" '$1==k{print substr($0, length(k)+2)}' "$WORK/$1.result" 2>/dev/null; }
have() { [ -f "$WORK/$1.result" ]; }

f2()  { awk -v x="$1" 'BEGIN{printf (x==""?"n/a":"%.2f"), x}'; }
f0()  { awk -v x="$1" 'BEGIN{printf (x==""?"n/a":"%.0f"), x}'; }
mib() { awk -v x="$1" 'BEGIN{printf (x==""?"n/a":"%.1f"), x/1024}'; }
big() { awk -v x="$1" 'BEGIN{if(x=="") {print "n/a"; exit} printf "%\x27d", x}' 2>/dev/null || echo "${1:-n/a}"; }

echo
echo "Workload: GET ${REQ_PATH}   connections=${VUS}   duration=${DURATION}   warmup=${WARMUP}"
if [ "$HAVE_PERF" = 1 ]; then
	echo "Hardware counters: perf ($(uname))"
else
	echo "Hardware counters: unavailable ($(uname); needs Linux + perf)"
fi
echo

printf '%-26s %16s %16s\n' "Metric" "Go" "Zig"
printf '%-26s %16s %16s\n' "--------------------------" "----------------" "----------------"
row() { # LABEL GO_VALUE ZIG_VALUE
	printf '%-26s %16s %16s\n' "$1" "$2" "$3"
}

row "Requests"                 "$(f0  "$(get Go REQS)")"   "$(f0  "$(get Zig REQS)")"
row "RPS (req/s)"              "$(f0  "$(get Go RPS)")"    "$(f0  "$(get Zig RPS)")"
row "Latency avg (ms)"        "$(f2  "$(get Go AVG)")"    "$(f2  "$(get Zig AVG)")"
row "Latency p90 (ms)"        "$(f2  "$(get Go P90)")"    "$(f2  "$(get Zig P90)")"
row "Latency p99 (ms)"        "$(f2  "$(get Go P99)")"    "$(f2  "$(get Zig P99)")"
row "CPU avg (% of 1 core)"   "$(f0  "$(get Go CPU)")"    "$(f0  "$(get Zig CPU)")"
row "Mem avg (MiB)"           "$(mib "$(get Go MEMAVG)")" "$(mib "$(get Zig MEMAVG)")"
row "Mem max (MiB)"           "$(mib "$(get Go MEMMAX)")" "$(mib "$(get Zig MEMMAX)")"
if [ "$HAVE_PERF" = 1 ]; then
	row "Cycles"               "$(big "$(get Go CYCLES)")"        "$(big "$(get Zig CYCLES)")"
	row "Instructions"         "$(big "$(get Go INSTRUCTIONS)")"  "$(big "$(get Zig INSTRUCTIONS)")"
	row "Cache misses"         "$(big "$(get Go CACHE_MISSES)")"  "$(big "$(get Zig CACHE_MISSES)")"
	row "Branch misses"        "$(big "$(get Go BRANCH_MISSES)")" "$(big "$(get Zig BRANCH_MISSES)")"
fi
echo

for name in Go Zig; do
	have "$name" || continue
	fr=$(get "$name" FAILRATE)
	if [ "$(awk -v x="${fr:-0}" 'BEGIN{print (x+0>0)?1:0}')" = 1 ]; then
		echo "WARNING: $name had failed requests (http_req_failed rate ${fr})."
	fi
done

exit 0