#!/usr/bin/env bash

set -euo pipefail

nickname=""
project_dir="/home/lijinming/tebis"
basic_script_dir="${project_dir}/ycsb_log/scripts"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

epoch=1
backup_label="offline_coding"
backup_method="offline_coding"
regions_file="regions_file_cross"
gc_method="sync"
valid_segments_threshold_values=(
	0
	1
	2
	3
)
high_amplification_power_values=(
	0.2
)
exp5_build_cmake_args=(
	-DHIGH_AMPLIFICATION_AWARE=ON
	-DSPACE_OCCUPATION=ON
	-DCOLD_LOG_SEPARATION=ON
)
workloads=(
	a
)

load_times=100000000
run_times=1500000000
ops_lower_threshold=200000000
ops_higher_threshold=2000000000
server_threads=4
client_threads=16
date_time=$(date +%Y%m%d_%H%M%S)
stable_check_interval_sec=200
stable_check_timeout_sec=0
servers_may_be_running=0
high_amplification_build_enabled=0
valid_segments_header="${project_dir}/tebis_server/offline_coding/coding_region_desc.h"
high_amplification_source="${project_dir}/tebis_server/offline_coding/sync_gc_primary.c"
default_valid_segments_threshold=""
current_valid_segments_threshold=""
default_high_amplification_power=""
current_high_amplification_power=""

results_dir=""
summary_file=""
host_file=""

hosts=(
	10.118.0.227
	10.118.0.28
	10.118.0.229
	10.118.0.30
	10.118.0.31
	10.118.0.32
)

SPACE_STATUS=""
SPACE_TOTAL_USED_BYTES=0
SPACE_TOTAL_USED_GIB="0.00"
SPACE_PER_HOST_USED_BYTES=""
SPACE_PER_HOST_USED_GIB=""
DISK_TOTAL_WRITE_BYTES=""
DISK_TOTAL_WRITE_GIB=""
DISK_PER_HOST_WRITE_BYTES=""
DISK_PER_HOST_WRITE_GIB=""
DISK_PER_HOST_WRITE_PIDS=""

declare -A LAST_HOST_SPACE_STATUS=()
declare -A LAST_HOST_SPACE_TS=()
declare -A LAST_HOST_SPACE_USED_BYTES=()
declare -A LAST_HOST_SPACE_USED_GIB=()
declare -A PREV_HOST_SPACE_USED_BYTES=()
declare -A PREV_HOST_SPACE_USED_GIB=()
declare -A LAST_HOST_DISK_WRITE_PIDS=()
declare -A LAST_HOST_DISK_WRITE_BYTES=()
declare -A LAST_HOST_DISK_WRITE_GIB=()

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

if [[ -n "${EXP5_GC_HOSTS:-}" ]]; then
	read -r -a hosts <<< "${EXP5_GC_HOSTS}"
fi

if [[ ${#hosts[@]} -ne 6 ]]; then
	echo "This script expects exactly 6 hosts, got: ${#hosts[@]}" >&2
	exit 1
fi

results_dir="${script_dir}/${nickname}_${date_time}"
mkdir -p "${results_dir}"
summary_file="${results_dir}/exp5_gc_summary.tsv"
host_file="${results_dir}/exp5_gc_hosts.tsv"

sync_and_build_all_nodes() {
	local cmake_args=("$@")

	echo "Syncing source and building locally/remotely via scripts/scp.sh ${cmake_args[*]} ..." >&2
	(
		cd "${project_dir}"
		"${project_dir}/scp.sh" "${cmake_args[@]}"
	)
}

read_valid_segments_threshold() {
	if [[ ! -f "${valid_segments_header}" ]]; then
		echo "coding_region_desc.h not found: ${valid_segments_header}" >&2
		return 1
	fi

	awk '/^#define[[:space:]]+VALID_SEGMENTS_THRESHOLD[[:space:]]+[0-9]+/ { print $3; exit }' "${valid_segments_header}"
}

set_valid_segments_threshold() {
	local threshold=$1

	if [[ ! -f "${valid_segments_header}" ]]; then
		echo "coding_region_desc.h not found: ${valid_segments_header}" >&2
		return 1
	fi

	if ! [[ "${threshold}" =~ ^[0-9]+$ ]]; then
		echo "VALID_SEGMENTS_THRESHOLD must be a non-negative integer, got: ${threshold}" >&2
		return 1
	fi

	if ! grep -qE '^#define[[:space:]]+VALID_SEGMENTS_THRESHOLD[[:space:]]+[0-9]+' "${valid_segments_header}"; then
		echo "VALID_SEGMENTS_THRESHOLD macro not found in ${valid_segments_header}" >&2
		return 1
	fi

	sed -i -E \
		"s|^#define[[:space:]]+VALID_SEGMENTS_THRESHOLD[[:space:]]+[0-9]+$|#define VALID_SEGMENTS_THRESHOLD ${threshold}|" \
		"${valid_segments_header}"
	grep -E '^#define[[:space:]]+VALID_SEGMENTS_THRESHOLD[[:space:]]+[0-9]+' "${valid_segments_header}" >&2
	current_valid_segments_threshold=${threshold}
}

read_high_amplification_power() {
	if [[ ! -f "${high_amplification_source}" ]]; then
		echo "sync_gc_primary.c not found: ${high_amplification_source}" >&2
		return 1
	fi

	sed -n -E 's|^[[:space:]]*static[[:space:]]+const[[:space:]]+float[[:space:]]+high_amplification_power[[:space:]]*=[[:space:]]*([0-9]+(\.[0-9]+)?)[fF][[:space:]]*;[[:space:]]*$|\1|p' \
		"${high_amplification_source}" | head -n 1
}

set_high_amplification_power() {
	local power=$1

	if [[ ! -f "${high_amplification_source}" ]]; then
		echo "sync_gc_primary.c not found: ${high_amplification_source}" >&2
		return 1
	fi

	if ! [[ "${power}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		echo "high_amplification_power must be a non-negative float, got: ${power}" >&2
		return 1
	fi

	if ! grep -qE '^[[:space:]]*static[[:space:]]+const[[:space:]]+float[[:space:]]+high_amplification_power[[:space:]]*=[[:space:]]*[0-9]+(\.[0-9]+)?[fF][[:space:]]*;' "${high_amplification_source}"; then
		echo "high_amplification_power constant not found in ${high_amplification_source}" >&2
		return 1
	fi

	sed -i -E \
		"s|^[[:space:]]*static[[:space:]]+const[[:space:]]+float[[:space:]]+high_amplification_power[[:space:]]*=[[:space:]]*[0-9]+(\.[0-9]+)?[fF][[:space:]]*;[[:space:]]*$|static const float high_amplification_power = ${power}f;|" \
		"${high_amplification_source}"
	grep -E '^[[:space:]]*static[[:space:]]+const[[:space:]]+float[[:space:]]+high_amplification_power[[:space:]]*=[[:space:]]*[0-9]+(\.[0-9]+)?[fF][[:space:]]*;' "${high_amplification_source}" >&2
	current_high_amplification_power=${power}
}

enable_exp5_build() {
	echo "Building with exp5 cmake args: ${exp5_build_cmake_args[*]}" >&2
	sync_and_build_all_nodes "${exp5_build_cmake_args[@]}"
	high_amplification_build_enabled=1
}

ensure_exp5_build_for_params() {
	local threshold=$1
	local power=$2

	if [[ "${current_valid_segments_threshold}" == "${threshold}" &&
		"${current_high_amplification_power}" == "${power}" &&
		${high_amplification_build_enabled} -eq 1 ]]; then
		echo "VALID_SEGMENTS_THRESHOLD already ${threshold} and high_amplification_power already ${power}, skipping source sync/build." >&2
		return 0
	fi

	echo "Setting VALID_SEGMENTS_THRESHOLD=${threshold}, high_amplification_power=${power} and building exp5_gc flags..." >&2
	set_valid_segments_threshold "${threshold}"
	set_high_amplification_power "${power}"
	enable_exp5_build
}

restore_default_valid_segments_threshold() {
	if [[ -z "${default_valid_segments_threshold}" ]]; then
		return 0
	fi

	if [[ "${current_valid_segments_threshold}" == "${default_valid_segments_threshold}" ]]; then
		return 0
	fi

	echo "Restoring VALID_SEGMENTS_THRESHOLD=${default_valid_segments_threshold}..." >&2
	set_valid_segments_threshold "${default_valid_segments_threshold}"
}

restore_default_high_amplification_power() {
	if [[ -z "${default_high_amplification_power}" ]]; then
		return 0
	fi

	if [[ "${current_high_amplification_power}" == "${default_high_amplification_power}" ]]; then
		return 0
	fi

	echo "Restoring high_amplification_power=${default_high_amplification_power}..." >&2
	set_high_amplification_power "${default_high_amplification_power}"
}

restore_default_build() {
	if [[ ${high_amplification_build_enabled} -eq 0 ]]; then
		return 0
	fi

	echo "Rebuilding with default scp.sh flags after exp5_gc..." >&2
	sync_and_build_all_nodes
	high_amplification_build_enabled=0
}

stop_servers() {
	local host
	for host in "${hosts[@]}"; do
		ssh "${host}" "sudo pkill -f 'tebis_server/tebis_server -b ${backup_method}'" >/dev/null 2>&1 || true
	done
}

cleanup() {
	local cleanup_failed=0

	if [[ ${servers_may_be_running} -eq 1 ]]; then
		echo "Stopping tebis servers from exp5_gc cleanup..." >&2
		stop_servers
		servers_may_be_running=0
	fi

	if ! restore_default_valid_segments_threshold; then
		cleanup_failed=1
	fi

	if ! restore_default_high_amplification_power; then
		cleanup_failed=1
	fi

	if ! restore_default_build; then
		cleanup_failed=1
	fi

	if [[ ${cleanup_failed} -ne 0 ]]; then
		echo "Cleanup finished with restore/build errors." >&2
	fi
}

trap cleanup EXIT

filter_ops_file() {
	local ops_file=$1
	local tmp_file

	if [[ ! -f "${ops_file}" ]]; then
		echo "Skip filtering, file not found: ${ops_file}" >&2
		return
	fi

	tmp_file=$(mktemp)
	awk -v lower_threshold="${ops_lower_threshold}" -v higher_threshold="${ops_higher_threshold}" '
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

extract_host_disk_write_usage() {
	local host=$1
	local remote_rows
	local pid
	local bytes
	local pids=""
	local total_bytes=0
	local total_gib
	local count=0

	remote_rows=$(ssh "${host}" "
		pids=\$(pidof tebis_server 2>/dev/null || true)
		if [ -z \"\${pids}\" ]; then
			pids=\$(pgrep -f 'tebis_server/tebis_server -b ${backup_method}' 2>/dev/null || true)
		fi
		if [ -z \"\${pids}\" ]; then
			exit 2
		fi
		for pid in \${pids}; do
			sudo cat \"/proc/\${pid}/io\" 2>/dev/null | awk -v pid=\"\${pid}\" '\$1 == \"write_bytes:\" { print pid \"\\t\" \$2 }'
		done
	") || return $?

	if [[ -z "${remote_rows}" ]]; then
		return 2
	fi

	while IFS=$'\t' read -r pid bytes; do
		if ! [[ "${pid}" =~ ^[0-9]+$ && "${bytes}" =~ ^[0-9]+$ ]]; then
			continue
		fi
		pids="${pids}${pids:+,}${pid}"
		total_bytes=$((total_bytes + 10#${bytes}))
		count=$((count + 1))
	done <<< "${remote_rows}"

	if [[ ${count} -eq 0 ]]; then
		return 2
	fi

	total_gib=$(awk -v bytes="${total_bytes}" 'BEGIN { printf "%.2f", bytes / 1024 / 1024 / 1024 }')
	printf "%s\t%s\t%s\n" "${pids}" "${total_bytes}" "${total_gib}"
}

collect_disk_write_usage() {
	local host
	local host_line
	local pids
	local bytes
	local gib
	local total_bytes=0
	local per_host_bytes=""
	local per_host_gib=""
	local per_host_pids=""
	local rc

	DISK_TOTAL_WRITE_BYTES=""
	DISK_TOTAL_WRITE_GIB=""
	DISK_PER_HOST_WRITE_BYTES=""
	DISK_PER_HOST_WRITE_GIB=""
	DISK_PER_HOST_WRITE_PIDS=""

	for host in "${hosts[@]}"; do
		if host_line=$(extract_host_disk_write_usage "${host}"); then
			:
		else
			rc=$?
			if [[ ${rc} -eq 2 ]]; then
				echo "No running tebis_server write_bytes found on host=${host}; collect before killing servers." >&2
			else
				echo "Failed to read /proc/<tebis_server-pid>/io on host=${host} (rc=${rc})." >&2
			fi
			return 1
		fi

		IFS=$'\t' read -r pids bytes gib <<< "${host_line}"

		LAST_HOST_DISK_WRITE_PIDS["${host}"]=${pids}
		LAST_HOST_DISK_WRITE_BYTES["${host}"]=${bytes}
		LAST_HOST_DISK_WRITE_GIB["${host}"]=${gib}

		total_bytes=$((total_bytes + 10#${bytes}))
		per_host_bytes="${per_host_bytes}${per_host_bytes:+,}${host}:${bytes}"
		per_host_gib="${per_host_gib}${per_host_gib:+,}${host}:${gib}"
		per_host_pids="${per_host_pids}${per_host_pids:+,}${host}:${pids}"
	done

	DISK_TOTAL_WRITE_BYTES=${total_bytes}
	DISK_TOTAL_WRITE_GIB=$(awk -v bytes="${total_bytes}" 'BEGIN { printf "%.2f", bytes / 1024 / 1024 / 1024 }')
	DISK_PER_HOST_WRITE_BYTES=${per_host_bytes}
	DISK_PER_HOST_WRITE_GIB=${per_host_gib}
	DISK_PER_HOST_WRITE_PIDS=${per_host_pids}
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
		matches=\$(grep -F '[space_counter] space occupation' '${remote_log}' || true)
		if [ -z \"\${matches}\" ]; then
			exit 2
		fi
		printf '%s\n' \"\${matches}\" | tail -n 1
	") || return $?

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
			last_ts = ts
			last_bytes = bytes
			last_gib = gib
			cnt++
		}
	}
	END {
		if (cnt == 0) exit 2
		printf "OK\t%s\t%s\t%s\n", last_ts, last_bytes, last_gib
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
	local -A next_status=()
	local -A next_ts=()
	local -A next_bytes=()
	local -A next_gib=()
	local -A next_prev_bytes=()
	local -A next_prev_gib=()

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
					echo "Failed to parse space_counter on host=${host}: ${remote_log} (rc=${rc})" >&2
				fi
				ssh "${host}" "echo '--- tail -n 5 ${remote_log} ---' >&2; tail -n 5 '${remote_log}' 2>/dev/null >&2 || true; echo '--- grep space_counter tail -n 5 ---' >&2; grep -F '[space_counter] space occupation' '${remote_log}' 2>/dev/null | tail -n 5 >&2 || true" || true
			fi
			return 1
		fi

		IFS=$'\t' read -r row_status last_ts last_bytes last_gib <<< "${host_line}"
		prev_bytes=${LAST_HOST_SPACE_USED_BYTES[${host}]:-NA}
		prev_gib=${LAST_HOST_SPACE_USED_GIB[${host}]:-NA}

		host_stable="UNSTABLE"
		if [[ "${row_status}" == "OK" && "${last_bytes}" == "${prev_bytes}" ]]; then
			host_stable="STABLE"
		else
			all_hosts_stable=0
		fi

		next_status["${host}"]=${host_stable}
		next_ts["${host}"]=${last_ts}
		next_bytes["${host}"]=${last_bytes}
		next_gib["${host}"]=${last_gib}
		next_prev_bytes["${host}"]=${prev_bytes}
		next_prev_gib["${host}"]=${prev_gib}

		total_bytes=$((total_bytes + 10#${last_bytes}))
		total_gib=$(awk -v acc="${total_gib}" -v val="${last_gib}" 'BEGIN { printf "%.2f", acc + val }')
		per_host_bytes="${per_host_bytes}${per_host_bytes:+,}${host}:${last_bytes}"
		per_host_gib="${per_host_gib}${per_host_gib:+,}${host}:${last_gib}"
	done

	for host in "${hosts[@]}"; do
		LAST_HOST_SPACE_STATUS["${host}"]=${next_status[${host}]}
		LAST_HOST_SPACE_TS["${host}"]=${next_ts[${host}]}
		LAST_HOST_SPACE_USED_BYTES["${host}"]=${next_bytes[${host}]}
		LAST_HOST_SPACE_USED_GIB["${host}"]=${next_gib[${host}]}
		PREV_HOST_SPACE_USED_BYTES["${host}"]=${next_prev_bytes[${host}]}
		PREV_HOST_SPACE_USED_GIB["${host}"]=${next_prev_gib[${host}]}
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

reset_space_snapshots() {
	SPACE_STATUS="NOT_READY"
	SPACE_TOTAL_USED_BYTES=0
	SPACE_TOTAL_USED_GIB="0.00"
	SPACE_PER_HOST_USED_BYTES=""
	SPACE_PER_HOST_USED_GIB=""

	LAST_HOST_SPACE_STATUS=()
	LAST_HOST_SPACE_TS=()
	LAST_HOST_SPACE_USED_BYTES=()
	LAST_HOST_SPACE_USED_GIB=()
	PREV_HOST_SPACE_USED_BYTES=()
	PREV_HOST_SPACE_USED_GIB=()
}

wait_until_stable_space_usage() {
	local remote_log=$1
	local start_ts
	local now_ts
	local elapsed_sec
	local attempt=0

	reset_space_snapshots
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
	local valid_segments_threshold=$1
	local high_amplification_power=$2
	local workload=$3
	local ep=$4
	local remote_log=$5
	local host

	for host in "${hosts[@]}"; do
		printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
			"${valid_segments_threshold}" "${high_amplification_power}" "${workload}" "${backup_label}" "${gc_method}" "${ep}" "${host}" \
			"${LAST_HOST_SPACE_STATUS[${host}]}" "${LAST_HOST_SPACE_TS[${host}]}" \
			"${LAST_HOST_SPACE_USED_BYTES[${host}]}" "${LAST_HOST_SPACE_USED_GIB[${host}]}" \
			"${PREV_HOST_SPACE_USED_BYTES[${host}]}" "${PREV_HOST_SPACE_USED_GIB[${host}]}" \
			"${LAST_HOST_DISK_WRITE_PIDS[${host}]}" "${LAST_HOST_DISK_WRITE_BYTES[${host}]}" \
			"${LAST_HOST_DISK_WRITE_GIB[${host}]}" \
			"${remote_log}" \
			>> "${host_file}"
	done
}

default_valid_segments_threshold=$(read_valid_segments_threshold)
if [[ -z "${default_valid_segments_threshold}" ]]; then
	echo "Failed to read default VALID_SEGMENTS_THRESHOLD from ${valid_segments_header}" >&2
	exit 1
fi
current_valid_segments_threshold=${default_valid_segments_threshold}

default_high_amplification_power=$(read_high_amplification_power)
if [[ -z "${default_high_amplification_power}" ]]; then
	echo "Failed to read default high_amplification_power from ${high_amplification_source}" >&2
	exit 1
fi
current_high_amplification_power=${default_high_amplification_power}

printf "valid_segments_threshold\thigh_amplification_power\tworkload\tbackup_method\tgc_method\tepoch\tspace_status\tspace_usage_bytes\tspace_usage_gib\tper_host_space_usage_bytes\tper_host_space_usage_gib\ttotal_disk_write_bytes\ttotal_disk_write_gib\tper_host_disk_write_bytes\tper_host_disk_write_gib\tper_host_disk_write_pids\tserver_log_path\n" > "${summary_file}"
printf "valid_segments_threshold\thigh_amplification_power\tworkload\tbackup_method\tgc_method\tepoch\thost\tspace_status\tspace_timestamp\tspace_usage_bytes\tspace_usage_gib\tprev_space_usage_bytes\tprev_space_usage_gib\tdisk_write_pids\tdisk_write_bytes\tdisk_write_gib\tserver_log_path\n" > "${host_file}"

echo "Running exp5_gc with epoch=${epoch}, backup=${backup_label}, gc=${gc_method}, valid_segments_thresholds=${valid_segments_threshold_values[*]}, high_amplification_powers=${high_amplification_power_values[*]}, workloads=${workloads[*]}"

for high_amplification_power in "${high_amplification_power_values[@]}"; do
	power_tag="hap${high_amplification_power//./p}"

	for valid_segments_threshold in "${valid_segments_threshold_values[@]}"; do
		ensure_exp5_build_for_params "${valid_segments_threshold}" "${high_amplification_power}"
		threshold_tag="vseg${valid_segments_threshold}"
		param_tag="${threshold_tag}_${power_tag}"

		for workload in "${workloads[@]}"; do
			for ((ep = 1; ep <= epoch; ep++)); do
				run_tag="${date_time}_${param_tag}_ep$(printf "%02d" "${ep}")"
				output_base="ycsb_log/tmp_log/${nickname}_${backup_label}_${gc_method}_${workload}_${param_tag}_thread_${server_threads}_${client_threads}"
				output_path="${project_dir}/${output_base}_${run_tag}"
				server_log_path="/tmp/lijinming_tebis_server_${backup_label}_${gc_method}_${workload}_${param_tag}_${run_tag}.log"

				echo -e "\n*********Running exp5_gc threshold=${valid_segments_threshold}, high_amplification_power=${high_amplification_power}, workload=${workload}, backup=${backup_label}, gc=${gc_method}, epoch=${ep}/${epoch}*********"

				servers_may_be_running=1
				"${basic_script_dir}/run_cluster.sh" -b "${backup_method}" -g "${gc_method}" -l "${load_times}" \
					-r "${run_times}" -u "${ops_higher_threshold}" -w "${workload}" -o "${output_base}" \
					-d "${run_tag}" -t "${server_threads}" -c "${client_threads}" -f "${regions_file}" -k \
					-s "${server_log_path}"

				ops_file="${output_path}/run_${workload}/ops.txt"
				filter_ops_file "${ops_file}"

				wait_until_stable_space_usage "${server_log_path}"
				collect_disk_write_usage

				printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
					"${valid_segments_threshold}" "${high_amplification_power}" "${workload}" "${backup_label}" "${gc_method}" "${ep}" \
					"${SPACE_STATUS}" \
					"${SPACE_TOTAL_USED_BYTES}" "${SPACE_TOTAL_USED_GIB}" \
					"${SPACE_PER_HOST_USED_BYTES}" "${SPACE_PER_HOST_USED_GIB}" \
					"${DISK_TOTAL_WRITE_BYTES}" "${DISK_TOTAL_WRITE_GIB}" \
					"${DISK_PER_HOST_WRITE_BYTES}" "${DISK_PER_HOST_WRITE_GIB}" "${DISK_PER_HOST_WRITE_PIDS}" \
					"${server_log_path}" \
					>> "${summary_file}"

				write_host_rows "${valid_segments_threshold}" "${high_amplification_power}" "${workload}" "${ep}" "${server_log_path}"

				echo "Exp5 result: threshold=${valid_segments_threshold}, high_amplification_power=${high_amplification_power}, epoch=${ep}, disk_write_gib=${DISK_TOTAL_WRITE_GIB}, space_usage_gib=${SPACE_TOTAL_USED_GIB}" >&2

				stop_servers
				servers_may_be_running=0

				sleep 10
			done
		done
	done
done

echo ""
echo "Saved exp5 summary: ${summary_file}"
echo "Saved per-host exp5 rows: ${host_file}"
echo ""
cat "${summary_file}"
