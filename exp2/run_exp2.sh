#!/usr/bin/env bash

set -euo pipefail

nickname=""
project_dir="/home/lijinming/tebis"
script_dir="${project_dir}/ycsb_log/scripts"

repeat_times=5
gc_method=none
backup_methods=(
	offline_coding
)
load_times=100000000
run_times=500000000
ops_lower_threshold=200000000
ops_higher_threshold=800000000
workloads=(
	load
)
server_threads=1
client_threads=16
date_time=$(date +%Y%m%d_%H%M%S)
results_dir=""
students_results_dir=""

usage() {
	echo "Usage: $0 -n nickname"
}

while getopts "n:" opt; do
	case $opt in
	n)
		nickname=${OPTARG}
		;;
	*)
		usage
		exit 1
		;;
	esac
done

if [[ -z "${nickname}" ]]; then
	usage
	exit 1
fi

if [[ ${#backup_methods[@]} -lt 1 ]]; then
	echo "backup_methods must contain at least one backup type." >&2
	exit 1
fi

if [[ ${repeat_times} -lt 1 ]]; then
	echo "repeat_times must be >= 1." >&2
	exit 1
fi

results_dir="${project_dir}/ycsb_log/tmp_log/${nickname}_${date_time}"
mkdir -p "${results_dir}"
students_results_dir="${project_dir}/ycsb_log/exp2/${nickname}_${date_time}"
mkdir -p "${students_results_dir}"

declare -A run_output_paths

resolve_backup_config() {
	local backup_label=$1

	case "${backup_label}" in
	elect)
		echo "elect regions_file_elect"
		;;
	replication)
		echo "online_coding regions_file_replica"
		;;
	offline_coding)
		echo "offline_coding regions_file_cross"
		;;
	*)
		echo "Unsupported backup method label: ${backup_label}" >&2
		exit 1
		;;
	esac
}

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

run_latency_summary_for_backup() {
	local backup_label="$1"
	local workload="$2"
	shift 2
	local log_paths=("$@")

	if [[ ${#log_paths[@]} -eq 0 ]]; then
		echo "Skip latency summary for ${backup_label}/${workload}: no log paths." >&2
		return
	fi

	local summary_prefix
	summary_prefix="${students_results_dir}/${backup_label}_${workload}_students"

	local -a cmd
	cmd=("${script_dir}/latency_breakdown_with_students.sh")
	local idx
	for idx in "${!log_paths[@]}"; do
		cmd+=( -l "${log_paths[$idx]}" -G "run_$(printf "%02d" $((idx + 1)))" )
	done
	cmd+=( -o "${summary_prefix}" )
    echo "Running latency summary command: ${cmd[*]}" >&2
	echo "Generating Student-t latency summary for backup=${backup_label}, workload=${workload}" >&2
	"${cmd[@]}"
}

echo "Running exp2 with repeat_times=${repeat_times}, backups=${backup_methods[*]}, workloads=${workloads[*]}"

for workload in "${workloads[@]}"; do
	for backup_label in "${backup_methods[@]}"; do
		echo -e "\n*********Running exp2 workload=${workload}, backup=${backup_label}*********"

		read -r backup_method regions_file <<< "$(resolve_backup_config "${backup_label}")"

		log_paths_for_summary=()

		for ((run_idx = 1; run_idx <= repeat_times; run_idx++)); do
			run_tag="${date_time}_r$(printf "%02d" "${run_idx}")"
			output_base="ycsb_log/tmp_log/${nickname}_${backup_label}_${workload}_thread_${server_threads}_${client_threads}"
			output_path="${project_dir}/${output_base}_${run_tag}"
			server_log_path="/tmp/lijinming_tebis_server_${backup_label}_${workload}_${run_tag}.log"

			echo "Run ${run_idx}/${repeat_times}: backup=${backup_label}, workload=${workload}, tag=${run_tag}" >&2

			"${script_dir}/run_cluster.sh" -b "${backup_method}" -g "${gc_method}" -l "${load_times}" \
				-r "${run_times}" -u "${ops_higher_threshold}" -w "${workload}" -o "${output_base}" \
				-d "${run_tag}" -t "${server_threads}" -c "${client_threads}" -f "${regions_file}" \
				-s "${server_log_path}"

			ops_file="${output_path}/run_${workload}/ops.txt"
			filter_ops_file "${ops_file}"

			log_paths_for_summary+=("${server_log_path}")
			run_output_paths["${backup_label}_${workload}"]="${output_path}"
			sleep 10
		done

		run_latency_summary_for_backup "${backup_label}" "${workload}" "${log_paths_for_summary[@]}"
	done
done

echo "exp2 finished. Latency Student-t summaries were generated per backup/workload." >&2
