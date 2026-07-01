#!/usr/bin/env bash

set -euo pipefail

nickname=""
project_dir="/home/lijinming/tebis"
basic_script_dir="/home/lijinming/tebis/ycsb_log/scripts"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

gc_method=none
backup_methods=(
	replication
	elect
	elect+
)
load_times=100000000
run_times=1000000000
ops_lower_threshold=200000000
ops_higher_threshold=700000000
workloads=(
	load
)
server_threads=8
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
printf "workload\tbackup_method\tthroughput_kops\tops_file\n" > "${throughput_file}"

resolve_backup_config() {
	local backup_label=$1

	case "${backup_label}" in
	elect)
		echo "elect regions_file_elect"
		;;
	elect+)
		echo "elect regions_file_elect"
		;;
	replication)
		# Keep the method label as requested; run_cluster still uses online_coding.
		echo "online_coding regions_file_elect"
		;;
	*)
		echo "Unsupported backup method label: ${backup_label}" >&2
		exit 1
		;;
	esac
}

sync_and_build_all_nodes() {
	local cmake_args=("$@")

	echo "Syncing source and building locally/remotely via ./scp.sh ${cmake_args[*]} ..." >&2
	(
		cd "${project_dir}"
		./scp.sh "${cmake_args[@]}"
	)
}

sync_and_build_for_backup() {
	local backup_label=$1

	case "${backup_label}" in
	elect)
		sync_and_build_all_nodes -DELECT_MINIMIZE_NETWORK=OFF
		;;
	elect+)
		# Use scp.sh defaults, currently including -DELECT_MINIMIZE_NETWORK=ON.
		sync_and_build_all_nodes
		;;
	esac
}

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

echo "Running mot exp1 (single run per workload/backup), backups=${backup_methods[*]}, workloads=${workloads[*]}"

for workload in "${workloads[@]}"; do
	for backup_label in "${backup_methods[@]}"; do
		echo -e "\n*********Running motivation exp1 workload=${workload}, backup=${backup_label}*********"

		read -r backup_method regions_file <<< "$(resolve_backup_config "${backup_label}")"
		sync_and_build_for_backup "${backup_label}"

		run_tag="${date_time}"
		output_base="${results_rel}/client_logs/${nickname}_${backup_label}_${workload}_thread_${server_threads}_${client_threads}"
		output_path="${project_dir}/${output_base}_${run_tag}"
		server_log_path="/tmp/lijinming_tebis_server_${backup_label}_${workload}_${run_tag}.log"

		echo "Running workload=${workload}, method=${backup_label}" >&2

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
		printf "%s\t%s\t%s\t%s\n" "${workload}" "${backup_label}" "${kops}" "${ops_file}" >> "${throughput_file}"

		sample_key="${backup_label}_${workload}"
		sample_run_dirs["${sample_key}"]="${output_path}"

		sleep 10
	done
done

if [[ ${#backup_methods[@]} -lt 2 ]]; then
	echo "Skip plotting: need at least two backup methods, got ${#backup_methods[@]}" >&2
	exit 0
fi

plot_label1="${backup_methods[0]}"
plot_label2="${backup_methods[1]}"
plot_label3="${backup_methods[2]:-}"

for workload in "${workloads[@]}"; do
	plot_output="${results_dir}/run_${workload}_throughput.pdf"
	echo "Plotting throughput curve for workload=${workload} (${backup_methods[*]})"
	plot_cmd=(
		python3 "${basic_script_dir}/plot_ops_triple.py"
		--label1 "${plot_label1}"
		--label2 "${plot_label2}"
		--window 5
		--ops-lower-threshold "${ops_lower_threshold}"
		--ops-higher-threshold "${ops_higher_threshold}"
		--output "${plot_output}"
	)
	if [[ -n "${plot_label3}" ]]; then
		plot_cmd+=(--label3 "${plot_label3}")
	fi

	for index in "${!backup_methods[@]}"; do
		backup_label="${backup_methods[${index}]}"
		sample_key="${backup_label}_${workload}"
		dirs_csv="${sample_run_dirs[${sample_key}]:-}"

		if [[ -z "${dirs_csv}" ]]; then
			echo "Skip plotting workload=${workload}: missing run directory for backup=${backup_label}." >&2
			continue 2
		fi

		series_num=$((index + 1))

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

echo "motivation exp1 finished. Results: ${results_dir}"
echo "Saved throughput summary: ${throughput_file}"
