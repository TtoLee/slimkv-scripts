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
run_times=900000000
ops_lower_threshold=200000000
ops_higher_threshold=700000000
workloads=(
	load
)
server_threads=8
client_threads=32
window=1

# Fill these two variables before running, or override them with -H/-D.
metric_host="${MOT_EXP1_IOSTAT_HOST:-10.118.0.30}"
metric_nvme_device="${MOT_EXP1_IOSTAT_DEVICE:-nvme0n1}"

date_time=$(date +%Y%m%d_%H%M%S)
run_date=$(date +%Y-%m-%d)

results_dir=""
results_rel=""
client_logs_dir=""
plot_dir=""
raw_dir=""
summary_file=""
matplotlib_cache_dir=""
iostat_pid=""
iostat_raw_file=""

usage() {
	echo "Usage: $0 -n nickname [-H metric_host] [-D nvme_device] [-w window]"
	echo "Example: MOT_EXP1_IOSTAT_HOST=10.118.0.227 MOT_EXP1_IOSTAT_DEVICE=nvme0n1 $0 -n test"
}

while getopts "n:H:D:w:" opt; do
	case $opt in
	n)
		nickname=${OPTARG}
		;;
	H)
		metric_host=${OPTARG}
		;;
	D)
		metric_nvme_device=${OPTARG}
		;;
	w)
		window=${OPTARG}
		;;
	*)
		usage
		exit 1
		;;
	esac
done

if [[ -z "${nickname}" || -z "${metric_host}" || -z "${metric_nvme_device}" ]]; then
	usage
	exit 1
fi

if ! [[ "${metric_host}" =~ ^[A-Za-z0-9._@:-]+$ ]]; then
	echo "metric_host contains unsupported characters: ${metric_host}" >&2
	exit 1
fi

if ! [[ "${metric_nvme_device}" =~ ^[A-Za-z0-9._-]+$ ]]; then
	echo "metric_nvme_device should be a device name like nvme0n1, got: ${metric_nvme_device}" >&2
	exit 1
fi

if ! [[ "${window}" =~ ^[0-9]+$ ]] || [[ "${window}" -le 0 ]]; then
	echo "window must be a positive integer, got: ${window}" >&2
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
plot_dir="${results_dir}/plots"
raw_dir="${results_dir}/raw"
matplotlib_cache_dir="${results_dir}/matplotlib_cache"
mkdir -p "${client_logs_dir}" "${plot_dir}" "${raw_dir}" "${matplotlib_cache_dir}"
export MPLCONFIGDIR="${matplotlib_cache_dir}"
summary_file="${results_dir}/summary.tsv"
printf "workload\tbackup_method\tmetric_host\tnvme_device\trun_dir\tiostat_raw\tserver_log_local\tplot_dir\n" > "${summary_file}"

stop_iostat() {
	if [[ -n "${iostat_pid}" ]] && kill -0 "${iostat_pid}" 2>/dev/null; then
		kill "${iostat_pid}" 2>/dev/null || true
		wait "${iostat_pid}" 2>/dev/null || true
	fi
	iostat_pid=""
}

cleanup() {
	stop_iostat
}

trap cleanup EXIT

start_iostat() {
	local host=$1
	local device=$2
	local output_file=$3
	local error_file="${output_file%.log}.err"

	: > "${output_file}"
	: > "${error_file}"
	echo "Starting iostat on host=${host}, device=${device}" >&2
	ssh "${host}" "LANG=C iostat -dx -t '${device}' 1" > "${output_file}" 2> "${error_file}" &
	iostat_pid=$!
	sleep 2
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

echo "Running motivation exp3 disk-write iostat collection: backups=${backup_methods[*]}, host=${metric_host}, device=${metric_nvme_device}, window=${window}"

for workload in "${workloads[@]}"; do
	workload_plot_dir="${plot_dir}/${workload}"
	mkdir -p "${workload_plot_dir}"
	plot_cmd=(
		python3 "${basic_script_dir}/plot_iostat_flush_timeseries.py"
		--device "${metric_nvme_device}"
		--run-date "${run_date}"
		--output-dir "${workload_plot_dir}"
		--window "${window}"
		--ops-lower-threshold "${ops_lower_threshold}"
		--ops-higher-threshold "${ops_higher_threshold}"
	)

	for backup_label in "${backup_methods[@]}"; do
		echo -e "\n*********Running motivation exp3 disk-write iostat workload=${workload}, backup=${backup_label}*********"

		read -r backup_method regions_file <<< "$(resolve_backup_config "${backup_label}")"
		sync_and_build_for_backup "${backup_label}"

		run_tag="${date_time}"
		output_base="${results_rel}/client_logs/${nickname}_${backup_label}_${workload}_thread_${server_threads}_${client_threads}"
		output_path="${project_dir}/${output_base}_${run_tag}"
		server_log_path="/tmp/lijinming_tebis_server_${backup_label}_${workload}_${run_tag}.log"
		iostat_raw_file="${raw_dir}/${backup_label}_${workload}_${metric_host}_${metric_nvme_device}_iostat.log"
		server_log_local="${raw_dir}/${backup_label}_${workload}_${metric_host}_server.log"

		start_iostat "${metric_host}" "${metric_nvme_device}" "${iostat_raw_file}"

		"${basic_script_dir}/run_cluster.sh" -b "${backup_method}" -g "${gc_method}" -l "${load_times}" \
			-r "${run_times}" -u "${ops_higher_threshold}" -w "${workload}" -o "${output_base}" \
			-d "${run_tag}" -t "${server_threads}" -c "${client_threads}" -f "${regions_file}" \
			-s "${server_log_path}"

		stop_iostat

		ops_file="${output_path}/run_${workload}/ops.txt"
		kops=$(compute_kops_from_ops_file "${ops_file}") || {
			echo "Failed to compute throughput from ${ops_file}" >&2
			exit 1
		}
		echo "YCSB throughput in selected window: ${kops} kops/sec"

		echo "Collecting server log from ${metric_host}:${server_log_path}" >&2
		scp -q "${metric_host}:${server_log_path}" "${server_log_local}" || {
			echo "Failed to copy server log from ${metric_host}:${server_log_path}" >&2
			exit 1
		}

		plot_cmd+=(
			--ops-file "${ops_file}"
			--iostat-file "${iostat_raw_file}"
			--server-log "${server_log_local}"
			--label "${backup_label}"
		)

		printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
			"${workload}" "${backup_label}" "${metric_host}" "${metric_nvme_device}" \
			"${output_path}" "${iostat_raw_file}" "${server_log_local}" "${workload_plot_dir}" \
			>> "${summary_file}"

		sleep 10
	done

	echo "Executing plot command:"
	printf '  %q' "${plot_cmd[@]}"
	echo
	"${plot_cmd[@]}"
done

echo "motivation exp3 disk-write iostat finished. Results: ${results_dir}"
echo "Saved summary: ${summary_file}"
