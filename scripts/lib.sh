#!/usr/bin/env bash
# Common helpers. Every verb script sources this file, which in turn sources
# config.sh, the optional local.env override, and the active provider.

set -euo pipefail

CD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CD_ROOT="$(cd "$CD_SCRIPT_DIR/.." && pwd)"

# Precedence: explicit env var, then local.env, then the config.sh default.
#
# config.sh gives way to both because it assigns with `: "${VAR:=default}"`,
# but local.env is a generated file of plain assignments, so sourcing it would
# overwrite an env var the caller passed. `CD_NODE_COUNT=2 ./celld-demo create`
# would then silently build the one node local.env remembers. Snapshot the
# exported CD_* vars, source, and put them back.
if [ -f "$CD_SCRIPT_DIR/local.env" ]; then
    CD_ENV_OVERRIDES="$(export -p | grep -E '^(export |declare -x )CD_[A-Za-z0-9_]*=' || true)"
    # shellcheck disable=SC1091
    source "$CD_SCRIPT_DIR/local.env"
    if [ -n "$CD_ENV_OVERRIDES" ]; then
        eval "$CD_ENV_OVERRIDES"
    fi
    unset CD_ENV_OVERRIDES
fi
# shellcheck disable=SC1091
source "$CD_SCRIPT_DIR/config.sh"

log_info()  { echo -e "\033[0;32m[celld]\033[0m $1"; }
log_warn()  { echo -e "\033[1;33m[celld]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[celld]\033[0m $1" >&2; }
log_step()  { echo -e "\n\033[1;36m==>\033[0m \033[1m$1\033[0m"; }

die() { log_error "$1"; exit 1; }

# --- Fleet -----------------------------------------------------------------

# Node N's instance name. Nodes are 1-indexed: celld-patcon-1.
node_name() { echo "${CD_INSTANCE_PREFIX}-$1"; }

node_numbers() { seq 1 "$CD_NODE_COUNT"; }

# Run a command once per node, passing the node number as the last argument:
#   for_each_node provider_start_node
for_each_node() {
    local n
    for n in $(node_numbers); do
        "$@" "$n"
    done
}

# --- Storage ---------------------------------------------------------------

# The single seam that swaps GCS for Silo. Emits KEY=VALUE lines, consumed both
# by the node's systemd EnvironmentFile and, via export, by the local celld CLI.
#
# GCS needs no credentials here on purpose: celld picks up Application Default
# Credentials, which is the attached service account on a node and
# `gcloud auth application-default login` on your laptop. Nothing lands on disk.
storage_env() {
    [ -n "${CD_BUCKET:-}" ] || die "CD_BUCKET is not set. Run: ./celld-demo init"
    echo "CELLD_BUCKET=$CD_BUCKET"
    case "$CD_STORAGE_BACKEND" in
        gcs)
            case "$CD_BUCKET" in
                gs://*) ;;
                *) die "CD_STORAGE_BACKEND=gcs wants a gs:// bucket, got '$CD_BUCKET'" ;;
            esac
            ;;
        silo)
            case "$CD_BUCKET" in
                s3://*) ;;
                *) die "CD_STORAGE_BACKEND=silo wants an s3:// bucket, got '$CD_BUCKET'" ;;
            esac
            [ -n "$CD_S3_ENDPOINT" ] || die "CD_STORAGE_BACKEND=silo needs CD_S3_ENDPOINT"
            echo "S3_ENDPOINT=$CD_S3_ENDPOINT"
            echo "AWS_REGION=${CD_S3_REGION:-auto}"
            echo "AWS_ACCESS_KEY_ID=$CD_S3_ACCESS_KEY_ID"
            echo "AWS_SECRET_ACCESS_KEY=$CD_S3_SECRET_ACCESS_KEY"
            ;;
        *)
            die "Unknown CD_STORAGE_BACKEND: '$CD_STORAGE_BACKEND' (want gcs or silo)"
            ;;
    esac
}

# Export storage_env into the current shell, for the local celld CLI.
export_storage_env() {
    local line
    while IFS= read -r line; do
        export "${line?}"
    done < <(storage_env)
}

# The bucket flags every celld subcommand takes (deploy, cell, kv, diagnose).
# Word-split at the call site on purpose; none of these values contain spaces.
celld_bucket_args() {
    printf -- '--bucket %s' "$CD_BUCKET"
    if [ "$CD_STORAGE_BACKEND" = "silo" ]; then
        printf -- ' --endpoint %s --region %s' "$CD_S3_ENDPOINT" "${CD_S3_REGION:-auto}"
    fi
}

# --- Guards ----------------------------------------------------------------

# CD_PROJECT, CD_ZONE and CD_BUCKET are per-person and have no committed
# default, so a missing value means init has not run rather than a typo.
require_config() {
    if [ -z "${CD_PROJECT:-}" ] || [ -z "${CD_ZONE:-}" ] || [ -z "${CD_BUCKET:-}" ]; then
        die "Not configured yet. Run: ./celld-demo init
It asks which GCP project, zone and bucket to use, and writes them to
scripts/local.env (gitignored)."
    fi
}

# Check a local CLI is on PATH, dying with the exact install command.
require_tool() {
    local tool="$1" install="$2"
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH.

Install it:
  $install"
}

# The celld CLI, which `deploy` runs locally. Worth its own function rather
# than a require_tool call, because the official installer refuses to run on
# half the laptops here: celld publishes x86_64-unknown-linux-gnu,
# aarch64-unknown-linux-gnu and aarch64-apple-darwin, and nothing else. An
# Intel Mac gets "no prebuilt release exists for Darwin x86_64 yet" and there
# is no flag that changes that — the binary has to be built.
#
# https://github.com/patcon/celld/actions/runs/34000069189 is one such build.
# Drop it at ~/.local/bin/celld and this passes.
require_celld() {
    command -v celld >/dev/null 2>&1 && return 0

    local hint="curl -fsSL celld.dev/install.sh | sh"
    if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "x86_64" ]; then
        hint="The installer has no build for your platform (Darwin x86_64).
  Download a celld-x86_64-apple-darwin build, then:
    install -m 755 ~/Downloads/celld ~/.local/bin/celld"
    fi
    die "celld not found on PATH.

Install it:
  $hint"
}

# --- Polling ---------------------------------------------------------------

# Retry a command until it succeeds, printing a dot per attempt. Every caller
# pairs this with a `|| die` that names the command to debug with, because a
# silent timeout here is the most confusing failure in the whole tool.
#
#   wait_for "SSH is up" 30 10 provider_ssh 1 true || die "..."
wait_for() {
    local desc="$1" attempts="$2" delay="$3"
    shift 3
    local i
    for i in $(seq 1 "$attempts"); do
        if "$@" >/dev/null 2>&1; then
            [ "$i" -gt 1 ] && echo
            log_info "$desc"
            return 0
        fi
        printf '.'
        sleep "$delay"
    done
    echo
    return 1
}

# --- local.env -------------------------------------------------------------

# Write a single setting into local.env, updating the line if it is already
# there and appending it if not. Scripts that change a setting on the cloud
# side call this so the next run agrees with reality rather than drifting.
persist_local_env() {
    local key="$1" value="$2" file="$CD_SCRIPT_DIR/local.env"
    [ -f "$file" ] || return 0
    if grep -q "^$key=" "$file"; then
        # -i.bak then remove: BSD sed requires the suffix, GNU sed accepts it.
        sed -i.bak "s|^$key=.*|$key=\"$value\"|" "$file"
        rm -f "$file.bak"
    else
        echo "$key=\"$value\"" >> "$file"
    fi
    log_info "Set $key=\"$value\" in local.env"
}

# --- Ingress ---------------------------------------------------------------

# The URL the app is reachable at. A named tunnel is a fixed hostname we
# already know; a quick tunnel picks a random one at process start, so the only
# place it exists is cloudflared's own log on the node.
tunnel_url() {
    local n="${1:-1}"
    if [ "$CD_TUNNEL_MODE" = "named" ]; then
        [ -n "$CD_TUNNEL_HOSTNAME" ] && echo "https://$CD_TUNNEL_HOSTNAME"
        return 0
    fi
    provider_ssh "$n" \
        "sudo journalctl -u cloudflared --no-pager 2>/dev/null | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1" \
        2>/dev/null || true
}

# --- Provider --------------------------------------------------------------

# Credentials the *local* celld CLI needs to reach the bucket. Providers
# override this; the default is "nothing extra", which is correct for any
# backend whose credentials already live in local.env.
provider_require_deploy_creds() { :; }

# Everything cloud-shaped lives behind this. The rule that keeps the seam
# honest: no script outside providers/ may call gcloud directly.
[ -f "$CD_SCRIPT_DIR/providers/$CD_PROVIDER.sh" ] \
    || die "Unknown CD_PROVIDER '$CD_PROVIDER'. Available: $(cd "$CD_SCRIPT_DIR/providers" && ls *.sh | sed 's/\.sh$//' | tr '\n' ' ')"
# shellcheck disable=SC1090
source "$CD_SCRIPT_DIR/providers/$CD_PROVIDER.sh"

# --- Help ------------------------------------------------------------------

# Print a script's own header comment block as its help text, so the
# explanation lives next to the code rather than in a duplicate usage string.
header_help() {
    sed -n '2,/^[^#]/p' "$1" | sed '$d' | sed 's/^#\{1,\} \{0,1\}//'
}

# Every verb calls this first, so `./celld-demo <verb> --help` works uniformly.
handle_help() {
    case "${1:-}" in
        -h|--help) header_help "$2"; exit 0 ;;
    esac
}
