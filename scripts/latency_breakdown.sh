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

usage() {
	cat <<'EOF'
Usage: ./latency_breakdown.sh -l <remote_log_path> [-o <output_file>] [-H "host1,host2,..."] [-p <plot_prefix>] [-n]

Description:
  Collects [time_counter] stats from each host log and merges them into one global view.
  For each host, only the latest line of each metric scope is used.
  Supports:
    - old format: count=...
    - new format: total(count=...) last100k(count=...)
  Metric names may contain spaces.

Options:
  -l  Required. Absolute path of log file on each remote host.
  -o  Optional. Write final merged table to this file as TSV.
  -H  Optional. Comma-separated host list. If omitted, built-in HOSTS is used.
  -p  Optional. Output prefix passed to plot_latency_breakdown.py.
  -n  Optional. Skip python plotting.
  -h  Show this help.
EOF
}

LOG_PATH=""
OUTPUT_PATH=""
PLOT_PREFIX="latency_breakdown"
ENABLE_PLOT=1

parse_args() {
	while getopts ":l:o:H:p:nh" opt; do
		case "${opt}" in
		l)
			LOG_PATH="${OPTARG}"
			;;
		o)
			OUTPUT_PATH="${OPTARG}"
			;;
		H)
			IFS=',' read -r -a HOSTS <<< "${OPTARG}"
			;;
		p)
			PLOT_PREFIX="${OPTARG}"
			;;
		n)
			ENABLE_PLOT=0
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

	if [[ -z "${LOG_PATH}" ]]; then
		echo "Missing required option: -l <remote_log_path>" >&2
		usage
		exit 1
	fi

	if [[ ${#HOSTS[@]} -eq 0 ]]; then
		echo "Host list is empty." >&2
		exit 1
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

# 只处理包含 [time_counter] 且带 count= 的行
/\[time_counter\]/ && /count=/ {
	line = $0

	# 提取 metric：
	# 从 [time_counter] 后开始，到第一个 " total(count=" 或 " last100k(count=" 或 " count=" 之前结束
	metric = line
	sub(/^.*\[time_counter\][[:space:]]+/, "", metric)

	stop = length(metric) + 1

	p1 = index(metric, " total(count=")
	if (p1 > 0 && p1 < stop) stop = p1

	p2 = index(metric, " last100k(count=")
	if (p2 > 0 && p2 < stop) stop = p2

	p3 = index(metric, " count=")
	if (p3 > 0 && p3 < stop) stop = p3

	metric = substr(metric, 1, stop - 1)
	gsub(/^[[:space:]]+|[[:space:]]+$/, "", metric)

	if (metric == "") {
		next
	}

	# 新格式：循环提取 total(...) / last100k(...) / 其他 scope(...)
	rest = line
	found_new_scope = 0

	while (match(rest, /([A-Za-z0-9_]+)\(count=[0-9.]+ avg=[0-9.]+ ns stddev=[0-9.]+ ns min=[0-9.]+ ns max=[0-9.]+ ns( p99=[0-9.]+ ns p999=[0-9.]+ ns)?\)/)) {
		block = substr(rest, RSTART, RLENGTH)
		scope = block
		sub(/\(.*/, "", scope)

		tmp = block
		sub(/^[^(]*\(count=/, "", tmp)
		sub(/ avg=.*/, "", tmp)
		cnt = tmp + 0

		tmp = block
		sub(/^.* avg=/, "", tmp)
		sub(/ ns stddev=.*/, "", tmp)
		avg = tmp + 0

		tmp = block
		sub(/^.* stddev=/, "", tmp)
		sub(/ ns min=.*/, "", tmp)
		stddev = tmp + 0

		tmp = block
		sub(/^.* min=/, "", tmp)
		sub(/ ns max=.*/, "", tmp)
		minv = tmp + 0

		tmp = block
		sub(/^.* max=/, "", tmp)
		sub(/ ns\).*/, "", tmp)
		maxv = tmp + 0

		p99 = 0
		if (block ~ / p99=[0-9.]+ ns/) {
			tmp = block
			sub(/^.* p99=/, "", tmp)
			sub(/ ns p999=.*/, "", tmp)
			p99 = tmp + 0
		}

		p999 = 0
		if (block ~ / p999=[0-9.]+ ns/) {
			tmp = block
			sub(/^.* p999=/, "", tmp)
			sub(/ ns\).*/, "", tmp)
			p999 = tmp + 0
		}

		key = metric SUBSEP scope
		last[key] = metric OFS scope OFS cnt OFS avg OFS stddev OFS minv OFS maxv OFS p99 OFS p999

		# 记录此 host 内首次出现顺序；最终仍只输出 latest line
		if (!(key in seen_order)) {
			seen_order[key] = 1
			order[++order_cnt] = key
		}

		rest = substr(rest, RSTART + RLENGTH)
		found_new_scope = 1
	}

	# 旧格式兜底：count=... avg=... stddev=... min=... max=...
	if (!found_new_scope && line ~ /count=/ && line ~ /avg=/ && line ~ /stddev=/ && line ~ /min=/ && line ~ /max=/) {
		scope = "total"

		tmp = line
		sub(/^.* count=/, "", tmp)
		sub(/ avg=.*/, "", tmp)
		cnt = tmp + 0

		tmp = line
		sub(/^.* avg=/, "", tmp)
		sub(/ ns stddev=.*/, "", tmp)
		avg = tmp + 0

		tmp = line
		sub(/^.* stddev=/, "", tmp)
		sub(/ ns min=.*/, "", tmp)
		stddev = tmp + 0

		tmp = line
		sub(/^.* min=/, "", tmp)
		sub(/ ns max=.*/, "", tmp)
		minv = tmp + 0

		tmp = line
		sub(/^.* max=/, "", tmp)
		sub(/ ns.*/, "", tmp)
		maxv = tmp + 0

		p99 = 0
		p999 = 0

		key = metric SUBSEP scope
		last[key] = metric OFS scope OFS cnt OFS avg OFS stddev OFS minv OFS maxv OFS p99 OFS p999

		if (!(key in seen_order)) {
			seen_order[key] = 1
			order[++order_cnt] = key
		}
	}
}

END {
	# 按该 host 日志中首次出现顺序输出，但值取 latest
	for (i = 1; i <= order_cnt; i++) {
		key = order[i]
		if (key in last) {
			print last[key]
		}
	}
}
' "${log_path}"
EOF
}

main() {
	parse_args "$@"

	local temp_dir
	temp_dir=$(mktemp -d)
	trap '[[ -n "${temp_dir:-}" ]] && rm -rf "${temp_dir}"' EXIT

	echo "Collecting metrics from ${#HOSTS[@]} hosts..." >&2

	local -a pids=()
	local -a ordered_files=()

	local idx
	for idx in "${!HOSTS[@]}"; do
		host="${HOSTS[$idx]}"
		out_file="${temp_dir}/$(printf "%04d" "$idx")_${host}.tsv"
		ordered_files+=("${out_file}")

		{
			if output=$(collect_single_host "${host}" "${LOG_PATH}"); then
				if [[ -n "${output}" ]]; then
					awk -v h="${host}" 'BEGIN {FS=OFS="\t"} {print h, $0}' <<< "${output}" > "${out_file}"
				else
					echo "WARN: ${host} has no [time_counter] data in ${LOG_PATH}" >&2
					: > "${out_file}"
				fi
			else
				echo "WARN: failed to read ${LOG_PATH} on ${host}" >&2
				: > "${out_file}"
			fi
		} &
		pids+=("$!")
	done

	local pid
	for pid in "${pids[@]}"; do
		wait "${pid}"
	done

	local has_data=0
	for f in "${ordered_files[@]}"; do
		if [[ -s "${f}" ]]; then
			has_data=1
			break
		fi
	done

	if [[ ${has_data} -eq 0 ]]; then
		echo "ERROR: no time_counter data collected from any host." >&2
		exit 1
	fi

	# 严格按 HOSTS 数组顺序拼接 host 文件
	cat "${ordered_files[@]}" | awk '
BEGIN {
	FS = OFS = "\t"
}
{
	host   = $1
	metric = $2
	scope  = $3
	n      = $4 + 0
	mu     = $5 + 0
	sd     = $6 + 0
	mn     = $7 + 0
	mx     = $8 + 0
	p99    = $9 + 0
	p999   = $10 + 0

	key = metric ":" scope

	# 全局首次出现顺序 = 按 HOSTS 顺序 + 各 host 内日志顺序
	if (!(key in seen_key)) {
		seen_key[key] = 1
		order[++order_cnt] = key
	}

	host_seen = host SUBSEP key
	if (!(host_seen in seen_host_key)) {
		seen_host_key[host_seen] = 1
		host_cnt[key]++
	}

	sum_n[key]  += n
	sum_x[key]  += n * mu
	sum_x2[key] += n * (sd * sd + mu * mu)
	sum_p99[key]  += n * p99
	sum_p999[key] += n * p999

	if (!(key in min_v) || mn < min_v[key]) {
		min_v[key] = mn
	}
	if (!(key in max_v) || mx > max_v[key]) {
		max_v[key] = mx
	}
}
END {
	for (i = 1; i <= order_cnt; i++) {
		k = order[i]

		if (sum_n[k] <= 0) {
			continue
		}

		avg = sum_x[k] / sum_n[k]
		var = (sum_x2[k] / sum_n[k]) - (avg * avg)
		if (var < 0 && var > -1e-12) {
			var = 0
		}
		stddev = (var > 0) ? sqrt(var) : 0
		merged_p99 = sum_p99[k] / sum_n[k]
		merged_p999 = sum_p999[k] / sum_n[k]

		printf "%s\t%d\t%.0f\t%.2f\t%.2f\t%.0f\t%.0f\t%.2f\t%.2f\n", \
			k, host_cnt[k], sum_n[k], avg, stddev, min_v[k], max_v[k], merged_p99, merged_p999
	}
}
' > "${temp_dir}/merged_body.tsv"

	{
		echo -e "metric\thost_count\ttotal_count\tavg_ns\tstddev_ns\tmin_ns\tmax_ns\tp99_ns\tp999_ns"
		cat "${temp_dir}/merged_body.tsv"
	} > "${temp_dir}/merged.tsv"

	cat "${temp_dir}/merged.tsv"

	if [[ -n "${OUTPUT_PATH}" ]]; then
		cp "${temp_dir}/merged.tsv" "${OUTPUT_PATH}"
		echo "Saved merged output to ${OUTPUT_PATH}" >&2
	fi

	if [[ ${ENABLE_PLOT} -eq 1 ]]; then
		local script_dir
		script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
		local plot_script="${script_dir}/plot_latency_breakdown.py"

		if [[ -f "${plot_script}" ]]; then
			if command -v python3 >/dev/null 2>&1; then
				# 这里不再传任何 sort 参数，顺序应保持 merged.tsv 输入顺序
				python3 "${plot_script}" -i "${temp_dir}/merged.tsv" -o "${PLOT_PREFIX}"
			else
				echo "WARN: python3 not found, skip plotting." >&2
			fi
		else
			echo "WARN: ${plot_script} not found, skip plotting." >&2
		fi
	fi
}

main "$@"