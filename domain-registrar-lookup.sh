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
    echo >&2 "Fetching rdap data. (${#domains[*]} domains)"

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
        if [ -s "$whois_tmpdir/$domain.json" ]; then
            echo >&2 "Already have RDAP data for $domain"
            continue
        fi

        if [ -s "$whois_tmpdir/$domain.txt" ]; then
            echo >&2 "Already have whois data for $domain"
            continue
        fi

        # special case for TLDs that don't support RDAP
        case "$domain" in
            *.gov)
                echo "Registrar URL: https://get.gov" > "$whois_tmpdir/$domain.txt"
                continue
                ;;
        esac

        # exec rdap
        rdap --json "$domain" > "$whois_tmpdir/$domain.json" && ret=$? || ret=$?

        if [[ $ret -ne 0 ]]; then
            # handle TLDs that don't support RDAP
            if (rdap --json "$domain" 2>&1 || true) | grep -q "Error: No RDAP servers found"; then
                echo >&2 "Falling back to whois for $domain"
                # fall back to whois
                with_retries 5 30 whois "$domain" > "$whois_tmpdir/$domain.txt" &
            else
                return "$ret"
            fi
        fi

    done

    echo >&2 "Waiting for last jobs to finish ($(jobs -p | wc -l) jobs)"

    wait
}

parse_results() {
    local i=0
    local domain registrar

    echo >&2 "Reading registrar info from whois files in $whois_tmpdir (${#domains[*]} domains)"

    for domain in "${domains[@]}"; do
        (( ++i ))

        registrar=
        registrar_name=

        if [ -s "$whois_tmpdir/$domain.txt" ]; then
            registrar=$(grep -m 1 -i "registrar url:" < "$whois_tmpdir/$domain.txt") || {
                registrar="Error: bad whois"
            }
        elif [[ $domain == *.gov ]]; then
            registrar='https://get.gov/'
        elif [ -s "$whois_tmpdir/$domain.json" ]; then
            registrar=$(jq -r '.entities[] | select(.roles[]=="registrar") | .links[] | select(.rel=="about") | .href' < "$whois_tmpdir/$domain.json") || {
                registrar="Error: no URL in RDAP"
            }

            registrar_name=$(jq -r '.entities[] | select(.roles[] == "registrar") | .vcardArray[1][] | select(.[0] == "fn") | .[3]' < "$whois_tmpdir/$domain.json") || {
                registrar_name="<UNKNOWN>"
            }
        else
            registrar="Error: no result"
        fi

        echo -e "$i\t$domain\t$registrar\t$registrar_name"
    done
}

whois_lookup

parse_results

trap - EXIT
