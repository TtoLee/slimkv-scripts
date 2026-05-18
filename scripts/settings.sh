#!/bin/bash
user="lijinming"

# Nodes can be either raw IPs or Host aliases from ~/.ssh/config.
# For jump-host setups, prefer aliases, for example:
# node0="ict-27-jumper1"
# node0_user="lijinming"   # optional; defaults to $user when omitted
# If a node entry already includes a user, such as "lijingming@ict-27-jumper1",
# the scripts will use it directly.

NODES=(
    10.118.0.227
    10.118.0.28
    10.118.0.229
    10.118.0.30
    10.118.0.31
    10.118.0.32
)

PATHS=(
    "/home/lijinming/UCAS2025"
    "/home/lijinming/UCAS2025"
    "/home/lijinming/UCAS2025"
    "/home/lijinming/UCAS2025"
    "/home/lijinming/UCAS2025"
    "/home/lijinming/UCAS2025"
)
# node0="ict-27-jumper1"
# n0_data_path="/home/lijinming/UCAS2025"
# node1="ict-28-jumper1"
# n1_data_path="/home/lijinming/UCAS2025"
# node2="ict-29-jumper1"
# n2_data_path="/home/lijinming/UCAS2025"
# node3="ict-30-jumper1"
# n3_data_path="/home/lijinming/UCAS2025"
# node4="ict-31-jumper1"
# n4_data_path="/home/lijinming/UCAS2025"
# node5="ict-32-jumper1"
# n5_data_path="/home/lijinming/UCAS2025"
