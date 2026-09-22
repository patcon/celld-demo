#!/usr/bin/env bash
# Stops celld and cloudflared, leaving the VMs running.
#
# Useful for taking the app offline, or freeing memory on a small node, without
# losing the boot. It saves you nothing: a running VM bills the same whether
# celld is on it or not. To stop paying for compute, use `./celld-demo stop`.
#
# celld is stopped last and cloudflared first, so traffic stops arriving before
# the cells start moving.

CD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$CD_SCRIPT_DIR/lib.sh"
handle_help "${1:-}" "$0"

require_config

for n in $(node_numbers); do
    name="$(node_name "$n")"
    status="$(provider_node_status "$n")"
    if [ "$status" != "RUNNING" ]; then
        log_info "$name is $status; nothing to stop."
        continue
    fi
    log_step "Stopping services on $name"
    provider_ssh "$n" "sudo systemctl stop cloudflared celld"
    log_info "$name is idle"
done

log_info "VMs are still running and still billing. ./celld-demo stop to stop paying."
