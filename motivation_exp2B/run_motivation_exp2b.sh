#!/usr/bin/env bash

set -euo pipefail

nickname=""
project_dir="/home/lijinming/tebis"
basic_script_dir="${project_dir}/ycsb_log/scripts"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

backup_methods=(
	elect
)
gc_methods=(
	normal
)
workloads=(
	a
)

load_times=100000000
run_times=700000000
ops_lower_threshold=000000000
ops_higher_threshold=900000000
server_threads=8
client_threads=32
date_time=$(date +%Y%m%d_%H%M%S)
stable_check_interval_sec=200
stable_check_timeout_sec=0
servers_may_be_running=0
current_backup_method="elect"

results_dir=""
summary_file=""
final_file=""
compact_file=""

hosts=(
	10.118.0.227
	10.118.0.28
	10.118.0.229
	10.118.0.30
	10.118.0.31
	10.118.0.32
)

GC_OVERHEAD_STATUS=""
GC_OVERHEAD_TIMESTAMP="PER_HOST_LAST"
GC_REINSERT_BYTES=0
GC_UPDATE_BYTES=0
GC_REPLICA_COUNT=0
GC_PARITY_COUNT=0

declare -A LAST_HOST_STATUS=()
declare -A LAST_HOST_TS=()
declare -A LAST_HOST_REINSERT_BYTES=()
declare -A LAST_HOST_UPDATE_BYTES=()
declare -A LAST_HOST_REPLICA_COUNT=()
declare -A LAST_HOST_PARITY_COUNT=()

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

if [[ -n "${MOT_EXP2B_HOSTS:-}" ]]; then
	read -r -a hosts <<< "${MOT_EXP2B_HOSTS}"
fi

if [[ ${#hosts[@]} -ne 6 ]]; then
	echo "This script expects exactly 6 hosts, got: ${#hosts[@]}" >&2
	exit 1
fi

calc_ratio() {
	local numerator=$1
	local denominator=$2

	if [[ "${denominator}" == "0" ]]; then
		echo "0.000000"
		return
	fi

	awk -v num="${numerator}" -v den="${denominator}" 'BEGIN { printf "%.6f", num / den }'
}

bytes_to_gib() {
	local bytes=$1

	awk -v bytes="${bytes}" 'BEGIN { printf "%.6f", bytes / (1024.0 * 1024.0 * 1024.0) }'
}

stop_servers() {
	local backup_method=$1
	local host
	for host in "${hosts[@]}"; do
		ssh "${host}" "sudo pkill -f 'tebis_server/tebis_server -b ${backup_method}'" >/dev/null 2>&1 || true
	done
}

cleanup() {
	if [[ ${servers_may_be_running} -eq 1 ]]; then
		echo "Stopping tebis servers from motivation_exp2b cleanup..." >&2
		stop_servers "${current_backup_method}"
		servers_may_be_running=0
	fi
}

trap cleanup EXIT

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

extract_host_last_two_gc_stats() {
	local host=$1
	local remote_log=$2
	local remote_tail

	# Exit codes from remote side:
	# 3 -> file not found, 4 -> file unreadable, 2 -> missing GC overhead lines.
	remote_tail=$(ssh "${host}" "
		if [ ! -e '${remote_log}' ]; then
			exit 3
		fi
		if [ ! -r '${remote_log}' ]; then
			exit 4
		fi
		grep -F '[GC overhead]' '${remote_log}' | tail -n 2
		echo '__GC_COMPLETED_LINES__'
		grep -E 'GC completed:.*replica GC:.*parity GC:' '${remote_log}' | tail -n 1
	") || return $?

	if [[ -z "${remote_tail}" ]]; then
		return 2
	fi

	awk '
	BEGIN {
		section = "overhead"
		overhead_cnt = 0
		completed_cnt = 0
	}
	/^__GC_COMPLETED_LINES__$/ {
		section = "completed"
		next
	}
	section == "overhead" && /\[GC overhead\]/ {
		ts = $1
		reinsert = $0
		update = $0
		sub(/^.*written data during reinsert: /, "", reinsert)
		sub(/[^0-9].*$/, "", reinsert)
		sub(/^.*written data during update: /, "", update)
		sub(/[^0-9].*$/, "", update)
		if (reinsert ~ /^[0-9]+$/ && update ~ /^[0-9]+$/) {
			prev_ts = last_ts
			prev_reinsert = last_reinsert
			prev_update = last_update
			last_ts = ts
			last_reinsert = reinsert + 0
			last_update = update + 0
			overhead_cnt++
		}
		next
	}
	section == "completed" && /GC completed:/ {
		replica = $0
		parity = $0
		sub(/^.*replica GC: /, "", replica)
		sub(/, parity GC:.*$/, "", replica)
		sub(/^.*parity GC: /, "", parity)
		sub(/[^0-9].*$/, "", parity)
		if (replica ~ /^[0-9]+$/ && parity ~ /^[0-9]+$/) {
			prev_replica = last_replica
			prev_parity = last_parity
			last_replica = replica + 0
			last_parity = parity + 0
			completed_cnt++
		}
	}
	END {
		if (overhead_cnt == 0) {
			exit 2
		}
		if (completed_cnt == 0) {
			last_replica = 0
			last_parity = 0
			prev_replica = 0
			prev_parity = 0
		}
		if (overhead_cnt == 1) {
			printf "ONE\t%s\t%.0f\t%.0f\t%.0f\t%.0f\t0\t0\t0\t0\n", last_ts, last_reinsert, last_update, last_replica, last_parity
			exit 0
		}
		printf "OK\t%s\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\n", last_ts, last_reinsert, last_update, last_replica, last_parity, prev_reinsert, prev_update, prev_replica, prev_parity
	}
	' <<< "${remote_tail}"
}

collect_last_two_gc_stats() {
	local remote_log=$1
	local allow_missing=${2:-0}
	local verbose_fail=${3:-1}
	local host
	local host_line
	local row_status
	local last_ts
	local last_reinsert
	local last_update
	local last_replica
	local last_parity
	local prev_reinsert
	local prev_update
	local prev_replica
	local prev_parity
	local host_stable
	local all_hosts_stable=1
	local rc

	GC_REINSERT_BYTES=0
	GC_UPDATE_BYTES=0
	GC_REPLICA_COUNT=0
	GC_PARITY_COUNT=0
	GC_OVERHEAD_TIMESTAMP="PER_HOST_LAST"

	for host in "${hosts[@]}"; do
		if host_line=$(extract_host_last_two_gc_stats "${host}" "${remote_log}"); then
			:
		else
			rc=$?
			if [[ ${rc} -eq 2 && ${allow_missing} -eq 1 ]]; then
				host_line=$'MISSING\tNA\t0\t0\t0\t0\t0\t0\t0\t0'
			else
				if [[ ${verbose_fail} -eq 1 ]]; then
					if [[ ${rc} -eq 3 ]]; then
						echo "Remote log not found on host=${host}: ${remote_log}" >&2
					elif [[ ${rc} -eq 4 ]]; then
						echo "Remote log exists but is not readable on host=${host}: ${remote_log}" >&2
					elif [[ ${rc} -eq 2 ]]; then
						echo "Missing GC overhead lines in remote log on host=${host}: ${remote_log}" >&2
					else
						echo "Failed to parse remote log on host=${host}: ${remote_log} (rc=${rc})" >&2
					fi
					ssh "${host}" "echo '--- tail -n 5 ${remote_log} ---' >&2; tail -n 5 '${remote_log}' 2>/dev/null >&2 || true; echo '--- grep GC stats tail -n 5 ---' >&2; grep -E '\\[GC overhead\\]|GC completed:' '${remote_log}' 2>/dev/null | tail -n 5 >&2 || true" || true
				fi
				return 1
			fi
		fi

		IFS=$'\t' read -r row_status last_ts last_reinsert last_update last_replica last_parity prev_reinsert prev_update prev_replica prev_parity <<< "${host_line}"

		host_stable="UNSTABLE"
		if [[ "${row_status}" == "MISSING" ]]; then
			host_stable="STABLE"
		elif [[ "${row_status}" == "OK" && "${last_reinsert}" == "${prev_reinsert}" && "${last_update}" == "${prev_update}" ]]; then
			host_stable="STABLE"
		else
			all_hosts_stable=0
		fi

		LAST_HOST_STATUS["${host}"]=${host_stable}
		LAST_HOST_TS["${host}"]=${last_ts}
		LAST_HOST_REINSERT_BYTES["${host}"]=${last_reinsert}
		LAST_HOST_UPDATE_BYTES["${host}"]=${last_update}
		LAST_HOST_REPLICA_COUNT["${host}"]=${last_replica}
		LAST_HOST_PARITY_COUNT["${host}"]=${last_parity}

		GC_REINSERT_BYTES=$((GC_REINSERT_BYTES + last_reinsert))
		GC_UPDATE_BYTES=$((GC_UPDATE_BYTES + last_update))
		GC_REPLICA_COUNT=$((GC_REPLICA_COUNT + last_replica))
		GC_PARITY_COUNT=$((GC_PARITY_COUNT + last_parity))
	done

	if [[ ${all_hosts_stable} -eq 1 ]]; then
		GC_OVERHEAD_STATUS="STABLE"
	else
		GC_OVERHEAD_STATUS="UNSTABLE"
	fi
}

wait_until_stable_gc_stats() {
	local remote_log=$1
	local allow_missing=$2
	local start_ts
	local now_ts
	local elapsed_sec
	local attempt=0

	start_ts=$(date +%s)

	while true; do
		attempt=$((attempt + 1))
		if collect_last_two_gc_stats "${remote_log}" "${allow_missing}" 0; then
			if [[ "${GC_OVERHEAD_STATUS}" == "STABLE" ]]; then
				return 0
			else
				echo "GC overhead still changing (attempt=${attempt}), wait ${stable_check_interval_sec}s..." >&2
			fi
		else
			echo "GC overhead not ready yet (attempt=${attempt}), wait ${stable_check_interval_sec}s..." >&2
		fi

		now_ts=$(date +%s)
		elapsed_sec=$((now_ts - start_ts))
		if [[ ${stable_check_timeout_sec} -gt 0 && ${elapsed_sec} -ge ${stable_check_timeout_sec} ]]; then
			echo "Timed out waiting GC overhead to become stable after ${elapsed_sec}s." >&2
			collect_last_two_gc_stats "${remote_log}" "${allow_missing}" 1 || true
			return 1
		fi

		sleep "${stable_check_interval_sec}"
	done
}

append_final_report_for_current_run() {
	local output_file=$1
	local round_idx=$2
	local backup_method=$3
	local gc_method=$4
	local workload=$5
	local ratio_sum=$6
	local host
	local host_ratio
	local host_reinsert_gib
	local host_update_gib

	for host in "${hosts[@]}"; do
		host_ratio=$(calc_ratio "${LAST_HOST_UPDATE_BYTES[${host}]}" "${LAST_HOST_REINSERT_BYTES[${host}]}")
		host_reinsert_gib=$(bytes_to_gib "${LAST_HOST_REINSERT_BYTES[${host}]}")
		host_update_gib=$(bytes_to_gib "${LAST_HOST_UPDATE_BYTES[${host}]}")
		printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
			"${round_idx}" "${backup_method}" "${gc_method}" "${workload}" "${host}" \
			"${LAST_HOST_STATUS[${host}]}" "${LAST_HOST_TS[${host}]}" \
			"${host_reinsert_gib}" "${host_update_gib}" "${host_ratio}" "${host_ratio}" \
			"${LAST_HOST_REPLICA_COUNT[${host}]}" "${LAST_HOST_PARITY_COUNT[${host}]}" \
			>> "${output_file}"
	done

	printf "%s\t%s\t%s\t%s\tSUM\t%s\tPER_HOST_LAST\t%s\t%s\t%s\t%s\t%s\t%s\n" \
		"${round_idx}" "${backup_method}" "${gc_method}" "${workload}" \
		"${GC_OVERHEAD_STATUS}" "$(bytes_to_gib "${GC_REINSERT_BYTES}")" "$(bytes_to_gib "${GC_UPDATE_BYTES}")" "${ratio_sum}" "${ratio_sum}" \
		"${GC_REPLICA_COUNT}" "${GC_PARITY_COUNT}" \
		>> "${output_file}"
}

results_dir="${script_dir}/${nickname}_${date_time}"
mkdir -p "${results_dir}"
summary_file="${results_dir}/gc_reinsert_overhead_runs.tsv"
final_file="${results_dir}/gc_reinsert_overhead_final.tsv"
compact_file="${results_dir}/gc_reinsert_overhead_lines.log"

printf "round\tbackup_method\tgc_method\tworkload\tstatus\ttimestamp\treinsert_gib\tupdate_gib\tupdate_insert_ratio\tparity_reinsert_ratio\treplica_gc\tparity_gc\n" > "${summary_file}"
printf "round\tbackup_method\tgc_method\tworkload\thost\tstatus\tlast_timestamp\treinsert_gib\tupdate_gib\tupdate_insert_ratio\tparity_reinsert_ratio\treplica_gc\tparity_gc\n" > "${final_file}"

echo "Running motivation exp2b with backup_methods=${backup_methods[*]}, gc_methods=${gc_methods[*]}, workloads=${workloads[*]}"

round_idx=0

for workload in "${workloads[@]}"; do
	for backup_method in "${backup_methods[@]}"; do
		for gc_method in "${gc_methods[@]}"; do
			allow_missing=0
			regions_file="regions_file_elect"

			round_idx=$((round_idx + 1))

			echo -e "\n*********Running motivation exp2b round=${round_idx} workload=${workload}, backup=${backup_method}, gc=${gc_method}*********"

			run_tag="${date_time}_${backup_method}_${gc_method}_${workload}"
			output_base="ycsb_log/tmp_log/${nickname}_${backup_method}_${gc_method}_${workload}_thread_${server_threads}_${client_threads}"
			output_path="${project_dir}/${output_base}_${run_tag}"
			server_log_path="/tmp/lijinming_tebis_server_${backup_method}_${gc_method}_${workload}_${run_tag}.log"

			echo "Running single round: workload=${workload}, backup=${backup_method}, gc=${gc_method}, tag=${run_tag}" >&2

			"${basic_script_dir}/run_cluster.sh" -b "${backup_method}" -g "${gc_method}" -l "${load_times}" \
				-r "${run_times}" -u "${ops_higher_threshold}" -w "${workload}" -o "${output_base}" \
				-d "${run_tag}" -t "${server_threads}" -c "${client_threads}" -f "${regions_file}" -k \
				-s "${server_log_path}"

			servers_may_be_running=1
			current_backup_method="${backup_method}"

			ops_file="${output_path}/run_${workload}/ops.txt"
			filter_ops_file "${ops_file}"

			wait_until_stable_gc_stats "${server_log_path}" "${allow_missing}"
			stop_servers "${backup_method}"
			servers_may_be_running=0

			ratio_sum=$(calc_ratio "${GC_UPDATE_BYTES}" "${GC_REINSERT_BYTES}")
			reinsert_gib=$(bytes_to_gib "${GC_REINSERT_BYTES}")
			update_gib=$(bytes_to_gib "${GC_UPDATE_BYTES}")

			printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
				"${round_idx}" "${backup_method}" "${gc_method}" "${workload}" \
				"${GC_OVERHEAD_STATUS}" "${GC_OVERHEAD_TIMESTAMP}" "${reinsert_gib}" "${update_gib}" "${ratio_sum}" "${ratio_sum}" \
				"${GC_REPLICA_COUNT}" "${GC_PARITY_COUNT}" \
				>> "${summary_file}"

			append_final_report_for_current_run "${final_file}" "${round_idx}" "${backup_method}" "${gc_method}" "${workload}" "${ratio_sum}"

			{
				echo "# round=${round_idx} backup=${backup_method} gc=${gc_method} workload=${workload}"
				echo "[GC overhead] written data during reinsert: ${reinsert_gib} GiB, written data during update: ${update_gib} GiB"
				echo "[Derived metric] parity/reinsert ratio: ${ratio_sum}"
				echo "[GC completed] replica GC: ${GC_REPLICA_COUNT}, parity GC: ${GC_PARITY_COUNT}"
			} >> "${compact_file}"

			echo "[GC overhead] written data during reinsert: ${reinsert_gib} GiB, written data during update: ${update_gib} GiB"
			echo "[GC completed] replica GC: ${GC_REPLICA_COUNT}, parity GC: ${GC_PARITY_COUNT}"
			echo "[Derived metric] parity/reinsert ratio: ${ratio_sum}"

			sleep 10
		done
	done
done

echo ""
echo "Final per-host and summed GC reinsert/update overhead:"
cat "${final_file}"
echo ""
echo "Saved run summary: ${summary_file}"
echo "Saved final host+sum report: ${final_file}"
echo "Saved compact overhead lines: ${compact_file}"
