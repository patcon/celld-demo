#!/usr/bin/env bash
# Starts the stopped VMs. The counterpart to stop.
#
# celld and cloudflared are systemd-enabled, so they come back on their own;
# this waits until they actually have. In quick-tunnel mode the public URL is
# new, because a quick tunnel's hostname is assigned at process start and
# cloudflared just restarted. A named tunnel keeps its hostname.

CD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$CD_SCRIPT_DIR/lib.sh"
handle_help "${1:-}" "$0"

require_config

for_each_node provider_start_node

for n in $(node_numbers); do
    name="$(node_name "$n")"
    log_step "Waiting for $name"
    wait_for "SSH is up" 30 10 provider_ssh "$n" true \
        || die "SSH did not come up after 5 minutes on $name."
    wait_for "celld is healthy" 30 5 \
        provider_ssh "$n" "curl -fsS http://127.0.0.1:${CD_PUBLIC_PORT}/.well-known/celld/health" \
        || die "celld did not become healthy on $name. Read the log: ./celld-demo logs $n"
done

URL="$(tunnel_url 1)"
log_step "Running"
if [ -n "$URL" ]; then
    echo "  $URL"
    [ "$CD_TUNNEL_MODE" = "quick" ] && echo "  (a quick tunnel gets a new hostname on every start)"
else
    echo "  Run ./celld-demo status for the public URL."
fi
