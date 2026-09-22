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

# Read once for the whole fleet: the bucket, not any one node, is what knows
# which node owns which cell.
OWNERS="$(provider_cell_owners)"

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
    # rather than loopback, so the node has to curl its own internal IP. Only
    # the curl runs there; the JSON comes back here to be read.
    # shellcheck disable=SC2086
    provider_ssh "$n" "curl -s $CD_CURL_DEADLINE http://${ip}:${CD_INTERNAL_PORT}/state" 2>/dev/null \
        | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    print("  state          (could not read the operator API)"); raise SystemExit
name, owners = sys.argv[1], sys.argv[2]
# resident_cells and cpu_percent_x100 exist only inside node_load; read from
# the top level they were always 0. occupied is the same count as the former.
load = s.get("node_load") or {}
def split(counts): return "  (%s)" % ", ".join("%s: %s" % kv for kv in sorted(counts.items())) if counts else ""
# Resident cells are listed as Class:id. Owned ones are only counted, so their
# classes come from the ownership records in the bucket (provider_cell_owners);
# without those, the count stands alone.
resident = {}
for c in s.get("residents", []):
    k = c.split(":", 1)[0]
    resident[k] = resident.get(k, 0) + 1
owned = {}
for line in owners.splitlines():
    node, cls, n = line.split()
    if node == name:
        owned[cls] = int(n)
print("  owned cells    %s%s" % (s.get("owned_cells", 0), split(owned)))
print("  resident cells %s%s" % (s.get("occupied", 0), split(resident)))
print("  rss            %.0f MB" % (s.get("rss_bytes", 0) / 1048576.0))
print("  cpu            %.1f%%" % (load.get("cpu_percent_x100", 0) / 100.0))
iso = (s.get("deployment") or {}).get("isolates")
if iso is not None:
    print("  isolates       %s" % (len(iso) if isinstance(iso, (list, dict)) else iso))
' "$name" "$OWNERS"
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
echo
echo "  by prefix:"
provider_bucket_breakdown
