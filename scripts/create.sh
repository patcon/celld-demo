#!/usr/bin/env bash
# Creates the bucket, the service account and the fleet's VMs.
#
# Idempotent throughout: anything that already exists is reported and skipped,
# so this is also how you add a node. Raise CD_NODE_COUNT and re-run.
#
# It does not deploy the app. `./celld-demo deploy` does that, and the fleet is
# expected to come up with nothing deployed; celld serves 404s until it has a
# deployment pointer to read.

CD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$CD_SCRIPT_DIR/lib.sh"
handle_help "${1:-}" "$0"

log_step "Checking access to $CD_PROJECT"
provider_preflight

log_step "Fleet bucket"
provider_ensure_bucket
provider_ensure_firewall

log_step "Nodes"
log_info "Fleet size: $CD_NODE_COUNT"
for_each_node provider_ensure_node

for n in $(node_numbers); do
    name="$(node_name "$n")"

    log_step "Waiting for SSH on $name"
    wait_for "SSH is up" 30 10 provider_ssh "$n" true \
        || die "SSH did not come up after 5 minutes on $name.
Check the console output:
  gcloud compute instances get-serial-port-output $name --zone $CD_ZONE --project $CD_PROJECT"

    log_step "Waiting for bootstrap on $name"
    # The startup script installs celld and cloudflared, which is a download
    # each, so first boot takes a couple of minutes.
    wait_for "Bootstrap finished" 30 10 \
        provider_ssh "$n" "test -f /var/lib/celld-bootstrap-done" \
        || die "Bootstrap did not finish after 5 minutes on $name.
Read the log:
  ./celld-demo ssh $n -- sudo tail -50 /var/log/celld-bootstrap.log"

    log_step "Waiting for celld to report healthy on $name"
    # Health is 503 until the node has joined the fleet and settled, so this
    # waits for a real 200 rather than for the port to open.
    wait_for "celld is healthy" 30 5 \
        provider_ssh "$n" "curl -fsS http://127.0.0.1:${CD_PUBLIC_PORT}/.well-known/celld/health" \
        || die "celld did not become healthy after 2.5 minutes on $name.
Read the log:
  ./celld-demo logs $n"
done

log_step "Ingress"
URL="$(tunnel_url 1)"
if [ -n "$URL" ]; then
    log_info "Public URL: $URL"
else
    log_warn "Could not read the tunnel URL yet. ./celld-demo status will show it once cloudflared has registered."
fi

log_step "Next"
cat <<EOF
  ./celld-demo deploy    build app/ and roll it out
  ./celld-demo status    nodes, cells, memory, and the public URL

A running node costs money whether or not anything is deployed to it. When you
finish for the day:
  ./celld-demo stop
EOF
