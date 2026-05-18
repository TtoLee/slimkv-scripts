#!/bin/bash
set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "${SCRIPT_DIR}/settings.sh" ]]; then
    source "${SCRIPT_DIR}/settings.sh"
else
    source ~/tebis/settings.sh
fi

TEBIS_DIR=${TEBIS_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}
BUILD_TARGET=${BUILD_TARGET:-tebis_server}
BUILD_JOBS=${BUILD_JOBS:-2}

cmake_args=(-DTEBIS_FORMAT=ON -DSPACE_OCCUPATION=OFF -DMICROBENCHMARK=OFF -DRUN_IWYU=OFF -DCOLD_LOG_SEPARATION=OFF -DHIGH_AMPLIFICATION_AWARE=OFF -DFETCHCONTENT_UPDATES_DISCONNECTED=ON -DFETCHCONTENT_FULLY_DISCONNECTED=ON "$@")

echo "Configuring local build with CMake args: ${cmake_args[*]}"
mkdir -p "${TEBIS_DIR}/build"
cmake -S "${TEBIS_DIR}" -B "${TEBIS_DIR}/build" "${cmake_args[@]}"

cmake --build "${TEBIS_DIR}/build" --target "${BUILD_TARGET}" -j "${BUILD_JOBS}"
if [ $? -ne 0 ]; then
    echo "Build failed. Please check the output for errors."
    exit 1
fi

BUILD_TARGET="${BUILD_TARGET}" BUILD_JOBS="${BUILD_JOBS}" bash "${SCRIPT_DIR}/scp_src.sh" "${cmake_args[@]}"
