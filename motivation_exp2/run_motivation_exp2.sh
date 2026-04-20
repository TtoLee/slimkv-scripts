#!/usr/bin/env bash

set -euo pipefail

nickname=""
project_dir="/home/lijinming/tebis"
basic_script_dir="${project_dir}/ycsb_log/scripts"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

backup_method="elect"
regions_file="regions_file_elect"
gc_methods=(
	none
	normal
)
workloads=(
	a
)

load_times=100000000
run_times=1100000000
ops_lower_threshold=200000000
ops_higher_threshold=900000000
server_threads=4
client_threads=16
date_time=$(date +%Y%m%d_%H%M%S)

results_dir=""
results_rel=""
client_logs_dir=""
throughput_file=""

declare -A sample_run_dirs

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

results_dir="${script_dir}/${nickname}_${date_time}"
mkdir -p "${results_dir}"
results_rel="${results_dir#${project_dir}/}"
if [[ "${results_rel}" == "${results_dir}" ]]; then
	echo "results_dir must be under project_dir. results_dir=${results_dir}, project_dir=${project_dir}" >&2
	exit 1
fi

client_logs_dir="${results_dir}/client_logs"
mkdir -p "${client_logs_dir}"

throughput_file="${results_dir}/throughput.tsv"
printf "workload\tbackup_method\tgc_method\tthroughput_kops\tops_file\n" > "${throughput_file}"

compute_kops_from_ops_file() {
	local ops_file=$1

	awk -v lower_threshold="${ops_lower_threshold}" -v higher_threshold="${ops_higher_threshold}" '
	{
		if (match($0, /([0-9]+)[[:space:]]+sec[[:space:]]+([0-9.eE+-]+)[[:space:]]+operations/, m)) {
			sec = m[1] + 0
			operations = m[2] + 0
			if (!(operations > lower_threshold && operations <= higher_threshold)) {
				next
			}
			if (!seen) {
				first_sec = sec
				first_operations = operations
				seen = 1
			}
			last_sec = sec
			last_operations = operations
		}
	}
	END {
		if (!seen) {
			exit 2
		}
		elapsed_sec = last_sec - first_sec
		elapsed_operations = last_operations - first_operations
		if (elapsed_sec <= 0 || elapsed_operations < 0) {
			exit 3
		}
		printf "%.10f\n", (elapsed_operations / elapsed_sec) / 1000.0
	}
	' "${ops_file}"
}

echo "Running motivation exp2 (backup=${backup_method}), gc_methods=${gc_methods[*]}, workloads=${workloads[*]}"

for workload in "${workloads[@]}"; do
	for gc_method in "${gc_methods[@]}"; do
		echo -e "\n*********Running motivation exp2 workload=${workload}, backup=${backup_method}, gc=${gc_method}*********"

		run_tag="${date_time}_${gc_method}"
		output_base="${results_rel}/client_logs/${nickname}_${backup_method}_${gc_method}_${workload}_thread_${server_threads}_${client_threads}"
		output_path="${project_dir}/${output_base}_${run_tag}"
		server_log_path="/tmp/lijinming_tebis_server_${backup_method}_${gc_method}_${workload}_${run_tag}.log"

		echo "Running workload=${workload}, backup=${backup_method}, gc=${gc_method}" >&2

		"${basic_script_dir}/run_cluster.sh" -b "${backup_method}" -g "${gc_method}" -l "${load_times}" \
			-r "${run_times}" -u "${ops_higher_threshold}" -w "${workload}" -o "${output_base}" \
			-d "${run_tag}" -t "${server_threads}" -c "${client_threads}" -f "${regions_file}" \
			-s "${server_log_path}"

		ops_file="${output_path}/run_${workload}/ops.txt"

		kops=$(compute_kops_from_ops_file "${ops_file}") || {
			echo "Failed to compute throughput from ${ops_file}" >&2
			exit 1
		}

		echo "Throughput: ${kops} kops/sec"
		printf "%s\t%s\t%s\t%s\t%s\n" "${workload}" "${backup_method}" "${gc_method}" "${kops}" "${ops_file}" >> "${throughput_file}"

		sample_key="${gc_method}_${workload}"
		sample_run_dirs["${sample_key}"]="${output_path}"

		sleep 10
	done
done

if [[ ${#gc_methods[@]} -lt 2 ]]; then
	echo "Skip plotting: need at least two gc methods, got ${#gc_methods[@]}" >&2
	exit 0
fi

plot_label1="${gc_methods[0]}"
plot_label2="${gc_methods[1]}"

for workload in "${workloads[@]}"; do
	first_key="${plot_label1}_${workload}"
	second_key="${plot_label2}_${workload}"
	dir1="${sample_run_dirs[${first_key}]:-}"
	dir2="${sample_run_dirs[${second_key}]:-}"

	if [[ -z "${dir1}" || -z "${dir2}" ]]; then
		echo "Skip plotting workload=${workload}: missing run directories." >&2
		continue
	fi

	plot_output="${results_dir}/run_${workload}_throughput_${backup_method}_gc_${plot_label1}_vs_${plot_label2}.pdf"
	echo "Plotting throughput curve for workload=${workload} (${plot_label1} vs ${plot_label2})"
	plot_cmd=(
		python3 "${basic_script_dir}/plot_ops_triple.py"
		--label1 "gc=${plot_label1}"
		--label2 "gc=${plot_label2}"
		--window 5
		--ops-lower-threshold "${ops_lower_threshold}"
		--ops-higher-threshold "${ops_higher_threshold}"
		--output "${plot_output}"
		--dir1 "${dir1}"
		--dir2 "${dir2}"
	)
	echo "Executing plot command:"
	printf '  %q' "${plot_cmd[@]}"
	echo
	"${plot_cmd[@]}"
done

echo "motivation exp2 finished. Results: ${results_dir}"
echo "Saved throughput summary: ${throughput_file}"
