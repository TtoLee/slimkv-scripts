#!/usr/bin/env bash

set -euo pipefail

nickname=""
project_dir="/home/lijinming/tebis"
script_dir="${project_dir}/ycsb_log/scripts"

epoch=5
gc_method=none
backup_methods=(
    replication
    offline_coding
)
load_times=100000000
run_times=1000000000
ops_lower_threshold=200000000
ops_higher_threshold=700000000
workloads=(
    c
    ) 
server_threads=8
client_threads=32
date_time=$(date +%Y%m%d_%H%M%S)
results_dir=""
plot_dir=""
latency_dir=""
client_logs_dir=""
plot_inputs_dir=""
filtered_ops_dir=""
unified_metrics_file=""

latency_hosts=(
    10.118.0.227
    10.118.0.28
    10.118.0.229
    10.118.0.30
    10.118.0.31
    10.118.0.32
)

usage() {
    echo "Usage: $0 -n nickname [-e epoch]"
}

while getopts "n:e:" opt; do
    case $opt in
    n) nickname=${OPTARG} ;;
    e) epoch=${OPTARG} ;;
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

results_dir="${project_dir}/ycsb_log/exp1/${nickname}_${date_time}"
plot_dir="${results_dir}/output"
latency_dir="${results_dir}/latency"
client_logs_dir="${results_dir}/client_logs"
plot_inputs_dir="${results_dir}/plot_inputs"
filtered_ops_dir="${plot_inputs_dir}/filtered_ops"
mkdir -p "${plot_dir}" "${latency_dir}" "${client_logs_dir}" "${filtered_ops_dir}"
unified_metrics_file="${latency_dir}/throughput_latency_unified.tsv"
printf "section\tworkload\tbackup_method\tepoch\tmetric\tgroup\tselected_total_count\tthroughput_kops\tavg_us\tstddev_us\tmin_us\tmax_us\tp50_us\tp99_us\tp999_us\n" > "${unified_metrics_file}"

declare -A sample_ops_paths

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
    local filtered_file=$2
    local higher_threshold

    higher_threshold=${ops_higher_threshold}
    if [[ "${workload}" == "load" ]]; then
        higher_threshold=$((ops_higher_threshold + load_times))
    fi

    if [[ ! -f "${ops_file}" ]]; then
        echo "Skip filtering, file not found: ${ops_file}" >&2
        return 1
    fi

    mkdir -p "$(dirname "${filtered_file}")"
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
    ' "${ops_file}" > "${filtered_file}"
    echo "${filtered_file}"
}

compute_kops_from_ops_file() {
    local ops_file=$1

    awk '
    {
        if (match($0, /([0-9]+)[[:space:]]+sec[[:space:]]+([0-9.eE+-]+)[[:space:]]+operations/, m)) {
            sec = m[1] + 0
            operations = m[2] + 0
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

run_latency_summary_for_backup() {
    local backup_label="$1"
    local workload="$2"
    shift 2
    local log_paths=("$@")

    if [[ ${#log_paths[@]} -eq 0 ]]; then
        echo "Skip latency summary for ${backup_label}/${workload}: no log paths." >&2
        return
    fi

    local filtered_students_summary_file
    filtered_students_summary_file="${latency_dir}/${backup_label}_${workload}.students.tsv"
    echo "Generating latency summary for backup=${backup_label}, workload=${workload}" >&2

    summarize_latency_for_workload "${workload}" "${filtered_students_summary_file}" "${log_paths[@]}"

    if [[ -f "${filtered_students_summary_file}" ]]; then
        echo "  - ${filtered_students_summary_file}" >&2
        echo "Filtered latency summary (PUT/GET/YCSB total):" >&2
        cat "${filtered_students_summary_file}" >&2

        awk -F '\t' -v OFS='\t' -v workload="${workload}" -v backup_label="${backup_label}" '
        NR == 1 { next }
        {
            printf "latency\t%s\t%s\tall\t%s\t%s\t%s\t\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                workload, backup_label, $1, $2, $3, $4, $5, $6, $7, $8, $9, $10
        }
        ' "${filtered_students_summary_file}" >> "${unified_metrics_file}"
    fi
}

summarize_latency_for_workload() {
    local workload="$1"
    local output_file="$2"
    shift 2
    local log_paths=("$@")

    if [[ ${#log_paths[@]} -eq 0 ]]; then
        echo "Skip filtered latency summary, no log paths." >&2
        return
    fi

    local selected_rows
    selected_rows=$(mktemp)

    local temp_dir
    temp_dir=$(mktemp -d)

    local gi
    for gi in "${!log_paths[@]}"; do
        local group_name
        local group_log_path
        local group_host_rows

        group_name="ep_$(printf "%02d" $((gi + 1)))"
        group_log_path="${log_paths[$gi]}"
        group_host_rows="${temp_dir}/${group_name}.host_rows.tsv"

        : > "${group_host_rows}"

        local host
        for host in "${latency_hosts[@]}"; do
            if output=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "${host}" "bash -s -- \"${group_log_path}\"" <<'EOF'
set -euo pipefail
log_path="$1"

if [[ ! -r "${log_path}" ]]; then
    exit 2
fi

awk '
BEGIN {
    OFS = "\t"
}
function trim(s) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    return s
}
function canonical_metric(raw,    m) {
    m = toupper(trim(raw))
    gsub(/[[:space:]]+/, " ", m)

    if (m == "YCSB REQUEST NS" || m == "YCSB REQUEST") return "YCSB REQUESTS"
    if (m == "PUT REQUEST") return "PUT REQUESTS"
    if (m == "GET REQUEST") return "GET REQUESTS"
    return m
}
function extract_first(line, pattern, prefix_re, suffix_re, default_value,    tmp) {
    if (!match(line, pattern)) {
        return default_value
    }
    tmp = substr(line, RSTART, RLENGTH)
    if (prefix_re != "") sub(prefix_re, "", tmp)
    if (suffix_re != "") sub(suffix_re, "", tmp)
    return tmp + 0
}
/\[time_counter\]/ && /count=/ {
    line = $0
    metric = line
    sub(/^.*\[time_counter\][[:space:]]+/, "", metric)

    # Support both formats:
    # [time_counter] METRIC total(count=...)
    # [time_counter] METRIC (count=...)
    sub(/[[:space:]]+total\(count=.*/, "", metric)
    sub(/[[:space:]]*\(count=.*/, "", metric)
    metric = canonical_metric(metric)

    if (!(metric == "YCSB REQUESTS" || metric == "PUT REQUESTS" || metric == "GET REQUESTS")) {
        next
    }

    occ[metric]++
    idx = occ[metric]

    # Parse the first stats tuple in the line as the "total" scope.
    # This makes the parser tolerant to both old/new counter formats.
    cnt = extract_first(line, "count=[0-9.eE+-]+", "^count=", "", -1)
    avg = extract_first(line, " avg=[0-9.eE+-]+ ns", "^ avg=", " ns$", -1)
    stddev = extract_first(line, " stddev=[0-9.eE+-]+ ns", "^ stddev=", " ns$", -1)
    minv = extract_first(line, " min=[0-9.eE+-]+ ns", "^ min=", " ns$", -1)
    maxv = extract_first(line, " max=[0-9.eE+-]+ ns", "^ max=", " ns$", -1)

    if (cnt < 0 || avg < 0 || stddev < 0 || minv < 0 || maxv < 0) {
        next
    }

    p50 = extract_first(line, " p50=[0-9.eE+-]+ ns", "^ p50=", " ns$", 0)
    p99 = extract_first(line, " p99=[0-9.eE+-]+ ns", "^ p99=", " ns$", 0)
    p999 = extract_first(line, " p999=[0-9.eE+-]+ ns", "^ p999=", " ns$", 0)

    print idx, metric, "total", cnt, avg, stddev, minv, maxv, p50, p99, p999
}
' "${log_path}"
EOF
); then
                if [[ -n "${output}" ]]; then
                    awk -v h="${host}" 'BEGIN {FS=OFS="\t"} {print h, $0}' <<< "${output}" >> "${group_host_rows}"
                else
                    echo "WARN: no matching time_counter rows in ${group_log_path} on ${host}" >&2
                fi
            else
                echo "WARN: failed to read ${group_log_path} on ${host}" >&2
            fi
        done

        if [[ ! -s "${group_host_rows}" ]]; then
            echo "WARN: no host rows parsed for group ${group_name}" >&2
            continue
        fi

        awk -F '\t' -v OFS='\t' -v group_name="${group_name}" '
        $4 == "total" && ($3 == "PUT REQUESTS" || $3 == "GET REQUESTS" || $3 == "YCSB REQUESTS") {
            host_metric_key = $1 SUBSEP $3
            idx = $2 + 0
            if (!(host_metric_key in last_idx) || idx >= last_idx[host_metric_key]) {
                last_idx[host_metric_key] = idx
                last_n[host_metric_key] = $5 + 0
                last_avg[host_metric_key] = $6 + 0
                last_stddev[host_metric_key] = $7 + 0
                last_min[host_metric_key] = $8 + 0
                last_max[host_metric_key] = $9 + 0
                last_p50[host_metric_key] = $10 + 0
                last_p99[host_metric_key] = $11 + 0
                last_p999[host_metric_key] = $12 + 0
            }
        }
        END {
            for (host_metric_key in last_idx) {
                split(host_metric_key, parts, SUBSEP)
                metric = parts[2]
                n = last_n[host_metric_key]
                avg = last_avg[host_metric_key]
                stddev = last_stddev[host_metric_key]
                minv = last_min[host_metric_key]
                maxv = last_max[host_metric_key]
                p50 = last_p50[host_metric_key]
                p99 = last_p99[host_metric_key]
                p999 = last_p999[host_metric_key]

                if (!(host_metric_key in seen_host_metric)) {
                    seen_host_metric[host_metric_key] = 1
                    host_count[metric]++
                }

                sum_n[metric] += n
                sum_x[metric] += n * avg
                sum_x2[metric] += n * (stddev * stddev + avg * avg)
                sum_p50[metric] += n * p50
                sum_p99[metric] += n * p99
                sum_p999[metric] += n * p999

                if (!(metric in min_all) || minv < min_all[metric]) min_all[metric] = minv
                if (!(metric in max_all) || maxv > max_all[metric]) max_all[metric] = maxv
                if (!(metric in seen_metric)) {
                    seen_metric[metric] = 1
                    order[++order_cnt] = metric
                }
            }

            for (i = 1; i <= order_cnt; i++) {
                metric = order[i]
                if (sum_n[metric] <= 0) continue

                avg = sum_x[metric] / sum_n[metric]
                var = (sum_x2[metric] / sum_n[metric]) - (avg * avg)
                if (var < 0 && var > -1e-12) var = 0
                stddev = (var > 0) ? sqrt(var) : 0
                p50 = sum_p50[metric] / sum_n[metric]
                p99 = sum_p99[metric] / sum_n[metric]
                p999 = sum_p999[metric] / sum_n[metric]

                printf "%s\t%s\t%d\t%.0f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\n", group_name, metric, host_count[metric], sum_n[metric], avg / 1000.0, stddev / 1000.0, min_all[metric] / 1000.0, max_all[metric] / 1000.0, p50 / 1000.0, p99 / 1000.0, p999 / 1000.0
            }
        }
        ' "${group_host_rows}" >> "${selected_rows}"
    done

    if [[ ! -s "${selected_rows}" ]]; then
        echo "Skip filtered latency summary, no selected rows generated." >&2
        rm -rf "${temp_dir}"
        rm -f "${selected_rows}"
        return
    fi

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
    function fmt_mean_ci(sumv, sumsqv, n,    mean, variance, sd, tv, ci) {
        if (n <= 0) {
            return ""
        }
        mean = sumv / n
        if (n > 1) {
            variance = (sumsqv - (sumv * sumv / n)) / (n - 1)
            if (variance < 0 && variance > -1e-12) variance = 0
            sd = (variance > 0) ? sqrt(variance) : 0
            tv = t_critical_95(n - 1)
            ci = tv * sd / sqrt(n)
        } else {
            ci = 0
        }
        return sprintf("%.2f±%.2f", mean, ci)
    }
    {
        metric = $2
        total_count = $4 + 0
        avg = $5 + 0
        stddev = $6 + 0
        minv = $7 + 0
        maxv = $8 + 0
        p50 = $9 + 0
        p99 = $10 + 0
        p999 = $11 + 0

        if (!(metric in seen_metric)) {
            seen_metric[metric] = 1
            metric_order[++metric_order_cnt] = metric
        }

        if (!(metric SUBSEP $1 in seen_group_metric)) {
            seen_group_metric[metric SUBSEP $1] = 1
            group_count[metric]++
        }

        sample_count[metric] += total_count

        sum[metric, 1] += avg
        sumsq[metric, 1] += avg * avg
        obs[metric, 1]++

        sum[metric, 2] += stddev
        sumsq[metric, 2] += stddev * stddev
        obs[metric, 2]++

        sum[metric, 3] += minv
        sumsq[metric, 3] += minv * minv
        obs[metric, 3]++

        sum[metric, 4] += maxv
        sumsq[metric, 4] += maxv * maxv
        obs[metric, 4]++

        sum[metric, 5] += p50
        sumsq[metric, 5] += p50 * p50
        obs[metric, 5]++

        sum[metric, 6] += p99
        sumsq[metric, 6] += p99 * p99
        obs[metric, 6]++

        sum[metric, 7] += p999
        sumsq[metric, 7] += p999 * p999
        obs[metric, 7]++
    }
    END {
        print "metric", "group", "selected_total_count", "avg", "stddev", "min", "max", "p50", "p99", "p999"
        for (i = 1; i <= metric_order_cnt; i++) {
            metric = metric_order[i]
            printf "%s\t%d\t%.0f", metric, group_count[metric], sample_count[metric]
            for (j = 1; j <= 7; j++) {
                printf "\t%s", fmt_mean_ci(sum[metric, j], sumsq[metric, j], obs[metric, j])
            }
            printf "\n"
        }
    }
    ' "${selected_rows}" > "${output_file}"

    rm -rf "${temp_dir}"
    rm -f "${selected_rows}"
}

for workload in "${workloads[@]}"; do
    for backup_label in "${backup_methods[@]}"; do
        echo -e "\n*********Running experiment with workload: ${workload}, backup method: ${backup_label}, epoch=${epoch}*********"

        read -r backup_method regions_file <<< "$(resolve_backup_config "${backup_label}")"
        log_paths_for_summary=()

        for ((ep = 1; ep <= epoch; ep++)); do
            run_tag="${date_time}_ep${ep}"
            output_base="ycsb_log/tmp_log/${nickname}_${backup_label}_${workload}_thread_${server_threads}_${client_threads}_ep${ep}"
            output_path="${project_dir}/${output_base}_${run_tag}"
            server_log_path="/tmp/lijinming_tebis_server_${backup_label}_${workload}_${run_tag}.log"

            echo "Epoch ${ep}/${epoch}: workload=${workload}, method=${backup_label}"
            "${script_dir}/run_cluster.sh" -b "${backup_method}" -g "${gc_method}" -l "${load_times}" \
                -r "${run_times}" -u "${ops_higher_threshold}" -w "${workload}" -o "${output_base}" \
                -d "${run_tag}" -t "${server_threads}" -c "${client_threads}" -f "${regions_file}" \
                -s "${server_log_path}"

            if [[ ! -d "${output_path}" ]]; then
                echo "Missing collected client output directory: ${output_path}" >&2
                exit 1
            fi

            cp -a "${output_path}" "${client_logs_dir}/"
            client_log_path="${client_logs_dir}/$(basename "${output_path}")"

            ops_file="${client_log_path}/run_${workload}/ops.txt"
            filtered_ops_relative="plot_inputs/filtered_ops/${backup_label}_${workload}_ep${ep}.ops.txt"
            filtered_ops_file="${results_dir}/${filtered_ops_relative}"
            filter_ops_file "${ops_file}" "${filtered_ops_file}" > /dev/null || {
                echo "Failed to filter ${ops_file}" >&2
                exit 1
            }

            kops=$(compute_kops_from_ops_file "${filtered_ops_file}") || {
                echo "Failed to compute throughput from ${filtered_ops_file}" >&2
                exit 1
            }

            echo "Epoch ${ep} throughput: ${kops} kops/sec"

            group_name=$(printf "ep_%02d" "${ep}")
            printf "throughput\t%s\t%s\t%s\tTHROUGHPUT\t%s\t\t%s\t\t\t\t\t\t\t\n" \
                "${workload}" "${backup_label}" "${ep}" "${group_name}" "${kops}" >> "${unified_metrics_file}"

            sample_key="${backup_label}_${workload}"
            if [[ -n "${sample_ops_paths[${sample_key}]:-}" ]]; then
                sample_ops_paths["${sample_key}"]+=";${filtered_ops_relative}"
            else
                sample_ops_paths["${sample_key}"]="${filtered_ops_relative}"
            fi

            log_paths_for_summary+=("${server_log_path}")
            sleep 10
        done

        run_latency_summary_for_backup "${backup_label}" "${workload}" "${log_paths_for_summary[@]}"
    done
done

groups_file="${plot_inputs_dir}/groups-file.txt"
summary_plot_file="${plot_inputs_dir}/summary-input.tsv"
: > "${groups_file}"
: > "${summary_plot_file}"

for workload in "${workloads[@]}"; do
    group_line=""
    for backup_label in "${backup_methods[@]}"; do
        group_line+="${sample_ops_paths[${backup_label}_${workload}]} "

        summary_file="${latency_dir}/${backup_label}_${workload}.students.tsv"
        if [[ ! -f "${summary_file}" ]]; then
            echo "Missing latency summary file: ${summary_file}" >&2
            exit 1
        fi

        read -r p50_field p99_field p999_field < <(
            awk -F '\t' '$1 == "YCSB REQUESTS" {print $8, $9, $10; exit}' "${summary_file}"
        )

        if [[ -z "${p50_field}" || -z "${p99_field}" || -z "${p999_field}" ]]; then
            echo "Invalid YCSB latency fields (p50/p99/p999) in ${summary_file}" >&2
            exit 1
        fi

        # Column order matches plot_grouped_ops_bar.py parse_summary_file expectations.
        printf "%s\t%s\t%s\t-\t-\t-\t%s\t%s\n" "${workload}" "${backup_label}" "${p50_field}" "${p99_field}" "${p999_field}" >> "${summary_plot_file}"
    done
    printf "%s\n" "${group_line}" >> "${groups_file}"
done

bar_label_csv=$(printf "%s," "${workloads[@]}")
bar_label_csv=${bar_label_csv%,}
bar_label_csv=$(echo "${bar_label_csv}" | tr '[:lower:]' '[:upper:]')

display_backup_labels=()
for label in "${backup_methods[@]}"; do
    display_backup_labels+=("${label//_/ }")
done
item_label_csv=$(printf "%s," "${display_backup_labels[@]}")
item_label_csv=${item_label_csv%,}

plot_output_dir="output"
groups_file_arg="plot_inputs/groups-file.txt"
summary_plot_file_arg="plot_inputs/summary-input.tsv"

echo "Executing command:"
echo "cd \"${results_dir}\" && python3 \"${script_dir}/plot_grouped_ops_bar.py\" --groups-file \"${groups_file_arg}\" --summary-input \"${summary_plot_file_arg}\" --bar-label \"${bar_label_csv}\" --item-labels \"${item_label_csv}\" --x-axis-label \"Workload\" --y1-axis-label \"Throughput (kops/sec)\" --y2-axis-label \"P50 latency (us)\" --y3-axis-label \"P99 latency (us)\" --y4-axis-label \"P999 latency (us)\" --output \"${plot_output_dir}\""

(
cd "${results_dir}"
python3 "${script_dir}/plot_grouped_ops_bar.py" \
    --groups-file "${groups_file_arg}" \
    --summary-input "${summary_plot_file_arg}" \
    --bar-label "${bar_label_csv}" \
    --item-labels "${item_label_csv}" \
    --x-axis-label "Workload" \
    --y1-axis-label "Throughput (kops/sec)" \
    --y2-axis-label "P50 latency (us)" \
    --y3-axis-label "P99 latency (us)" \
    --y4-axis-label "P999 latency (us)" \
    --output "${plot_output_dir}"
)
