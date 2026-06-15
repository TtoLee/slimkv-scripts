#!/usr/bin/env bash

set -euo pipefail

nickname=""
project_dir="/home/lijinming/tebis"
basic_script_dir="/home/lijinming/tebis/ycsb_log/scripts"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

backup_method="offline_coding"
regions_file="regions_file_cross"
gc_methods=(
	none
	normal
	sync
)
cmake_args=(
)
load_times=100000000
run_times=1600000000
ops_lower_threshold=200000000
ops_higher_threshold=1200000000
workloads=(
	a
)
server_threads=4
client_threads=32
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

sync_and_build_all_nodes() {
	echo "Syncing source and building locally/remotely via ./scp.sh ${cmake_args[*]} ..." >&2
	(
		cd "${project_dir}"
		./scp.sh "${cmake_args[@]}"
	)
}

sync_and_build_all_nodes

echo "Running exp6 gc throughput (backup=${backup_method}), gc_methods=${gc_methods[*]}, workloads=${workloads[*]}"

for workload in "${workloads[@]}"; do
	for gc_method in "${gc_methods[@]}"; do
		echo -e "\n*********Running exp6_gc_thpt workload=${workload}, backup=${backup_method}, gc=${gc_method}*********"

		run_tag="${date_time}_${gc_method}"
		output_base="${results_rel}/client_logs/${nickname}_${backup_method}_${gc_method}_${workload}_thread_${server_threads}_${client_threads}"
		output_path="${project_dir}/${output_base}_${run_tag}"
		server_log_path="/tmp/lijinming_tebis_server_${backup_method}_${gc_method}_${workload}_${run_tag}.log"

		echo "Running workload=${workload}, backup=${backup_method}, gc=${gc_method}" >&2

		run_cmd=(
			"${basic_script_dir}/run_cluster.sh" -b "${backup_method}" -g "${gc_method}" -l "${load_times}"
			-r "${run_times}" -u "${ops_higher_threshold}" -w "${workload}" -o "${output_base}"
			-d "${run_tag}" -t "${server_threads}" -c "${client_threads}" -f "${regions_file}"
			-s "${server_log_path}"
		)

		"${run_cmd[@]}"

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

for workload in "${workloads[@]}"; do
	gc_label_slug=$(IFS=_; echo "${gc_methods[*]}")
	plot_output="${results_dir}/run_${workload}_throughput_${backup_method}_gc_${gc_label_slug}.pdf"
	echo "Plotting throughput curve for workload=${workload} (${gc_methods[*]})"
	plot_cmd=(
		python3 "${basic_script_dir}/plot_ops_triple.py"
		--window 5
		--ops-lower-threshold "${ops_lower_threshold}"
		--ops-higher-threshold "${ops_higher_threshold}"
		--output "${plot_output}"
	)

	for index in "${!gc_methods[@]}"; do
		gc_method="${gc_methods[${index}]}"
		sample_key="${gc_method}_${workload}"
		dirs_csv="${sample_run_dirs[${sample_key}]:-}"

		if [[ -z "${dirs_csv}" ]]; then
			echo "Skip plotting workload=${workload}: missing run directory for gc=${gc_method}." >&2
			continue 2
		fi

		series_num=$((index + 1))
		plot_cmd+=("--label${series_num}" "${gc_method}")

		IFS=';' read -r -a dirs <<< "${dirs_csv}"
		for d in "${dirs[@]}"; do
			plot_cmd+=("--dir${series_num}" "${d}")
		done
	done

	echo "Executing plot command:"
	printf '  %q' "${plot_cmd[@]}"
	echo
	"${plot_cmd[@]}"
done

echo "exp6 gc throughput finished. Results: ${results_dir}"
echo "Saved throughput summary: ${throughput_file}"
