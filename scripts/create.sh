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

    # A node that already existed has not re-read its metadata: GCE runs the
    # startup script at boot and only at boot. So refreshing metadata alone
    # fixes nothing on a node that failed to bootstrap -- there is no run in
    # flight to succeed, to fail, or to write a marker, and the wait below
    # would spend its whole timeout watching a node where nothing is happening.
    #
    # Only for pre-existing nodes. A node created moments ago is running the
    # script already, and a second concurrent copy would race the first.
    case " ${CD_EXISTING_NODES:-} " in
        *" $n "*)
            if provider_ssh "$n" "test -f /var/lib/celld-bootstrap-done" >/dev/null 2>&1; then
                log_info "$name is already bootstrapped"
            else
                log_step "Running bootstrap on $name"
                log_info "It has not completed here before, so this runs it now. Output is live:"
                # Not backgrounded: the exit status is the answer, and the log
                # streaming past is the thing you actually want to watch.
                provider_ssh "$n" "sudo google_metadata_script_runner startup" 2>&1 \
                    | sed 's/^/  /' || true
            fi
            ;;
    esac

    log_step "Waiting for bootstrap on $name"
    # The startup script installs celld and cloudflared, which is a download
    # each, so first boot takes a couple of minutes. It writes a failure marker
    # if it dies, so a broken bootstrap stops the wait instead of burning the
    # timeout and then being reported as slowness.
    # `|| RC=$?` rather than a bare call: set -e would exit on the non-zero
    # return before the case below ever ran, turning both failure modes back
    # into the silent death this is meant to replace.
    RC=0
    wait_for_or_abort "Bootstrap finished" 30 10 \
        "provider_ssh $n 'test -f /var/lib/celld-bootstrap-failed'" \
        provider_ssh "$n" "test -f /var/lib/celld-bootstrap-done" || RC=$?
    case "$RC" in
        0) ;;
        2) log_error "Bootstrap FAILED on $name. Last 30 lines of its log:"
           provider_ssh "$n" "sudo tail -30 /var/log/celld-bootstrap.log" 2>/dev/null | sed 's/^/  /' || true
           die "Provisioning failed on $name.

Fix the cause, then re-run the startup script on the node:
  ./celld-demo ssh $n -- sudo google_metadata_script_runner startup

If the cause was a setting, change it and re-push it to the node first:
  ./celld-demo create    (updates metadata on existing nodes)" ;;
        *) die "Bootstrap did not finish after 5 minutes on $name, and did not
report a failure either -- so it is either still running or it died before it
could say so (a node bootstrapped by an older copy of these scripts cannot
report failure at all).

Read the log:
  ./celld-demo ssh $n -- sudo tail -50 /var/log/celld-bootstrap.log

If it died, re-run the startup script once the cause is fixed:
  ./celld-demo ssh $n -- sudo google_metadata_script_runner startup" ;;
    esac

    log_step "Waiting for celld to accept connections on $name"
    # Deliberately not a health check. celld reserves its listener sockets
    # before it touches storage, then blocks until the fleet bucket holds a
    # deployment pointer, so a node that has never been deployed to accepts
    # the connection and answers nothing -- health returns neither 200 nor
    # 503, it just never replies. Gating create on a 200 could therefore
    # never pass on a fresh fleet: the deployment that would open the gate
    # comes from `./celld-demo deploy`, which create told you to run *after*
    # it finished. That deadlock is why this waits for the port instead, and
    # why deploy owns the health check.
    wait_for "celld is listening" 30 5 node_port_open "$n" \
        || die "celld is not listening on port $CD_PUBLIC_PORT after 2.5 minutes on $name.
Read the log:
  ./celld-demo logs $n"

    # One bounded probe, for the report rather than as a gate. A fleet that
    # has been deployed to before answers 200 here on a rebuilt node, and
    # saying so is more honest than calling every node "awaiting deployment".
    log_info "health: $(describe_health "$(node_health_code "$n")")"
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
                         Until this runs once, the nodes idle with their ports
                         reserved and serve nothing -- that is celld waiting on
                         the fleet bucket for a deployment, not a broken node.
  ./celld-demo status    nodes, cells, memory, and the public URL

A running node costs money whether or not anything is deployed to it. When you
finish for the day:
  ./celld-demo stop
EOF
