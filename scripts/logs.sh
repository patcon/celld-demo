#!/usr/bin/env bash
# Tails a node's celld log.
#
# Usage:
#   ./celld-demo logs                 follow node 1's celld log
#   ./celld-demo logs 2               follow node 2
#   ./celld-demo logs 1 --cloudflared the tunnel's log instead
#   ./celld-demo logs 1 --boot        the one-time bootstrap log
#   ./celld-demo logs 1 --no-follow   the last 200 lines and exit
#
# celld writes data to stdout and messages to stderr, so both land here. Set
# RUST_LOG on the node (in /etc/celld.env) for anything more detailed.

CD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$CD_SCRIPT_DIR/lib.sh"
handle_help "${1:-}" "$0"

require_config

NODE=1
UNIT=celld
FOLLOW=true
BOOT=false
for arg in "$@"; do
    case "$arg" in
        --cloudflared) UNIT=cloudflared ;;
        --boot)        BOOT=true ;;
        --no-follow)   FOLLOW=false ;;
        -*)            die "Unknown option: $arg" ;;
        *)             NODE="$arg" ;;
    esac
done

require_running_node() {
    local status
    status="$(provider_node_status "$1")"
    [ "$status" = "RUNNING" ] || die "$(node_name "$1") is $status. Run: ./celld-demo start"
}
require_running_node "$NODE"

if [ "$BOOT" = true ]; then
    provider_ssh "$NODE" "sudo tail -n 200 /var/log/celld-bootstrap.log"
    exit 0
fi

if [ "$FOLLOW" = true ]; then
    log_info "Following $UNIT on $(node_name "$NODE"). Ctrl-C to stop."
    provider_ssh "$NODE" "sudo journalctl -u $UNIT -n 100 -f"
else
    provider_ssh "$NODE" "sudo journalctl -u $UNIT -n 200 --no-pager"
fi
