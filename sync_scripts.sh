#!/usr/bin/env bash

set -euo pipefail

LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_HOST="${1:-ict-15-jumper1}"
REMOTE_DIR="${2:-/home/lijinming/tebis/ycsb_log}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [remote_host] [remote_dir]

Sync only .py and .sh files under this directory to the remote machine while
preserving the directory structure. Other file types are ignored and existing
remote non-.py/.sh files are left untouched.

Examples:
  $(basename "$0")
  $(basename "$0") ict-15-jumper
  $(basename "$0") ict-15-jumper /tmp/ycsb_log
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

echo "Syncing .py and .sh files from ${LOCAL_DIR} to ${REMOTE_HOST}:${REMOTE_DIR}"

rsync -avm \
  --include='*/' \
  --include='*.py' \
  --include='*.sh' \
  --include='.gitignore' \
  --exclude='*' \
  "${LOCAL_DIR}/" "${REMOTE_HOST}:${REMOTE_DIR}/"
