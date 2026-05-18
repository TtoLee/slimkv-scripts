#!/usr/bin/env bash

set -euo pipefail

nickname=""
project_dir="/home/lijinming/tebis"
basic_script_dir="${project_dir}/ycsb_log/scripts"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
time_count_source="${project_dir}/time_counter/time_count.h"

epoch=5
gc_method=none
backup_methods=(
	replication
	elect
	offline_coding
)
load_times=100000000
run_times=500000000
ops_lower_threshold=000000000
ops_higher_threshold=700000000
workloads=(
	load
    a
)
server_threads=4
client_threads=16
date_time=$(date +%Y%m%d_%H%M%S)
stable_check_interval_sec=200
stable_check_timeout_sec=0
servers_may_be_running=0

results_dir=""
summary_file=""
host_file=""
space_occupation_original_state=""
space_occupation_build_enabled=0

hosts=(
	10.118.0.227
	10.118.0.28
	10.118.0.229
	10.118.0.30
	10.118.0.31
	10.118.0.32
)

SPACE_STATUS=""
SPACE_TIMESTAMP="PER_HOST_LAST"
SPACE_TOTAL_USED_BYTES=""
SPACE_TOTAL_USED_GIB=""
SPACE_PER_HOST_USED_BYTES=""
SPACE_PER_HOST_USED_GIB=""

declare -A LAST_HOST_STATUS=()
declare -A LAST_HOST_TS=()
declare -A LAST_HOST_USED_BYTES=()
declare -A LAST_HOST_USED_GIB=()
declare -A PREV_HOST_USED_BYTES=()
declare -A PREV_HOST_USED_GIB=()

usage() {
	echo "Usage: $0 -n nickname [-e epoch]"
}

while getopts "n:e:" opt; do
	case $opt in
	n)
		nickname=${OPTARG}
		;;
	e)
		epoch=${OPTARG}
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

if ! [[ "${epoch}" =~ ^[0-9]+$ ]] || [[ "${epoch}" -le 0 ]]; then
	echo "epoch must be a positive integer, got: ${epoch}" >&2
	exit 1
fi

if [[ -n "${DESIGN_EXP_HOSTS:-}" ]]; then
	read -r -a hosts <<< "${DESIGN_EXP_HOSTS}"
fi

if [[ ${#hosts[@]} -lt 1 ]]; then
	echo "hosts must contain at least one host." >&2
	exit 1
fi

results_dir="${script_dir}/${nickname}_${date_time}"
mkdir -p "${results_dir}"
summary_file="${results_dir}/space_occupation_summary.tsv"
host_file="${results_dir}/space_occupation_hosts.tsv"

stop_servers() {
	local host
	for host in "${hosts[@]}"; do
		ssh "${host}" "sudo pkill -f 'tebis_server/tebis_server -b ${backup_method}'" >/dev/null 2>&1 || true
	done
}

read_space_occupation_macro_state() {
	if [[ ! -f "${time_count_source}" ]]; then
		echo "time_count.c not found: ${time_count_source}" >&2
		return 1
	fi

	if grep -qE '^[[:space:]]*#define[[:space:]]+SPACE_OCCUPATION([[:space:]]|$)' "${time_count_source}"; then
		echo "enabled"
		return 0
	fi

	if grep -qE '^[[:space:]]*//[[:space:]]*#define[[:space:]]+SPACE_OCCUPATION([[:space:]]|$)' "${time_count_source}"; then
		echo "disabled"
		return 0
	fi

	echo "SPACE_OCCUPATION macro not found in ${time_count_source}" >&2
	return 1
}

set_space_occupation_macro_state() {
	local desired_state=$1

	case "${desired_state}" in
	enabled)
		if grep -qE '^[[:space:]]*#define[[:space:]]+SPACE_OCCUPATION([[:space:]]|$)' "${time_count_source}"; then
			grep -E '^[[:space:]]*#define[[:space:]]+SPACE_OCCUPATION([[:space:]]|$)' "${time_count_source}" >&2
			return 0
		fi
		if ! grep -qE '^[[:space:]]*//[[:space:]]*#define[[:space:]]+SPACE_OCCUPATION([[:space:]]|$)' "${time_count_source}"; then
			echo "Cannot enable SPACE_OCCUPATION: commented macro not found in ${time_count_source}" >&2
			return 1
		fi
		sed -i -E \
			'0,/^[[:space:]]*\/\/[[:space:]]*#define[[:space:]]+SPACE_OCCUPATION([[:space:]]|$)/s//#define SPACE_OCCUPATION/' \
			"${time_count_source}"
		;;
	disabled)
		if grep -qE '^[[:space:]]*//[[:space:]]*#define[[:space:]]+SPACE_OCCUPATION([[:space:]]|$)' "${time_count_source}"; then
			grep -E '^[[:space:]]*//[[:space:]]*#define[[:space:]]+SPACE_OCCUPATION([[:space:]]|$)' "${time_count_source}" >&2
			return 0
		fi
		if ! grep -qE '^[[:space:]]*#define[[:space:]]+SPACE_OCCUPATION([[:space:]]|$)' "${time_count_source}"; then
			echo "Cannot disable SPACE_OCCUPATION: enabled macro not found in ${time_count_source}" >&2
			return 1
		fi
		sed -i -E \
			'0,/^[[:space:]]*#define[[:space:]]+SPACE_OCCUPATION([[:space:]]|$)/s//\/\/#define SPACE_OCCUPATION/' \
			"${time_count_source}"
		;;
	*)
		echo "Unsupported SPACE_OCCUPATION state: ${desired_state}" >&2
		return 1
		;;
	esac

	grep -E '^[[:space:]]*(//[[:space:]]*)?#define[[:space:]]+SPACE_OCCUPATION([[:space:]]|$)' "${time_count_source}" >&2
}

sync_and_build_all_nodes() {
	local cmake_args=("$@")

	echo "Syncing source and building locally/remotely via ./scp.sh ..." >&2
	(
		cd "${project_dir}"
		./scp.sh "${cmake_args[@]}"
	)
}

enable_space_occupation_for_experiment() {
	echo "Building with SPACE_OCCUPATION and syncing..." >&2
	sync_and_build_all_nodes -DSPACE_OCCUPATION=ON
	space_occupation_build_enabled=1
}

restore_space_occupation_macro() {
	if [[ ${space_occupation_build_enabled} -eq 0 ]]; then
		return 0
	fi

	echo "Rebuilding without SPACE_OCCUPATION and syncing..." >&2
	sync_and_build_all_nodes
	space_occupation_build_enabled=0
}

cleanup() {
	local cleanup_failed=0

	if [[ ${servers_may_be_running} -eq 1 ]]; then
		echo "Stopping tebis servers from exp2-space cleanup..." >&2
		stop_servers
		servers_may_be_running=0
	fi

	if ! restore_space_occupation_macro; then
		cleanup_failed=1
	fi

	if [[ ${cleanup_failed} -ne 0 ]]; then
		echo "Cleanup finished with restore/build errors." >&2
	fi
}

trap cleanup EXIT

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

extract_host_space_usage() {
	local host=$1
	local remote_log=$2
	local remote_tail

	remote_tail=$(ssh "${host}" "
		if [ ! -e '${remote_log}' ]; then
			exit 3
		fi
		if [ ! -r '${remote_log}' ]; then
			exit 4
		fi
		grep -F '[space_counter] space occupation' '${remote_log}' | tail -n 2 || true
	") || return $?

	if [[ -z "${remote_tail}" ]]; then
		return 2
	fi

	awk '
	/\[space_counter\][[:space:]]+space occupation/ {
		ts = $1
		bytes = ""
		gib = ""

		if (match($0, /used_bytes=[0-9]+/)) {
			bytes = substr($0, RSTART, RLENGTH)
			sub(/^used_bytes=/, "", bytes)
		}
		if (match($0, /used_gib=[0-9]+(\.[0-9]+)?/)) {
			gib = substr($0, RSTART, RLENGTH)
			sub(/^used_gib=/, "", gib)
		}

		if (bytes != "" && gib != "") {
			prev_ts = last_ts
			prev_bytes = last_bytes
			prev_gib = last_gib
			last_ts = ts
			last_bytes = bytes
			last_gib = gib
			cnt++
		}
	}
	END {
		if (cnt == 0) exit 2
		if (cnt == 1) {
			printf "ONE\t%s\t%s\t%s\tNA\tNA\n", last_ts, last_bytes, last_gib
		} else {
			printf "OK\t%s\t%s\t%s\t%s\t%s\n", last_ts, last_bytes, last_gib, prev_bytes, prev_gib
		}
	}
	' <<< "${remote_tail}"
}

collect_space_usage() {
	local remote_log=$1
	local verbose_fail=${2:-1}
	local host
	local host_line
	local row_status
	local last_ts
	local last_bytes
	local last_gib
	local prev_bytes
	local prev_gib
	local host_stable
	local all_hosts_stable=1
	local rc
	local total_bytes=0
	local total_gib="0.00"
	local per_host_bytes=""
	local per_host_gib=""

	SPACE_TOTAL_USED_BYTES=""
	SPACE_TOTAL_USED_GIB=""
	SPACE_PER_HOST_USED_BYTES=""
	SPACE_PER_HOST_USED_GIB=""
	SPACE_TIMESTAMP="PER_HOST_LAST"

	for host in "${hosts[@]}"; do
		if host_line=$(extract_host_space_usage "${host}" "${remote_log}"); then
			:
		else
			rc=$?
			if [[ ${verbose_fail} -eq 1 ]]; then
				if [[ ${rc} -eq 3 ]]; then
					echo "Remote log not found on host=${host}: ${remote_log}" >&2
				elif [[ ${rc} -eq 4 ]]; then
					echo "Remote log exists but is not readable on host=${host}: ${remote_log}" >&2
				elif [[ ${rc} -eq 2 ]]; then
					echo "No space_counter lines in remote log on host=${host}: ${remote_log}" >&2
				else
					echo "Failed to parse remote log on host=${host}: ${remote_log} (rc=${rc})" >&2
				fi
				ssh "${host}" "echo '--- tail -n 5 ${remote_log} ---' >&2; tail -n 5 '${remote_log}' 2>/dev/null >&2 || true; echo '--- grep space_counter tail -n 5 ---' >&2; grep -F '[space_counter] space occupation' '${remote_log}' 2>/dev/null | tail -n 5 >&2 || true" || true
			fi
			return 1
		fi

		IFS=$'\t' read -r row_status last_ts last_bytes last_gib prev_bytes prev_gib <<< "${host_line}"

		host_stable="UNSTABLE"
		if [[ "${row_status}" == "OK" && "${last_bytes}" == "${prev_bytes}" && "${last_gib}" == "${prev_gib}" ]]; then
			host_stable="STABLE"
		else
			all_hosts_stable=0
		fi

		LAST_HOST_STATUS["${host}"]=${host_stable}
		LAST_HOST_TS["${host}"]=${last_ts}
		LAST_HOST_USED_BYTES["${host}"]=${last_bytes}
		LAST_HOST_USED_GIB["${host}"]=${last_gib}
		PREV_HOST_USED_BYTES["${host}"]=${prev_bytes}
		PREV_HOST_USED_GIB["${host}"]=${prev_gib}

		total_bytes=$((total_bytes + 10#${last_bytes}))
		total_gib=$(awk -v acc="${total_gib}" -v val="${last_gib}" 'BEGIN { printf "%.2f", acc + val }')

		per_host_bytes="${per_host_bytes}${per_host_bytes:+,}${host}:${last_bytes}"
		per_host_gib="${per_host_gib}${per_host_gib:+,}${host}:${last_gib}"
	done

	SPACE_TOTAL_USED_BYTES=${total_bytes}
	SPACE_TOTAL_USED_GIB=${total_gib}
	SPACE_PER_HOST_USED_BYTES=${per_host_bytes}
	SPACE_PER_HOST_USED_GIB=${per_host_gib}

	if [[ ${all_hosts_stable} -eq 1 ]]; then
		SPACE_STATUS="STABLE"
	else
		SPACE_STATUS="UNSTABLE"
	fi
}

wait_until_stable_space_usage() {
	local remote_log=$1
	local start_ts
	local now_ts
	local elapsed_sec
	local attempt=0

	start_ts=$(date +%s)

	while true; do
		attempt=$((attempt + 1))
		if collect_space_usage "${remote_log}" 0; then
			if [[ "${SPACE_STATUS}" == "STABLE" ]]; then
				echo "Space occupation stable: total_used_gib=${SPACE_TOTAL_USED_GIB}, total_used_bytes=${SPACE_TOTAL_USED_BYTES}" >&2
				return 0
			fi
			echo "Space occupation still changing (attempt=${attempt}), wait ${stable_check_interval_sec}s..." >&2
		else
			echo "Space occupation not ready yet (attempt=${attempt}), wait ${stable_check_interval_sec}s..." >&2
		fi

		now_ts=$(date +%s)
		elapsed_sec=$((now_ts - start_ts))
		if [[ ${stable_check_timeout_sec} -gt 0 && ${elapsed_sec} -ge ${stable_check_timeout_sec} ]]; then
			echo "Timed out waiting for space occupation to become stable after ${elapsed_sec}s." >&2
			collect_space_usage "${remote_log}" 1 || true
			return 1
		fi

		sleep "${stable_check_interval_sec}"
	done
}

write_host_rows() {
	local workload=$1
	local backup_label=$2
	local ep=$3
	local remote_log=$4
	local host

	for host in "${hosts[@]}"; do
		printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
			"${workload}" "${backup_label}" "${ep}" "${host}" "${LAST_HOST_STATUS[${host}]}" \
			"${LAST_HOST_TS[${host}]}" "${LAST_HOST_USED_BYTES[${host}]}" "${LAST_HOST_USED_GIB[${host}]}" \
			"${PREV_HOST_USED_BYTES[${host}]}" "${PREV_HOST_USED_GIB[${host}]}" "${remote_log}" \
			>> "${host_file}"
	done
}

enable_space_occupation_for_experiment

printf "workload\tbackup_method\tepoch\tstatus\ttotal_used_bytes\ttotal_used_gib\tper_host_used_bytes\tper_host_used_gib\tserver_log_path\n" > "${summary_file}"
printf "workload\tbackup_method\tepoch\thost\tstatus\tlast_timestamp\tused_bytes\tused_gib\tprev_used_bytes\tprev_used_gib\tserver_log_path\n" > "${host_file}"

echo "Running exp2 space occupation with epoch=${epoch}, backups=${backup_methods[*]}, workloads=${workloads[*]}"

for workload in "${workloads[@]}"; do
	for backup_label in "${backup_methods[@]}"; do
		echo -e "\n*********Running exp2-space workload=${workload}, backup=${backup_label}*********"

		read -r backup_method regions_file <<< "$(resolve_backup_config "${backup_label}")"

		for ((ep = 1; ep <= epoch; ep++)); do
			run_tag="${date_time}_ep$(printf "%02d" "${ep}")"
			output_base="ycsb_log/tmp_log/${nickname}_${backup_label}_${workload}_thread_${server_threads}_${client_threads}"
			output_path="${project_dir}/${output_base}_${run_tag}"
			server_log_path="/tmp/lijinming_tebis_server_${backup_label}_${workload}_${run_tag}.log"

			echo "Run ${ep}/${epoch}: backup=${backup_label}, workload=${workload}, tag=${run_tag}" >&2

			"${basic_script_dir}/run_cluster.sh" -b "${backup_method}" -g "${gc_method}" -l "${load_times}" \
				-r "${run_times}" -u "${ops_higher_threshold}" -w "${workload}" -o "${output_base}" \
				-d "${run_tag}" -t "${server_threads}" -c "${client_threads}" -f "${regions_file}" -k \
				-s "${server_log_path}"

			servers_may_be_running=1

			ops_file="${output_path}/run_${workload}/ops.txt"
			filter_ops_file "${ops_file}"

			wait_until_stable_space_usage "${server_log_path}"
			stop_servers
			servers_may_be_running=0

			printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
				"${workload}" "${backup_label}" "${ep}" "${SPACE_STATUS}" \
				"${SPACE_TOTAL_USED_BYTES}" "${SPACE_TOTAL_USED_GIB}" \
				"${SPACE_PER_HOST_USED_BYTES}" "${SPACE_PER_HOST_USED_GIB}" "${server_log_path}" \
				>> "${summary_file}"
			echo "Space occupation result: workload=${workload}, backup=${backup_label}, epoch=${ep}, total_used_gib=${SPACE_TOTAL_USED_GIB}" >&2

			write_host_rows "${workload}" "${backup_label}" "${ep}" "${server_log_path}"

			sleep 10
		done
	done
done

echo ""
echo "Saved space occupation summary: ${summary_file}"
echo "Saved per-host space occupation rows: ${host_file}"
echo ""
cat "${summary_file}"
