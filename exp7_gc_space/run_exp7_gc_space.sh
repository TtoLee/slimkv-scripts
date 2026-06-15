    #!/usr/bin/env bash

    set -euo pipefail

    nickname=""
    project_dir="/home/lijinming/tebis"
    basic_script_dir="/home/lijinming/tebis/ycsb_log/scripts"
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

    backup_method="offline_coding"
    regions_file="regions_file_cross"
    gc_methods=(
        none
        normal
        sync
    )
    valid_segments_threshold_value=2
    high_amplification_power_value=0.2
    cmake_args=()
    load_times=100000000
    run_times=1500000000
    ops_lower_threshold=200000000
    ops_higher_threshold=2000000000
    workloads=(
        a
    )
    server_threads=4
    client_threads=16
    date_time=$(date +%Y%m%d_%H%M%S)
    stable_check_interval_sec=400
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
    results_rel=""
    client_logs_dir=""
    throughput_file=""
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
    SPACE_TIMESTAMP="PER_HOST_LAST"
    SPACE_TOTAL_USED_BYTES=""
    SPACE_TOTAL_USED_GIB=""
    SPACE_PER_HOST_USED_BYTES=""
    SPACE_PER_HOST_USED_GIB=""
    DISK_TOTAL_WRITE_BYTES=""
    DISK_TOTAL_WRITE_GIB=""
    DISK_PER_HOST_WRITE_BYTES=""
    DISK_PER_HOST_WRITE_GIB=""
    DISK_PER_HOST_WRITE_PIDS=""

    declare -A LAST_HOST_STATUS=()
    declare -A LAST_HOST_TS=()
    declare -A LAST_HOST_USED_BYTES=()
    declare -A LAST_HOST_USED_GIB=()
    declare -A PREV_HOST_USED_BYTES=()
    declare -A PREV_HOST_USED_GIB=()
    declare -A LAST_HOST_DISK_WRITE_PIDS=()
    declare -A LAST_HOST_DISK_WRITE_BYTES=()
    declare -A LAST_HOST_DISK_WRITE_GIB=()

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

    if [[ -n "${DESIGN_EXP_HOSTS:-}" ]]; then
        read -r -a hosts <<< "${DESIGN_EXP_HOSTS}"
    fi

    if [[ ${#hosts[@]} -lt 1 ]]; then
        echo "hosts must contain at least one host." >&2
        exit 1
    fi

    results_dir="${script_dir}/${nickname}_${date_time}"
    mkdir -p "${results_dir}"
    results_rel="${results_dir#${project_dir}/}"
    if [[ "${results_rel}" == "${results_dir}" ]]; then
        echo "results_dir must be under project_dir. results_dir=${results_dir}, project_dir=${project_dir}" >&2
        exit 1
    fi
    client_logs_dir="${results_dir}/client_logs"
    mkdir -p "${client_logs_dir}"
    throughput_file="${results_dir}/throughput.tsv"
    summary_file="${results_dir}/space_occupation_summary.tsv"
    host_file="${results_dir}/space_occupation_hosts.tsv"
    printf "workload\tbackup_method\tgc_method\tthroughput_kops\tops_file\n" > "${throughput_file}"
    printf "workload\tbackup_method\tgc_method\tstatus\ttotal_used_bytes\ttotal_used_gib\tper_host_used_bytes\tper_host_used_gib\ttotal_disk_write_bytes\ttotal_disk_write_gib\tper_host_disk_write_bytes\tper_host_disk_write_gib\tper_host_disk_write_pids\tserver_log_path\n" > "${summary_file}"
    printf "workload\tbackup_method\tgc_method\thost\tstatus\tlast_timestamp\tused_bytes\tused_gib\tprev_used_bytes\tprev_used_gib\tdisk_write_pids\tdisk_write_bytes\tdisk_write_gib\tserver_log_path\n" > "${host_file}"

    stop_servers() {
        local host
        for host in "${hosts[@]}"; do
            ssh "${host}" "sudo pkill -f 'tebis_server/tebis_server -b ${backup_method}'" >/dev/null 2>&1 || true
        done
    }

    cleanup() {
        local cleanup_failed=0

        if [[ ${servers_may_be_running} -eq 1 ]]; then
            echo "Stopping tebis servers from exp7 cleanup..." >&2
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

    compute_kops_from_ops_file() {
        local ops_file=$1

        awk -v lower_threshold="${ops_lower_threshold}" -v higher_threshold="${ops_higher_threshold}" '
        {
            if (match($0, /([0-9]+)[[:space:]]+sec[[:space:]]+([0-9.eE+-]+)[[:space:]]+operations/, m)) {
                sec = m[1] + 0
                operations = m[2] + 0
                if (!(operations > lower_threshold && operations <= higher_threshold)) {
                    next
                }
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

    sync_and_build_all_nodes() {
        echo "Syncing source and building locally/remotely via ./scp.sh ${cmake_args[*]} ..." >&2
        (
            cd "${project_dir}"
            ./scp.sh "${cmake_args[@]}"
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

    set_fixed_exp_params() {
        echo "Setting VALID_SEGMENTS_THRESHOLD=${valid_segments_threshold_value}, high_amplification_power=${high_amplification_power_value} before exp7_gc_space build..." >&2
        set_valid_segments_threshold "${valid_segments_threshold_value}"
        set_high_amplification_power "${high_amplification_power_value}"
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

        echo "Rebuilding with default scp.sh flags after exp7_gc_space..." >&2
        cmake_args=()
        sync_and_build_all_nodes
        high_amplification_build_enabled=0
    }

    set_gc_cmake_args() {
        local gc_method=$1

        cmake_args=(
            -DSPACE_OCCUPATION=ON
        )

        if [[ "${gc_method}" == "sync" ]]; then
            cmake_args+=(
                -DHIGH_AMPLIFICATION_AWARE=ON
                -DCOLD_LOG_SEPARATION=ON
            )
        else
            cmake_args+=(
                -DHIGH_AMPLIFICATION_AWARE=OFF
                -DCOLD_LOG_SEPARATION=OFF
            )
        fi
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
        local gc_method=$2
        local remote_log=$3
        local host

        for host in "${hosts[@]}"; do
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
                "${workload}" "${backup_method}" "${gc_method}" "${host}" "${LAST_HOST_STATUS[${host}]}" \
                "${LAST_HOST_TS[${host}]}" "${LAST_HOST_USED_BYTES[${host}]}" "${LAST_HOST_USED_GIB[${host}]}" \
                "${PREV_HOST_USED_BYTES[${host}]}" "${PREV_HOST_USED_GIB[${host}]}" \
                "${LAST_HOST_DISK_WRITE_PIDS[${host}]}" "${LAST_HOST_DISK_WRITE_BYTES[${host}]}" \
                "${LAST_HOST_DISK_WRITE_GIB[${host}]}" "${remote_log}" \
                >> "${host_file}"
        done
    }

    join_csv() {
        local csv=""
        local value

        for value in "$@"; do
            csv="${csv}${csv:+,}${value}"
        done

        printf "%s" "${csv}"
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

    echo "Running exp7 gc space (backup=${backup_method}), gc_methods=${gc_methods[*]}, valid_segments_threshold=${valid_segments_threshold_value}, high_amplification_power=${high_amplification_power_value}, workloads=${workloads[*]}"

    for workload in "${workloads[@]}"; do
        for gc_method in "${gc_methods[@]}"; do
            echo -e "\n*********Running exp7_gc_space workload=${workload}, backup=${backup_method}, gc=${gc_method}*********"

            set_gc_cmake_args "${gc_method}"
            set_fixed_exp_params
            sync_and_build_all_nodes
            high_amplification_build_enabled=1

            run_tag="${date_time}_${gc_method}"
            output_base="${results_rel}/client_logs/${nickname}_${backup_method}_${gc_method}_${workload}_thread_${server_threads}_${client_threads}"
            output_path="${project_dir}/${output_base}_${run_tag}"
            server_log_path="/tmp/lijinming_tebis_server_exp7_${backup_method}_${gc_method}_${workload}_${run_tag}.log"

            echo "Running workload=${workload}, backup=${backup_method}, gc=${gc_method}" >&2

            run_cmd=(
                "${basic_script_dir}/run_cluster.sh" -b "${backup_method}" -g "${gc_method}" -l "${load_times}"
                -r "${run_times}" -u "${ops_higher_threshold}" -w "${workload}" -o "${output_base}"
                -d "${run_tag}" -t "${server_threads}" -c "${client_threads}" -f "${regions_file}" -k
                -s "${server_log_path}"
            )

            "${run_cmd[@]}"
            servers_may_be_running=1

            ops_file="${output_path}/run_${workload}/ops.txt"

            kops=$(compute_kops_from_ops_file "${ops_file}") || {
                echo "Failed to compute throughput from ${ops_file}" >&2
                exit 1
            }

            echo "Throughput: ${kops} kops/sec"
            printf "%s\t%s\t%s\t%s\t%s\n" "${workload}" "${backup_method}" "${gc_method}" "${kops}" "${ops_file}" >> "${throughput_file}"

            wait_until_stable_space_usage "${server_log_path}"
            collect_disk_write_usage
            stop_servers
            servers_may_be_running=0

            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
                "${workload}" "${backup_method}" "${gc_method}" "${SPACE_STATUS}" \
                "${SPACE_TOTAL_USED_BYTES}" "${SPACE_TOTAL_USED_GIB}" \
                "${SPACE_PER_HOST_USED_BYTES}" "${SPACE_PER_HOST_USED_GIB}" \
                "${DISK_TOTAL_WRITE_BYTES}" "${DISK_TOTAL_WRITE_GIB}" \
                "${DISK_PER_HOST_WRITE_BYTES}" "${DISK_PER_HOST_WRITE_GIB}" \
                "${DISK_PER_HOST_WRITE_PIDS}" "${server_log_path}" \
                >> "${summary_file}"
            echo "Space usage result: workload=${workload}, backup=${backup_method}, gc=${gc_method}, total_used_gib=${SPACE_TOTAL_USED_GIB}, total_disk_write_gib=${DISK_TOTAL_WRITE_GIB}" >&2

            write_host_rows "${workload}" "${gc_method}" "${server_log_path}"

            sleep 10
        done
    done

    display_workload_labels=()
    for workload in "${workloads[@]}"; do
        if [[ ${#workload} -eq 1 ]]; then
            display_workload_labels+=("${workload^^}")
        else
            display_workload_labels+=("${workload}")
        fi
    done

    gc_labels=()
    for gc_method in "${gc_methods[@]}"; do
        gc_labels+=("${gc_method}")
    done

    workload_csv=$(join_csv "${workloads[@]}")
    gc_method_csv=$(join_csv "${gc_methods[@]}")
    bar_label_csv=$(join_csv "${display_workload_labels[@]}")
    gc_label_csv=$(join_csv "${gc_labels[@]}")

    echo ""
    echo "Executing command:"
    echo "python3 \"${basic_script_dir}/plot_exp2_space_bar.py\" --input \"${summary_file}\" --output \"${results_dir}\" --workloads \"${workload_csv}\" --backups \"${gc_method_csv}\" --item-column gc_method --bar-label \"${bar_label_csv}\" --item-labels \"${gc_label_csv}\" --x-axis-label \"Workload\" --y-axis-label \"Space usage (GiB)\" --value-column total_used_gib --output-name space_occupation.pdf --legend-output-name space_occupation_legend.pdf"

    python3 "${basic_script_dir}/plot_exp2_space_bar.py" \
        --input "${summary_file}" \
        --output "${results_dir}" \
        --workloads "${workload_csv}" \
        --backups "${gc_method_csv}" \
        --item-column gc_method \
        --bar-label "${bar_label_csv}" \
        --item-labels "${gc_label_csv}" \
        --x-axis-label "Workload" \
        --y-axis-label "Space usage (GiB)" \
        --value-column total_used_gib \
        --output-name space_occupation.pdf \
        --legend-output-name space_occupation_legend.pdf

    echo ""
    echo "Executing command:"
    echo "python3 \"${basic_script_dir}/plot_exp2_space_bar.py\" --input \"${summary_file}\" --output \"${results_dir}\" --workloads \"${workload_csv}\" --backups \"${gc_method_csv}\" --item-column gc_method --bar-label \"${bar_label_csv}\" --item-labels \"${gc_label_csv}\" --x-axis-label \"Workload\" --y-axis-label \"Disk writes (GiB)\" --value-column total_disk_write_gib --output-name disk_write.pdf --legend-output-name disk_write_legend.pdf"

    python3 "${basic_script_dir}/plot_exp2_space_bar.py" \
        --input "${summary_file}" \
        --output "${results_dir}" \
        --workloads "${workload_csv}" \
        --backups "${gc_method_csv}" \
        --item-column gc_method \
        --bar-label "${bar_label_csv}" \
        --item-labels "${gc_label_csv}" \
        --x-axis-label "Workload" \
        --y-axis-label "Disk writes (GiB)" \
        --value-column total_disk_write_gib \
        --output-name disk_write.pdf \
        --legend-output-name disk_write_legend.pdf

    echo "exp7 gc space finished. Results: ${results_dir}"
    echo "Saved throughput summary: ${throughput_file}"
    echo "Saved space occupation summary: ${summary_file}"
    echo "Saved per-host space occupation rows: ${host_file}"
