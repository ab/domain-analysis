#!/bin/bash
set -euo pipefail

run() {
    echo >&2 "+ $*"
    "$@"
}

# Retries a command on failure.
# usage: with_retries max_attempts COMMAND...
with_retries() {
    local -r -i max_attempts="$1"; shift
    local -i attempt_num=1
    local -i delay=2
    local -i ret

    while true; do
        timeout 5 "$@" && ret=$? || ret=$?

        if [ "$ret" -eq 0 ]; then
            return
        fi

        if (( attempt_num >= max_attempts )); then
            echo >&2 "Attempt $attempt_num failed and there are no more attempts left!"
            return "$ret"
        else
            echo >&2 "Attempt $attempt_num failed! Trying again in $delay seconds..."
            sleep "$delay"
            (( attempt_num++ ))
            #(( delay *= 2 ))
        fi
    done
}

trap 'echo ERROR' EXIT

skip="${1-0}"
i=0

while read -r domain; do
    ((i++))

    if [[ $i -lt $skip ]]; then
        echo >&2 "skipping to line $skip"
        continue
    fi

    # skip "domain" column label
    if [ "$domain" = "domain" ]; then
        continue
    fi

    echo >&2 "domain: '$domain'"

    registrar=$(with_retries 5 whois domain "$domain" | grep -m 1 -i 'registrar url:') || {
        registrar="FAILED"
    }

    echo -e "$i\t$domain\t$registrar"
done

trap - EXIT
