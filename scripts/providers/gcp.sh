#!/usr/bin/env bash
# GCP provider: Compute Engine VMs, a GCS fleet bucket, and a service account
# scoped to that bucket alone.
#
# This is the only file allowed to call gcloud. Every verb script goes through
# the provider_* contract below, which is what makes providers/exe.sh a
# fill-in-the-blanks exercise rather than a rewrite.

# Every gcloud call goes through these wrappers so the pinned project, zone and
# account can never be forgotten at a call site.
#
# The account matters as much as the project when you hold more than one, which
# on a work laptop is the normal case: a bare gcloud call runs as whichever
# account is *active*, and `gcloud config set account` or another tool's login
# can move that out from under you between two runs of this CLI. Pinning it in
# local.env means this tool always acts as the same identity no matter what the
# active account happens to be, and a wrong one fails loudly instead of quietly
# creating billable resources somewhere else.
#
# ${VAR:+--account=$VAR} expands to nothing when unset, so this stays correct
# before init has run. Unquoted on purpose -- it must vanish entirely when
# empty, and an account is an email address, so there is nothing to split on.
# shellcheck disable=SC2086
gc() { gcloud --project "$CD_PROJECT" ${CD_GCLOUD_ACCOUNT:+--account=$CD_GCLOUD_ACCOUNT} "$@"; }

# For compute subcommands that take no `--` passthrough. The zone lands at the
# end, which is fine here but would be wrong for ssh/scp: anything after `--`
# is handed to the real ssh binary, so a trailing --zone would be passed
# through as a bogus ssh argument instead of being read by gcloud.
# shellcheck disable=SC2086
gc_zone() {
    gcloud --project "$CD_PROJECT" ${CD_GCLOUD_ACCOUNT:+--account=$CD_GCLOUD_ACCOUNT} \
        compute "$@" --zone "$CD_ZONE"
}

# ssh and scp put --zone up front, before any caller-supplied args, so callers
# are free to use `--` for real ssh flags.
gc_ssh() {
    local name="$1"
    shift
    # shellcheck disable=SC2086
    gcloud --project "$CD_PROJECT" ${CD_GCLOUD_ACCOUNT:+--account=$CD_GCLOUD_ACCOUNT} \
        compute ssh "$name" --zone "$CD_ZONE" "$@"
}

cd_service_account_email() { echo "${CD_SERVICE_ACCOUNT}@${CD_PROJECT}.iam.gserviceaccount.com"; }

# Bucket name without the gs:// scheme, for gcloud storage, which wants both
# forms in different places.
cd_bucket_name() { echo "${CD_BUCKET#gs://}"; }

# --- Auth ------------------------------------------------------------------

# Only checks that a credential is on disk. It cannot tell whether that
# credential still refreshes; require_gcloud's live API call does that.
require_auth() {
    command -v gcloud >/dev/null 2>&1 \
        || die "gcloud not found. Install the Google Cloud CLI: https://cloud.google.com/sdk/docs/install"

    # A pinned account (local.env, written by init) wins over the active one.
    # It does not have to be the active account -- the wrappers pass --account
    # explicitly -- but it does have to be signed in, or every call fails with
    # a stack of gcloud output that never says "wrong account".
    if [ -n "${CD_GCLOUD_ACCOUNT:-}" ]; then
        gcloud auth list --format='value(account)' 2>/dev/null | grep -qx "$CD_GCLOUD_ACCOUNT" || die \
            "'$CD_GCLOUD_ACCOUNT' is pinned in scripts/local.env but is not signed in to gcloud.

Sign in as that account:
  gcloud auth login $CD_GCLOUD_ACCOUNT

Or, if this fleet should belong to a different account, change
CD_GCLOUD_ACCOUNT in scripts/local.env. Signed in now:
$(gcloud auth list --format='value(account)' 2>/dev/null | sed 's/^/  /')"
        log_info "Acting as $CD_GCLOUD_ACCOUNT (pinned)"
        return 0
    fi

    CD_GCLOUD_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
    [ -n "$CD_GCLOUD_ACCOUNT" ] || die "No active gcloud account. Run: gcloud auth login"
    log_info "Authenticated as $CD_GCLOUD_ACCOUNT"
}

# The ADC identity is a separate credential from the gcloud one, and the
# browser -- not the CLI -- decides which account it ends up on. When you hold
# two Google accounts, the chooser will happily hand back the one you were
# already signed into. `celld deploy` writes to the fleet bucket as *that*
# identity, so a mismatch shows up as a 403 on deploy long after init looked
# like it succeeded. Cheap to check, so check rather than assume.
adc_account() {
    local token
    token="$(gcloud auth application-default print-access-token 2>/dev/null)" || return 1
    curl -sf "https://www.googleapis.com/oauth2/v3/tokeninfo?access_token=$token" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("email",""))' 2>/dev/null
}

# An expired refresh token fails every API call, so without this the caller
# sees "cannot access project" and concludes the project is gone.
die_reauth() {
    die "gcloud credentials for '${CD_GCLOUD_ACCOUNT:-your account}' have expired.

Renew them, then re-run. Naming the account matters: a bare 'gcloud auth login'
signs in as whoever the browser is signed in as, and leaves that account active
instead.

  gcloud auth login ${CD_GCLOUD_ACCOUNT:-<account>}

Nothing in GCP has changed. An expired token makes every project and instance
look missing, because the API rejects the call before it looks anything up."
}

is_reauth_error() {
    case "$1" in
        *"Reauthentication failed"*|*"Reauthentication required"*) return 0 ;;
        *"refreshing your current auth tokens"*|*"invalid_grant"*)  return 0 ;;
        *"credentials are no longer valid"*|*"do not have valid credentials"*) return 0 ;;
        *) return 1 ;;
    esac
}

require_gcloud() {
    require_auth
    require_config

    # First live API call of every script, so it is where a stale token, a
    # project pending deletion, and a genuine permissions problem get told
    # apart. They all surface as the same failed describe otherwise.
    local out
    out="$(gcloud projects describe "$CD_PROJECT" --format='value(lifecycleState)' 2>&1)" || {
        is_reauth_error "$out" && die_reauth
        die "'${CD_GCLOUD_ACCOUNT:-your account}' cannot access project '$CD_PROJECT'.
Check the project id. gcloud said:

$out"
    }

    if [ "$out" = "DELETE_REQUESTED" ]; then
        die "Project '$CD_PROJECT' is scheduled for deletion.

GCP keeps it for 30 days, so it can be brought back:

  gcloud projects undelete $CD_PROJECT"
    fi
}

# Application Default Credentials are separate from your gcloud login, and the
# local celld CLI needs them: `celld deploy` writes to the gs:// bucket from
# here, not from a node.
provider_require_deploy_creds() {
    [ "$CD_STORAGE_BACKEND" = "gcs" ] || return 0
    gcloud auth application-default print-access-token >/dev/null 2>&1 || die \
"No Application Default Credentials.

Your gcloud login and ADC are separate credentials, and the celld CLI uses ADC
to reach $CD_BUCKET from this machine. Run:

  gcloud auth application-default login"
}

# Services are not enabled on a fresh project. Enabling is idempotent and takes
# up to a minute the first time, so only call the API when it is actually off.
require_api() {
    local api="$1"
    if gc services list --enabled --format='value(config.name)' 2>/dev/null | grep -qx "$api"; then
        return 0
    fi
    log_warn "$api is not enabled on '$CD_PROJECT'. Enabling now (this can take a minute)."
    gc services enable "$api"
    log_info "Enabled $api"
}

provider_preflight() {
    require_gcloud
    require_api compute.googleapis.com
    require_api storage.googleapis.com
    require_api iam.googleapis.com
}

# --- Bucket and identity ---------------------------------------------------

provider_ensure_bucket() {
    local name
    name="$(cd_bucket_name)"

    if gc storage buckets describe "gs://$name" --format='value(name)' >/dev/null 2>&1; then
        log_info "Bucket gs://$name already exists"
    else
        log_step "Creating bucket gs://$name"
        # --soft-delete-duration=0 matters more than it looks. GCS now defaults
        # to retaining deleted and superseded objects for 7 days, and celld
        # rewrites bucket objects constantly, so the default quietly bills for
        # a week of every version of everything.
        #
        # No versioning, for the same reason. celld does its own consistency
        # with conditional writes; object versions would only add cost.
        gc storage buckets create "gs://$name" \
            --location="$CD_BUCKET_LOCATION" \
            --uniform-bucket-level-access \
            --soft-delete-duration=0
        log_info "Created gs://$name in $CD_BUCKET_LOCATION"
    fi

    local sa
    sa="$(cd_service_account_email)"
    if gc iam service-accounts describe "$sa" >/dev/null 2>&1; then
        log_info "Service account $sa already exists"
    else
        log_step "Creating service account $CD_SERVICE_ACCOUNT"
        gc iam service-accounts create "$CD_SERVICE_ACCOUNT" \
            --display-name="celld fleet node" \
            --description="Runs celld; has objectAdmin on the fleet bucket and nothing else"
        # IAM is eventually consistent, and the instances create below fails
        # outright if the account is not visible yet.
        wait_for "Service account is visible" 12 5 \
            gc iam service-accounts describe "$sa" \
            || die "Service account $sa did not become visible after a minute."
    fi

    # Scoped to this one bucket, per celld's security doc: bucket credentials
    # are fleet control, so they get the narrowest grant that works.
    #
    # Retried, because "visible to the IAM API" and "resolvable as a principal
    # by Cloud Storage" are two different clocks, and the second one lags by up
    # to a minute after the account is created. Storage reports the gap as
    # `HTTPError 400: Service account ... does not exist`, which reads like the
    # create failed when it actually succeeded -- so polling the describe above
    # is not enough on its own. Only the binding itself tells you it is ready.
    log_step "Granting $CD_SERVICE_ACCOUNT objectAdmin on gs://$name"
    wait_for "Granted" 24 5 \
        gc storage buckets add-iam-policy-binding "gs://$name" \
            --member="serviceAccount:$sa" \
            --role=roles/storage.objectAdmin \
        || die "Could not grant objectAdmin on gs://$name to $sa after two minutes.

If this still says the service account does not exist, check it is really there:
  gcloud --project $CD_PROJECT iam service-accounts describe $sa

Re-running './celld-demo create' is safe and picks up where this left off."
}

# Nothing is needed for ingress: cloudflared dials out, and celld's public
# listener binds loopback. The only rule in play is peer replication between
# nodes on the internal listener, and only once there is more than one node.
provider_ensure_firewall() {
    [ "$CD_NODE_COUNT" -gt 1 ] || return 0

    if gc compute firewall-rules describe default-allow-internal >/dev/null 2>&1; then
        log_info "default-allow-internal covers peer traffic"
        return 0
    fi

    if gc compute firewall-rules describe celld-internal >/dev/null 2>&1; then
        log_info "celld-internal firewall rule already exists"
        return 0
    fi

    log_step "Creating celld-internal firewall rule"
    # Source and target are both the celld-node tag, so this opens the internal
    # listener to other celld nodes and to nothing else in the VPC. The
    # operator API on that port is unauthenticated, which is exactly why this
    # is not a subnet-wide rule.
    gc compute firewall-rules create celld-internal \
        --network=default \
        --allow="tcp:$CD_INTERNAL_PORT" \
        --source-tags=celld-node \
        --target-tags=celld-node \
        --description="celld peer replication and operator API (celld-demo)"
    log_info "Created celld-internal"
}

# --- Nodes -----------------------------------------------------------------

provider_node_status() {
    gc_zone instances describe "$(node_name "$1")" --format='value(status)' 2>/dev/null || echo "NOT_FOUND"
}

provider_node_exists() {
    gc_zone instances describe "$(node_name "$1")" --format='value(name)' >/dev/null 2>&1
}

provider_internal_ip() {
    gc_zone instances describe "$(node_name "$1")" \
        --format='value(networkInterfaces[0].networkIP)' 2>/dev/null
}

# GCE internal DNS. This is what peers dial, and it is stable across stop and
# start in a way the IP is not guaranteed to be.
provider_advertise_addr() {
    echo "$(node_name "$1").${CD_ZONE}.c.${CD_PROJECT}.internal:${CD_INTERNAL_PORT}"
}

# Everything create pushes to a node, built once so creating a node and
# refreshing an existing one cannot drift apart. Sets $FROM_FILE and $META in
# the caller's scope, and needs a $tmp directory to write the env file into.
_node_metadata() {
    local env_file="$1/celld.env"
    storage_env > "$env_file"

    # The storage env and the tunnel credentials go up as metadata *files*
    # rather than --metadata values: values are comma-separated, so a secret
    # containing a comma would silently split into two keys, and JSON contains
    # plenty of them.
    FROM_FILE="startup-script=$CD_SCRIPT_DIR/bootstrap-vm.sh,celld-env=$env_file"
    local tunnel_meta=""
    if [ "$CD_TUNNEL_MODE" = "named" ]; then
        [ -n "$CD_TUNNEL_ID" ] || die "CD_TUNNEL_MODE=named needs CD_TUNNEL_ID. Re-run: ./celld-demo init"
        local cred="$HOME/.cloudflared/${CD_TUNNEL_ID}.json"
        [ -f "$cred" ] || die "Tunnel credentials not found at $cred

That file is written by \`cloudflared tunnel create\` and is the only copy.
If it is gone, delete the tunnel and make a new one:

  cloudflared tunnel delete ${CD_TUNNEL_NAME:-$CD_TUNNEL_ID} && ./celld-demo init"
        FROM_FILE="$FROM_FILE,celld-tunnel-cred=$cred"
        tunnel_meta=",celld-tunnel-id=${CD_TUNNEL_ID}"
    fi

    META="celld-version=${CD_CELLD_VERSION},celld-public-port=${CD_PUBLIC_PORT},celld-internal-port=${CD_INTERNAL_PORT},celld-tunnel-mode=${CD_TUNNEL_MODE},celld-tunnel-hostname=${CD_TUNNEL_HOSTNAME}${tunnel_meta}"
}

provider_ensure_node() {
    local n="$1" name
    name="$(node_name "$n")"

    _node_metadata "$CD_TMPDIR"

    # An existing node gets its metadata refreshed rather than skipped. The
    # startup script and every setting it reads live in metadata, so skipping
    # left a node pinned to whatever config it was born with: fixing a bad
    # setting meant either editing metadata by hand or deleting the instance,
    # and "re-run create" -- the obvious thing to try -- did nothing at all.
    #
    # This only updates what the next boot will read. It deliberately does not
    # restart anything, because that would make an idempotent create able to
    # interrupt a running fleet.
    if provider_node_exists "$n"; then
        log_info "Node $name already exists ($(provider_node_status "$n"))"
        gc compute instances add-metadata "$name" --zone="$CD_ZONE" \
            --metadata-from-file="$FROM_FILE" --metadata="$META" >/dev/null
        log_info "Refreshed its metadata"
        # Recorded so create knows this node did not just boot. GCE runs the
        # startup script at boot and only at boot, so a pre-existing node has
        # read none of the metadata just written.
        CD_EXISTING_NODES="${CD_EXISTING_NODES:-} $n"
        return 0
    fi

    log_step "Creating node $name"
    gc compute instances create "$name" \
        --zone="$CD_ZONE" \
        --machine-type="$CD_MACHINE_TYPE" \
        --image-family="$CD_IMAGE_FAMILY" \
        --image-project="$CD_IMAGE_PROJECT" \
        --boot-disk-size="$CD_DISK_SIZE" \
        --boot-disk-type="$CD_DISK_TYPE" \
        --boot-disk-device-name="$name" \
        --service-account="$(cd_service_account_email)" \
        --scopes=cloud-platform \
        --tags=celld-node \
        --labels=purpose=celld-demo,managed-by=celld-demo-scripts \
        --metadata-from-file="$FROM_FILE" \
        --metadata="$META"
    log_info "Created $name"
}

provider_start_node() {
    local n="$1" name status
    name="$(node_name "$n")"
    status="$(provider_node_status "$n")"
    case "$status" in
        RUNNING)   log_info "$name is already running" ;;
        NOT_FOUND) die "$name does not exist. Run: ./celld-demo create" ;;
        *)         log_step "Starting $name"
                   gc_zone instances start "$name" --quiet ;;
    esac
}

provider_stop_node() {
    local n="$1" name
    name="$(node_name "$1")"
    log_step "Stopping $name"
    gc_zone instances stop "$name" --quiet
}

provider_delete_node() {
    local n="$1" name
    name="$(node_name "$1")"
    log_step "Deleting $name"
    gc_zone instances delete "$name" --quiet --delete-disks=all
}

# Run a command on node N. gcloud's ssh wrapper manages the
# ~/.ssh/google_compute_engine keypair and pushes the public key into project
# metadata, so there is no manual key handling.
provider_ssh() {
    local n="$1"
    shift
    gc_ssh "$(node_name "$n")" --command "$*"
}

provider_ssh_interactive() {
    local n="$1"
    shift
    gc_ssh "$(node_name "$n")" "$@"
}

# One table of every node in the fleet, whatever state it is in.
provider_list_nodes() {
    gc compute instances list \
        --filter="name~^${CD_INSTANCE_PREFIX}-" \
        --format='table(name,status,machineType.basename(),networkInterfaces[0].networkIP:label=INTERNAL_IP,zone.basename())'
}

# `du -s` alone prints a bare byte count against the bucket URL, which reads as
# an unlabelled number that jumps by four orders of magnitude the first time
# anything is deployed. --readable-sizes carries its own unit.
provider_bucket_usage() {
    gc storage du -s --readable-sizes "$CD_BUCKET" 2>/dev/null \
        || echo "  (could not read $CD_BUCKET)"
}

# Which node owns each cell, as "<node name> <Class> <count>" lines. A node's
# /state only counts the cells it owns, so this is the one place their classes
# come from. It costs a read per cell, so past CD_OWNER_SCAN_MAX cells it prints
# nothing and status falls back to counts alone.
provider_cell_owners() {
    local token
    token="$(gc auth print-access-token 2>/dev/null)" || return 0
    python3 - "${CD_BUCKET#gs://}" "$token" "${CD_OWNER_SCAN_MAX:-500}" <<'PY'
import json, subprocess, sys, urllib.parse
from concurrent.futures import ThreadPoolExecutor
bucket, token, cap = sys.argv[1], sys.argv[2], int(sys.argv[3])
api = "https://storage.googleapis.com/storage/v1/b/%s/o" % bucket
# curl rather than urllib: python.org builds on macOS ship without a CA bundle,
# and curl uses the system one.
def get(url):
    return subprocess.run(["curl", "-sSf", "-m", "10", "-H", "Authorization: Bearer " + token, url],
                          check=True, capture_output=True).stdout
def names(prefix, glob):
    out, page = [], None
    while True:
        q = {"prefix": prefix, "matchGlob": glob, "fields": "items/name,nextPageToken"}
        if page: q["pageToken"] = page
        r = json.loads(get(api + "?" + urllib.parse.urlencode(q)))
        out += [i["name"] for i in r.get("items", [])]
        page = r.get("nextPageToken")
        if not page or len(out) > cap: return out
def body(name):
    return json.loads(get("%s/%s?alt=media" % (api, urllib.parse.quote(name, safe=""))))
try:
    owns = names("cells/", "cells/*/own.json")
    if len(owns) > cap: raise SystemExit
    with ThreadPoolExecutor(16) as pool:
        # A lease names its node by internal DNS address, whose first label is
        # the instance name. Stale leases from a previous process are harmless:
        # nothing owns a cell under their ids any more.
        host = {}
        for lease in pool.map(body, names("nodes/", "nodes/*.json")):
            host[lease["node"]] = lease.get("addr", "").split(".", 1)[0]
        counts = {}
        for name, rec in zip(owns, pool.map(body, owns)):
            if rec.get("node"):  # null: released, owned by nobody
                key = (host.get(rec["node"], rec["node"]), name.split("/")[1].split(":", 1)[0])
                counts[key] = counts.get(key, 0) + 1
    for (node, cls), n in sorted(counts.items()):
        print(node, cls, n)
except Exception:
    pass
    pass
PY
}

# Everything that is not per-node. Called by destroy after the VMs are gone.
provider_teardown() {
    local sa
    sa="$(cd_service_account_email)"
    if gc iam service-accounts describe "$sa" >/dev/null 2>&1; then
        log_step "Deleting service account $sa"
        gc iam service-accounts delete "$sa" --quiet
    fi
    if gc compute firewall-rules describe celld-internal >/dev/null 2>&1; then
        log_step "Deleting celld-internal firewall rule"
        gc compute firewall-rules delete celld-internal --quiet
    fi
}

provider_delete_bucket() {
    log_step "Deleting $CD_BUCKET and everything in it"
    gc storage rm -r "$CD_BUCKET"
}
