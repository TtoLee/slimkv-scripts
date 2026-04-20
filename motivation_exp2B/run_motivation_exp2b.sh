#!/usr/bin/env bash

set -euo pipefail

nickname=""
project_dir="/home/lijinming/tebis"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

backup_methods=(
	elect
)
gc_methods=(
	normal
)
gc_ratios=(
	0.2
    0.25
    0.3
    0.35
    0.4
)
workloads=(
	a
)

load_times=100000000
run_times=700000000
ops_lower_threshold=000000000
ops_higher_threshold=900000000
server_threads=4
client_threads=16
date_time=$(date +%Y%m%d_%H%M%S)
stable_check_interval_sec=500
stable_check_timeout_sec=0
servers_may_be_running=0
current_backup_method="elect"

results_dir=""
summary_file=""
final_file=""
compact_file=""
plot_data_file=""

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

normal_gc_header="${project_dir}/tebis_server/normal_gc.h"
default_gc_ratio="0.2"

declare -A LAST_HOST_STATUS=()
declare -A LAST_HOST_TS=()
declare -A LAST_HOST_REINSERT_BYTES=()
declare -A LAST_HOST_UPDATE_BYTES=()

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

set_gc_ratio_macro() {
	local ratio=$1

	if [[ ! -f "${normal_gc_header}" ]]; then
		echo "normal_gc.h not found: ${normal_gc_header}" >&2
		return 1
	fi

	if ! grep -qE '^#define[[:space:]]+GC_RATIO[[:space:]]+' "${normal_gc_header}"; then
		echo "GC_RATIO macro not found in ${normal_gc_header}" >&2
		return 1
	fi

	sed -i -E "s|^#define[[:space:]]+GC_RATIO[[:space:]]+.*$|#define GC_RATIO ${ratio}f|" "${normal_gc_header}"
	grep -E '^#define[[:space:]]+GC_RATIO[[:space:]]+' "${normal_gc_header}" >&2
}

sync_and_build_all_nodes() {
	echo "Syncing source and building locally/remotely via ./scp.sh ..." >&2
	(
		cd "${project_dir}"
		./scp.sh
	)
}

calc_ratio() {
	local numerator=$1
	local denominator=$2

	if [[ "${denominator}" == "0" ]]; then
		echo "0.000000"
		return
	fi

	awk -v num="${numerator}" -v den="${denominator}" 'BEGIN { printf "%.6f", num / den }'
}

restore_default_gc_ratio() {
	echo "Restoring GC_RATIO to ${default_gc_ratio}f and syncing/building..." >&2
	if ! set_gc_ratio_macro "${default_gc_ratio}"; then
		echo "Failed to restore GC_RATIO macro in ${normal_gc_header}" >&2
		return 1
	fi
	if ! sync_and_build_all_nodes; then
		echo "Failed to sync/build after restoring GC_RATIO=${default_gc_ratio}f" >&2
		return 1
	fi
	echo "GC_RATIO restored to ${default_gc_ratio}f on local and remote builds." >&2
}

stop_servers() {
	local backup_method=$1
	local host
	for host in "${hosts[@]}"; do
		ssh "${host}" "sudo pkill -f 'tebis_server/tebis_server -b ${backup_method}'" >/dev/null 2>&1 || true
	done
}

cleanup() {
	local cleanup_failed=0

	if [[ ${servers_may_be_running} -eq 1 ]]; then
		echo "Stopping tebis servers from motivation_exp2b cleanup..." >&2
		stop_servers "${current_backup_method}"
		servers_may_be_running=0
	fi

	if ! restore_default_gc_ratio; then
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

extract_host_last_two_gc_overhead() {
	local host=$1
	local remote_log=$2
	local remote_tail

	# Exit codes from remote side:
	# 3 -> file not found, 4 -> file unreadable, 2 -> no GC overhead lines.
	remote_tail=$(ssh "${host}" "
		if [ ! -e '${remote_log}' ]; then
			exit 3
		fi
		if [ ! -r '${remote_log}' ]; then
			exit 4
		fi
		grep -F '[GC overhead]' '${remote_log}' | tail -n 2
	") || return $?

	if [[ -z "${remote_tail}" ]]; then
		return 2
	fi

	awk '
	BEGIN {
		cnt = 0
	}
	/\[GC overhead\]/ {
		ts = $1
		reinsert = $0
		update = $0
		sub(/^.*written data during reinsert: /, "", reinsert)
		sub(/ B, written data during update:.*$/, "", reinsert)
		sub(/^.*written data during update: /, "", update)
		sub(/ B.*$/, "", update)
		if (reinsert ~ /^[0-9]+$/ && update ~ /^[0-9]+$/) {
			prev_ts = last_ts
			prev_reinsert = last_reinsert
			prev_update = last_update
			last_ts = ts
			last_reinsert = reinsert + 0
			last_update = update + 0
			cnt++
		}
	}
	END {
		if (cnt == 0) {
			exit 2
		}
		if (cnt == 1) {
			printf "ONE\t%s\t%.0f\t%.0f\tNA\t0\t0\n", last_ts, last_reinsert, last_update
			exit 0
		}
		printf "OK\t%s\t%.0f\t%.0f\t%s\t%.0f\t%.0f\n", last_ts, last_reinsert, last_update, prev_ts, prev_reinsert, prev_update
	}
	' <<< "${remote_tail}"
}

collect_last_two_gc_overhead() {
	local remote_log=$1
	local allow_missing=${2:-0}
	local verbose_fail=${3:-1}
	local host
	local host_line
	local row_status
	local last_ts
	local last_reinsert
	local last_update
	local prev_ts
	local prev_reinsert
	local prev_update
	local host_stable
	local all_hosts_stable=1
	local rc

	GC_REINSERT_BYTES=0
	GC_UPDATE_BYTES=0
	GC_OVERHEAD_TIMESTAMP="PER_HOST_LAST"

	for host in "${hosts[@]}"; do
		if ! host_line=$(extract_host_last_two_gc_overhead "${host}" "${remote_log}"); then
			rc=$?
			if [[ ${rc} -eq 2 && ${allow_missing} -eq 1 ]]; then
				host_line=$'MISSING\tNA\t0\t0\tNA\t0\t0'
			else
				if [[ ${verbose_fail} -eq 1 ]]; then
					if [[ ${rc} -eq 3 ]]; then
						echo "Remote log not found on host=${host}: ${remote_log}" >&2
					elif [[ ${rc} -eq 4 ]]; then
						echo "Remote log exists but is not readable on host=${host}: ${remote_log}" >&2
					elif [[ ${rc} -eq 2 ]]; then
						echo "No GC overhead lines in remote log on host=${host}: ${remote_log}" >&2
					else
						echo "Failed to parse remote log on host=${host}: ${remote_log} (rc=${rc})" >&2
					fi
					ssh "${host}" "echo '--- tail -n 5 ${remote_log} ---' >&2; tail -n 5 '${remote_log}' 2>/dev/null >&2 || true; echo '--- grep GC overhead tail -n 5 ---' >&2; grep -F '[GC overhead]' '${remote_log}' 2>/dev/null | tail -n 5 >&2 || true" || true
				fi
				return 1
			fi
		fi

		IFS=$'\t' read -r row_status last_ts last_reinsert last_update prev_ts prev_reinsert prev_update <<< "${host_line}"

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

		GC_REINSERT_BYTES=$((GC_REINSERT_BYTES + last_reinsert))
		GC_UPDATE_BYTES=$((GC_UPDATE_BYTES + last_update))
	done

	if [[ ${all_hosts_stable} -eq 1 ]]; then
		GC_OVERHEAD_STATUS="STABLE"
	else
		GC_OVERHEAD_STATUS="UNSTABLE"
	fi
}

wait_until_stable_gc_overhead() {
	local remote_log=$1
	local allow_missing=$2
	local start_ts
	local now_ts
	local elapsed_sec
	local attempt=0

	start_ts=$(date +%s)

	while true; do
		attempt=$((attempt + 1))
		if collect_last_two_gc_overhead "${remote_log}" "${allow_missing}" 0; then
			if [[ "${GC_OVERHEAD_STATUS}" == "STABLE" ]]; then
				return 0
			fi
			echo "GC overhead still changing (attempt=${attempt}), wait ${stable_check_interval_sec}s..." >&2
		else
			echo "GC overhead not ready yet (attempt=${attempt}), wait ${stable_check_interval_sec}s..." >&2
		fi

		now_ts=$(date +%s)
		elapsed_sec=$((now_ts - start_ts))
		if [[ ${stable_check_timeout_sec} -gt 0 && ${elapsed_sec} -ge ${stable_check_timeout_sec} ]]; then
			echo "Timed out waiting GC overhead to become stable after ${elapsed_sec}s." >&2
			collect_last_two_gc_overhead "${remote_log}" "${allow_missing}" 1 || true
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
	local gc_ratio=$6
	local ratio_sum=$7
	local host
	local host_ratio

	for host in "${hosts[@]}"; do
		host_ratio=$(calc_ratio "${LAST_HOST_UPDATE_BYTES[${host}]}" "${LAST_HOST_REINSERT_BYTES[${host}]}")
		printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
			"${round_idx}" "${backup_method}" "${gc_method}" "${gc_ratio}" "${workload}" "${host}" \
			"${LAST_HOST_STATUS[${host}]}" "${LAST_HOST_TS[${host}]}" \
			"${LAST_HOST_REINSERT_BYTES[${host}]}" "${LAST_HOST_UPDATE_BYTES[${host}]}" "${host_ratio}" \
			>> "${output_file}"
	done

	printf "%s\t%s\t%s\t%s\t%s\tSUM\t%s\tPER_HOST_LAST\t%s\t%s\t%s\n" \
		"${round_idx}" "${backup_method}" "${gc_method}" "${gc_ratio}" "${workload}" \
		"${GC_OVERHEAD_STATUS}" "${GC_REINSERT_BYTES}" "${GC_UPDATE_BYTES}" "${ratio_sum}" \
		>> "${output_file}"
}

results_dir="${script_dir}/${nickname}_${date_time}"
mkdir -p "${results_dir}"
summary_file="${results_dir}/gc_reinsert_overhead_runs.tsv"
final_file="${results_dir}/gc_reinsert_overhead_final.tsv"
compact_file="${results_dir}/gc_reinsert_overhead_lines.log"
plot_data_file="${results_dir}/write_amplification.tsv"

printf "round\tbackup_method\tgc_method\tgc_ratio\tworkload\tstatus\ttimestamp\treinsert_bytes\tupdate_bytes\tupdate_insert_ratio\n" > "${summary_file}"
printf "round\tbackup_method\tgc_method\tgc_ratio\tworkload\thost\tstatus\tlast_timestamp\treinsert_bytes\tupdate_bytes\tupdate_insert_ratio\n" > "${final_file}"
printf "gc_ratio\treinsert_bytes\tupdate_bytes\tupdate_insert_ratio\n" > "${plot_data_file}"

echo "Running motivation exp2b with backup_methods=${backup_methods[*]}, gc_methods=${gc_methods[*]}, gc_ratios=${gc_ratios[*]}, workloads=${workloads[*]}"

round_idx=0

for workload in "${workloads[@]}"; do
	for backup_method in "${backup_methods[@]}"; do
		for gc_method in "${gc_methods[@]}"; do
			allow_missing=0
			regions_file="regions_file_elect"

			for gc_ratio in "${gc_ratios[@]}"; do
				round_idx=$((round_idx + 1))
				ratio_tag=${gc_ratio/./p}

				echo -e "\n*********Running motivation exp2b round=${round_idx} workload=${workload}, backup=${backup_method}, gc=${gc_method}, gc_ratio=${gc_ratio}*********"

				set_gc_ratio_macro "${gc_ratio}"
				sync_and_build_all_nodes

				run_tag="${date_time}_${backup_method}_${gc_method}_${workload}_gcratio_${ratio_tag}"
				output_base="ycsb_log/tmp_log/${nickname}_${backup_method}_${gc_method}_${workload}_gcratio_${ratio_tag}_thread_${server_threads}_${client_threads}"
				output_path="${project_dir}/${output_base}_${run_tag}"
				server_log_path="/tmp/lijinming_tebis_server_${backup_method}_${gc_method}_${workload}_gcratio_${ratio_tag}_${run_tag}.log"

				echo "Running single round: workload=${workload}, backup=${backup_method}, gc=${gc_method}, gc_ratio=${gc_ratio}, tag=${run_tag}" >&2

				"${project_dir}/run_cluster.sh" -b "${backup_method}" -g "${gc_method}" -l "${load_times}" \
					-r "${run_times}" -u "${ops_higher_threshold}" -w "${workload}" -o "${output_base}" \
					-d "${run_tag}" -t "${server_threads}" -c "${client_threads}" -f "${regions_file}" -k \
					-s "${server_log_path}"

				servers_may_be_running=1
				current_backup_method="${backup_method}"

				ops_file="${output_path}/run_${workload}/ops.txt"
				filter_ops_file "${ops_file}"

				wait_until_stable_gc_overhead "${server_log_path}" "${allow_missing}"
				stop_servers "${backup_method}"
				servers_may_be_running=0

				ratio_sum=$(calc_ratio "${GC_UPDATE_BYTES}" "${GC_REINSERT_BYTES}")

				printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
					"${round_idx}" "${backup_method}" "${gc_method}" "${gc_ratio}" "${workload}" \
					"${GC_OVERHEAD_STATUS}" "${GC_OVERHEAD_TIMESTAMP}" "${GC_REINSERT_BYTES}" "${GC_UPDATE_BYTES}" "${ratio_sum}" \
					>> "${summary_file}"

				printf "%s\t%s\t%s\t%s\n" \
					"${gc_ratio}" "${GC_REINSERT_BYTES}" "${GC_UPDATE_BYTES}" "${ratio_sum}" \
					>> "${plot_data_file}"

				append_final_report_for_current_run "${final_file}" "${round_idx}" "${backup_method}" "${gc_method}" "${workload}" "${gc_ratio}" "${ratio_sum}"

				{
					echo "# round=${round_idx} backup=${backup_method} gc=${gc_method} workload=${workload} gc_ratio=${gc_ratio}"
					echo "[GC overhead] written data during reinsert: ${GC_REINSERT_BYTES} B, written data during update: ${GC_UPDATE_BYTES} B"
				} >> "${compact_file}"

				echo "[GC overhead] written data during reinsert: ${GC_REINSERT_BYTES} B, written data during update: ${GC_UPDATE_BYTES} B"
				echo "[Derived metric] update/reinsert ratio: ${ratio_sum}"

				sleep 10
			done
		done
	done
done

plot_output="${results_dir}/write_amplification.png"
plot_cmd=(
	python3 "${script_dir}/plot_write_amplification.py"
	--data "${plot_data_file}"
	--output "${plot_output}"
)

echo ""
echo "Executing plot command:"
printf '  %q' "${plot_cmd[@]}"
echo ""
"${plot_cmd[@]}"

echo ""
echo "Final per-host and summed GC reinsert/update overhead:"
cat "${final_file}"
echo ""
echo "Saved run summary: ${summary_file}"
echo "Saved final host+sum report: ${final_file}"
echo "Saved compact overhead lines: ${compact_file}"
echo "Saved plot data: ${plot_data_file}"
echo "Saved plot: ${plot_output}"
