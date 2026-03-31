#!/bin/bash
# koha-worker-fix.sh
# Diagnose and fix stale/missing Koha background worker daemons.
# Usage: sudo koha-worker-fix.sh [instancename ...]
#        (no args = all enabled instances)

set -euo pipefail

QUEUES=("default" "long_tasks")
PIDFILE_BASE="/var/run/koha"
LOGFILE_BASE="/var/log/koha"
KOHA_SITES="/etc/koha/sites"
WORKER_DAEMON="/usr/share/koha/bin/workers/background_jobs_worker.pl"
PERL5LIB="/usr/share/koha/lib"

RED='\033[0;31m'
YEL='\033[1;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
RST='\033[0m'

info()  { echo -e "${CYN}[INFO]${RST}  $*"; }
ok()    { echo -e "${GRN}[ OK ]${RST}  $*"; }
warn()  { echo -e "${YEL}[WARN]${RST}  $*"; }
fail()  { echo -e "${RED}[FAIL]${RST}  $*"; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Run as root (sudo $0 $*)" >&2
        exit 1
    fi
}

get_worker_name() {
    local instance=$1 queue=$2
    if [[ "$queue" == "default" ]]; then
        echo "${instance}-koha-worker"
    else
        echo "${instance}-koha-worker-${queue}"
    fi
}

pidfile_path() {
    local instance=$1 queue=$2
    local name
    name=$(get_worker_name "$instance" "$queue")
    echo "${PIDFILE_BASE}/${instance}/${name}.pid"
}

clientpid_path() {
    local instance=$1 queue=$2
    local name
    name=$(get_worker_name "$instance" "$queue")
    echo "${PIDFILE_BASE}/${instance}/${name}.clientpid"
}

is_pid_alive() {
    local pid=$1
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

check_pidfile() {
    local pidfile=$1
    if [[ ! -f "$pidfile" ]]; then
        echo "missing"
        return
    fi
    local pid
    pid=$(cat "$pidfile" 2>/dev/null || true)
    if [[ -z "$pid" ]]; then
        echo "empty"
    elif is_pid_alive "$pid"; then
        echo "alive:$pid"
    else
        echo "stale:$pid"
    fi
}

# Returns: running | stale | missing
worker_state() {
    local instance=$1 queue=$2
    local dpid cpid
    dpid=$(check_pidfile "$(pidfile_path "$instance" "$queue")")
    cpid=$(check_pidfile "$(clientpid_path "$instance" "$queue")")

    if [[ "$dpid" == alive:* && "$cpid" == alive:* ]]; then
        echo "running"
    elif [[ "$dpid" == stale:* || "$cpid" == stale:* ]]; then
        echo "stale"
    elif [[ "$dpid" == missing && "$cpid" == missing ]]; then
        echo "missing"
    else
        # one alive, one missing/stale — partial
        echo "stale"
    fi
}

purge_stale_pidfiles() {
    local instance=$1 queue=$2
    local pf cpf
    pf=$(pidfile_path "$instance" "$queue")
    cpf=$(clientpid_path "$instance" "$queue")
    [[ -f "$pf"  ]] && rm -f "$pf"  && warn "  Removed stale pidfile: $pf"
    [[ -f "$cpf" ]] && rm -f "$cpf" && warn "  Removed stale clientpid: $cpf"
}

start_worker() {
    local instance=$1 queue=$2
    local name
    name=$(get_worker_name "$instance" "$queue")
    local koha_conf="${KOHA_SITES}/${instance}/koha-conf.xml"

    info "  Attempting: koha-worker --start --queue ${queue} ${instance}"

    # Let koha-worker try first (it uses /etc/default/koha-common for PERL5LIB)
    if koha-worker --start --queue "${queue}" "${instance}" 2>/dev/null; then
        ok "  Started via koha-worker"
        return 0
    fi

    # Fallback: direct daemon invocation with explicit env
    warn "  koha-worker failed, falling back to direct daemon invocation"
    if daemon \
        --name="${name}" \
        --errlog="${LOGFILE_BASE}/${instance}/worker-error.log" \
        --output="${LOGFILE_BASE}/${instance}/worker-output.log" \
        --pidfiles="${PIDFILE_BASE}/${instance}/" \
        --verbose=1 --respawn --delay=30 \
        --user="${instance}-koha.${instance}-koha" \
        -- /usr/bin/env \
            KOHA_CONF="${koha_conf}" \
            PERL5LIB="${PERL5LIB}" \
            /usr/bin/perl "${WORKER_DAEMON}" --queue "${queue}"; then
        ok "  Started via direct daemon (env: KOHA_CONF + PERL5LIB injected)"
    else
        fail "  Could not start worker for ${instance} (${queue})"
        return 1
    fi
}

tail_worker_logs() {
    local instance=$1
    echo
    info "  --- Last 10 lines: worker-error.log ---"
    tail -10 "${LOGFILE_BASE}/${instance}/worker-error.log" 2>/dev/null || true
    info "  --- Last 10 lines: worker-output.log ---"
    tail -10 "${LOGFILE_BASE}/${instance}/worker-output.log" 2>/dev/null || true
}

diagnose_and_fix() {
    local instance=$1
    local koha_conf="${KOHA_SITES}/${instance}/koha-conf.xml"
    local had_issue=0

    echo
    echo -e "${CYN}--- instance: ${instance} ---${RST}"

    # Sanity: instance must exist
    if [[ ! -f "$koha_conf" ]]; then
        fail "koha-conf.xml not found at ${koha_conf} — skipping"
        return 1
    fi

    for queue in "${QUEUES[@]}"; do
        local state
        state=$(worker_state "$instance" "$queue")

        case "$state" in
            running)
                ok "Worker [${queue}] running"
                ;;
            stale)
                warn "Worker [${queue}] has stale pidfiles — cleaning up"
                had_issue=1

                # Stop the daemon gracefully first (ignore errors)
                local name
                name=$(get_worker_name "$instance" "$queue")
                daemon \
                    --name="${name}" \
                    --pidfiles="${PIDFILE_BASE}/${instance}/" \
                    --stop 2>/dev/null || true

                purge_stale_pidfiles "$instance" "$queue"
                sleep 1
                start_worker "$instance" "$queue"
                ;;
            missing)
                warn "Worker [${queue}] not running — starting"
                had_issue=1
                start_worker "$instance" "$queue"
                ;;
        esac

        # Re-verify after fix attempt
        if [[ "$state" != "running" ]]; then
            sleep 2
            local new_state
            new_state=$(worker_state "$instance" "$queue")
            if [[ "$new_state" == "running" ]]; then
                ok "Worker [${queue}] confirmed running after fix"
            else
                fail "Worker [${queue}] still not running after fix attempt"
                tail_worker_logs "$instance"
            fi
        fi
    done

    if [[ $had_issue -eq 0 ]]; then
        ok "All workers healthy, no action taken"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

require_root

# Source /etc/default/koha-common so PERL5LIB is set (same as koha-worker)
[[ -r /etc/default/koha-common ]] && . /etc/default/koha-common

# Source koha-functions for is_instance etc if available
[[ -f /usr/share/koha/bin/koha-functions.sh ]] && \
    . /usr/share/koha/bin/koha-functions.sh

if [[ $# -gt 0 ]]; then
    INSTANCES=("$@")
else
    # All enabled instances
    mapfile -t INSTANCES < <(koha-list --enabled 2>/dev/null)
fi

if [[ ${#INSTANCES[@]} -eq 0 ]]; then
    warn "No instances found."
    exit 0
fi

echo -e "${CYN}koha-worker debugger${RST} -- queues: ${QUEUES[*]}"
echo -e "Instances: ${INSTANCES[*]}"

FAILED=()
for instance in "${INSTANCES[@]}"; do
    if ! diagnose_and_fix "$instance"; then
        FAILED+=("$instance")
    fi
done

echo
if [[ ${#FAILED[@]} -gt 0 ]]; then
    fail "Instances with unresolved issues: ${FAILED[*]}"
    exit 1
else
    ok "All done."
fi
