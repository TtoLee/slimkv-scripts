#!/bin/bash
source ~/tebis/settings.sh
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

TEBIS_DIR=${TEBIS_DIR:-${SCRIPT_DIR}}
BUILD_TARGET=${BUILD_TARGET:-tebis_server}
BUILD_JOBS=${BUILD_JOBS:-2}

cmake_args=("$@")
if [[ ${#cmake_args[@]} -eq 0 ]]; then
    cmake_args=(-DTEBIS_FORMAT=ON -DSPACE_OCCUPATION=OFF -DMICROBENCHMARK=OFF -DRUN_IWYU=OFF -DCOLD_LOG_SEPARATION=OFF -DHIGH_AMPLIFICATION_AWARE=OFF -DFETCHCONTENT_UPDATES_DISCONNECTED=ON -DFETCHCONTENT_FULLY_DISCONNECTED=ON)
fi
build_target_quoted=$(printf '%q' "${BUILD_TARGET}")
build_jobs_quoted=$(printf '%q' "${BUILD_JOBS}")

# Define common rsync options for source files
RSYNC=rsync
SSH_CMD=${SSH_CMD:-ssh}
RSYNC_OPTS=(-avz --include='*/' --include='*.c' --include='*.h' --exclude='*' --delete)
RSYNC_OPTS_QUIET=(-avz --quiet --include='*/' --include='*.c' --include='*.h' --exclude='*' --delete)

if [[ ${#PATHS[@]} -eq 0 ]]; then
    echo "PATHS is empty. Define PATHS in settings.sh." >&2
    exit 1
fi

remote_target() {
    local index=$1
    local node="${NODES[$index]}"
    local node_user_var="node${index}_user"
    local node_user="${!node_user_var:-$user}"

    if [[ -z "${node}" ]]; then
        return 1
    fi

    if [[ "${node}" == *"@"* || -z "${node_user}" ]]; then
        printf '%s\n' "${node}"
    else
        printf '%s@%s\n' "${node_user}" "${node}"
    fi
}

# Function to check if first node needs sync
check_first_node_sync_needed() {
    local component=$1
    local first_target
    first_target=$(remote_target 0) || return 1
    
    # Use rsync dry-run to check if files would be transferred
    local dry_run_output
    if [[ "${component}" == "parallax" ]]; then
        dry_run_output=$(${RSYNC} -e "${SSH_CMD}" -avz --dry-run --include='*/' --include='CMakeLists.txt' --include='*.cmake' --include='*.cmake.in' --include='*.in' --include='*.yml' --include='*.c' --include='*.h' --exclude='*' "${TEBIS_DIR}/${component}" ${first_target}:${PATHS[0]} 2>/dev/null | grep -v '^receiving\|^sent\|^total\|^$\|^sending incremental file list')
    elif [[ "${component}" == "YCSB-CXX" ]]; then
        dry_run_output=$(${RSYNC} -e "${SSH_CMD}" --include='*.cc' --include='*.hpp' ${RSYNC_OPTS[@]} --dry-run "${TEBIS_DIR}/${component}" ${first_target}:${PATHS[0]} 2>/dev/null | grep -v '^receiving\|^sent\|^total\|^$\|^sending incremental file list')
    elif [[ "${component}" == "tebis_server" || "${component}" == "tests" || "${component}" == "tebis_rdma" ]]; then
        dry_run_output=$(${RSYNC} -e "${SSH_CMD}" --include='CMakeLists.txt' ${RSYNC_OPTS[@]} --dry-run "${TEBIS_DIR}/${component}" ${first_target}:${PATHS[0]} 2>/dev/null | grep -v '^receiving\|^sent\|^total\|^$\|^sending incremental file list')
    else
        dry_run_output=$(${RSYNC} -e "${SSH_CMD}" ${RSYNC_OPTS[@]} --dry-run "${TEBIS_DIR}/${component}" ${first_target}:${PATHS[0]} 2>/dev/null | grep -v '^receiving\|^sent\|^total\|^$\|^sending incremental file list')
    fi
    
    # If dry-run output is empty, no sync needed
    if [[ -z "${dry_run_output}" ]]; then
        echo -e "  -> No changes detected for ${component} on first node ${NODES[0]}, skipping all nodes\n"
        return 1  # No sync needed
    else
        echo "  -> Changes detected for ${component} on first node ${NODES[0]}, proceeding with sync"
        # Debug: show actual output
        echo "  -> content:"
        echo "${dry_run_output}" | sed 's/^/    /'
        local file_count=$(echo "${dry_run_output}" | grep -c '^')
        echo "  -> Detected changes: ${file_count} files"
        return 0  # Sync needed
    fi
}

# Sync tebis_server
echo "Syncing tebis_server..."
if check_first_node_sync_needed "tebis_server"; then
    for i in "${!NODES[@]}"; do
        target=$(remote_target "$i") || continue
        echo "  -> ${NODES[$i]}"
        ${RSYNC} -e "${SSH_CMD}" --include='CMakeLists.txt' ${RSYNC_OPTS_QUIET[@]} "${TEBIS_DIR}/tebis_server" ${target}:${PATHS[$i]}
    done
fi

# Sync parallax
echo "Syncing parallax..."
if check_first_node_sync_needed "parallax"; then
    for i in "${!NODES[@]}"; do
        target=$(remote_target "$i") || continue
        echo "  -> ${NODES[$i]}"
        ${RSYNC} -e "${SSH_CMD}" -avz --quiet --include='*/' --include='CMakeLists.txt' --include='*.cmake' --include='*.cmake.in' --include='*.in' --include='*.yml' --include='*.c' --include='*.h' --exclude='*' "${TEBIS_DIR}/parallax" ${target}:${PATHS[$i]}
    done
fi

# Sync utilities
echo "Syncing utilities..."
if check_first_node_sync_needed "utilities"; then
    for i in "${!NODES[@]}"; do
        target=$(remote_target "$i") || continue
        echo "  -> ${NODES[$i]}"
        ${RSYNC} -e "${SSH_CMD}" ${RSYNC_OPTS_QUIET[@]} "${TEBIS_DIR}/utilities" ${target}:${PATHS[$i]}
    done
fi

# Sync common
echo "Syncing common..."
if check_first_node_sync_needed "common"; then
    for i in "${!NODES[@]}"; do
        target=$(remote_target "$i") || continue
        echo "  -> ${NODES[$i]}"
        ${RSYNC} -e "${SSH_CMD}" ${RSYNC_OPTS_QUIET[@]} "${TEBIS_DIR}/common" ${target}:${PATHS[$i]}
    done
fi

# Sync tebis_rdma
echo "Syncing tebis_rdma..."
if check_first_node_sync_needed "tebis_rdma"; then
    for i in "${!NODES[@]}"; do
        target=$(remote_target "$i") || continue
        echo "  -> ${NODES[$i]}"
        ${RSYNC} -e "${SSH_CMD}" --include='CMakeLists.txt' ${RSYNC_OPTS_QUIET[@]} "${TEBIS_DIR}/tebis_rdma" ${target}:${PATHS[$i]}
    done
fi

# Sync tebis_rdma_client
echo "Syncing tebis_rdma_client..."
if check_first_node_sync_needed "tebis_rdma_client"; then
    for i in "${!NODES[@]}"; do
        target=$(remote_target "$i") || continue
        echo "  -> ${NODES[$i]}"
        ${RSYNC} -e "${SSH_CMD}" ${RSYNC_OPTS_QUIET[@]} "${TEBIS_DIR}/tebis_rdma_client" ${target}:${PATHS[$i]}
    done
fi

# Sync YCSB-CXX
echo "Syncing YCSB-CXX..."
if check_first_node_sync_needed "YCSB-CXX"; then
    for i in "${!NODES[@]}"; do
        target=$(remote_target "$i") || continue
        echo "  -> ${NODES[$i]}"
        ${RSYNC} -e "${SSH_CMD}" --include='*.cc' --include='*.hpp' ${RSYNC_OPTS_QUIET[@]} "${TEBIS_DIR}/YCSB-CXX" ${target}:${PATHS[$i]}
    done
fi

# Sync tests
echo "Syncing tests..."
if check_first_node_sync_needed "tests"; then
    for i in "${!NODES[@]}"; do
        target=$(remote_target "$i") || continue
        echo "  -> ${NODES[$i]}"
        ${RSYNC} -e "${SSH_CMD}" --include='CMakeLists.txt' ${RSYNC_OPTS_QUIET[@]} "${TEBIS_DIR}/tests" ${target}:${PATHS[$i]}
    done
fi

# Sync time_counter
echo "Syncing time_counter..."
if check_first_node_sync_needed "time_counter"; then
    for i in "${!NODES[@]}"; do
        target=$(remote_target "$i") || continue
        echo "  -> ${NODES[$i]}"
        ${RSYNC} -e "${SSH_CMD}" --include='CMakeLists.txt' ${RSYNC_OPTS_QUIET[@]} "${TEBIS_DIR}/time_counter" ${target}:${PATHS[$i]}
    done
fi

# Sync tebis_zk_init.py script
echo "Syncing tebis_zk_init.py..."
# Check if the script needs sync on first node
echo "Checking if tebis_zk_init.py needs sync on first node ${NODES[0]}..."
first_target=$(remote_target 0)
dry_run_output=$(${RSYNC} -e "${SSH_CMD}" -avz --dry-run "${TEBIS_DIR}/scripts/tebis/tebis_zk_init.py" ${first_target}:${PATHS[0]}/scripts/tebis/ 2>/dev/null | grep -v '^receiving\|^sent\|^total\|^$\|^sending incremental file list')

if [[ -z "${dry_run_output}" ]]; then
    echo -e "  -> No changes detected for tebis_zk_init.py, skipping all nodes\n"
else
    echo "  -> Changes detected for tebis_zk_init.py, proceeding with sync"
    # Debug: show actual output
    echo "  -> Debug - dry_run_output content:"
    echo "${dry_run_output}" | sed 's/^/    /'
    file_count=$(echo "${dry_run_output}" | grep -c '^')
    echo "  -> Detected changes: ${file_count} files"
    for i in "${!NODES[@]}"; do
        target=$(remote_target "$i") || continue
        echo "  -> ${NODES[$i]}"
        ${RSYNC} -e "${SSH_CMD}" -avz --quiet "${TEBIS_DIR}/scripts/tebis/tebis_zk_init.py" ${target}:${PATHS[$i]}/scripts/tebis/
    done
fi

# Sync CMakeLists.txt
echo "Syncing top-level CMakeLists.txt..."
for i in "${!NODES[@]}"; do
    target=$(remote_target "$i") || continue
    dry_run_output=$(${RSYNC} -e "${SSH_CMD}" -avz --dry-run "${TEBIS_DIR}/CMakeLists.txt" ${target}:${PATHS[$i]} 2>/dev/null | grep -v '^receiving\|^sent\|^total\|^$\|^sending incremental file list')
    if [[ -z "${dry_run_output}" ]]; then
        echo "  -> No changes detected on ${NODES[$i]}"
    else
        echo "  -> Updating ${NODES[$i]}"
        ${RSYNC} -e "${SSH_CMD}" -avz --quiet "${TEBIS_DIR}/CMakeLists.txt" ${target}:${PATHS[$i]}
    fi
done

echo "All syncing completed!"

# for i in "${!NODES[@]}"; do
#     echo "Starting transfer build on ${NODES[$i]}..."
#     rsync -avz --quiet --delete "${TEBIS_DIR}/build" ${user}@${NODES[$i]}:${PATHS[$i]}
# done

echo "Building on remote nodes..."
echo "Remote CMake args: ${cmake_args[*]}"
build_pids=()
for i in "${!NODES[@]}"; do
    target=$(remote_target "$i") || continue
    echo "  Building on ${NODES[$i]}..."
    remote_cmake_args=("${cmake_args[@]}" "-DFETCHCONTENT_SOURCE_DIR_PARALLAX=${PATHS[$i]}/parallax")
    remote_cmake_args_quoted=$(printf '%q ' "${remote_cmake_args[@]}")
    remote_source_quoted=$(printf '%q' "${PATHS[$i]}")
    remote_build_quoted=$(printf '%q' "${PATHS[$i]}/build")
    remote_log_quoted=$(printf '%q' "${PATHS[$i]}/build/scp_build.log")
    ${SSH_CMD} ${target} "mkdir -p ${remote_build_quoted} && cmake -S ${remote_source_quoted} -B ${remote_build_quoted} ${remote_cmake_args_quoted} > ${remote_log_quoted} 2>&1 && cmake --build ${remote_build_quoted} --target ${build_target_quoted} -j ${build_jobs_quoted} >> ${remote_log_quoted} 2>&1" &
    build_pids[$i]=$!
done

build_failed=0
for i in "${!build_pids[@]}"; do
    if ! wait "${build_pids[$i]}"; then
        echo "  -> Build failed on ${NODES[$i]}" >&2
        build_failed=1
    fi
done

if [[ ${build_failed} -eq 0 ]]; then
    echo "All builds completed!"
else
    echo "Builds completed with errors." >&2
fi
