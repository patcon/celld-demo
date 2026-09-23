#!/usr/bin/env bash
# Deletes the VMs, and optionally the bucket.
#
# Two confirmations, because they are different sizes of mistake. Deleting the
# VMs costs you a few minutes: everything durable is in the bucket, so
# `./celld-demo create && ./celld-demo deploy` puts it all back with the state
# intact. Deleting the bucket is the irreversible one -- that is every cell's
# database, and celld has no other copy.
#
# It only ever deletes nodes 1..CD_NODE_COUNT. If you scaled down by lowering
# the count, the extra nodes are deliberately left alone rather than silently
# destroyed; the fleet list at the top shows them.
#
# Usage:
#   ./celld-demo destroy
#   ./celld-demo destroy --bucket    also offer to delete the bucket

CD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$CD_SCRIPT_DIR/lib.sh"
handle_help "${1:-}" "$0"

require_config

OFFER_BUCKET=false
[ "${1:-}" = "--bucket" ] && OFFER_BUCKET=true

log_step "What exists right now"
provider_list_nodes 2>/dev/null | sed 's/^/  /' || log_warn "  (could not list instances)"
echo
echo "  bucket  $CD_BUCKET"
provider_bucket_usage | sed 's/^/  /'

log_step "What this will do"
# Red X for deleted, green check for kept, so the bucket's fate is visible at
# a glance instead of implied by its absence from a list.
DEL="\033[0;31m✗ delete\033[0m"
KEEP="\033[0;32m✓ keep  \033[0m"
ASK="\033[1;33m? ask   \033[0m"
for n in $(node_numbers); do
    echo -e "  $DEL  $(node_name "$n") + boot disk  ($(provider_node_status "$n"))"
done
echo -e "  $DEL  service account $CD_SERVICE_ACCOUNT"
echo -e "  $DEL  celld-internal firewall rule, if present"
if [ "$OFFER_BUCKET" = true ]; then
    echo -e "  $ASK  $CD_BUCKET  (separate confirmation after this one)"
else
    echo -e "  $KEEP  $CD_BUCKET  (every cell's database; still bills for storage)"
    echo
    echo "  Re-run with --bucket to delete the bucket too."
fi
echo
read -r -p "$(echo -e "\033[0;31mType the instance prefix to confirm:\033[0m $CD_INSTANCE_PREFIX ")" CONFIRM </dev/tty
[ "$CONFIRM" = "$CD_INSTANCE_PREFIX" ] || die "Confirmation did not match. Nothing was deleted."

for n in $(node_numbers); do
    status="$(provider_node_status "$n")"
    if [ "$status" = "NOT_FOUND" ]; then
        log_info "$(node_name "$n") is already gone"
        continue
    fi
    provider_delete_node "$n"
done

provider_teardown

if [ "$OFFER_BUCKET" = true ]; then
    log_step "Deleting the bucket"
    log_warn "$CD_BUCKET holds every cell's database. There is no other copy."
    log_warn "Without it, recreating the fleet gives you an empty one."
    echo
    read -r -p "$(echo -e "\033[0;31mType the bucket name to confirm:\033[0m ${CD_BUCKET#gs://} ")" CONFIRM </dev/tty
    if [ "$CONFIRM" = "${CD_BUCKET#gs://}" ]; then
        provider_delete_bucket
        log_info "Deleted $CD_BUCKET"
    else
        log_info "Confirmation did not match. The bucket was kept."
    fi
else
    log_info "Kept $CD_BUCKET. Re-run with --bucket to delete it too."
fi

log_step "Done"
cat <<EOF
The VMs are gone, so compute billing has stopped. scripts/local.env is
untouched, so ./celld-demo create rebuilds the same fleet.
EOF
