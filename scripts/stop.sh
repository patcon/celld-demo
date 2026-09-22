#!/usr/bin/env bash
# Stops the VMs. Run this whenever you finish for the day.
#
# This is the cost lever. A stopped VM bills only for its boot disk, a couple
# of dollars a month, against ~$13+ per node per month for leaving it running.
# Nothing is lost: every byte of durable state is in the bucket, not on the
# disk, so a stopped fleet is just a fleet with no nodes in it.
#
# celld is stopped first and waited on. SIGTERM starts a handoff -- report
# unhealthy, finish in-flight requests, release cells to peers, publish the
# ownership records -- and cutting the VM's power mid-handoff means the next
# node has to recover those cells from the bucket the slow way instead.

CD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$CD_SCRIPT_DIR/lib.sh"
handle_help "${1:-}" "$0"

require_config

for n in $(node_numbers); do
    name="$(node_name "$n")"
    status="$(provider_node_status "$n")"

    case "$status" in
        NOT_FOUND)
            log_warn "$name does not exist; skipping."
            continue
            ;;
        TERMINATED)
            log_info "$name is already stopped."
            continue
            ;;
    esac

    log_step "Draining $name"
    # `systemctl stop` blocks until the unit is really down, and the unit's
    # TimeoutStopSec is 90s against celld's 40s shutdown bound, so this returns
    # only once the handoff has finished or celld gave up on it.
    provider_ssh "$n" "sudo systemctl stop cloudflared celld" \
        || log_warn "Could not stop services cleanly on $name; stopping the VM anyway."

    provider_stop_node "$n"
done

log_info "Stopped. Durable state is in $CD_BUCKET. Bring it back with ./celld-demo start"
