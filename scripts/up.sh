#!/usr/bin/env bash
# Starts celld and cloudflared on running VMs.
#
# The counterpart to down. Use this after a `down`, or when a node's services
# died and you want them back without a reboot.
#
# This does not start VMs and does not save you money on its own. To stop
# paying for compute, use `./celld-demo stop`.

CD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$CD_SCRIPT_DIR/lib.sh"
handle_help "${1:-}" "$0"

require_config

for n in $(node_numbers); do
    name="$(node_name "$n")"
    status="$(provider_node_status "$n")"
    if [ "$status" != "RUNNING" ]; then
        log_warn "$name is $status. Run ./celld-demo start first."
        continue
    fi

    log_step "Starting services on $name"
    provider_ssh "$n" "sudo systemctl start celld cloudflared"
    wait_for "celld is healthy" 30 5 \
        provider_ssh "$n" "curl -fsS http://127.0.0.1:${CD_PUBLIC_PORT}/.well-known/celld/health" \
        || die "celld did not become healthy on $name. Read the log: ./celld-demo logs $n"
done

URL="$(tunnel_url 1)"
[ -n "$URL" ] && log_info "Public URL: $URL"
