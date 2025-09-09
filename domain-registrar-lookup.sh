#!/usr/bin/env bash
set -euo pipefail

run() {
    echo >&2 "+ $*"
    "$@"
}

# Retries a command on failure.
# usage: with_retries max_attempts timeout COMMAND...
with_retries() {
    local -r -i max_attempts="$1"; shift
    local -r -i timeout="$1"; shift
    local -i attempt_num=1
    local -i delay=2
    local -i ret

    while true; do
        timeout "$timeout" "$@" && ret=$? || ret=$?

        if [ "$ret" -eq 0 ]; then
            return
        fi

        if (( attempt_num >= max_attempts )); then
            echo >&2 "Attempt $attempt_num failed and there are no more attempts left!"
            echo >&2 "  command: $*"
            return "$ret"
        else
            echo >&2 "Attempt $attempt_num failed! Trying again in $delay seconds..."
            echo >&2 "  command: $*"
            sleep "$delay"
            (( attempt_num++ ))
            #(( delay *= 2 ))
        fi
    done
}

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    cat >&2 <<EOM
usage: $0 DOMAIN_LIST WHOIS_TMPDIR [SKIP_N]
EOM
fi
domain_list=$1
whois_tmpdir=$2
skip="${3-0}"

trap 'echo ERROR' EXIT

mkdir -vp "$whois_tmpdir"

echo >&2 "Reading domains from $domain_list"
readarray -t domains < "$domain_list"

whois_lookup() {
    echo >&2 "Fetching whois data. (${#domains[*]} domains)"

    local -i max_jobs=10
    local -i i=0
    local domain
    #local -A waiting=()

    for domain in "${domains[@]}"; do
        # NB: can't do i++ because of stupid let/set -e behavior
        (( ++i ))

        if [[ $i -lt $skip ]]; then
            echo >&2 "skipping to line $skip"
            continue
        fi

        # skip "domain" column label
        if [ "$domain" = "domain" ]; then
            continue
        fi

        echo >&2 "domain: '$domain'"

        if ! [[ "$domain" =~ ^[a-z0-9\.-]+$ ]]; then
            echo >&2 "Invalid domain: '$domain'"
            exit 2
        fi

        while [[ $(jobs -p | wc -l) -ge $max_jobs ]]; do
            echo >&2 "Reached max background jobs ($max_jobs), waiting..."
            jobs
            wait -n
        done

        # skip domains where we already have data
        if [ -s "$whois_tmpdir/$domain" ]; then
            echo >&2 "Already have data for $domain"
            continue
        fi

        # exec whois
        with_retries 5 30 bash -c "whois domain '$domain' > '$whois_tmpdir/$domain'" &

    done

    echo >&2 "Waiting for last jobs to finish"
    jobs

    wait
}

parse_results() {
    local i=0
    local domain registrar

    echo >&2 "Reading registrar info from whois files in $whois_tmpdir (${#domains[*]} domains)"

    for domain in "${domains[@]}"; do
        (( ++i ))
        registrar=$(grep -m 1 -i 'registrar url:' < "$whois_tmpdir/$domain") || {
            registrar="FAILED"
        }

        echo -e "$i\t$domain\t$registrar"
    done
}

whois_lookup

parse_results

trap - EXIT
