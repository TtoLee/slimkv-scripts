#!/usr/bin/env bash

set -euo pipefail

cgroup_name=""
memory_limit_bytes=""
log_file=""

usage() {
    echo "Usage: $0 --cgroup-name NAME --memory-limit-bytes BYTES --log-file FILE -- <command...>"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --cgroup-name)
        cgroup_name=${2:-}
        shift 2
        ;;
    --memory-limit-bytes)
        memory_limit_bytes=${2:-}
        shift 2
        ;;
    --log-file)
        log_file=${2:-}
        shift 2
        ;;
    --)
        shift
        break
        ;;
    *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
done

if [[ -z "${cgroup_name}" || -z "${memory_limit_bytes}" || -z "${log_file}" ]]; then
    usage
    exit 1
fi

if [[ $# -eq 0 ]]; then
    echo "Missing server command after --" >&2
    usage
    exit 1
fi

if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    cgroup_dir="/sys/fs/cgroup/${cgroup_name}"
    memory_file="${cgroup_dir}/memory.max"
    memory_high_file="${cgroup_dir}/memory.high"
    procs_file="${cgroup_dir}/cgroup.procs"
elif [[ -d /sys/fs/cgroup/memory ]]; then
    cgroup_dir="/sys/fs/cgroup/memory/${cgroup_name}"
    memory_file="${cgroup_dir}/memory.limit_in_bytes"
    memory_high_file="${cgroup_dir}/memory.soft_limit_in_bytes"
    procs_file="${cgroup_dir}/tasks"
else
    echo "Unsupported cgroup layout on host $(hostname)" >&2
    exit 1
fi

sudo mkdir -p "${cgroup_dir}"
memory_high_bytes=$((memory_limit_bytes * ))

echo "${memory_limit_bytes}" | sudo tee "${memory_file}" > /dev/null
# echo "${memory_high_bytes}" | sudo tee "${memory_high_file}" > /dev/null
echo max | sudo tee "${memory_high_file}" > /dev/null

# Put this launcher shell into cgroup, then exec the server command.
echo $$ | sudo tee "${procs_file}" > /dev/null
exec sudo "$@" >> "${log_file}" 2>&1
