#!/usr/bin/env bash

set -euo pipefail

nickname=""
project_dir="/home/lijinming/tebis"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

epoch=5
gc_method=none
backup_label="elect"
backup_method="elect"
regions_file="regions_file_elect"
load_times=100000000
run_times=500000000
ops_lower_threshold=000000000
ops_higher_threshold=300000000
workloads=(
	load
    a
)
server_threads=4
client_threads=16
date_time=$(date +%Y%m%d_%H%M%S)
stable_check_interval_sec=20
stable_check_timeout_sec=0
servers_may_be_running=0

results_dir=""
summary_file=""
stats_file=""
final_file=""

elect_hosts=(
	10.118.0.227
	10.118.0.28
	10.118.0.229
	10.118.0.30
	10.118.0.31
	10.118.0.32
)

ELECT_OVERHEAD_STATUS=""
ELECT_OVERHEAD_TIMESTAMP="PER_HOST_LAST"
ELECT_PRIMARY_TO_LEADER_BYTES=0
ELECT_LEADER_TO_OTHER_BYTES=0
ELECT_TOTAL_BYTES=0
ELECT_CODED_STRIPE_SUM=0
ELECT_PRIMARY_TO_LEADER_GB="0"
ELECT_LEADER_TO_OTHER_GB="0"
ELECT_TOTAL_GB="0"

declare -A LAST_HOST_STATUS=()
declare -A LAST_HOST_TS=()
declare -A LAST_HOST_P2L_BYTES=()
declare -A LAST_HOST_L2O_BYTES=()
declare -A LAST_HOST_TOTAL_BYTES=()
declare -A LAST_HOST_P2L_GB=()
declare -A LAST_HOST_L2O_GB=()
declare -A LAST_HOST_TOTAL_GB=()
declare -A LAST_HOST_CODED_STRIPE=()

declare -A FINAL_HOST_STATUS=()
declare -A FINAL_HOST_TS=()
declare -A FINAL_HOST_P2L_BYTES=()
declare -A FINAL_HOST_L2O_BYTES=()
declare -A FINAL_HOST_TOTAL_BYTES=()
declare -A FINAL_HOST_P2L_GB=()
declare -A FINAL_HOST_L2O_GB=()
declare -A FINAL_HOST_TOTAL_GB=()
declare -A FINAL_HOST_CODED_STRIPE=()

declare -A FINAL_WORKLOAD_STATUS=()
declare -A FINAL_WORKLOAD_P2L_BYTES=()
declare -A FINAL_WORKLOAD_L2O_BYTES=()
declare -A FINAL_WORKLOAD_TOTAL_BYTES=()
declare -A FINAL_WORKLOAD_P2L_GB=()
declare -A FINAL_WORKLOAD_L2O_GB=()
declare -A FINAL_WORKLOAD_TOTAL_GB=()
declare -A FINAL_WORKLOAD_CODED_STRIPE_SUM=()

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

if [[ ${epoch} -lt 1 ]]; then
	echo "epoch must be >= 1." >&2
	exit 1
fi

if [[ -n "${MOT_EXP1A_HOSTS:-}" ]]; then
	read -r -a elect_hosts <<< "${MOT_EXP1A_HOSTS}"
fi

if [[ ${#elect_hosts[@]} -ne 6 ]]; then
	echo "This script expects exactly 6 hosts, got: ${#elect_hosts[@]}" >&2
	exit 1
fi

stop_elect_servers() {
	local host
	for host in "${elect_hosts[@]}"; do
		ssh "${host}" "sudo pkill -f 'tebis_server/tebis_server -b ${backup_method}'" >/dev/null 2>&1 || true
	done
}

cleanup() {
	if [[ ${servers_may_be_running} -eq 1 ]]; then
		echo "Stopping tebis servers from motivation_exp1a cleanup..." >&2
		stop_elect_servers
		servers_may_be_running=0
	fi
}

trap cleanup EXIT

results_dir="${script_dir}/${nickname}_${date_time}"
mkdir -p "${results_dir}"
summary_file="${results_dir}/elect_network_overhead_runs.tsv"
stats_file="${results_dir}/elect_network_overhead_stats.tsv"
final_file="${results_dir}/elect_network_overhead_final.tsv"

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

extract_host_last_two() {
	local host=$1
	local remote_log=$2
	local remote_tail

	# Exit codes from remote side:
	# 3 -> file not found, 4 -> file unreadable, 2 -> no ELECT lines.
	remote_tail=$(ssh "${host}" "
		if [ ! -e '${remote_log}' ]; then
			exit 3
		fi
		if [ ! -r '${remote_log}' ]; then
			exit 4
		fi
		grep -F '[ELECT network overhead]' '${remote_log}' | tail -n 2
	") || return $?

	if [[ -z "${remote_tail}" ]]; then
		return 2
	fi

	awk '
	BEGIN {
		cnt = 0
	}
	/\[ELECT network overhead\]/ {
		ts = $1
		p2l = $0
		l2o = $0
		coded = $0
		sub(/^.*primary to leader parity: /, "", p2l)
		sub(/ B, leader parity to other parity:.*$/, "", p2l)
		sub(/^.*leader parity to other parity: /, "", l2o)
		sub(/ B.*$/, "", l2o)
		sub(/^.*coded stripe: /, "", coded)
		sub(/[^0-9].*$/, "", coded)
		if (ts ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ && p2l ~ /^[0-9]+$/ && l2o ~ /^[0-9]+$/ && coded ~ /^[0-9]+$/) {
			prev_ts = last_ts
			prev_p2l = last_p2l
			prev_l2o = last_l2o
			prev_coded = last_coded
			last_ts = ts
			last_p2l = p2l + 0
			last_l2o = l2o + 0
			last_coded = coded + 0
			cnt++
		}
	}
	END {
		if (cnt == 0) {
			exit 2
		}
		if (cnt == 1) {
			printf "ONE\t%s\t%.0f\t%.0f\t%.0f\tNA\t0\t0\t0\n", last_ts, last_p2l, last_l2o, last_coded
			exit 0
		}
		printf "OK\t%s\t%.0f\t%.0f\t%.0f\t%s\t%.0f\t%.0f\t%.0f\n", last_ts, last_p2l, last_l2o, last_coded, prev_ts, prev_p2l, prev_l2o, prev_coded
	}
	' <<< "${remote_tail}"
}

collect_last_two_elect_overhead() {
	local remote_log=$1
	local verbose_fail=${2:-1}
	local host
	local host_line
	local row_status
	local last_ts
	local last_p2l
	local last_l2o
	local last_coded
	local prev_ts
	local prev_p2l
	local prev_l2o
	local prev_coded
	local host_stable
	local all_hosts_stable=1
	local rc

	ELECT_PRIMARY_TO_LEADER_BYTES=0
	ELECT_LEADER_TO_OTHER_BYTES=0
	ELECT_TOTAL_BYTES=0
	ELECT_CODED_STRIPE_SUM=0
	ELECT_OVERHEAD_TIMESTAMP="PER_HOST_LAST"

	for host in "${elect_hosts[@]}"; do
		if ! host_line=$(extract_host_last_two "${host}" "${remote_log}"); then
			rc=$?
			if [[ ${verbose_fail} -eq 1 ]]; then
				if [[ ${rc} -eq 3 ]]; then
					echo "Remote log not found on host=${host}: ${remote_log}" >&2
				elif [[ ${rc} -eq 4 ]]; then
					echo "Remote log exists but is not readable on host=${host}: ${remote_log}" >&2
				elif [[ ${rc} -eq 2 ]]; then
					echo "No ELECT overhead lines in remote log on host=${host}: ${remote_log}" >&2
				else
					echo "Failed to parse remote log on host=${host}: ${remote_log} (rc=${rc})" >&2
				fi
				ssh "${host}" "echo '--- tail -n 5 ${remote_log} ---' >&2; tail -n 5 '${remote_log}' 2>/dev/null >&2 || true; echo '--- grep ELECT tail -n 5 ---' >&2; grep -F '[ELECT network overhead]' '${remote_log}' 2>/dev/null | tail -n 5 >&2 || true" || true
			fi
			return 1
		fi

		IFS=$'\t' read -r row_status last_ts last_p2l last_l2o last_coded prev_ts prev_p2l prev_l2o prev_coded <<< "${host_line}"

		host_stable="UNSTABLE"
		if [[ "${row_status}" == "OK" && "${last_p2l}" == "${prev_p2l}" && "${last_l2o}" == "${prev_l2o}" && "${last_coded}" == "${prev_coded}" ]]; then
			host_stable="STABLE"
		else
			all_hosts_stable=0
		fi

		LAST_HOST_STATUS["${host}"]=${host_stable}
		LAST_HOST_TS["${host}"]=${last_ts}
		LAST_HOST_P2L_BYTES["${host}"]=${last_p2l}
		LAST_HOST_L2O_BYTES["${host}"]=${last_l2o}
		LAST_HOST_TOTAL_BYTES["${host}"]=$((last_p2l + last_l2o))
		LAST_HOST_P2L_GB["${host}"]=$(bytes_to_gb "${last_p2l}")
		LAST_HOST_L2O_GB["${host}"]=$(bytes_to_gb "${last_l2o}")
		LAST_HOST_TOTAL_GB["${host}"]=$(bytes_to_gb "$((last_p2l + last_l2o))")
		LAST_HOST_CODED_STRIPE["${host}"]=${last_coded}

		ELECT_PRIMARY_TO_LEADER_BYTES=$((ELECT_PRIMARY_TO_LEADER_BYTES + last_p2l))
		ELECT_LEADER_TO_OTHER_BYTES=$((ELECT_LEADER_TO_OTHER_BYTES + last_l2o))
		ELECT_CODED_STRIPE_SUM=$((ELECT_CODED_STRIPE_SUM + last_coded))
	done

	ELECT_TOTAL_BYTES=$((ELECT_PRIMARY_TO_LEADER_BYTES + ELECT_LEADER_TO_OTHER_BYTES))
	ELECT_PRIMARY_TO_LEADER_GB=$(bytes_to_gb "${ELECT_PRIMARY_TO_LEADER_BYTES}")
	ELECT_LEADER_TO_OTHER_GB=$(bytes_to_gb "${ELECT_LEADER_TO_OTHER_BYTES}")
	ELECT_TOTAL_GB=$(bytes_to_gb "${ELECT_TOTAL_BYTES}")

	if [[ ${all_hosts_stable} -eq 1 ]]; then
		ELECT_OVERHEAD_STATUS="STABLE"
	else
		ELECT_OVERHEAD_STATUS="UNSTABLE"
	fi
}

wait_until_stable_elect_overhead() {
	local remote_log=$1
	local start_ts
	local now_ts
	local elapsed_sec
	local attempt=0

	start_ts=$(date +%s)

	while true; do
		attempt=$((attempt + 1))
		if collect_last_two_elect_overhead "${remote_log}" 0; then
			if [[ "${ELECT_OVERHEAD_STATUS}" == "STABLE" ]]; then
				return 0
			fi
			echo "ELECT overhead still changing (attempt=${attempt}), wait ${stable_check_interval_sec}s..." >&2
		else
			echo "ELECT overhead not ready yet (attempt=${attempt}), wait ${stable_check_interval_sec}s..." >&2
		fi

		now_ts=$(date +%s)
		elapsed_sec=$((now_ts - start_ts))
		if [[ ${stable_check_timeout_sec} -gt 0 && ${elapsed_sec} -ge ${stable_check_timeout_sec} ]]; then
			echo "Timed out waiting ELECT overhead to become stable after ${elapsed_sec}s." >&2
			collect_last_two_elect_overhead "${remote_log}" 1 || true
			return 1
		fi

		sleep "${stable_check_interval_sec}"
	done
}

snapshot_final_for_workload() {
	local workload=$1
	local host
	local key

	for host in "${elect_hosts[@]}"; do
		key="${workload}|${host}"
		FINAL_HOST_STATUS["${key}"]=${LAST_HOST_STATUS["${host}"]}
		FINAL_HOST_TS["${key}"]=${LAST_HOST_TS["${host}"]}
		FINAL_HOST_P2L_BYTES["${key}"]=${LAST_HOST_P2L_BYTES["${host}"]}
		FINAL_HOST_L2O_BYTES["${key}"]=${LAST_HOST_L2O_BYTES["${host}"]}
		FINAL_HOST_TOTAL_BYTES["${key}"]=${LAST_HOST_TOTAL_BYTES["${host}"]}
		FINAL_HOST_P2L_GB["${key}"]=${LAST_HOST_P2L_GB["${host}"]}
		FINAL_HOST_L2O_GB["${key}"]=${LAST_HOST_L2O_GB["${host}"]}
		FINAL_HOST_TOTAL_GB["${key}"]=${LAST_HOST_TOTAL_GB["${host}"]}
		FINAL_HOST_CODED_STRIPE["${key}"]=${LAST_HOST_CODED_STRIPE["${host}"]}
	done

	FINAL_WORKLOAD_STATUS["${workload}"]=${ELECT_OVERHEAD_STATUS}
	FINAL_WORKLOAD_P2L_BYTES["${workload}"]=${ELECT_PRIMARY_TO_LEADER_BYTES}
	FINAL_WORKLOAD_L2O_BYTES["${workload}"]=${ELECT_LEADER_TO_OTHER_BYTES}
	FINAL_WORKLOAD_TOTAL_BYTES["${workload}"]=${ELECT_TOTAL_BYTES}
	FINAL_WORKLOAD_P2L_GB["${workload}"]=${ELECT_PRIMARY_TO_LEADER_GB}
	FINAL_WORKLOAD_L2O_GB["${workload}"]=${ELECT_LEADER_TO_OTHER_GB}
	FINAL_WORKLOAD_TOTAL_GB["${workload}"]=${ELECT_TOTAL_GB}
	FINAL_WORKLOAD_CODED_STRIPE_SUM["${workload}"]=${ELECT_CODED_STRIPE_SUM}
}

generate_stats() {
	local input_file=$1
	local output_file=$2

	awk -F '\t' -v OFS='\t' '
	function t_critical_95(df) {
		if (df <= 1) return 12.706
		if (df == 2) return 4.303
		if (df == 3) return 3.182
		if (df == 4) return 2.776
		if (df == 5) return 2.571
		if (df == 6) return 2.447
		if (df == 7) return 2.365
		if (df == 8) return 2.306
		if (df == 9) return 2.262
		if (df == 10) return 2.228
		if (df == 11) return 2.201
		if (df == 12) return 2.179
		if (df == 13) return 2.160
		if (df == 14) return 2.145
		if (df == 15) return 2.131
		if (df == 16) return 2.120
		if (df == 17) return 2.110
		if (df == 18) return 2.101
		if (df == 19) return 2.093
		if (df == 20) return 2.086
		if (df == 21) return 2.080
		if (df == 22) return 2.074
		if (df == 23) return 2.069
		if (df == 24) return 2.064
		if (df == 25) return 2.060
		if (df == 26) return 2.056
		if (df == 27) return 2.052
		if (df == 28) return 2.048
		if (df == 29) return 2.045
		if (df == 30) return 2.042
		return 1.960
	}
	function add_sample(workload, metric, v) {
		key = workload SUBSEP metric
		sum[key] += v
		sumsq[key] += v * v
		n[key]++
		if (!(workload in seen_workload)) {
			seen_workload[workload] = 1
			workload_order[++workload_cnt] = workload
		}
	}
	NR == 1 { next }
	{
		w = $1
		add_sample(w, "primary_to_leader_gb", $8 + 0)
		add_sample(w, "leader_to_other_gb", $9 + 0)
		add_sample(w, "total_gb", $10 + 0)
	}
	END {
		print "workload", "metric", "n", "mean_gb", "ci95_gb"
		for (i = 1; i <= workload_cnt; i++) {
			w = workload_order[i]
			metrics[1] = "primary_to_leader_gb"
			metrics[2] = "leader_to_other_gb"
			metrics[3] = "total_gb"
			for (j = 1; j <= 3; j++) {
				m = metrics[j]
				key = w SUBSEP m
				if (n[key] <= 0) continue
				mean = sum[key] / n[key]
				if (n[key] > 1) {
					variance = (sumsq[key] - (sum[key] * sum[key] / n[key])) / (n[key] - 1)
					if (variance < 0 && variance > -1e-12) variance = 0
					sd = (variance > 0) ? sqrt(variance) : 0
					ci = t_critical_95(n[key] - 1) * sd / sqrt(n[key])
				} else {
					ci = 0
				}
				printf "%s\t%s\t%d\t%.6f\t%.6f\n", w, m, n[key], mean, ci
			}
		}
	}
	' "${input_file}" > "${output_file}"
}

write_final_report() {
	local output_file=$1
	local workload
	local host
	local key

	printf "workload\thost\tstatus\tlast_timestamp\tprimary_to_leader_bytes\tleader_to_other_bytes\ttotal_bytes\tprimary_to_leader_gb\tleader_to_other_gb\ttotal_gb\tcoded_stripe\n" > "${output_file}"

	for workload in "${workloads[@]}"; do
		for host in "${elect_hosts[@]}"; do
			key="${workload}|${host}"
			printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
				"${workload}" "${host}" "${FINAL_HOST_STATUS[${key}]}" "${FINAL_HOST_TS[${key}]}" \
				"${FINAL_HOST_P2L_BYTES[${key}]}" "${FINAL_HOST_L2O_BYTES[${key}]}" "${FINAL_HOST_TOTAL_BYTES[${key}]}" \
				"${FINAL_HOST_P2L_GB[${key}]}" "${FINAL_HOST_L2O_GB[${key}]}" "${FINAL_HOST_TOTAL_GB[${key}]}" \
				"${FINAL_HOST_CODED_STRIPE[${key}]}" \
				>> "${output_file}"
		done

		printf "%s\tSUM\t%s\tPER_HOST_LAST\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
			"${workload}" "${FINAL_WORKLOAD_STATUS[${workload}]}" \
			"${FINAL_WORKLOAD_P2L_BYTES[${workload}]}" "${FINAL_WORKLOAD_L2O_BYTES[${workload}]}" "${FINAL_WORKLOAD_TOTAL_BYTES[${workload}]}" \
			"${FINAL_WORKLOAD_P2L_GB[${workload}]}" "${FINAL_WORKLOAD_L2O_GB[${workload}]}" "${FINAL_WORKLOAD_TOTAL_GB[${workload}]}" \
			"${FINAL_WORKLOAD_CODED_STRIPE_SUM[${workload}]}" \
			>> "${output_file}"
	done
}

printf "workload\tepoch\tstatus\ttimestamp\tprimary_to_leader_bytes\tleader_to_other_bytes\ttotal_bytes\tprimary_to_leader_gb\tleader_to_other_gb\ttotal_gb\tcoded_stripe\n" > "${summary_file}"

echo "Running motivation exp1a with epoch=${epoch}, backup=${backup_label}, workloads=${workloads[*]}"

for workload in "${workloads[@]}"; do
	echo -e "\n*********Running motivation exp1a workload=${workload}, backup=${backup_label}*********"

	for ((run_idx = 1; run_idx <= epoch; run_idx++)); do
		run_tag="${date_time}_r$(printf "%02d" "${run_idx}")"
		output_base="ycsb_log/tmp_log/${nickname}_${backup_label}_${workload}_thread_${server_threads}_${client_threads}"
		output_path="${project_dir}/${output_base}_${run_tag}"
		server_log_path="/tmp/lijinming_tebis_server_${backup_label}_${workload}_${run_tag}.log"

		echo "Epoch ${run_idx}/${epoch}: workload=${workload}, tag=${run_tag}" >&2

		"${project_dir}/run_cluster.sh" -b "${backup_method}" -g "${gc_method}" -l "${load_times}" \
			-r "${run_times}" -u "${ops_higher_threshold}" -w "${workload}" -o "${output_base}" \
			-d "${run_tag}" -t "${server_threads}" -c "${client_threads}" -f "${regions_file}" -k \
			-s "${server_log_path}"

		servers_may_be_running=1

		ops_file="${output_path}/run_${workload}/ops.txt"
		filter_ops_file "${ops_file}"

		wait_until_stable_elect_overhead "${server_log_path}"
		stop_elect_servers
		servers_may_be_running=0

		printf "%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
			"${workload}" "${run_idx}" "${ELECT_OVERHEAD_STATUS}" "${ELECT_OVERHEAD_TIMESTAMP}" \
			"${ELECT_PRIMARY_TO_LEADER_BYTES}" "${ELECT_LEADER_TO_OTHER_BYTES}" "${ELECT_TOTAL_BYTES}" \
			"${ELECT_PRIMARY_TO_LEADER_GB}" "${ELECT_LEADER_TO_OTHER_GB}" "${ELECT_TOTAL_GB}" \
			"${ELECT_CODED_STRIPE_SUM}" \
			>> "${summary_file}"

		if [[ ${run_idx} -eq ${epoch} ]]; then
			snapshot_final_for_workload "${workload}"
		fi

		sleep 10
	done
done

generate_stats "${summary_file}" "${stats_file}"
write_final_report "${final_file}"

{
	echo ""
	echo "# mean_and_95ci"
	cat "${stats_file}"
} >> "${final_file}"

echo ""
echo "Final per-host and summed ELECT overhead:"
cat "${final_file}"
echo ""
echo "Mean and 95% CI over ${epoch} rounds:"
cat "${stats_file}"
echo ""
echo "Saved run summary: ${summary_file}"
echo "Saved mean and 95% CI summary: ${stats_file}"
echo "Saved final host+sum report: ${final_file}"
