#!/usr/bin/env bash

set -euo pipefail

nickname=""
project_dir="/home/lijinming/tebis"
basic_script_dir="${project_dir}/ycsb_log/scripts"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

gc_method=none
backup_methods=(
	replication
	elect
	elect+
)
load_times=100000000
run_times=700000000
ops_lower_threshold=000000000
ops_higher_threshold=900000000
workloads=(
	load
)
server_threads=8
client_threads=16
date_time=$(date +%Y%m%d_%H%M%S)
stable_check_interval_sec=100
stable_check_timeout_sec=0
servers_may_be_running=0
current_backup_method=""

results_dir=""
summary_file=""
final_file=""

cluster_hosts=(
	10.118.0.227
	10.118.0.28
	10.118.0.229
	10.118.0.30
	10.118.0.31
	10.118.0.32
)

OVERHEAD_STATUS=""
OVERHEAD_TIMESTAMP="PER_HOST_LAST"
TEBIS_PRIMARY_DATA_WRITE_BYTES=0
TEBIS_REPLICA_DATA_WRITE_BYTES=0
ELECT_PRIMARY_READ_BYTES=0
ELECT_LEADER_PARITY_READ_BYTES=0
ELECT_LEADER_PARITY_WRITE_BYTES=0
ELECT_OTHER_PARITY_WRITE_BYTES=0
TEBIS_PRIMARY_DATA_WRITE_GB="0"
TEBIS_REPLICA_DATA_WRITE_GB="0"
ELECT_PRIMARY_READ_GB="0"
ELECT_LEADER_PARITY_READ_GB="0"
ELECT_LEADER_PARITY_WRITE_GB="0"
ELECT_OTHER_PARITY_WRITE_GB="0"

declare -A LAST_HOST_STATUS=()
declare -A LAST_HOST_TEBIS_TS=()
declare -A LAST_HOST_ELECT_TS=()
declare -A LAST_HOST_PRIMARY_DATA_WRITE_BYTES=()
declare -A LAST_HOST_REPLICA_DATA_WRITE_BYTES=()
declare -A LAST_HOST_PRIMARY_READ_BYTES=()
declare -A LAST_HOST_LEADER_PARITY_READ_BYTES=()
declare -A LAST_HOST_LEADER_PARITY_WRITE_BYTES=()
declare -A LAST_HOST_OTHER_PARITY_WRITE_BYTES=()
declare -A LAST_HOST_PRIMARY_DATA_WRITE_GB=()
declare -A LAST_HOST_REPLICA_DATA_WRITE_GB=()
declare -A LAST_HOST_PRIMARY_READ_GB=()
declare -A LAST_HOST_LEADER_PARITY_READ_GB=()
declare -A LAST_HOST_LEADER_PARITY_WRITE_GB=()
declare -A LAST_HOST_OTHER_PARITY_WRITE_GB=()

declare -A FINAL_HOST_STATUS=()
declare -A FINAL_HOST_TEBIS_TS=()
declare -A FINAL_HOST_ELECT_TS=()
declare -A FINAL_HOST_PRIMARY_DATA_WRITE_BYTES=()
declare -A FINAL_HOST_REPLICA_DATA_WRITE_BYTES=()
declare -A FINAL_HOST_PRIMARY_READ_BYTES=()
declare -A FINAL_HOST_LEADER_PARITY_READ_BYTES=()
declare -A FINAL_HOST_LEADER_PARITY_WRITE_BYTES=()
declare -A FINAL_HOST_OTHER_PARITY_WRITE_BYTES=()
declare -A FINAL_HOST_PRIMARY_DATA_WRITE_GB=()
declare -A FINAL_HOST_REPLICA_DATA_WRITE_GB=()
declare -A FINAL_HOST_PRIMARY_READ_GB=()
declare -A FINAL_HOST_LEADER_PARITY_READ_GB=()
declare -A FINAL_HOST_LEADER_PARITY_WRITE_GB=()
declare -A FINAL_HOST_OTHER_PARITY_WRITE_GB=()

declare -A FINAL_RUN_STATUS=()
declare -A FINAL_RUN_PRIMARY_DATA_WRITE_BYTES=()
declare -A FINAL_RUN_REPLICA_DATA_WRITE_BYTES=()
declare -A FINAL_RUN_PRIMARY_READ_BYTES=()
declare -A FINAL_RUN_LEADER_PARITY_READ_BYTES=()
declare -A FINAL_RUN_LEADER_PARITY_WRITE_BYTES=()
declare -A FINAL_RUN_OTHER_PARITY_WRITE_BYTES=()
declare -A FINAL_RUN_PRIMARY_DATA_WRITE_GB=()
declare -A FINAL_RUN_REPLICA_DATA_WRITE_GB=()
declare -A FINAL_RUN_PRIMARY_READ_GB=()
declare -A FINAL_RUN_LEADER_PARITY_READ_GB=()
declare -A FINAL_RUN_LEADER_PARITY_WRITE_GB=()
declare -A FINAL_RUN_OTHER_PARITY_WRITE_GB=()

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

if [[ -n "${MOT_EXP1A_HOSTS:-}" ]]; then
	read -r -a cluster_hosts <<< "${MOT_EXP1A_HOSTS}"
fi

if [[ ${#cluster_hosts[@]} -ne 6 ]]; then
	echo "This script expects exactly 6 hosts, got: ${#cluster_hosts[@]}" >&2
	exit 1
fi

resolve_backup_config() {
	local backup_label=$1

	case "${backup_label}" in
	replication)
		echo "online_coding regions_file_elect"
		;;
	elect)
		echo "elect regions_file_elect"
		;;
	elect+)
		echo "elect regions_file_elect"
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
	replication)
		sync_and_build_all_nodes
		;;
	elect)
		sync_and_build_all_nodes -DELECT_MINIMIZE_NETWORK=OFF
		;;
	elect+)
		# Use scp.sh defaults, currently including -DELECT_MINIMIZE_NETWORK=ON.
		sync_and_build_all_nodes
		;;
	esac
}

stop_servers() {
	local backup_method=$1
	local host

	for host in "${cluster_hosts[@]}"; do
		ssh "${host}" "sudo pkill -f 'tebis_server/tebis_server -b ${backup_method}'" >/dev/null 2>&1 || true
	done
}

cleanup() {
	if [[ ${servers_may_be_running} -eq 1 && -n "${current_backup_method}" ]]; then
		echo "Stopping tebis servers from motivation_exp1a cleanup..." >&2
		stop_servers "${current_backup_method}"
		servers_may_be_running=0
	fi
}

trap cleanup EXIT

results_dir="${script_dir}/${nickname}_${date_time}"
mkdir -p "${results_dir}"
summary_file="${results_dir}/disk_overhead_runs.tsv"
final_file="${results_dir}/disk_overhead_final.tsv"

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

bytes_to_gb() {
	local bytes=$1
	awk -v b="${bytes}" 'BEGIN { printf "%.6f", b / (1024 * 1024 * 1024) }'
}

extract_host_last_two_tebis_disk_overhead() {
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
		grep -F '[TEBIS disk overhead]' '${remote_log}' | tail -n 2 || exit 2
	") || return $?

	if [[ -z "${remote_tail}" ]]; then
		return 2
	fi

	awk '
	BEGIN {
		cnt = 0
	}
	/\[TEBIS disk overhead\]/ {
		ts = $1
		primary_write = $0
		replica_write = $0
		sub(/^.*primary data write: /, "", primary_write)
		sub(/ B, replica data write:.*$/, "", primary_write)
		sub(/^.*replica data write: /, "", replica_write)
		sub(/ B.*$/, "", replica_write)
		if (primary_write ~ /^[0-9]+$/ && replica_write ~ /^[0-9]+$/) {
			prev_ts = last_ts
			prev_primary_write = last_primary_write
			prev_replica_write = last_replica_write
			last_ts = ts
			last_primary_write = primary_write + 0
			last_replica_write = replica_write + 0
			cnt++
		}
	}
	END {
		if (cnt == 0) {
			exit 2
		}
		if (cnt == 1) {
			printf "ONE\t%s\t%.0f\t%.0f\tNA\t0\t0\n",
				last_ts, last_primary_write, last_replica_write
			exit 0
		}
		printf "OK\t%s\t%.0f\t%.0f\t%s\t%.0f\t%.0f\n",
			last_ts, last_primary_write, last_replica_write,
			prev_ts, prev_primary_write, prev_replica_write
	}
	' <<< "${remote_tail}"
}

extract_host_last_two_elect_disk_overhead() {
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
		grep -F '[ELECT disk overhead]' '${remote_log}' | tail -n 2 || exit 2
	") || return $?

	if [[ -z "${remote_tail}" ]]; then
		return 2
	fi

	awk '
	BEGIN {
		cnt = 0
	}
	/\[ELECT disk overhead\]/ {
		ts = $1
		primary_read = $0
		leader_read = $0
		leader_write = $0
		other_write = $0
		sub(/^.*primary read: /, "", primary_read)
		sub(/ B, leader parity read:.*$/, "", primary_read)
		sub(/^.*leader parity read: /, "", leader_read)
		sub(/ B, leader parity write:.*$/, "", leader_read)
		sub(/^.*leader parity write: /, "", leader_write)
		sub(/ B, other parity write:.*$/, "", leader_write)
		sub(/^.*other parity write: /, "", other_write)
		sub(/ B.*$/, "", other_write)
		if (primary_read ~ /^[0-9]+$/ && leader_read ~ /^[0-9]+$/ &&
			leader_write ~ /^[0-9]+$/ && other_write ~ /^[0-9]+$/) {
			prev_ts = last_ts
			prev_primary_read = last_primary_read
			prev_leader_read = last_leader_read
			prev_leader_write = last_leader_write
			prev_other_write = last_other_write
			last_ts = ts
			last_primary_read = primary_read + 0
			last_leader_read = leader_read + 0
			last_leader_write = leader_write + 0
			last_other_write = other_write + 0
			cnt++
		}
	}
	END {
		if (cnt == 0) {
			exit 2
		}
		if (cnt == 1) {
			printf "ONE\t%s\t%.0f\t%.0f\t%.0f\t%.0f\tNA\t0\t0\t0\t0\n",
				last_ts, last_primary_read, last_leader_read, last_leader_write, last_other_write
			exit 0
		}
		printf "OK\t%s\t%.0f\t%.0f\t%.0f\t%.0f\t%s\t%.0f\t%.0f\t%.0f\t%.0f\n",
			last_ts, last_primary_read, last_leader_read, last_leader_write, last_other_write,
			prev_ts, prev_primary_read, prev_leader_read, prev_leader_write, prev_other_write
	}
	' <<< "${remote_tail}"
}

print_remote_log_debug() {
	local host=$1
	local remote_log=$2
	local pattern=$3

	ssh "${host}" "echo '--- tail -n 5 ${remote_log} ---' >&2; tail -n 5 '${remote_log}' 2>/dev/null >&2 || true; echo '--- grep ${pattern} tail -n 5 ---' >&2; grep -F '${pattern}' '${remote_log}' 2>/dev/null | tail -n 5 >&2 || true" || true
}

collect_last_two_disk_overhead() {
	local remote_log=$1
	local backup_label=$2
	local verbose_fail=${3:-1}
	local need_elect=1
	local host
	local tebis_line
	local elect_line
	local tebis_status
	local elect_status
	local last_tebis_ts
	local prev_tebis_ts
	local last_primary_write
	local last_replica_write
	local prev_primary_write
	local prev_replica_write
	local last_elect_ts
	local prev_elect_ts
	local last_primary_read
	local last_leader_read
	local last_leader_write
	local last_other_write
	local prev_primary_read
	local prev_leader_read
	local prev_leader_write
	local prev_other_write
	local host_stable
	local all_hosts_stable=1
	local rc

	if [[ "${backup_label}" == "replication" ]]; then
		need_elect=0
	fi

	TEBIS_PRIMARY_DATA_WRITE_BYTES=0
	TEBIS_REPLICA_DATA_WRITE_BYTES=0
	ELECT_PRIMARY_READ_BYTES=0
	ELECT_LEADER_PARITY_READ_BYTES=0
	ELECT_LEADER_PARITY_WRITE_BYTES=0
	ELECT_OTHER_PARITY_WRITE_BYTES=0
	OVERHEAD_TIMESTAMP="PER_HOST_LAST"

	for host in "${cluster_hosts[@]}"; do
		if tebis_line=$(extract_host_last_two_tebis_disk_overhead "${host}" "${remote_log}"); then
			:
		else
			rc=$?
			if [[ ${verbose_fail} -eq 1 ]]; then
				echo "Failed to parse TEBIS disk overhead on host=${host}: ${remote_log} (rc=${rc})" >&2
				print_remote_log_debug "${host}" "${remote_log}" "[TEBIS disk overhead]"
			fi
			return 1
		fi

		IFS=$'\t' read -r tebis_status last_tebis_ts last_primary_write last_replica_write prev_tebis_ts prev_primary_write prev_replica_write <<< "${tebis_line}"
		host_stable="UNSTABLE"
		if [[ "${tebis_status}" == "OK" &&
			"${last_primary_write}" == "${prev_primary_write}" &&
			"${last_replica_write}" == "${prev_replica_write}" ]]; then
			host_stable="STABLE"
		else
			all_hosts_stable=0
		fi

		last_elect_ts="N/A"
		last_primary_read=0
		last_leader_read=0
		last_leader_write=0
		last_other_write=0

		if [[ ${need_elect} -eq 1 ]]; then
			if elect_line=$(extract_host_last_two_elect_disk_overhead "${host}" "${remote_log}"); then
				:
			else
				rc=$?
				if [[ ${verbose_fail} -eq 1 ]]; then
					echo "Failed to parse ELECT disk overhead on host=${host}: ${remote_log} (rc=${rc})" >&2
					print_remote_log_debug "${host}" "${remote_log}" "[ELECT disk overhead]"
				fi
				return 1
			fi

			IFS=$'\t' read -r elect_status last_elect_ts last_primary_read last_leader_read last_leader_write last_other_write prev_elect_ts prev_primary_read prev_leader_read prev_leader_write prev_other_write <<< "${elect_line}"
			if [[ "${host_stable}" == "STABLE" &&
				"${elect_status}" == "OK" &&
				"${last_primary_read}" == "${prev_primary_read}" &&
				"${last_leader_read}" == "${prev_leader_read}" &&
				"${last_leader_write}" == "${prev_leader_write}" &&
				"${last_other_write}" == "${prev_other_write}" ]]; then
				host_stable="STABLE"
			else
				host_stable="UNSTABLE"
				all_hosts_stable=0
			fi
		fi

		LAST_HOST_STATUS["${host}"]=${host_stable}
		LAST_HOST_TEBIS_TS["${host}"]=${last_tebis_ts}
		LAST_HOST_ELECT_TS["${host}"]=${last_elect_ts}
		LAST_HOST_PRIMARY_DATA_WRITE_BYTES["${host}"]=${last_primary_write}
		LAST_HOST_REPLICA_DATA_WRITE_BYTES["${host}"]=${last_replica_write}
		LAST_HOST_PRIMARY_READ_BYTES["${host}"]=${last_primary_read}
		LAST_HOST_LEADER_PARITY_READ_BYTES["${host}"]=${last_leader_read}
		LAST_HOST_LEADER_PARITY_WRITE_BYTES["${host}"]=${last_leader_write}
		LAST_HOST_OTHER_PARITY_WRITE_BYTES["${host}"]=${last_other_write}
		LAST_HOST_PRIMARY_DATA_WRITE_GB["${host}"]=$(bytes_to_gb "${last_primary_write}")
		LAST_HOST_REPLICA_DATA_WRITE_GB["${host}"]=$(bytes_to_gb "${last_replica_write}")
		LAST_HOST_PRIMARY_READ_GB["${host}"]=$(bytes_to_gb "${last_primary_read}")
		LAST_HOST_LEADER_PARITY_READ_GB["${host}"]=$(bytes_to_gb "${last_leader_read}")
		LAST_HOST_LEADER_PARITY_WRITE_GB["${host}"]=$(bytes_to_gb "${last_leader_write}")
		LAST_HOST_OTHER_PARITY_WRITE_GB["${host}"]=$(bytes_to_gb "${last_other_write}")

		TEBIS_PRIMARY_DATA_WRITE_BYTES=$((TEBIS_PRIMARY_DATA_WRITE_BYTES + last_primary_write))
		TEBIS_REPLICA_DATA_WRITE_BYTES=$((TEBIS_REPLICA_DATA_WRITE_BYTES + last_replica_write))
		ELECT_PRIMARY_READ_BYTES=$((ELECT_PRIMARY_READ_BYTES + last_primary_read))
		ELECT_LEADER_PARITY_READ_BYTES=$((ELECT_LEADER_PARITY_READ_BYTES + last_leader_read))
		ELECT_LEADER_PARITY_WRITE_BYTES=$((ELECT_LEADER_PARITY_WRITE_BYTES + last_leader_write))
		ELECT_OTHER_PARITY_WRITE_BYTES=$((ELECT_OTHER_PARITY_WRITE_BYTES + last_other_write))
	done

	TEBIS_PRIMARY_DATA_WRITE_GB=$(bytes_to_gb "${TEBIS_PRIMARY_DATA_WRITE_BYTES}")
	TEBIS_REPLICA_DATA_WRITE_GB=$(bytes_to_gb "${TEBIS_REPLICA_DATA_WRITE_BYTES}")
	ELECT_PRIMARY_READ_GB=$(bytes_to_gb "${ELECT_PRIMARY_READ_BYTES}")
	ELECT_LEADER_PARITY_READ_GB=$(bytes_to_gb "${ELECT_LEADER_PARITY_READ_BYTES}")
	ELECT_LEADER_PARITY_WRITE_GB=$(bytes_to_gb "${ELECT_LEADER_PARITY_WRITE_BYTES}")
	ELECT_OTHER_PARITY_WRITE_GB=$(bytes_to_gb "${ELECT_OTHER_PARITY_WRITE_BYTES}")

	if [[ ${all_hosts_stable} -eq 1 ]]; then
		OVERHEAD_STATUS="STABLE"
	else
		OVERHEAD_STATUS="UNSTABLE"
	fi
}

wait_until_stable_disk_overhead() {
	local remote_log=$1
	local backup_label=$2
	local start_ts
	local now_ts
	local elapsed_sec
	local attempt=0

	start_ts=$(date +%s)

	while true; do
		attempt=$((attempt + 1))
		if collect_last_two_disk_overhead "${remote_log}" "${backup_label}" 0; then
			if [[ "${OVERHEAD_STATUS}" == "STABLE" ]]; then
				return 0
			fi
			echo "Disk overhead still changing (backup=${backup_label}, attempt=${attempt}), wait ${stable_check_interval_sec}s..." >&2
		else
			echo "Disk overhead not ready yet (backup=${backup_label}, attempt=${attempt}), wait ${stable_check_interval_sec}s..." >&2
		fi

		now_ts=$(date +%s)
		elapsed_sec=$((now_ts - start_ts))
		if [[ ${stable_check_timeout_sec} -gt 0 && ${elapsed_sec} -ge ${stable_check_timeout_sec} ]]; then
			echo "Timed out waiting disk overhead to become stable after ${elapsed_sec}s." >&2
			collect_last_two_disk_overhead "${remote_log}" "${backup_label}" 1 || true
			return 1
		fi

		sleep "${stable_check_interval_sec}"
	done
}

snapshot_final_for_run() {
	local backup_label=$1
	local workload=$2
	local host
	local key
	local run_key

	for host in "${cluster_hosts[@]}"; do
		key="${backup_label}|${workload}|${host}"
		FINAL_HOST_STATUS["${key}"]=${LAST_HOST_STATUS["${host}"]}
		FINAL_HOST_TEBIS_TS["${key}"]=${LAST_HOST_TEBIS_TS["${host}"]}
		FINAL_HOST_ELECT_TS["${key}"]=${LAST_HOST_ELECT_TS["${host}"]}
		FINAL_HOST_PRIMARY_DATA_WRITE_BYTES["${key}"]=${LAST_HOST_PRIMARY_DATA_WRITE_BYTES["${host}"]}
		FINAL_HOST_REPLICA_DATA_WRITE_BYTES["${key}"]=${LAST_HOST_REPLICA_DATA_WRITE_BYTES["${host}"]}
		FINAL_HOST_PRIMARY_READ_BYTES["${key}"]=${LAST_HOST_PRIMARY_READ_BYTES["${host}"]}
		FINAL_HOST_LEADER_PARITY_READ_BYTES["${key}"]=${LAST_HOST_LEADER_PARITY_READ_BYTES["${host}"]}
		FINAL_HOST_LEADER_PARITY_WRITE_BYTES["${key}"]=${LAST_HOST_LEADER_PARITY_WRITE_BYTES["${host}"]}
		FINAL_HOST_OTHER_PARITY_WRITE_BYTES["${key}"]=${LAST_HOST_OTHER_PARITY_WRITE_BYTES["${host}"]}
		FINAL_HOST_PRIMARY_DATA_WRITE_GB["${key}"]=${LAST_HOST_PRIMARY_DATA_WRITE_GB["${host}"]}
		FINAL_HOST_REPLICA_DATA_WRITE_GB["${key}"]=${LAST_HOST_REPLICA_DATA_WRITE_GB["${host}"]}
		FINAL_HOST_PRIMARY_READ_GB["${key}"]=${LAST_HOST_PRIMARY_READ_GB["${host}"]}
		FINAL_HOST_LEADER_PARITY_READ_GB["${key}"]=${LAST_HOST_LEADER_PARITY_READ_GB["${host}"]}
		FINAL_HOST_LEADER_PARITY_WRITE_GB["${key}"]=${LAST_HOST_LEADER_PARITY_WRITE_GB["${host}"]}
		FINAL_HOST_OTHER_PARITY_WRITE_GB["${key}"]=${LAST_HOST_OTHER_PARITY_WRITE_GB["${host}"]}
	done

	run_key="${backup_label}|${workload}"
	FINAL_RUN_STATUS["${run_key}"]=${OVERHEAD_STATUS}
	FINAL_RUN_PRIMARY_DATA_WRITE_BYTES["${run_key}"]=${TEBIS_PRIMARY_DATA_WRITE_BYTES}
	FINAL_RUN_REPLICA_DATA_WRITE_BYTES["${run_key}"]=${TEBIS_REPLICA_DATA_WRITE_BYTES}
	FINAL_RUN_PRIMARY_READ_BYTES["${run_key}"]=${ELECT_PRIMARY_READ_BYTES}
	FINAL_RUN_LEADER_PARITY_READ_BYTES["${run_key}"]=${ELECT_LEADER_PARITY_READ_BYTES}
	FINAL_RUN_LEADER_PARITY_WRITE_BYTES["${run_key}"]=${ELECT_LEADER_PARITY_WRITE_BYTES}
	FINAL_RUN_OTHER_PARITY_WRITE_BYTES["${run_key}"]=${ELECT_OTHER_PARITY_WRITE_BYTES}
	FINAL_RUN_PRIMARY_DATA_WRITE_GB["${run_key}"]=${TEBIS_PRIMARY_DATA_WRITE_GB}
	FINAL_RUN_REPLICA_DATA_WRITE_GB["${run_key}"]=${TEBIS_REPLICA_DATA_WRITE_GB}
	FINAL_RUN_PRIMARY_READ_GB["${run_key}"]=${ELECT_PRIMARY_READ_GB}
	FINAL_RUN_LEADER_PARITY_READ_GB["${run_key}"]=${ELECT_LEADER_PARITY_READ_GB}
	FINAL_RUN_LEADER_PARITY_WRITE_GB["${run_key}"]=${ELECT_LEADER_PARITY_WRITE_GB}
	FINAL_RUN_OTHER_PARITY_WRITE_GB["${run_key}"]=${ELECT_OTHER_PARITY_WRITE_GB}
}

write_final_report() {
	local output_file=$1
	local backup_label
	local workload
	local host
	local key
	local run_key

	printf "backup_label\tworkload\thost\tstatus\ttebis_timestamp\telect_timestamp\tprimary_data_write_bytes\treplica_data_write_bytes\tprimary_read_bytes\tleader_parity_read_bytes\tleader_parity_write_bytes\tother_parity_write_bytes\tprimary_data_write_gb\treplica_data_write_gb\tprimary_read_gb\tleader_parity_read_gb\tleader_parity_write_gb\tother_parity_write_gb\n" > "${output_file}"

	for backup_label in "${backup_methods[@]}"; do
		for workload in "${workloads[@]}"; do
			for host in "${cluster_hosts[@]}"; do
				key="${backup_label}|${workload}|${host}"
				printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
					"${backup_label}" "${workload}" "${host}" "${FINAL_HOST_STATUS[${key}]}" \
					"${FINAL_HOST_TEBIS_TS[${key}]}" "${FINAL_HOST_ELECT_TS[${key}]}" \
					"${FINAL_HOST_PRIMARY_DATA_WRITE_BYTES[${key}]}" \
					"${FINAL_HOST_REPLICA_DATA_WRITE_BYTES[${key}]}" \
					"${FINAL_HOST_PRIMARY_READ_BYTES[${key}]}" \
					"${FINAL_HOST_LEADER_PARITY_READ_BYTES[${key}]}" \
					"${FINAL_HOST_LEADER_PARITY_WRITE_BYTES[${key}]}" \
					"${FINAL_HOST_OTHER_PARITY_WRITE_BYTES[${key}]}" \
					"${FINAL_HOST_PRIMARY_DATA_WRITE_GB[${key}]}" \
					"${FINAL_HOST_REPLICA_DATA_WRITE_GB[${key}]}" \
					"${FINAL_HOST_PRIMARY_READ_GB[${key}]}" \
					"${FINAL_HOST_LEADER_PARITY_READ_GB[${key}]}" \
					"${FINAL_HOST_LEADER_PARITY_WRITE_GB[${key}]}" \
					"${FINAL_HOST_OTHER_PARITY_WRITE_GB[${key}]}" \
					>> "${output_file}"
			done

			run_key="${backup_label}|${workload}"
			printf "%s\t%s\tSUM\t%s\tPER_HOST_LAST\tPER_HOST_LAST\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
				"${backup_label}" "${workload}" "${FINAL_RUN_STATUS[${run_key}]}" \
				"${FINAL_RUN_PRIMARY_DATA_WRITE_BYTES[${run_key}]}" \
				"${FINAL_RUN_REPLICA_DATA_WRITE_BYTES[${run_key}]}" \
				"${FINAL_RUN_PRIMARY_READ_BYTES[${run_key}]}" \
				"${FINAL_RUN_LEADER_PARITY_READ_BYTES[${run_key}]}" \
				"${FINAL_RUN_LEADER_PARITY_WRITE_BYTES[${run_key}]}" \
				"${FINAL_RUN_OTHER_PARITY_WRITE_BYTES[${run_key}]}" \
				"${FINAL_RUN_PRIMARY_DATA_WRITE_GB[${run_key}]}" \
				"${FINAL_RUN_REPLICA_DATA_WRITE_GB[${run_key}]}" \
				"${FINAL_RUN_PRIMARY_READ_GB[${run_key}]}" \
				"${FINAL_RUN_LEADER_PARITY_READ_GB[${run_key}]}" \
				"${FINAL_RUN_LEADER_PARITY_WRITE_GB[${run_key}]}" \
				"${FINAL_RUN_OTHER_PARITY_WRITE_GB[${run_key}]}" \
				>> "${output_file}"
		done
	done
}

printf "backup_label\tworkload\tstatus\ttimestamp\tprimary_data_write_bytes\treplica_data_write_bytes\tprimary_read_bytes\tleader_parity_read_bytes\tleader_parity_write_bytes\tother_parity_write_bytes\tprimary_data_write_gb\treplica_data_write_gb\tprimary_read_gb\tleader_parity_read_gb\tleader_parity_write_gb\tother_parity_write_gb\n" > "${summary_file}"

echo "Running motivation exp1a with backups=${backup_methods[*]}, workloads=${workloads[*]}"

for backup_label in "${backup_methods[@]}"; do
	read -r backup_method regions_file <<< "$(resolve_backup_config "${backup_label}")"
	current_backup_method="${backup_method}"
	sync_and_build_for_backup "${backup_label}"

	for workload in "${workloads[@]}"; do
		echo -e "\n*********Running motivation exp1a workload=${workload}, backup=${backup_label}*********"

		run_tag="${date_time}"
		output_base="ycsb_log/tmp_log/${nickname}_${backup_label}_${workload}_thread_${server_threads}_${client_threads}"
		output_path="${project_dir}/${output_base}_${run_tag}"
		server_log_path="/tmp/lijinming_tebis_server_${backup_label}_${workload}_${run_tag}.log"

		echo "Running single round: workload=${workload}, backup=${backup_label}, tag=${run_tag}" >&2

		"${basic_script_dir}/run_cluster.sh" -b "${backup_method}" -g "${gc_method}" -l "${load_times}" \
			-r "${run_times}" -u "${ops_higher_threshold}" -w "${workload}" -o "${output_base}" \
			-d "${run_tag}" -t "${server_threads}" -c "${client_threads}" -f "${regions_file}" -k \
			-s "${server_log_path}"

		servers_may_be_running=1

		ops_file="${output_path}/run_${workload}/ops.txt"
		filter_ops_file "${ops_file}"

		wait_until_stable_disk_overhead "${server_log_path}" "${backup_label}"
		stop_servers "${backup_method}"
		servers_may_be_running=0

		printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
			"${backup_label}" "${workload}" "${OVERHEAD_STATUS}" "${OVERHEAD_TIMESTAMP}" \
			"${TEBIS_PRIMARY_DATA_WRITE_BYTES}" "${TEBIS_REPLICA_DATA_WRITE_BYTES}" \
			"${ELECT_PRIMARY_READ_BYTES}" "${ELECT_LEADER_PARITY_READ_BYTES}" \
			"${ELECT_LEADER_PARITY_WRITE_BYTES}" "${ELECT_OTHER_PARITY_WRITE_BYTES}" \
			"${TEBIS_PRIMARY_DATA_WRITE_GB}" "${TEBIS_REPLICA_DATA_WRITE_GB}" \
			"${ELECT_PRIMARY_READ_GB}" "${ELECT_LEADER_PARITY_READ_GB}" \
			"${ELECT_LEADER_PARITY_WRITE_GB}" "${ELECT_OTHER_PARITY_WRITE_GB}" \
			>> "${summary_file}"

		snapshot_final_for_run "${backup_label}" "${workload}"

		sleep 10
	done
done

write_final_report "${final_file}"

echo ""
echo "Final per-host and summed disk overhead:"
cat "${final_file}"
echo ""
echo "Saved run summary: ${summary_file}"
echo "Saved final host+sum report: ${final_file}"
