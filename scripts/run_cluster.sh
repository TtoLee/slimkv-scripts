#!/usr/bin/env bash

set -euo pipefail

# Static paths
TEBIS_DIR=/home/lijinming/tebis
UCAS_DIR=/home/lijinming/UCAS2025
BUILD_DIR=${UCAS_DIR}/build
YCSB_DIR=${BUILD_DIR}/YCSB-CXX

# Cluster topology
HOSTS=(
	10.118.0.227
	10.118.0.28
	10.118.0.229
	10.118.0.30
	10.118.0.31
	10.118.0.32
)
ZOOKEEPER_HOST=10.118.0.28
CLIENT_HOST=10.118.0.227
ZOOKEEPER_PORT=2181
ZOOKEEPER_ENDPOINT=${ZOOKEEPER_HOST}:${ZOOKEEPER_PORT}

date_time=$(date +%Y%m%d_%H%M%S)

# Defaults
client_output_path=/tmp/lijinming_tebis_client_${date_time}
custom_client_output=0
server_log_path=/tmp/lijinming_tebis_server_${date_time}.log
execution_plan_path=/tmp/lijinming_execution_plan.txt
server_threads=4
client_threads=32
cgroup_name=slimkv
cgroup_memory_limit_gb=32
remote_cgroup_launcher=/tmp/tebis_cgroup_launcher.sh
ops_higher_threshold=""
ops_check_interval_sec=2
keep_servers_alive=0

servers_started=0

usage() {
    echo "Usage: $0 [-o <client_output_path>] [-s <server_log_path>] -b <backup_method> -g <gc_method> -l <load_times> -r <run_times> -u <ops_higher_threshold> -w <workload> [-d <date_time>] -f <regions_file> [-t <server_threads>] [-c <client_threads>] [-N <cgroup_name>] [-M <cgroup_memory_limit_gb>] [-k]"
}

parse_args() {
    while getopts "o:s:b:g:l:r:u:w:t:c:d:f:N:M:k" opt; do
        case $opt in
        o)
            client_output_path=${OPTARG}
            custom_client_output=1
            ;;
        s) server_log_path=$OPTARG ;;
        b) backup_method=$OPTARG ;;
        g) gc_method=$OPTARG ;;
        l) load_times=${OPTARG} ;;
        r) run_times=${OPTARG} ;;
        u) ops_higher_threshold=${OPTARG} ;;
        w) workload=$OPTARG ;;
        t) server_threads=${OPTARG} ;;
        c) client_threads=${OPTARG} ;;
        d)
            date_time=${OPTARG}
            server_log_path=/tmp/lijinming_tebis_server_${date_time}.log
            ;;
        f)
            regions_file=${OPTARG} ;;
        N)
            cgroup_name=${OPTARG}
            ;;
        M)
            cgroup_memory_limit_gb=${OPTARG}
            ;;
        k)
            keep_servers_alive=1
            ;;
        *)
            usage
            ;;
        esac
    done

    if [[ ${custom_client_output} -eq 1 ]]; then
        client_output_path=${client_output_path}_${date_time}
    fi
}

validate_args() {
    if [[ -z "${backup_method:-}" || -z "${gc_method:-}" || -z "${load_times:-}" || -z "${run_times:-}" || -z "${workload:-}" || -z "${regions_file:-}" ]]; then
        echo "All options are required. Use -s, -b, -g, -l, -r, -w, and -f to specify them."
        usage
        exit 1
    fi

    if [[ "${workload}" != "load" && "${workload}" != "a" && "${workload}" != "b" && "${workload}" != "c" && "${workload}" != "d" && "${workload}" != "e" && "${workload}" != "f" ]]; then
        echo "Invalid workload type. Use -w to specify one of load, a, b, c, d, e, or f."
        exit 1
    fi

    if ! [[ "${cgroup_memory_limit_gb}" =~ ^[0-9]+$ ]] || [[ "${cgroup_memory_limit_gb}" -le 0 ]]; then
        echo "cgroup memory limit must be a positive integer (GB), got: ${cgroup_memory_limit_gb}" >&2
        exit 1
    fi

    if [[ -z "${cgroup_name}" ]]; then
        echo "cgroup name cannot be empty" >&2
        exit 1
    fi

    if [[ -z "${ops_higher_threshold}" ]]; then
        ops_higher_threshold=${run_times}
    fi

    if ! [[ "${ops_higher_threshold}" =~ ^[0-9]+$ ]] || [[ "${ops_higher_threshold}" -le 0 ]]; then
        echo "ops_higher_threshold must be a positive integer, got: ${ops_higher_threshold}" >&2
        exit 1
    fi
}

get_remote_max_ops_count() {
    local remote_ops_file=$1

    ssh "${CLIENT_HOST}" "awk '
    {
        num_count = 0
        for (i = 1; i <= NF; i++) {
            if (\$i ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) {
                num_count++
                if (num_count == 2) {
                    val = \$i + 0
                    if (!seen || val > maxv) {
                        maxv = val
                        seen = 1
                    }
                    break
                }
            }
        }
    }
    END {
        if (seen) {
            printf \"%.0f\\n\", maxv
        }
    }
    ' '${remote_ops_file}' 2>/dev/null" || true
}

prepare_remote_workload() {
    local remote_workload_file

    # if [[ "${workload}" != "load" ]]; then
        remote_workload_file="${YCSB_DIR}/workloads/workload${workload}"
        printf "load_%s load workloads/workload%s\nrun_%s run workloads/workload%s\n" \
            "$workload" "$workload" "$workload" "$workload" \
            | ssh "$CLIENT_HOST" "cat > ${execution_plan_path}"

        ssh "$CLIENT_HOST" "sed -i -E \
            -e 's/^[[:space:]]*recordcount=.*/recordcount=${load_times}/' \
            -e 's/^[[:space:]]*operationcount=.*/operationcount=${run_times}/' \
            '${remote_workload_file}'"
    # else
    #     remote_workload_file="${YCSB_DIR}/workloads/workloada"
    #     printf "run_load load workloads/workloada\n" \
    #         | ssh "$CLIENT_HOST" "cat > ${execution_plan_path}"
    #     ssh "$CLIENT_HOST" "sed -i -E \
    #         -e 's/^[[:space:]]*recordcount=.*/recordcount=$((load_times + run_times))/' \
    #         '${remote_workload_file}'"
    # fi
}

start_zookeeper() {
    local zookeeper_cmd
    zookeeper_cmd="python3 ./scripts/tebis/tebis_zk_init.py ./hosts_file ./${regions_file} ${ZOOKEEPER_ENDPOINT}"

    echo "Restarting Zookeeper on ${ZOOKEEPER_HOST}..."
    ssh "${ZOOKEEPER_HOST}" "cd ${UCAS_DIR} && ${zookeeper_cmd}" > /dev/null 2>&1 || {
        echo "Failed to restart Zookeeper on ${ZOOKEEPER_HOST}" >&2
        exit 1
    }
}

start_servers() {
    local server_cmd
    local cgroup_memory_limit_bytes
    server_cmd="numactl --physcpubind=0-47 --membind=0 ./tebis_server/tebis_server -b ${backup_method} -g ${gc_method} -d /mnt/solidigmssd/slimdata -z ${ZOOKEEPER_ENDPOINT} -r 10.0.0 -p 16 -c $((server_threads + 1)) -t 192 -n mlx5_0"
    cgroup_memory_limit_bytes=$((cgroup_memory_limit_gb * 1024 * 1024 * 1024))

    echo "Starting tebis servers on hosts: ${HOSTS[*]}"
    for host in "${HOSTS[@]}"; do
        scp -q "${TEBIS_DIR}/ycsb_log/scripts/remote_start_tebis_with_cgroup.sh" "${host}:${remote_cgroup_launcher}" || {
            echo "Failed to copy cgroup launcher to ${host}" >&2
            exit 1
        }

        ssh "${host}" "chmod +x ${remote_cgroup_launcher} && cd ${BUILD_DIR} && nohup ${remote_cgroup_launcher} --cgroup-name '${cgroup_name}' --memory-limit-bytes '${cgroup_memory_limit_bytes}' --log-file '${server_log_path}' -- ${server_cmd} > /dev/null 2>&1 &" > /dev/null 2>&1 &
    done

    sleep 5
    servers_started=1
}

drop_remote_page_cache() {
    echo "Dropping page cache on remote hosts..."
    for host in "${HOSTS[@]}"; do
        ssh "${host}" "sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'" > /dev/null 2>&1 || {
            echo "Failed to drop page cache on ${host}" >&2
            exit 1
        }
    done
}

cleanup() {
	if [[ ${servers_started} -eq 1 ]]; then
        if [[ ${keep_servers_alive} -eq 1 ]]; then
            echo "Keeping tebis servers alive by request (-k)."
            return
        fi
		echo "Stopping tebis servers..."
		for host in "${HOSTS[@]}"; do
			ssh "${host}" "sudo pkill -f 'tebis_server/tebis_server -b ${backup_method}'"
		done
	fi
}

run_client() {
    local client_cmd
    local start_time
    local timer_pid
    local remote_ops_file
    local client_ssh_pid
    local client_status
    local killed_by_threshold
    client_cmd="numactl --physcpubind=48-95 --membind=1 ./ycsb-async-tebis -threads ${client_threads} -w l -zookeeper ${ZOOKEEPER_ENDPOINT} -dbnum 1 -e ${execution_plan_path} -insertStart 0 -o ${UCAS_DIR}/${client_output_path} > /tmp/lijinming_tebis_client.log"
    remote_ops_file="${UCAS_DIR}/${client_output_path}/run_${workload}/ops.txt"
    killed_by_threshold=0
    if [[ ${workload} == "d" ]]; then
        client_cmd="numactl --physcpubind=48-95 --membind=1 ./ycsb-async-tebis -threads ${client_threads} -w l -zookeeper ${ZOOKEEPER_ENDPOINT} -dbnum 1 -ackOnReply -e ${execution_plan_path} -insertStart 0 -o ${UCAS_DIR}/${client_output_path} > /tmp/lijinming_tebis_client.log"
    fi

    echo "Server startup complete, starting client..."
    start_time=$(date +%s)
    (
    while true; do
        sleep 5
        now=$(date +%s)
        elapsed=$((now - start_time))
        printf "\rClient running for %ds..." "$elapsed"
    done
    ) &
    timer_pid=$!

    ssh "${CLIENT_HOST}" "cd ${YCSB_DIR} && ${client_cmd}" > /dev/null 2>&1 &
    client_ssh_pid=$!

    while kill -0 "${client_ssh_pid}" 2>/dev/null; do
        current_ops=$(get_remote_max_ops_count "${remote_ops_file}")
        if [[ -n "${current_ops}" ]] && [[ "${current_ops}" =~ ^[0-9]+$ ]] && [[ "${current_ops}" -gt "${ops_higher_threshold}" ]]; then
            echo
            echo "ops count ${current_ops} exceeded threshold ${ops_higher_threshold}, stopping client..."
            ssh "${CLIENT_HOST}" "pkill -f ycsb-async-tebis" > /dev/null 2>&1 || true
            killed_by_threshold=1
            break
        fi
        sleep "${ops_check_interval_sec}"
    done

    wait "${client_ssh_pid}" || client_status=$?
    kill "${timer_pid}" > /dev/null 2>&1 || true

    if [[ ${killed_by_threshold} -eq 0 && ${client_status:-0} -ne 0 ]]; then
        echo "Client execution failed on ${CLIENT_HOST}" >&2
        exit 1
    fi
}

collect_results() {
	 echo "Client run finished, collecting results..."
    mkdir -p "${TEBIS_DIR}/${client_output_path}"
    scp -rq "${CLIENT_HOST}:${UCAS_DIR}/${client_output_path}/*" "${TEBIS_DIR}/${client_output_path}"
    echo "Results copied to ${TEBIS_DIR}/${client_output_path}"
}

echo "Script started at ${date_time}"
trap cleanup EXIT

parse_args "$@"
validate_args

echo "Running experiment with ${backup_method}, ${gc_method} GC, load_times=${load_times}, run_times=${run_times}, ops_higher_threshold=${ops_higher_threshold}, workload${workload}"

prepare_remote_workload
start_zookeeper
drop_remote_page_cache
start_servers
run_client
collect_results
sleep 10
