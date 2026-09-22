#!/usr/bin/env bash
# Builds app/ and rolls it out to the fleet.
#
# Runs entirely on this machine: `celld deploy` bundles the Worker with esbuild
# and writes the deployment objects straight into the bucket. The nodes are not
# involved, which is why this works even while they are stopped.
#
# Nodes notice a new deployment within CELLD_DEPLOY_POLL_S (30s by default) on
# their own. This also pokes each node's /reload so the rollout is immediate.
# Pass --no-reload to skip that and let them find it in their own time.
#
# Usage:
#   ./celld-demo deploy
#   ./celld-demo deploy --no-reload

CD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$CD_SCRIPT_DIR/lib.sh"
handle_help "${1:-}" "$0"

RELOAD=true
[ "${1:-}" = "--no-reload" ] && RELOAD=false

require_config
require_celld

# celld shells out to esbuild to bundle the Worker. A local install in app/ is
# the reproducible way to get one, so put it on PATH if it is there and fall
# back to a global esbuild otherwise.
if [ -d "$CD_ROOT/app/node_modules/.bin" ]; then
    PATH="$CD_ROOT/app/node_modules/.bin:$PATH"
    export PATH
fi
require_tool esbuild "cd app && pnpm install"

provider_require_deploy_creds
export_storage_env

log_step "Deploying app/ to $CD_BUCKET"
# shellcheck disable=SC2046
celld deploy "$CD_ROOT/app" $(celld_bucket_args)

if [ "$RELOAD" = true ]; then
    log_step "Reloading nodes"
    for n in $(node_numbers); do
        name="$(node_name "$n")"
        status="$(provider_node_status "$n")"
        if [ "$status" != "RUNNING" ]; then
            log_warn "$name is $status; it will pick this deployment up when it starts."
            continue
        fi
        ip="$(provider_internal_ip "$n")"
        # /reload lives on the internal listener, which binds the VPC address
        # rather than loopback, so the node curls its own internal IP.
        # shellcheck disable=SC2086
        if provider_ssh "$n" "curl -fsS $CD_CURL_DEADLINE -X POST http://${ip}:${CD_INTERNAL_PORT}/reload" >/dev/null 2>&1; then
            log_info "$name adopted the new deployment"
        else
            log_warn "$name did not accept /reload; it will poll within 30s anyway."
        fi
    done
fi

# The health check lives here rather than in create, because this is the first
# moment it can pass. Before a deployment exists celld has reserved its ports
# but is still waiting on the bucket pointer, and the health path answers
# nothing at all; the deploy above is what releases it. A node reaches 200
# once it is not draining, its fleet gate is open, and it is serving.
log_step "Waiting for nodes to report healthy"
for n in $(node_numbers); do
    name="$(node_name "$n")"
    status="$(provider_node_status "$n")"
    if [ "$status" != "RUNNING" ]; then
        log_warn "$name is $status; skipping its health check."
        continue
    fi
    if wait_for "$name is healthy" 20 5 node_healthy "$n"; then
        continue
    fi
    # Not fatal. The deployment is already committed to the bucket -- that is
    # the fleet-wide commit point -- so a node that is slow to settle will
    # still pick it up. Failing the whole deploy here would imply the rollout
    # needs redoing, which it does not.
    log_warn "$name did not report healthy: $(describe_health "$(node_health_code "$n")")"
    log_warn "  The deployment is committed to the bucket regardless. Check: ./celld-demo logs $n"
done

URL="$(tunnel_url 1)"
log_step "Deployed"
if [ -n "$URL" ]; then
    echo "  $URL"
else
    echo "  Run ./celld-demo status for the public URL."
fi
