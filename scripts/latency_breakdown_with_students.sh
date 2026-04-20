#!/usr/bin/env bash

set -euo pipefail

HOSTS=(
	10.118.0.227
	10.118.0.28
	10.118.0.229
	10.118.0.30
	10.118.0.31
	10.118.0.32
)

declare -a LOG_PATHS=()
declare -a GROUP_NAMES=()
OUTPUT_PREFIX=""
CONVERT_NS_TO_US=1

usage() {
	cat <<'EOF'
Usage: ./latency_breakdown_with_students.sh -l <remote_log_path> [-l <remote_log_path> ...] [-G <group_name> ...] [-H "host1,host2,..."] [-o <output_prefix>]

Description:
  Collects [time_counter] metrics from each host for multiple groups of logs.
	Each group is merged by metric across hosts.
  Latency fields are converted from ns to us (divide by 1000) with 2 decimals.
  Outputs:
    1) Group-level merged table (TSV, ready to paste into Excel)
		2) Last-group classified students table (with flush / without flush / all)
			 with avg and 95% CI computed from count and stddev

Options:
  -l  Required, repeatable. Absolute log path for one group.
  -G  Optional, repeatable. Group name for each -l entry (same count as -l if used).
  -H  Optional. Comma-separated host list. If omitted, built-in HOSTS is used.
  -o  Optional. Output file prefix. Saves:
      <prefix>.groups.tsv and <prefix>.students.tsv
  -h  Show this help.
EOF
}

parse_args() {
	while getopts ":l:G:H:o:h" opt; do
		case "${opt}" in
		l)
			LOG_PATHS+=("${OPTARG}")
			;;
		G)
			GROUP_NAMES+=("${OPTARG}")
			;;
		H)
			IFS=',' read -r -a HOSTS <<< "${OPTARG}"
			;;
		o)
			OUTPUT_PREFIX="${OPTARG}"
			;;
		h)
			usage
			exit 0
			;;
		:)
			echo "Option -${OPTARG} requires an argument." >&2
			usage
			exit 1
			;;
		\?)
			echo "Unknown option: -${OPTARG}" >&2
			usage
			exit 1
			;;
		esac
	done

	if [[ ${#LOG_PATHS[@]} -eq 0 ]]; then
		echo "At least one -l <remote_log_path> is required." >&2
		usage
		exit 1
	fi

	if [[ ${#HOSTS[@]} -eq 0 ]]; then
		echo "Host list is empty." >&2
		exit 1
	fi

	if [[ ${#GROUP_NAMES[@]} -ne 0 && ${#GROUP_NAMES[@]} -ne ${#LOG_PATHS[@]} ]]; then
		echo "When -G is used, the number of group names must match the number of -l values." >&2
		exit 1
	fi
}

group_name_for_index() {
	local idx="$1"
	if [[ ${#GROUP_NAMES[@]} -ne 0 ]]; then
		echo "${GROUP_NAMES[$idx]}"
	else
		echo "group_$((idx + 1))"
	fi
}

collect_single_host() {
	local host="$1"
	local log_path="$2"

	ssh -o BatchMode=yes -o ConnectTimeout=8 "${host}" "bash -s -- \"${log_path}\"" <<'EOF'
set -euo pipefail
log_path="$1"

if [[ ! -r "${log_path}" ]]; then
	exit 2
fi

awk '
BEGIN {
	OFS = "\t"
}

/\[time_counter\]/ && /count=/ {
	line = $0
	payload = line
	sub(/^.*\[time_counter\][[:space:]]+/, "", payload)

	rest = payload
	found_count_block = 0
	base_metric = ""

	while (match(rest, /\(count=[^)]*\)/)) {
		block = substr(rest, RSTART, RLENGTH)
		prefix = substr(rest, 1, RSTART - 1)

		if (base_metric == "") {
			base_metric = prefix
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", base_metric)
			sub(/[[:space:]]+(total|last100k)$/, "", base_metric)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", base_metric)
		}

		metric = base_metric
		if (metric == "") {
			metric = prefix
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", metric)
		}
		if (metric == "") {
			rest = substr(rest, RSTART + RLENGTH)
			continue
		}

		tmp = block
		sub(/^\(count=/, "", tmp)
		sub(/[[:space:]]+avg=.*/, "", tmp)
		cnt = tmp + 0

		tmp = block
		sub(/^.* avg=/, "", tmp)
		sub(/[[:space:]]+ns[[:space:]]+stddev=.*/, "", tmp)
		avg = tmp + 0

		tmp = block
		sub(/^.* stddev=/, "", tmp)
		sub(/[[:space:]]+ns[[:space:]]+min=.*/, "", tmp)
		stddev = tmp + 0

		tmp = block
		sub(/^.* min=/, "", tmp)
		sub(/[[:space:]]+ns[[:space:]]+max=.*/, "", tmp)
		minv = tmp + 0

		tmp = block
		sub(/^.* max=/, "", tmp)
		sub(/[[:space:]]+ns\).*/, "", tmp)
		maxv = tmp + 0

		p50 = 0
		if (block ~ /[[:space:]]p50=[0-9.]+[[:space:]]ns/) {
			tmp = block
			sub(/^.* p50=/, "", tmp)
			sub(/[[:space:]]+ns.*/, "", tmp)
			p50 = tmp + 0
		}

		p99 = 0
		if (block ~ /[[:space:]]p99=[0-9.]+[[:space:]]ns/) {
			tmp = block
			sub(/^.* p99=/, "", tmp)
			sub(/[[:space:]]+ns.*/, "", tmp)
			p99 = tmp + 0
		}

		p999 = 0
		if (block ~ /[[:space:]]p999=[0-9.]+[[:space:]]ns/) {
			tmp = block
			sub(/^.* p999=/, "", tmp)
			sub(/[[:space:]]+ns\).*/, "", tmp)
			p999 = tmp + 0
		}

		key = metric
		last[key] = metric OFS cnt OFS avg OFS stddev OFS minv OFS maxv OFS p50 OFS p99 OFS p999

		if (!(key in seen_order)) {
			seen_order[key] = 1
			order[++order_cnt] = key
		}

		rest = substr(rest, RSTART + RLENGTH)
		found_count_block = 1
	}

	if (!found_count_block && payload ~ /count=/ && payload ~ /avg=/ && payload ~ /stddev=/ && payload ~ /min=/ && payload ~ /max=/) {
		metric = payload
		sub(/[[:space:]]+count=.*/, "", metric)
		gsub(/^[[:space:]]+|[[:space:]]+$/, "", metric)
		if (metric == "") next

		tmp = payload
		sub(/^.* count=/, "", tmp)
		sub(/ avg=.*/, "", tmp)
		cnt = tmp + 0

		tmp = payload
		sub(/^.* avg=/, "", tmp)
		sub(/ ns stddev=.*/, "", tmp)
		avg = tmp + 0

		tmp = payload
		sub(/^.* stddev=/, "", tmp)
		sub(/ ns min=.*/, "", tmp)
		stddev = tmp + 0

		tmp = payload
		sub(/^.* min=/, "", tmp)
		sub(/ ns max=.*/, "", tmp)
		minv = tmp + 0

		tmp = payload
		sub(/^.* max=/, "", tmp)
		sub(/ ns.*/, "", tmp)
		maxv = tmp + 0

		p50 = 0
		if (payload ~ / p50=[0-9.]+ ns/) {
			tmp = payload
			sub(/^.* p50=/, "", tmp)
			sub(/ ns.*/, "", tmp)
			p50 = tmp + 0
		}

		p99 = 0
		if (payload ~ / p99=[0-9.]+ ns/) {
			tmp = payload
			sub(/^.* p99=/, "", tmp)
			sub(/ ns.*/, "", tmp)
			p99 = tmp + 0
		}

		p999 = 0
		if (payload ~ / p999=[0-9.]+ ns/) {
			tmp = payload
			sub(/^.* p999=/, "", tmp)
			sub(/ ns.*/, "", tmp)
			p999 = tmp + 0
		}

		key = metric
		last[key] = metric OFS cnt OFS avg OFS stddev OFS minv OFS maxv OFS p50 OFS p99 OFS p999

		if (!(key in seen_order)) {
			seen_order[key] = 1
			order[++order_cnt] = key
		}
	}
}

END {
	for (i = 1; i <= order_cnt; i++) {
		key = order[i]
		if (key in last) print last[key]
	}
}
' "${log_path}"
EOF
}

merge_one_group() {
	local group_name="$1"
	local log_path="$2"
	local temp_dir="$3"
	local out_file="$4"

	echo "Collecting group '${group_name}' from ${#HOSTS[@]} hosts..." >&2

	local group_dir
	group_dir="${temp_dir}/${group_name}"
	mkdir -p "${group_dir}"

	local -a pids=()
	local -a ordered_files=()

	local idx host host_out
	for idx in "${!HOSTS[@]}"; do
		host="${HOSTS[$idx]}"
		host_out="${group_dir}/$(printf "%04d" "$idx")_${host}.tsv"
		ordered_files+=("${host_out}")

		{
			if output=$(collect_single_host "${host}" "${log_path}"); then
				if [[ -n "${output}" ]]; then
					awk -v h="${host}" 'BEGIN {FS=OFS="\t"} {print h, $0}' <<< "${output}" > "${host_out}"
				else
					echo "WARN: ${host} has no [time_counter] data in ${log_path}" >&2
					: > "${host_out}"
				fi
			else
				echo "WARN: failed to read ${log_path} on ${host}" >&2
				: > "${host_out}"
			fi
		} &
		pids+=("$!")
	done

	local pid
	for pid in "${pids[@]}"; do
		wait "${pid}"
	done

	local has_data=0
	local f
	for f in "${ordered_files[@]}"; do
		if [[ -s "${f}" ]]; then
			has_data=1
			break
		fi
	done

	if [[ ${has_data} -eq 0 ]]; then
		echo "ERROR: no time_counter data collected for group '${group_name}'." >&2
		return 1
	fi

	cat "${ordered_files[@]}" | awk '
BEGIN {
	FS = OFS = "\t"
}
{
	host   = $1
	metric = $2
	n      = $3 + 0
	mu     = $4 + 0
	sd     = $5 + 0
	mn     = $6 + 0
	mx     = $7 + 0
	p50    = $8 + 0
	p99    = $9 + 0
	p999   = $10 + 0

	key = metric

	if (!(key in seen_key)) {
		seen_key[key] = 1
		order[++order_cnt] = key
	}

	host_seen = host SUBSEP key
	if (!(host_seen in seen_host_key)) {
		seen_host_key[host_seen] = 1
		host_cnt[key]++
	}

	sum_n[key]    += n
	sum_x[key]    += n * mu
	sum_x2[key]   += n * (sd * sd + mu * mu)
	sum_p50[key]  += n * p50
	sum_p99[key]  += n * p99
	sum_p999[key] += n * p999

	if (!(key in min_v) || mn < min_v[key]) min_v[key] = mn
	if (!(key in max_v) || mx > max_v[key]) max_v[key] = mx
}
END {
	for (i = 1; i <= order_cnt; i++) {
		k = order[i]
		if (sum_n[k] <= 0) continue

		avg_ns = sum_x[k] / sum_n[k]
		var = (sum_x2[k] / sum_n[k]) - (avg_ns * avg_ns)
		if (var < 0 && var > -1e-12) var = 0
		stddev_ns = (var > 0) ? sqrt(var) : 0
		p50_ns = sum_p50[k] / sum_n[k]
		p99_ns = sum_p99[k] / sum_n[k]
		p999_ns = sum_p999[k] / sum_n[k]

		printf "%s\t%d\t%.0f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\n", \
			k, host_cnt[k], sum_n[k], avg_ns, stddev_ns, min_v[k], max_v[k], p50_ns, p99_ns, p999_ns
	}
}
' > "${out_file}"
}

build_students_summary() {
	local input_tsv="$1"
	local output_tsv="$2"
	local unit_label="$3"

	awk -v unit_label="${unit_label}" '
BEGIN {
	FS = OFS = "\t"
}

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

NR == 1 {
	next
}

{
	metric = $2
	for (j = 1; j <= 6; j++) {
		col = j + 4
		raw_val = $col
		if (raw_val != "") {
			val[j] = raw_val + 0
			has_val[j] = 1
		} else {
			has_val[j] = 0
		}
	}

	if (!(metric in seen_metric)) {
		seen_metric[metric] = 1
		order[++order_cnt] = metric
	}

	if (!(metric SUBSEP $1 in seen_group_metric)) {
		seen_group_metric[metric SUBSEP $1] = 1
		group_count[metric]++
	}

	for (j = 1; j <= 6; j++) {
		if (has_val[j]) {
			sum[metric, j] += val[j]
			sumsq[metric, j] += val[j] * val[j]
			obs_count[metric, j]++
		}
	}
}

END {
	print "metric", "group_count", \
		"avg_" unit_label, \
		"stddev_" unit_label, \
		"min_" unit_label, \
		"max_" unit_label, \
		"p99_" unit_label, \
		"p999_" unit_label

	for (i = 1; i <= order_cnt; i++) {
		m = order[i]
		n = group_count[m]
		printf "%s\t%d", m, n

		for (j = 1; j <= 6; j++) {
			nj = obs_count[m, j]
			if (nj <= 0) {
				printf "\t"
				continue
			}

			mean = sum[m, j] / nj
			if (nj > 1) {
				variance = (sumsq[m, j] - (sum[m, j] * sum[m, j] / nj)) / (nj - 1)
				if (variance < 0 && variance > -1e-12) variance = 0
				sd = (variance > 0) ? sqrt(variance) : 0
				tv = t_critical_95(nj - 1)
				ci = tv * sd / sqrt(nj)
			} else {
				ci = 0
			}

			printf "\t%.2f±%.2f", mean, ci
		}
		printf "\n"
	}
}
' "${input_tsv}" > "${output_tsv}"
}

write_last_group_summary() {
	local input_tsv="$1"
	local output_txt="$2"

	awk '
BEGIN {
	FS = OFS = "\t"
}

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

function add_value(base_key, col_idx, value) {
	sum[base_key, col_idx] += value
	sumsq[base_key, col_idx] += value * value
	nobs[base_key, col_idx]++
}

function append_count(base_key, count_v) {
	if (count_series[base_key] == "") {
		count_series[base_key] = sprintf("%.0f", count_v)
	} else {
		count_series[base_key] = count_series[base_key] "," sprintf("%.0f", count_v)
	}
}

function fmt_mean_ci(base_key, col_idx,    n, mean, variance, sd, tv, ci) {
	n = nobs[base_key, col_idx]
	if (n <= 0) return ""
	mean = sum[base_key, col_idx] / n
	if (n > 1) {
		variance = (sumsq[base_key, col_idx] - (sum[base_key, col_idx] * sum[base_key, col_idx] / n)) / (n - 1)
		if (variance < 0 && variance > -1e-12) variance = 0
		sd = (variance > 0) ? sqrt(variance) : 0
		tv = t_critical_95(n - 1)
		ci = tv * sd / sqrt(n)
	} else {
		ci = 0
	}
	return sprintf("%.2f±%.2f", mean, ci)
}

NR == 1 { next }

{
	metric = $2
	count_v = $4 + 0
	avg_us = $5 + 0
	stddev_us = $6 + 0
	min_us = $7 + 0
	max_us = $8 + 0
	p50_us = $9 + 0
	p99_us = $10 + 0
	p999_us = $11 + 0

	clean_metric = metric
	gsub(/\([^)]*\)/, "", clean_metric)
	gsub(/[[:space:]]+/, " ", clean_metric)
	gsub(/^[[:space:]]+|[[:space:]]+$/, "", clean_metric)

	lower_metric = tolower(metric)
	if (lower_metric ~ /\(with flush\)/) {
		section = "with flush"
	} else if (lower_metric ~ /\(without flush\)/) {
		section = "without flush"
	} else {
		section = "all"
	}

	base_key = section SUBSEP clean_metric
	if (!(base_key in seen_key)) {
		seen_key[base_key] = 1
		order[++order_cnt] = base_key
		section_of[base_key] = section
		metric_of[base_key] = clean_metric
	}

	append_count(base_key, count_v)
	add_value(base_key, 1, avg_us)
	add_value(base_key, 2, stddev_us)
	add_value(base_key, 3, min_us)
	add_value(base_key, 4, max_us)
	add_value(base_key, 5, p50_us)
	add_value(base_key, 6, p99_us)
	add_value(base_key, 7, p999_us)
}

END {
	sections[1] = "with flush"
	sections[2] = "without flush"
	sections[3] = "all"

	for (s = 1; s <= 3; s++) {
		cur = sections[s]
		print cur
		print "metric\tcounts\tavg_us\tstddev_us\tmin_us\tmax_us\tp50_us\tp99_us\tp999_us"
		for (i = 1; i <= order_cnt; i++) {
			k = order[i]
			if (section_of[k] != cur) continue
			printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
				metric_of[k], \
				count_series[k], \
				fmt_mean_ci(k, 1), \
				fmt_mean_ci(k, 2), \
				fmt_mean_ci(k, 3), \
				fmt_mean_ci(k, 4), \
				fmt_mean_ci(k, 5), \
				fmt_mean_ci(k, 6), \
				fmt_mean_ci(k, 7)
		}
		if (s < 3) print ""
	}
}
' "${input_tsv}" > "${output_txt}"
}

main() {
	parse_args "$@"

	local unit_divisor unit_label
	if [[ ${CONVERT_NS_TO_US} -eq 1 ]]; then
		unit_divisor=1000
		unit_label="us"
	else
		unit_divisor=1
		unit_label="ns"
	fi

	local temp_dir
	temp_dir=$(mktemp -d)
	trap '[[ -n "${temp_dir:-}" ]] && rm -rf "${temp_dir}"' EXIT

	local groups_tsv students_tsv
	groups_tsv="${temp_dir}/all_groups.tsv"
	students_tsv="${temp_dir}/students_summary.tsv"

	echo -e "group\tmetric\thost_count\tcount\tavg_${unit_label}\tstddev_${unit_label}\tmin_${unit_label}\tmax_${unit_label}\tp50_${unit_label}\tp99_${unit_label}\tp999_${unit_label}" > "${groups_tsv}"

	local idx group_name group_file
	for idx in "${!LOG_PATHS[@]}"; do
		group_name=$(group_name_for_index "${idx}")
		group_file="${temp_dir}/${group_name}.tsv"
		merge_one_group "${group_name}" "${LOG_PATHS[$idx]}" "${temp_dir}" "${group_file}"
		awk -v g="${group_name}" -v unit_divisor="${unit_divisor}" 'BEGIN {FS=OFS="\t"} {print g, $1, $2, $3, sprintf("%.2f", $4 / unit_divisor), sprintf("%.2f", $5 / unit_divisor), sprintf("%.2f", $6 / unit_divisor), sprintf("%.2f", $7 / unit_divisor), sprintf("%.2f", $8 / unit_divisor), sprintf("%.2f", $9 / unit_divisor), sprintf("%.2f", $10 / unit_divisor)}' "${group_file}" >> "${groups_tsv}"
	done

	write_last_group_summary "${groups_tsv}" "${students_tsv}"

	echo "===== Group Merged Table (paste into Excel) ====="
	cat "${groups_tsv}"
	echo
	echo "===== Students Table (all groups summarized by flush tag) ====="
	cat "${students_tsv}"

	if [[ -n "${OUTPUT_PREFIX}" ]]; then
		cp "${groups_tsv}" "${OUTPUT_PREFIX}.groups.tsv"
		cp "${students_tsv}" "${OUTPUT_PREFIX}.students.tsv"
		echo "Saved: ${OUTPUT_PREFIX}.groups.tsv" >&2
		echo "Saved: ${OUTPUT_PREFIX}.students.tsv" >&2
	fi
}

main "$@"
