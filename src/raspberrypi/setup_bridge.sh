#!/bin/bash
set -e # Fail if any command fails
sudo brctl addbr rascsi_bridge
sudo brctl addif rascsi_bridge eth0
sudo ip link set dev rascsi_bridge up

echo Bridge config:
brctl show
