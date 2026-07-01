#!/usr/bin/env bash

set -euo pipefail

nickname=""
project_dir="/home/lijinming/tebis"
basic_script_dir="${project_dir}/ycsb_log/scripts"
plot_gc_script="${basic_script_dir}/plot_valid_ratio_scatter.py"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plot_only=0
plot_runs_root=""
plot_logs_dir=""
plot_output_dir=""
plot_run_label=""
plot_regions_file=""
plot_valid_title=""
plot_count_title=""
plot_legend_names=""
plot_count_legend_name=""
plot_x_label=""
plot_valid_y_label=""
plot_count_y_label=""
plot_no_truncate=1

gc_methods=(
    none
    sync
)
sync_gc_times=(
	150
	600
)
backup_label="offline_coding"
backup_method="offline_coding"
regions_file="regions_file_cross"
load_times=100000000
run_times_values=(
    1000000000
)
ops_lower_threshold=000000000
ops_higher_threshold=1200000000
workloads=(
	a
)
server_threads=8
client_threads=32
date_time=$(date +%Y%m%d_%H%M%S)
gc_print_check_interval_sec=30
gc_print_check_timeout_sec=0
servers_may_be_running=0
sync_gc_primary_file="${project_dir}/tebis_server/offline_coding/sync_gc_primary.c"
default_sync_gc_time=""
current_sync_gc_time=""

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
	echo "   or: $0 -P <runs_root> [-F <regions_file>]"
	echo "      [-V <valid_title>] [-C <count_title>] [-G <legend_names>]"
	echo "      [-Q <count_legend_name>] [-X <x_label>] [-Y <valid_y_label>] [-Z <count_y_label>]"
	echo "      [-N]"
	echo "      runs_root should contain per-run subdirectories; each run uses server_logs, plots, and directory name."
}

while getopts "n:P:L:O:R:F:V:C:G:Q:X:Y:ZN" opt; do
	case $opt in
	n)
		nickname=${OPTARG}
		;;
	P)
		plot_only=1
		plot_runs_root=${OPTARG}
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
	V)
		plot_valid_title=${OPTARG}
		;;
	C)
		plot_count_title=${OPTARG}
		;;
	G)
		plot_legend_names=${OPTARG}
		;;
	Q)
		plot_count_legend_name=${OPTARG}
		;;
	X)
		plot_x_label=${OPTARG}
		;;
	Y)
		plot_valid_y_label=${OPTARG}
		;;
	Z)
		plot_count_y_label=${OPTARG}
		;;
	N)
		plot_no_truncate=0
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

read_sync_gc_time_macro() {
	if [[ ! -f "${sync_gc_primary_file}" ]]; then
		echo "sync_gc_primary.c not found: ${sync_gc_primary_file}" >&2
		return 1
	fi

	awk '/^#define[[:space:]]+SYNC_GC_TIME[[:space:]]+[0-9]+/ { print $3; exit }' "${sync_gc_primary_file}"
}

set_sync_gc_time_macro() {
	local sync_gc_time=$1

	if [[ ! -f "${sync_gc_primary_file}" ]]; then
		echo "sync_gc_primary.c not found: ${sync_gc_primary_file}" >&2
		return 1
	fi

	if ! grep -qE '^#define[[:space:]]+SYNC_GC_TIME[[:space:]]+[0-9]+' "${sync_gc_primary_file}"; then
		echo "SYNC_GC_TIME macro not found in ${sync_gc_primary_file}" >&2
		return 1
	fi

	sed -i -E \
		"s|^#define[[:space:]]+SYNC_GC_TIME[[:space:]]+[0-9]+$|#define SYNC_GC_TIME ${sync_gc_time}|" \
		"${sync_gc_primary_file}"
	grep -E '^#define[[:space:]]+SYNC_GC_TIME[[:space:]]+[0-9]+' "${sync_gc_primary_file}" >&2
	current_sync_gc_time=${sync_gc_time}
}

sync_and_build_all_nodes() {
	echo "Syncing source and building locally/remotely via ./scp.sh ..." >&2
	(
		cd "${project_dir}"
		./scp.sh
	)
}

ensure_sync_gc_time_built() {
	local desired_sync_gc_time=$1

	if [[ "${current_sync_gc_time}" == "${desired_sync_gc_time}" ]]; then
		echo "SYNC_GC_TIME already ${desired_sync_gc_time}, skipping source sync/build." >&2
		return 0
	fi

	echo "Setting SYNC_GC_TIME=${desired_sync_gc_time} and syncing/building..." >&2
	set_sync_gc_time_macro "${desired_sync_gc_time}"
	sync_and_build_all_nodes
}

restore_default_sync_gc_time() {
	if [[ -z "${default_sync_gc_time}" ]]; then
		return 0
	fi

	if [[ "${current_sync_gc_time}" == "${default_sync_gc_time}" ]]; then
		return 0
	fi

	echo "Restoring SYNC_GC_TIME=${default_sync_gc_time} and syncing/building..." >&2
	set_sync_gc_time_macro "${default_sync_gc_time}"
	sync_and_build_all_nodes
}

cleanup() {
	if [[ ${servers_may_be_running} -eq 1 ]]; then
		echo "Stopping tebis servers from design_exp2 cleanup..." >&2
		stop_servers
		servers_may_be_running=0
	fi

	if [[ ${plot_only} -eq 0 ]]; then
		restore_default_sync_gc_time || echo "Failed to restore SYNC_GC_TIME during cleanup." >&2
	fi
}

trap cleanup EXIT

if [[ ${plot_only} -eq 0 ]]; then
	default_sync_gc_time=$(read_sync_gc_time_macro)
	if [[ -z "${default_sync_gc_time}" ]]; then
		echo "Failed to read default SYNC_GC_TIME from ${sync_gc_primary_file}" >&2
		exit 1
	fi
	current_sync_gc_time=${default_sync_gc_time}

	results_dir="${script_dir}/${nickname}_${date_time}"
	mkdir -p "${results_dir}"
	summary_file="${results_dir}/gc_valid_data_runs.tsv"
fi

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
	local -a python_args

	mkdir -p "${output_dir}" "${output_dir}/.matplotlib"

	python_args=(
		--regions-file "${regions_file_path}"
		--logs-dir "${logs_dir}"
		--output-dir "${output_dir}"
		--run-label "${run_label}"
	)

	if [[ -n "${plot_valid_title}" ]]; then
		python_args+=(--valid-title "${plot_valid_title}")
	fi
	if [[ -n "${plot_count_title}" ]]; then
		python_args+=(--count-title "${plot_count_title}")
	fi
	if [[ -n "${plot_legend_names}" ]]; then
		python_args+=(--legend-names "${plot_legend_names}")
	fi
	if [[ -n "${plot_count_legend_name}" ]]; then
		python_args+=(--count-legend-name "${plot_count_legend_name}")
	fi
	if [[ -n "${plot_x_label}" ]]; then
		python_args+=(--x-label "${plot_x_label}")
	fi
	if [[ -n "${plot_valid_y_label}" ]]; then
		python_args+=(--valid-y-label "${plot_valid_y_label}")
	fi
	if [[ -n "${plot_count_y_label}" ]]; then
		python_args+=(--count-y-label "${plot_count_y_label}")
	fi
	if [[ ${plot_no_truncate} -eq 1 ]]; then
		python_args+=(--no-truncate)
	fi

	MPLCONFIGDIR="${output_dir}/.matplotlib" python3 "${plot_gc_script}" "${python_args[@]}"
}

generate_gc_segment_plots_for_root() {
	local regions_file_path=$1
	local runs_root=$2
	local -a python_args

	mkdir -p "${runs_root}/.matplotlib"

	python_args=(
		--regions-file "${regions_file_path}"
		--runs-root "${runs_root}"
	)

	if [[ -n "${plot_valid_title}" ]]; then
		python_args+=(--valid-title "${plot_valid_title}")
	fi
	if [[ -n "${plot_count_title}" ]]; then
		python_args+=(--count-title "${plot_count_title}")
	fi
	if [[ -n "${plot_legend_names}" ]]; then
		python_args+=(--legend-names "${plot_legend_names}")
	fi
	if [[ -n "${plot_count_legend_name}" ]]; then
		python_args+=(--count-legend-name "${plot_count_legend_name}")
	fi
	if [[ -n "${plot_x_label}" ]]; then
		python_args+=(--x-label "${plot_x_label}")
	fi
	if [[ -n "${plot_valid_y_label}" ]]; then
		python_args+=(--valid-y-label "${plot_valid_y_label}")
	fi
	if [[ -n "${plot_count_y_label}" ]]; then
		python_args+=(--count-y-label "${plot_count_y_label}")
	fi
	if [[ ${plot_no_truncate} -eq 1 ]]; then
		python_args+=(--no-truncate)
	fi

	MPLCONFIGDIR="${runs_root}/.matplotlib" python3 "${plot_gc_script}" "${python_args[@]}"
}

if [[ ${plot_only} -eq 1 ]]; then
	if [[ -z "${plot_runs_root}" ]]; then
		usage
		exit 1
	fi

	if [[ -z "${plot_regions_file}" ]]; then
		plot_regions_file="${project_dir}/${regions_file}"
	fi

	generate_gc_segment_plots_for_root "${plot_regions_file}" "${plot_runs_root}"
	echo "Saved plot-only outputs under each run's plots directory in: ${plot_runs_root}"
	exit 0
fi

printf "gc_method\tsync_gc_time\tworkload\trun_times\tstatus\tserver_log_path\tlogs_dir\tplots_dir\n" > "${summary_file}"

echo "Running GC valid-data experiment with backup=${backup_label}, gc_methods=${gc_methods[*]}, workloads=${workloads[*]}, run_times=${run_times_values[*]}"

for gc_method in "${gc_methods[@]}"; do
	for workload in "${workloads[@]}"; do
		for run_times in "${run_times_values[@]}"; do
			if [[ "${gc_method}" == "sync" ]]; then
				sync_gc_time_values=("${sync_gc_times[@]}")
			else
				sync_gc_time_values=("NA")
			fi

			for sync_gc_time in "${sync_gc_time_values[@]}"; do
				if [[ "${gc_method}" == "sync" ]]; then
					echo -e "\n*********Running GC valid-data experiment gc=${gc_method}, sync_gc_time=${sync_gc_time}, workload=${workload}, run_times=${run_times}, backup=${backup_label}*********"
					ensure_sync_gc_time_built "${sync_gc_time}"
					sync_suffix="_sgct${sync_gc_time}"
				else
					echo -e "\n*********Running GC valid-data experiment gc=${gc_method}, workload=${workload}, run_times=${run_times}, backup=${backup_label}*********"
					sync_suffix=""
				fi

				run_tag="${date_time}"
				run_name="${gc_method}${sync_suffix}_${workload}_rt${run_times}"
				output_base="ycsb_log/tmp_log/${nickname}_${backup_label}_${gc_method}${sync_suffix}_${workload}_thread_${server_threads}_${client_threads}_rt${run_times}"
				output_path="${project_dir}/${output_base}_${run_tag}"
				server_log_path="/tmp/lijinming_tebis_server_${backup_label}_${gc_method}${sync_suffix}_${workload}_rt${run_times}_${run_tag}.log"
				run_output_dir="${results_dir}/${run_name}"
				logs_dir="${run_output_dir}/server_logs"
				plots_dir="${run_output_dir}/plots"

				mkdir -p "${run_output_dir}"

				echo "Running single round: gc=${gc_method}, sync_gc_time=${sync_gc_time}, workload=${workload}, run_times=${run_times}, tag=${run_tag}" >&2

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

				printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
					"${gc_method}" "${sync_gc_time}" "${workload}" "${run_times}" "DONE" "${server_log_path}" "${logs_dir}" "${plots_dir}" \
					>> "${summary_file}"

				sleep 10
			done
		done
	done
done

echo ""
echo "Saved GC valid-data run summary: ${summary_file}"
echo "Per-run plots and TSV files are under: ${results_dir}"
