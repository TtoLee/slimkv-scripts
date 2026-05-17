#!/usr/bin/env bash

set -euo pipefail

nickname=""
project_dir="/home/lijinming/tebis"
basic_script_dir="${project_dir}/ycsb_log/scripts"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plot_only=0
plot_logs_dir=""
plot_output_dir=""
plot_run_label=""
plot_regions_file=""

gc_methods=(
	none
	sync
)
backup_label="offline_coding"
backup_method="offline_coding"
regions_file="regions_file_cross"
load_times=100000000
run_times_values=(
	300000000
    400000000
    500000000
)
ops_lower_threshold=000000000
ops_higher_threshold=900000000
workloads=(
	a
)
server_threads=4
client_threads=16
date_time=$(date +%Y%m%d_%H%M%S)
gc_print_check_interval_sec=30
gc_print_check_timeout_sec=0
servers_may_be_running=0

results_dir=""
summary_file=""

hosts=(
	10.118.0.227
	10.118.0.28
	10.118.0.229
	10.118.0.30
	10.118.0.31
	10.118.0.32
)

usage() {
	echo "Usage: $0 -n nickname"
	echo "   or: $0 -P -L <logs_dir> -O <plots_dir> [-R <run_label>] [-F <regions_file>]"
}

while getopts "n:PL:O:R:F:" opt; do
	case $opt in
	n)
		nickname=${OPTARG}
		;;
	P)
		plot_only=1
		;;
	L)
		plot_logs_dir=${OPTARG}
		;;
	O)
		plot_output_dir=${OPTARG}
		;;
	R)
		plot_run_label=${OPTARG}
		;;
	F)
		plot_regions_file=${OPTARG}
		;;
	*)
		usage
		exit 1
		;;
	esac
done

if [[ ${plot_only} -eq 0 && -z "${nickname}" ]]; then
	usage
	exit 1
fi

if [[ -n "${DESIGN_EXP_HOSTS:-}" ]]; then
	read -r -a hosts <<< "${DESIGN_EXP_HOSTS}"
fi

if [[ ${plot_only} -eq 0 && ${#hosts[@]} -ne 6 ]]; then
	echo "This script expects exactly 6 hosts, got: ${#hosts[@]}" >&2
	exit 1
fi

stop_servers() {
	local host
	for host in "${hosts[@]}"; do
		ssh "${host}" "sudo pkill -f 'tebis_server/tebis_server -b ${backup_method}'" >/dev/null 2>&1 || true
	done
}

cleanup() {
	if [[ ${servers_may_be_running} -eq 1 ]]; then
		echo "Stopping tebis servers from design_exp2 cleanup..." >&2
		stop_servers
		servers_may_be_running=0
	fi
}

trap cleanup EXIT

results_dir="${script_dir}/${nickname}_${date_time}"
mkdir -p "${results_dir}"
summary_file="${results_dir}/gc_valid_data_runs.tsv"

filter_ops_file() {
	local ops_file=$1
	local tmp_file
	local higher_threshold

	higher_threshold=${ops_higher_threshold}

	if [[ ! -f "${ops_file}" ]]; then
		echo "Skip filtering, file not found: ${ops_file}" >&2
		return
	fi

	tmp_file=$(mktemp)
	awk -v lower_threshold="${ops_lower_threshold}" -v higher_threshold="${higher_threshold}" '
	{
		num_count = 0
		second_num = -1
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) {
				num_count++
				if (num_count == 2) {
					second_num = $i + 0
					break
				}
			}
		}
		if (second_num > lower_threshold && second_num <= higher_threshold) {
			print
		}
	}
	' "${ops_file}" > "${tmp_file}"
	mv "${tmp_file}" "${ops_file}"
}

check_host_gc_segment_valid_data_done() {
	local host=$1
	local remote_log=$2

	ssh "${host}" "
		if [ ! -e '${remote_log}' ]; then
			echo MISSING
			exit 0
		fi
		if [ ! -r '${remote_log}' ]; then
			echo UNREADABLE
			exit 0
		fi
		if grep -Fq 'Finished printing GC segment valid data for all regions' '${remote_log}'; then
			echo READY
		else
			echo WAITING
		fi
	" 2>/dev/null
}

dump_remote_gc_segment_valid_data_context() {
	local remote_log=$1
	local host

	for host in "${hosts[@]}"; do
		echo "---- host=${host} log=${remote_log} ----" >&2
		ssh "${host}" "
			if [ ! -e '${remote_log}' ]; then
				echo 'remote log missing'
				exit 0
			fi
			echo 'tail -n 20:'
			tail -n 20 '${remote_log}' 2>/dev/null || true
			echo 'last gc valid-data lines:'
			grep -E 'region min key:|segment index:|segment_id:|Finished printing GC segment valid data for all regions' '${remote_log}' 2>/dev/null | tail -n 20 || true
		" >&2 || true
	done
}

wait_until_gc_segment_valid_data_done() {
	local remote_log=$1
	local start_ts
	local now_ts
	local elapsed_sec
	local attempt=0
	local host
	local status
	local ready_hosts
	local status_parts

	start_ts=$(date +%s)

	while true; do
		attempt=$((attempt + 1))
		ready_hosts=0
		status_parts=()

		for host in "${hosts[@]}"; do
			status=$(check_host_gc_segment_valid_data_done "${host}" "${remote_log}" || echo ERROR)
			if [[ "${status}" == "READY" ]]; then
				ready_hosts=$((ready_hosts + 1))
			fi
			status_parts+=("${host}:${status}")
		done

		if [[ ${ready_hosts} -eq ${#hosts[@]} ]]; then
			echo "GC segment valid-data printing finished on all hosts."
			return 0
		fi

		printf "\rWaiting for GC segment valid-data logs (attempt=${attempt}, ready=${ready_hosts}/${#hosts[@]}): ${status_parts[*]}" >&2

		now_ts=$(date +%s)
		elapsed_sec=$((now_ts - start_ts))
		if [[ ${gc_print_check_timeout_sec} -gt 0 && ${elapsed_sec} -ge ${gc_print_check_timeout_sec} ]]; then
			echo "Timed out waiting for GC segment valid-data logs after ${elapsed_sec}s." >&2
			dump_remote_gc_segment_valid_data_context "${remote_log}"
			return 1
		fi

		sleep "${gc_print_check_interval_sec}"
	done
}

collect_remote_server_logs() {
	local remote_log=$1
	local destination_dir=$2
	local host
	local host_log

	mkdir -p "${destination_dir}"
	for host in "${hosts[@]}"; do
		host_log="${destination_dir}/${host//./_}.log"
		scp -q "${host}:${remote_log}" "${host_log}" || {
			echo "Failed to copy remote log from ${host}:${remote_log}" >&2
			return 1
		}
	done
}

generate_gc_segment_plots() {
	local regions_file_path=$1
	local logs_dir=$2
	local output_dir=$3
	local run_label=$4

	mkdir -p "${output_dir}" "${output_dir}/.matplotlib"

	MPLCONFIGDIR="${output_dir}/.matplotlib" python3 - "${regions_file_path}" "${logs_dir}" "${output_dir}" "${run_label}" <<'PY'
import math
import os
import re
import sys
from pathlib import Path

regions_file = Path(sys.argv[1])
logs_dir = Path(sys.argv[2])
output_dir = Path(sys.argv[3])
run_label = sys.argv[4]
output_dir.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("MPLCONFIGDIR", str(output_dir / ".matplotlib"))
Path(os.environ["MPLCONFIGDIR"]).mkdir(parents=True, exist_ok=True)

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

REGION_PATTERN = re.compile(r"region min key:\s*(.*)")
SEGMENT_PATTERN = re.compile(r"segment(?: index|_id):\s*(\d+),\s*valid_size:\s*(\d+),?")
DONE_MARKER = "Finished printing GC segment valid data for all regions"
SEGMENT_BYTES = 2 * 1024 * 1024
PERCENT_COLORS = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728"]


def parse_region_groups(path: Path):
    regions_by_id = {}
    coding_groups = []
    in_coding_section = False
    with path.open("r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if line == "coding":
                in_coding_section = True
                continue
            if not line:
                continue

            parts = line.split()
            if not in_coding_section:
                if len(parts) < 3 or not parts[0].isdigit():
                    continue
                region_id = int(parts[0])
                regions_by_id[region_id] = {
                    "region_id": region_id,
                    "min_key": parts[1],
                    "max_key": parts[2],
                }
                continue

            if len(parts) < 2 or not parts[0].isdigit():
                continue

            group_entries = []
            for token in parts[1:]:
                if not token.isdigit():
                    continue
                region_id = int(token)
                if region_id not in regions_by_id:
                    raise RuntimeError(
                        f"Region id {region_id} referenced in coding section but not defined above"
                    )
                group_entries.append(regions_by_id[region_id])

            if group_entries:
                coding_groups.append(group_entries)

    if not coding_groups:
        raise RuntimeError(f"No coding groups found in {path}")

    return coding_groups


def parse_last_completed_cycle(path: Path):
    completed_cycles = []
    current_cycle = {}
    current_region = None

    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            if DONE_MARKER in raw_line:
                if current_cycle:
                    completed_cycles.append(current_cycle)
                current_cycle = {}
                current_region = None
                continue

            region_match = REGION_PATTERN.search(raw_line)
            if region_match:
                current_region = region_match.group(1).strip()
                current_cycle.setdefault(current_region, {})
                continue

            segment_match = SEGMENT_PATTERN.search(raw_line)
            if segment_match and current_region is not None:
                index = int(segment_match.group(1))
                valid_size = int(segment_match.group(2))
                current_cycle.setdefault(current_region, {})[index] = valid_size

    if not completed_cycles:
        return {}
    return completed_cycles[-1]


def merge_region_data(logs_path: Path):
    merged = {}
    sources = {}
    log_files = sorted(logs_path.glob("*.log"))
    if not log_files:
        raise RuntimeError(f"No copied server logs found in {logs_path}")

    for log_file in log_files:
        cycle = parse_last_completed_cycle(log_file)
        if not cycle:
            continue
        for region_min_key, series in cycle.items():
            merged.setdefault(region_min_key, {})
            for index, valid_size in series.items():
                if index in merged[region_min_key] and merged[region_min_key][index] != valid_size:
                    raise RuntimeError(
                        f"Conflicting valid_size for region {region_min_key} index {index}: "
                        f"{merged[region_min_key][index]} vs {valid_size} from {log_file.name}"
                    )
                merged[region_min_key][index] = valid_size
            sources.setdefault(region_min_key, []).append(log_file.name)

    if not merged:
        raise RuntimeError(f"No completed GC valid-data cycle found in {logs_path}")

    return merged, sources


def make_x_ticks(max_x: int):
    if max_x <= 0:
        return [0]
    tick_count = min(10, max_x + 1)
    if tick_count <= 1:
        return [0, max_x]
    step = max(1, math.ceil(max_x / (tick_count - 1)))
    ticks = list(range(0, max_x + 1, step))
    if ticks[-1] != max_x:
        ticks.append(max_x)
    return sorted(set(ticks))


def render_scatter_plot(output_path: Path, title: str, x_max: int, y_max: float, y_ticks, series_list,
                        x_label: str, y_label: str):
    fig, ax = plt.subplots(figsize=(14, 6), dpi=200)

    for series in series_list:
        if not series["points"]:
            continue
        xs = [point[0] for point in series["points"]]
        ys = [point[1] for point in series["points"]]
        ax.scatter(xs, ys, s=10, color=series["color"], alpha=0.85, label=series["label"])

    ax.set_title(title, fontsize=15)
    ax.set_xlabel(x_label)
    ax.set_ylabel(y_label)
    ax.set_ylim(-0.5, y_max + 0.5)

    if x_max <= 0:
        ax.set_xlim(-0.5, 0.5)
    else:
        ax.set_xlim(-0.5, x_max + 0.5)
        ax.set_xticks(make_x_ticks(x_max))

    ax.set_yticks(y_ticks)
    ax.grid(True, linestyle="--", linewidth=0.6, alpha=0.35)
    ax.legend(loc="upper right", frameon=True, fontsize=9)
    fig.tight_layout()
    fig.savefig(output_path, bbox_inches="tight")
    plt.close(fig)


def write_rows(path: Path, header, rows):
    with path.open("w", encoding="utf-8") as handle:
        handle.write("\t".join(header) + "\n")
        for row in rows:
            handle.write("\t".join(str(item) for item in row) + "\n")


def get_gc_title_label(label: str):
    lowered = label.lower()
    if "sync" in lowered:
        return "lazy"
    if "none" in lowered:
        return "no"
    return label


def get_run_time_label(label: str):
    match = re.search(r"\brt(\d+)\b", label)
    if match:
        run_time = int(match.group(1))
        if run_time % 1_000_000 == 0:
            return f"{run_time // 1_000_000}M"
        return str(run_time)
    return label


region_groups = parse_region_groups(regions_file)
region_data, region_sources = merge_region_data(logs_dir)
gc_title_label = get_gc_title_label(run_label)
run_time_label = get_run_time_label(run_label)

raw_rows = []
for region_min_key in sorted(region_data):
    for index in sorted(region_data[region_min_key]):
        raw_rows.append(
            (
                region_min_key,
                index,
                region_data[region_min_key][index],
                f"{region_data[region_min_key][index] * 100.0 / SEGMENT_BYTES:.6f}",
                ",".join(region_sources.get(region_min_key, [])),
            )
        )
write_rows(
    output_dir / "raw_region_valid_data.tsv",
    ["region_min_key", "index", "valid_size", "valid_percent", "source_logs"],
    raw_rows,
)

group_summary_rows = []
processed_rows = []
count_rows = []

for group_id, group in enumerate(region_groups):
    min_keys = [entry["min_key"] for entry in group]
    missing_regions = [min_key for min_key in min_keys if min_key not in region_data]
    if missing_regions:
        raise RuntimeError(
            f"Missing region data for group {group_id}: {', '.join(missing_regions)}"
        )

    empty_regions = [min_key for min_key in min_keys if not region_data[min_key]]
    if empty_regions:
        raise RuntimeError(
            f"Parsed no segment points for group {group_id}: {', '.join(empty_regions)}"
        )

    max_ids = {min_key: max(region_data[min_key]) for min_key in min_keys}
    cutoff = min(max_ids.values())
    x_values = list(range(cutoff + 1))

    percent_series = []
    non_zero_points = []

    group_data_rows = []
    group_count_rows = []

    for region_offset, (color, min_key) in enumerate(zip(PERCENT_COLORS, min_keys)):
        points = []
        for index in x_values:
            valid_size = region_data[min_key].get(index, 0)
            valid_percent = valid_size * 100.0 / SEGMENT_BYTES
            points.append((index, valid_percent))
            group_data_rows.append(
                (group_id, min_key, index, valid_size, f"{valid_percent:.6f}")
            )
            processed_rows.append(
                (group_id, min_key, index, valid_size, f"{valid_percent:.6f}")
            )
        region_label = f"region {group_id * 4 + region_offset}"
        percent_series.append({"color": color, "points": points, "label": region_label})

    for index in x_values:
        count = sum(1 for min_key in min_keys if region_data[min_key].get(index, 0) != 0)
        non_zero_points.append((index, count))
        group_count_rows.append((group_id, index, count))
        count_rows.append((group_id, index, count))

    group_summary_rows.append(
        (group_id, ", ".join(min_keys), cutoff, ",".join(f"{key}:{value}" for key, value in max_ids.items()))
    )

    write_rows(
        output_dir / f"group_{group_id}_valid_percent.tsv",
        ["group_id", "region_min_key", "index", "valid_size", "valid_percent"],
        group_data_rows,
    )
    write_rows(
        output_dir / f"group_{group_id}_nonzero_count.tsv",
        ["group_id", "index", "nonzero_region_count"],
        group_count_rows,
    )

    render_scatter_plot(
        output_dir / f"group_{group_id}_valid_percent_scatter.png",
        f"Valid data percent of segments in stripe {group_id} under {gc_title_label} GC. run time {run_time_label}",
        cutoff,
        100.0,
        [0, 20, 40, 60, 80, 100],
        percent_series,
        "Segment index",
        "Valid data (%)",
    )

    render_scatter_plot(
        output_dir / f"group_{group_id}_nonzero_count_scatter.png",
        f"Number of valid segment in stripe {group_id} under {gc_title_label} GC. run time {run_time_label}",
        cutoff,
        4.0,
        [0, 1, 2, 3, 4],
        [{"color": "#444444", "points": non_zero_points, "label": "non-zero count"}],
        "Segment index",
        "Non-zero region count",
    )

write_rows(
    output_dir / "group_summary.tsv",
    ["group_id", "group_min_keys", "cutoff_index", "region_max_ids"],
    group_summary_rows,
)
write_rows(
    output_dir / "processed_group_valid_data.tsv",
    ["group_id", "region_min_key", "index", "valid_size", "valid_percent"],
    processed_rows,
)
write_rows(
    output_dir / "processed_group_nonzero_count.tsv",
    ["group_id", "index", "nonzero_region_count"],
    count_rows,
)

print(f"Generated GC valid-data plots for {run_label} in {output_dir}")
PY
}

if [[ ${plot_only} -eq 1 ]]; then
	if [[ -z "${plot_logs_dir}" || -z "${plot_output_dir}" ]]; then
		usage
		exit 1
	fi

	if [[ -z "${plot_regions_file}" ]]; then
		plot_regions_file="${project_dir}/${regions_file}"
	fi

	if [[ -z "${plot_run_label}" ]]; then
		plot_run_label=$(basename "${plot_logs_dir}")
	fi

	generate_gc_segment_plots "${plot_regions_file}" "${plot_logs_dir}" "${plot_output_dir}" \
		"${plot_run_label}"
	echo "Saved plot-only outputs under: ${plot_output_dir}"
	exit 0
fi

printf "gc_method\tworkload\trun_times\tstatus\tserver_log_path\tlogs_dir\tplots_dir\n" > "${summary_file}"

echo "Running GC valid-data experiment with backup=${backup_label}, gc_methods=${gc_methods[*]}, workloads=${workloads[*]}, run_times=${run_times_values[*]}"

for gc_method in "${gc_methods[@]}"; do
	for workload in "${workloads[@]}"; do
		for run_times in "${run_times_values[@]}"; do
			echo -e "\n*********Running GC valid-data experiment gc=${gc_method}, workload=${workload}, run_times=${run_times}, backup=${backup_label}*********"

			run_tag="${date_time}"
			run_name="${gc_method}_${workload}_rt${run_times}"
			output_base="ycsb_log/tmp_log/${nickname}_${backup_label}_${gc_method}_${workload}_thread_${server_threads}_${client_threads}_rt${run_times}"
			output_path="${project_dir}/${output_base}_${run_tag}"
			server_log_path="/tmp/lijinming_tebis_server_${backup_label}_${gc_method}_${workload}_rt${run_times}_${run_tag}.log"
			run_output_dir="${results_dir}/${run_name}"
			logs_dir="${run_output_dir}/server_logs"
			plots_dir="${run_output_dir}/plots"

			mkdir -p "${run_output_dir}"

			echo "Running single round: gc=${gc_method}, workload=${workload}, run_times=${run_times}, tag=${run_tag}" >&2

			"${basic_script_dir}/run_cluster.sh" -b "${backup_method}" -g "${gc_method}" -l "${load_times}" \
				-r "${run_times}" -u "${ops_higher_threshold}" -w "${workload}" -o "${output_base}" \
				-d "${run_tag}" -t "${server_threads}" -c "${client_threads}" -f "${regions_file}" -k \
				-s "${server_log_path}"

			servers_may_be_running=1

			ops_file="${output_path}/run_${workload}/ops.txt"
			filter_ops_file "${ops_file}"

			wait_until_gc_segment_valid_data_done "${server_log_path}"
			stop_servers
			servers_may_be_running=0

			collect_remote_server_logs "${server_log_path}" "${logs_dir}"
			generate_gc_segment_plots "${project_dir}/${regions_file}" "${logs_dir}" "${plots_dir}" "${run_name}"

			printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
				"${gc_method}" "${workload}" "${run_times}" "DONE" "${server_log_path}" "${logs_dir}" "${plots_dir}" \
				>> "${summary_file}"

			sleep 10
		done
	done
done

echo ""
echo "Saved GC valid-data run summary: ${summary_file}"
echo "Per-run plots and TSV files are under: ${results_dir}"
