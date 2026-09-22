#!/usr/bin/env bash
# Where everything is: nodes, services, cells, the public URL, the bucket.
#
# Reads live state from GCP and from each node's operator API rather than from
# local.env, so this is also how you find out that local.env has drifted.

CD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$CD_SCRIPT_DIR/lib.sh"
handle_help "${1:-}" "$0"

require_config

log_step "Fleet"
echo "  project  $CD_PROJECT"
echo "  zone     $CD_ZONE"
echo "  bucket   $CD_BUCKET  (backend: $CD_STORAGE_BACKEND)"
echo "  nodes    $CD_NODE_COUNT configured"
echo

provider_list_nodes 2>/dev/null | sed 's/^/  /' || log_warn "  (could not list instances)"

for n in $(node_numbers); do
    name="$(node_name "$n")"
    status="$(provider_node_status "$n")"

    log_step "$name ($status)"
    if [ "$status" != "RUNNING" ]; then
        echo "  Not running. ./celld-demo start"
        continue
    fi

    services="$(provider_ssh "$n" "systemctl is-active celld cloudflared | tr '\n' ' '" 2>/dev/null || echo "unknown")"
    echo "  services       celld/cloudflared: $services"

    # Bounded, because a node awaiting its first deployment accepts the
    # connection and never answers. Without a deadline this call is where
    # status silently hung forever.
    echo "  health         $(describe_health "$(node_health_code "$n")")"

    ip="$(provider_internal_ip "$n")"
    # The operator API is on the internal listener, which binds the VPC address
    # rather than loopback, so the node has to curl its own internal IP.
    # shellcheck disable=SC2086
    provider_ssh "$n" "curl -s $CD_CURL_DEADLINE http://${ip}:${CD_INTERNAL_PORT}/state | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    print(\"  state          (no response from the operator API)\"); raise SystemExit
def g(k, d=0): return s.get(k, d)
print(\"  owned cells    %s\" % g(\"owned_cells\"))
print(\"  resident cells %s\" % g(\"resident_cells\"))
print(\"  rss            %.0f MB\" % (g(\"rss_bytes\")/1048576.0))
print(\"  cpu            %.1f%%\" % (g(\"cpu_percent_x100\")/100.0))
iso = (s.get(\"deployment\") or {}).get(\"isolates\")
if iso is not None:
    print(\"  isolates       %s\" % (len(iso) if isinstance(iso, (list, dict)) else iso))
'" 2>/dev/null || echo "  state          (could not read the operator API)"
done

log_step "Ingress"
URL="$(tunnel_url 1)"
if [ -n "$URL" ]; then
    echo "  $URL  ($CD_TUNNEL_MODE tunnel)"
else
    echo "  No tunnel URL yet ($CD_TUNNEL_MODE tunnel)."
    echo "  Check cloudflared: ./celld-demo logs 1 --cloudflared"
fi

log_step "Bucket"
# Labelled, because bare `du -s` output reads as an unexplained number that
# leaps by four orders of magnitude once the first deployment lands: an
# undeployed fleet bucket holds nothing but celld's format marker.
echo "  total size across all objects:"
provider_bucket_usage | sed 's/^/  /'
