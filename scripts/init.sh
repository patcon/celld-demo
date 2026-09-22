#!/usr/bin/env bash
# First-run setup: asks which GCP project, zone and bucket to use.
#
# Writes everything to scripts/local.env (gitignored) so the other verbs run
# unattended. Re-running is safe: current values are offered as defaults, so
# you can press enter through the parts you do not want to change.
#
# This is also where the Cloudflare tunnel is set up, because it is the only
# step that needs a browser.

CD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$CD_SCRIPT_DIR/lib.sh"
handle_help "${1:-}" "$0"

LOCAL_ENV="$CD_SCRIPT_DIR/local.env"

# Prompt with a default. Reads from the terminal rather than stdin so this
# still behaves if the script is piped.
ask() {
    local prompt="$1" default="${2:-}" answer
    if [ -n "$default" ]; then
        read -r -p "$(echo -e "\033[1;36m?\033[0m $prompt [\033[1m$default\033[0m]: ")" answer </dev/tty
        echo "${answer:-$default}"
    else
        read -r -p "$(echo -e "\033[1;36m?\033[0m $prompt: ")" answer </dev/tty
        echo "$answer"
    fi
}

confirm() {
    local answer
    answer="$(ask "$1 (y/n)" "${2:-y}")"
    [[ "$answer" =~ ^[Yy] ]]
}

# A test fleet should sit near you: you are the only traffic it will ever see,
# and every verb here is a round trip. Guess from the machine's timezone.
suggest_zone() {
    local tz
    tz="$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')"
    [ -n "$tz" ] || tz="$(date +%Z)"
    case "$tz" in
        America/Toronto|America/Montreal|America/New_York|EST|EDT) echo "northamerica-northeast2-a" ;;
        America/Vancouver|America/Los_Angeles|PST|PDT)             echo "us-west1-b" ;;
        America/Chicago|America/Winnipeg|CST|CDT)                  echo "us-central1-a" ;;
        America/Denver|MST|MDT)                                    echo "us-west3-a" ;;
        Europe/Amsterdam|Europe/Berlin|Europe/Paris|CET|CEST)      echo "europe-west4-a" ;;
        Europe/London|GMT|BST)                                     echo "europe-west2-a" ;;
        *)                                                         echo "us-central1-a" ;;
    esac
}

# us-central1-a -> us-central1. The bucket goes in the region the nodes are in:
# celld's durable writes are bucket round trips, so a bucket on another
# continent is the one configuration mistake that makes it look slow.
zone_region() { echo "${1%-*}"; }

log_step "Checking gcloud"
require_auth

# --- Account ---------------------------------------------------------------

# Only worth asking when there is a choice to get wrong. One signed-in account
# is the common case and answering "which one" there is pure friction.
SIGNED_IN="$(gcloud auth list --format='value(account)' 2>/dev/null)"
if [ "$(echo "$SIGNED_IN" | grep -c .)" -gt 1 ]; then
    log_step "Account"
    echo "You are signed in to more than one account. This fleet gets billed to"
    echo "whichever one you pick here, and every gcloud call this tool makes"
    echo "will name it explicitly -- so switching your active account later"
    echo "with 'gcloud config set account' will not move this fleet."
    echo
    echo "$SIGNED_IN" | sed 's/^/  /'
    echo
    ACCOUNT="$(ask "Account for this fleet" "$CD_GCLOUD_ACCOUNT")"
    echo "$SIGNED_IN" | grep -qx "$ACCOUNT" \
        || die "'$ACCOUNT' is not signed in. Run: gcloud auth login $ACCOUNT"
    CD_GCLOUD_ACCOUNT="$ACCOUNT"
    log_info "Using $CD_GCLOUD_ACCOUNT"
fi

# --- Project ---------------------------------------------------------------

log_step "Project"
echo "This creates VMs and a bucket and bills them, so use a sandbox project"
echo "you are happy to delete. Projects your account can see:"
echo
# shellcheck disable=SC2086
gcloud ${CD_GCLOUD_ACCOUNT:+--account=$CD_GCLOUD_ACCOUNT} \
    projects list --format='table(projectId,name,projectNumber)' 2>/dev/null | sed 's/^/  /' \
    || log_warn "  (could not list projects; if this says reauth, run: gcloud auth login $CD_GCLOUD_ACCOUNT)"
echo
PROJECT="$(ask "GCP project id" "${CD_PROJECT:-}")"
[ -n "$PROJECT" ] || die "A project id is required."

# shellcheck disable=SC2086
GC_ACCT="${CD_GCLOUD_ACCOUNT:+--account=$CD_GCLOUD_ACCOUNT}"
# shellcheck disable=SC2086
if gcloud $GC_ACCT billing projects describe "$PROJECT" >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    if [ "$(gcloud $GC_ACCT billing projects describe "$PROJECT" --format='value(billingEnabled)' 2>/dev/null)" != "True" ]; then
        log_warn "Billing is NOT enabled on '$PROJECT'. Compute Engine will refuse to create instances."
        log_warn "Link a billing account: gcloud billing projects link $PROJECT --billing-account=<ACCOUNT_ID>"
        confirm "Continue anyway?" "n" || exit 1
    else
        log_info "Billing is enabled"
    fi
else
    log_warn "Could not read billing status (needs the Cloud Billing API and billing.viewer). Skipping the check."
fi

# --- Credentials for the local celld CLI -----------------------------------

log_step "Application Default Credentials"
echo "Your gcloud login and ADC are separate credentials. \`celld deploy\` runs"
echo "on this machine and writes straight to the bucket, so it needs ADC."
if gcloud auth application-default print-access-token >/dev/null 2>&1; then
    log_info "ADC are present"
else
    log_warn "No Application Default Credentials found."
    if confirm "Run 'gcloud auth application-default login' now?" "y"; then
        # --account is a hint here, not a guarantee: this flow hands off to a
        # browser, and the browser's account chooser has the last word. Pick
        # $CD_GCLOUD_ACCOUNT in it. The check below is what actually catches a
        # wrong pick.
        # shellcheck disable=SC2086
        gcloud ${CD_GCLOUD_ACCOUNT:+--account=$CD_GCLOUD_ACCOUNT} auth application-default login
    else
        log_warn "Skipped. \`./celld-demo deploy\` will fail until you run it."
    fi
fi

# ADC is a second, independent credential, and the browser chose it. If it
# landed on a different Google account than the one running gcloud, everything
# here still looks fine -- until `celld deploy` writes to the bucket as that
# other identity and gets a 403. Say so now, while the fix is one command.
ADC_ACCOUNT="$(adc_account || true)"
if [ -n "$ADC_ACCOUNT" ] && [ -n "${CD_GCLOUD_ACCOUNT:-}" ] && [ "$ADC_ACCOUNT" != "$CD_GCLOUD_ACCOUNT" ]; then
    log_warn "ADC belong to '$ADC_ACCOUNT', but this fleet uses '$CD_GCLOUD_ACCOUNT'."
    log_warn "\`./celld-demo deploy\` writes to the bucket as '$ADC_ACCOUNT'."
    log_warn "Redo the ADC login and pick $CD_GCLOUD_ACCOUNT in the browser:"
    log_warn "  gcloud auth application-default login"
elif [ -n "$ADC_ACCOUNT" ]; then
    log_info "ADC belong to $ADC_ACCOUNT"
fi

# ADC login takes its quota project from whatever `gcloud config` currently
# points at, which is usually not the project chosen above -- so it warns about
# a project that has nothing to do with this fleet, and the warning names a
# permission you may well hold on the right one. Point it at the project we
# actually use.
#
# Nothing here needs a quota project: Cloud Storage bills operations to the
# bucket's own project, not the caller's. This is only to keep the login from
# reporting a problem about an unrelated project. Best effort, hence the
# warn-and-continue: it needs serviceusage.services.use on $PROJECT.
if gcloud auth application-default print-access-token >/dev/null 2>&1; then
    gcloud auth application-default set-quota-project "$PROJECT" >/dev/null 2>&1 \
        && log_info "ADC quota project set to '$PROJECT'" \
        || log_warn "Could not set the ADC quota project to '$PROJECT'. Harmless: GCS bills the bucket's project."
fi

# --- Zone and size ---------------------------------------------------------

log_step "Zone"
ZONE="$(ask "Zone" "${CD_ZONE:-$(suggest_zone)}")"

log_step "Machine type"
cat <<'EOF'
celld uses about 0.47 MB of RAM per resident cell, so this demo is nowhere
near memory-bound. Size for comfort, not for cells.

  1) e2-small        2 vCPU (burst) /  2 GB   ~$13/mo running, ~$2/mo stopped
  2) e2-medium       2 vCPU (burst) /  4 GB   ~$27/mo running, ~$2/mo stopped
  3) e2-standard-2   2 vCPU         /  8 GB   ~$49/mo running, ~$2/mo stopped
  4) something else

Those are per node, running 24/7. `./celld-demo stop` is what makes the
difference between the first number and the second.
EOF
case "${CD_MACHINE_TYPE:-}" in
    e2-small)      MACHINE_DEFAULT=1 ;;
    e2-medium)     MACHINE_DEFAULT=2 ;;
    e2-standard-2) MACHINE_DEFAULT=3 ;;
    *)             MACHINE_DEFAULT=4 ;;
esac
CHOICE="$(ask "Choose 1-4" "$MACHINE_DEFAULT")"
case "$CHOICE" in
    1) MACHINE="e2-small" ;;
    2) MACHINE="e2-medium" ;;
    3) MACHINE="e2-standard-2" ;;
    4) MACHINE="$(ask "Machine type" "${CD_MACHINE_TYPE:-e2-small}")" ;;
    # Someone who types a machine type instead of a number meant that.
    e2-*|n2-*|n2d-*|c3-*|c4-*|t2d-*|n1-*|custom-*) MACHINE="$CHOICE" ;;
    *) die "Not a valid choice: $CHOICE" ;;
esac

log_step "Fleet size"
cat <<'EOF'
One node is enough to deploy an app and watch its state survive a stop/start.
It is not enough to see what celld is for: with no peer, every durable write
waits on the bucket and there is nowhere to hand cells off to at shutdown.
Two nodes gets you fleet durability and ~20s failover, at double the compute.

You can change this later and re-run create; it only ever adds nodes.
EOF
NODE_COUNT="$(ask "Number of nodes" "${CD_NODE_COUNT:-1}")"
case "$NODE_COUNT" in
    ''|*[!0-9]*) die "Node count must be a number, got: $NODE_COUNT" ;;
esac
[ "$NODE_COUNT" -ge 1 ] || die "Node count must be at least 1."

# --- Bucket ----------------------------------------------------------------

log_step "Fleet bucket"
echo "All durable state lives here: every cell's SQLite database, the"
echo "deployment pointer, and the node leases. Whoever can read it controls"
echo "the fleet, so it gets its own bucket and its own service account."
echo
BUCKET_DEFAULT="${CD_BUCKET:-gs://celld-demo-$PROJECT}"
BUCKET="$(ask "Bucket (gs://NAME)" "$BUCKET_DEFAULT")"
case "$BUCKET" in
    gs://*) ;;
    *) BUCKET="gs://$BUCKET" ;;
esac
BUCKET_LOCATION="$(ask "Bucket location" "${CD_BUCKET_LOCATION:-$(zone_region "$ZONE")}")"

# --- Ingress ---------------------------------------------------------------

log_step "Ingress"
cat <<'EOF'
celld does not terminate TLS on either listener, so something has to sit in
front. cloudflared runs on each node and dials out to Cloudflare, which means
the VM needs no public IP and no open ingress port at all.

  quick  a random https://<words>.trycloudflare.com URL. No domain, no
         Cloudflare account, nothing to clean up. The URL changes every time
         cloudflared restarts, which includes every `./celld-demo start`.
  named  a stable hostname on a domain in your Cloudflare account. Needs a
         browser login once. Every node runs the same tunnel, so Cloudflare
         load-balances across them for free.
EOF
TUNNEL_MODE="$(ask "Tunnel mode (quick/named)" "${CD_TUNNEL_MODE:-quick}")"
TUNNEL_NAME="${CD_TUNNEL_NAME:-}"
TUNNEL_HOSTNAME="${CD_TUNNEL_HOSTNAME:-}"
TUNNEL_ID="${CD_TUNNEL_ID:-}"

if [ "$TUNNEL_MODE" = "named" ]; then
    require_tool cloudflared "brew install cloudflared"

    # cert.pem is the account-level credential cloudflared uses to create
    # tunnels and DNS records. It is separate from the per-tunnel credentials.
    if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
        log_warn "Not logged in to Cloudflare. A browser window will open."
        cloudflared tunnel login
    fi

    TUNNEL_NAME="$(ask "Tunnel name" "${TUNNEL_NAME:-celld-demo-$CD_USER_SLUG}")"
    TUNNEL_HOSTNAME="$(ask "Public hostname (e.g. celld.example.com)" "$TUNNEL_HOSTNAME")"
    [ -n "$TUNNEL_HOSTNAME" ] || die "A hostname is required for a named tunnel."

    EXISTING_ID="$(cloudflared tunnel list --output json 2>/dev/null \
        | python3 -c 'import json,sys;print(next((t["id"] for t in json.load(sys.stdin) if t["name"]==sys.argv[1]),""))' "$TUNNEL_NAME" 2>/dev/null || true)"
    if [ -n "$EXISTING_ID" ]; then
        TUNNEL_ID="$EXISTING_ID"
        log_info "Reusing tunnel '$TUNNEL_NAME' ($TUNNEL_ID)"
    else
        log_step "Creating tunnel '$TUNNEL_NAME'"
        cloudflared tunnel create "$TUNNEL_NAME"
        TUNNEL_ID="$(cloudflared tunnel list --output json 2>/dev/null \
            | python3 -c 'import json,sys;print(next((t["id"] for t in json.load(sys.stdin) if t["name"]==sys.argv[1]),""))' "$TUNNEL_NAME")"
        [ -n "$TUNNEL_ID" ] || die "Created the tunnel but could not read back its id."
    fi

    log_step "Pointing $TUNNEL_HOSTNAME at the tunnel"
    # Idempotent in practice: re-running on an existing record errors, and that
    # error is not worth failing init over.
    cloudflared tunnel route dns "$TUNNEL_NAME" "$TUNNEL_HOSTNAME" \
        || log_warn "Could not create the DNS record. If it already points at this tunnel, that is fine."

    log_info "Credentials live in ~/.cloudflared/$TUNNEL_ID.json and are shipped to the nodes by create."
else
    TUNNEL_MODE="quick"
fi

# --- celld version ---------------------------------------------------------

log_step "celld version"
echo "Empty means the latest release at create time. Pin a tag (e.g. v0.4.0)"
echo "to make create repeatable: celld has had upgrades that needed the whole"
echo "fleet stopped rather than a rolling restart."
CELLD_VERSION="$(ask "celld version (blank for latest)" "${CD_CELLD_VERSION:-}")"

# celld's installer requires a `v`-prefixed tag and rejects anything else with
# "release version must be a tag such as v0.0.1" -- on the VM, during boot,
# where nobody sees it until they go reading the bootstrap log. Typing 0.5.1
# rather than v0.5.1 is the obvious mistake to make, so accept it.
case "$CELLD_VERSION" in
    [0-9]*) CELLD_VERSION="v$CELLD_VERSION"; log_info "Reading that as $CELLD_VERSION" ;;
esac

# --- Write -----------------------------------------------------------------

log_step "Writing local.env"
cat > "$LOCAL_ENV" <<EOF
# Written by ./celld-demo init on $(date -u '+%Y-%m-%d %H:%M UTC'). Gitignored.
#
# Per-person settings for the celld demo fleet. Edit freely, or re-run init to
# regenerate. Committed defaults and the reasoning behind them live in
# config.sh; anything set here overrides them, and an explicit env var
# overrides both.

CD_PROJECT="$PROJECT"
CD_GCLOUD_ACCOUNT="$CD_GCLOUD_ACCOUNT"
CD_ZONE="$ZONE"
CD_BUCKET="$BUCKET"
CD_BUCKET_LOCATION="$BUCKET_LOCATION"

CD_NODE_COUNT="$NODE_COUNT"
CD_MACHINE_TYPE="$MACHINE"
CD_CELLD_VERSION="$CELLD_VERSION"

CD_TUNNEL_MODE="$TUNNEL_MODE"
CD_TUNNEL_NAME="$TUNNEL_NAME"
CD_TUNNEL_HOSTNAME="$TUNNEL_HOSTNAME"
CD_TUNNEL_ID="$TUNNEL_ID"
EOF

log_info "Wrote $LOCAL_ENV"
echo
grep -v '^#' "$LOCAL_ENV" | grep -v '^$' | sed 's/^/  /'

log_step "Next"
cat <<EOF
  ./celld-demo create    the bucket, the service account, and $NODE_COUNT node(s)
  ./celld-demo deploy    build app/ and roll it out to the fleet
  ./celld-demo status    where everything is

Before create, it is worth proving the app works with no cloud at all:
  cd app && celld dev
EOF
