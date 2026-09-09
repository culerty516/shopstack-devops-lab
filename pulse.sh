#!/usr/bin/env bash

set -euo pipefail

LOG_FILE="/var/log/shopstack-pulse.log"

while true; do
    MESSAGE="$(date --iso-8601=seconds) ShopStack heartbeat"
    echo "$MESSAGE" | tee -a "$LOG_FILE"
    sleep 10
done
