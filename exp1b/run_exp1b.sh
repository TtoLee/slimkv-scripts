#!/usr/bin/env bash

set -euo pipefail

nickname=""
project_dir="/home/lijinming/tebis"

gc_method=none
backup_methods=(
    replica
    offline_coding
    elect
)
load_times=100000000
run_times=500000000
ops_lower_threshold=000000000
ops_higher_threshold=300000000
workloads=(
    load
) 
server_threads=4
client_threads=32
date_time=$(date +%Y%m%d_%H%M%S)

usage() {
    echo "Usage: $0 -n nickname"
}

while getopts "n:" opt; do
    case $opt in
    n) nickname=${OPTARG} ;;
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

declare -A run_output_paths

resolve_backup_config() {
    local backup_label=$1

    case "${backup_label}" in
    elect)
        echo "elect regions_file_elect"
        ;;
    replica)
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
    # if [[ "${workload}" == "load" ]]; then
    #     higher_threshold=$((ops_higher_threshold + load_times))
    # fi

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

for workload in "${workloads[@]}"; do
    for backup_label in "${backup_methods[@]}"; do
        echo -e "\n*********Running experiment with workload: ${workload}, backup method: ${backup_label}*********"

        read -r backup_method regions_file <<< "$(resolve_backup_config "${backup_label}")"

        run_tag="${date_time}"
        output_base="ycsb_log/exp1b/${nickname}_${backup_label}_${workload}_thread_${server_threads}_${client_threads}"
        output_path="${project_dir}/${output_base}_${run_tag}"

        "${project_dir}/run_cluster.sh" -b "${backup_method}" -g "${gc_method}" -l "${load_times}" \
            -r "${run_times}" -w "${workload}" -o "${output_base}" \
            -d "${run_tag}" -t "${server_threads}" -c "${client_threads}" -f "${regions_file}" \
            -s "/tmp/lijinming_tebis_server_${backup_label}_${workload}_${run_tag}.log"

        ops_file="${output_path}/run_${workload}/ops.txt"
        filter_ops_file "${ops_file}"
        run_output_paths["${backup_label}_${workload}"]="${output_path}"
        sleep 10
    done
done

for workload in "${workloads[@]}"; do
    dir1=${run_output_paths["${backup_methods[0]}_${workload}"]:-}
    dir2=${run_output_paths["${backup_methods[1]}_${workload}"]:-}
    dir3=${run_output_paths["${backup_methods[2]}_${workload}"]:-}

    if [[ -z "${dir1}" || -z "${dir2}" || -z "${dir3}" ]]; then
        echo "Skip plotting for workload=${workload}: missing run output path" >&2
        continue
    fi

    output_plot="${project_dir}/ycsb_log/exp1b/${nickname}_${workload}_thread_${server_threads}_${client_threads}_throughput_${date_time}.png"

    python3 "${project_dir}/plot_ops_triple.py" \
        --dir1 "${dir1}" \
        --dir2 "${dir2}" \
        --dir3 "${dir3}" \
        --label1 "${backup_methods[0]}" \
        --label2 "${backup_methods[1]}" \
        --label3 "${backup_methods[2]}" \
        --title "YCSB Throughput Over Time (${workload})" \
        --output "${output_plot}"

    echo "Saved triple-line plot: ${output_plot}"
done