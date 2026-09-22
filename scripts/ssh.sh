#!/usr/bin/env bash
# Opens a shell on a node.
#
# Usage:
#   ./celld-demo ssh              node 1
#   ./celld-demo ssh 2            node 2
#   ./celld-demo ssh 1 -- sudo systemctl status celld
#
# Everything after `--` goes to the real ssh, so scp-style flags and one-off
# commands both work. The celld binary is at /opt/celld/bin/celld, its config
# at /etc/celld.env, and its working state at /var/lib/celld.

CD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$CD_SCRIPT_DIR/lib.sh"
handle_help "${1:-}" "$0"

require_config

NODE=1
case "${1:-}" in
    ''|--) ;;
    [0-9]*) NODE="$1"; shift ;;
esac
[ "${1:-}" = "--" ] && shift

status="$(provider_node_status "$NODE")"
[ "$status" = "RUNNING" ] || die "$(node_name "$NODE") is $status. Run: ./celld-demo start"

if [ $# -gt 0 ]; then
    provider_ssh "$NODE" "$@"
else
    provider_ssh_interactive "$NODE"
fi
