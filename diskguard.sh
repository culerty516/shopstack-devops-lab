#!/usr/bin/env bash

set -euo pipefail

THRESHOLD=80
EXIT_CODE=0

while read -r filesystem capacity mountpoint; do
    usage=${capacity%\%}

    if (( usage > THRESHOLD )); then
        echo "WARNING: ${mountpoint} (${filesystem}) usage is ${usage}%, above ${THRESHOLD}%."
        EXIT_CODE=1
    fi
done < <(df --output=source,pcent,target | tail -n +2)

if (( EXIT_CODE == 0 )); then
    echo "OK: no mounted filesystem exceeds ${THRESHOLD}% usage."
fi

exit "$EXIT_CODE"
