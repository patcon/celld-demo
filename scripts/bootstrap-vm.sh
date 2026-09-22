#!/usr/bin/env bash
# Runs as root on each node, as the GCE startup-script. Installs celld and
# cloudflared and puts both under systemd.
#
# Everything configurable is read from instance metadata rather than templated
# in, so the file committed here is byte-identical to the one you see in the
# GCP console, and `gcloud compute instances describe` never shows a stale copy
# of a script someone edited locally.
#
# GCE re-runs the startup script on every boot. The done-marker makes the
# second run a no-op: the services are systemd-enabled, so a `start` brings
# them back without reinstalling anything.

set -euo pipefail
exec > >(tee -a /var/log/celld-bootstrap.log) 2>&1

DONE_MARKER=/var/lib/celld-bootstrap-done
CELLD_HOME=/opt/celld
CELLD_STATE=/var/lib/celld

echo "=== celld bootstrap $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="

if [ -f "$DONE_MARKER" ]; then
    echo "Already bootstrapped. Services are enabled; nothing to do."
    exit 0
fi

meta() {
    curl -fsS -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" 2>/dev/null || true
}
meta_core() {
    curl -fsS -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/$1" 2>/dev/null || true
}

CELLD_VERSION="$(meta celld-version)"
PUBLIC_PORT="$(meta celld-public-port)"
INTERNAL_PORT="$(meta celld-internal-port)"
TUNNEL_MODE="$(meta celld-tunnel-mode)"
TUNNEL_HOSTNAME="$(meta celld-tunnel-hostname)"
TUNNEL_ID="$(meta celld-tunnel-id)"

: "${PUBLIC_PORT:=8080}"
: "${INTERNAL_PORT:=8081}"
: "${TUNNEL_MODE:=quick}"

NODE_NAME="$(meta_core instance/name)"
PROJECT_ID="$(meta_core project/project-id)"
INTERNAL_IP="$(meta_core instance/network-interfaces/0/ip)"
# instance/zone comes back as projects/<number>/zones/<zone>.
ZONE="$(meta_core instance/zone | sed 's|.*/||')"

# What peers dial to reach this node's internal listener. GCE's internal DNS
# name rather than the IP: the name survives a stop/start, and celld writes
# this address into the bucket for other nodes to read later.
ADVERTISE="${NODE_NAME}.${ZONE}.c.${PROJECT_ID}.internal:${INTERNAL_PORT}"

echo "node=$NODE_NAME internal=$INTERNAL_IP advertise=$ADVERTISE tunnel=$TUNNEL_MODE"

# --- celld -----------------------------------------------------------------

echo "--- installing celld"
export CELLD_INSTALL_ROOT="$CELLD_HOME"
if [ -n "$CELLD_VERSION" ]; then
    # The installer takes a tag, not a version number, and dies on the
    # difference. Normalised here as well as in init, because this value can
    # also arrive by hand-editing local.env or the instance metadata, and a
    # failure at this point costs a full instance rebuild to retry.
    case "$CELLD_VERSION" in
        [0-9]*) CELLD_VERSION="v$CELLD_VERSION" ;;
    esac
    export CELLD_VERSION
fi
curl -fsSL https://celld.dev/install.sh | sh
"$CELLD_HOME/bin/celld" --version || true

id celld >/dev/null 2>&1 || useradd --system --home-dir "$CELLD_STATE" --shell /usr/sbin/nologin celld
install -d -o celld -g celld -m 0750 "$CELLD_STATE"

# celld-env carries CELLD_BUCKET and, for an S3 backend, the endpoint and keys.
# For GCS it deliberately carries no credentials: celld picks up Application
# Default Credentials, which on a VM is the attached service account read from
# this same metadata server. Nothing secret touches the disk.
meta celld-env > /etc/celld.env
echo "CELLD_WATCH=$CELLD_STATE" >> /etc/celld.env
chmod 0640 /etc/celld.env
chgrp celld /etc/celld.env
sed 's/^\(AWS_SECRET_ACCESS_KEY=\).*/\1***/' /etc/celld.env

cat > /etc/systemd/system/celld.service <<EOF
[Unit]
Description=celld node
Documentation=https://celld.dev/docs
After=network-online.target
Wants=network-online.target

[Service]
User=celld
Group=celld
EnvironmentFile=/etc/celld.env
# The public listener binds loopback: cloudflared is on this host and dials it
# from here, so there is nothing to reach from outside and no firewall hole to
# open. The internal listener binds the VPC address, because peers do need it.
ExecStart=$CELLD_HOME/bin/celld \\
    --listen 127.0.0.1:${PUBLIC_PORT} \\
    --internal-listen ${INTERNAL_IP}:${INTERNAL_PORT} \\
    --advertise ${ADVERTISE}
Restart=always
RestartSec=2
# celld's shutdown handoff (drain, release cells to peers, publish ownership)
# is bounded by CELLD_SHUTDOWN_TOTAL_MS, default 40s. The docs require the
# supervisor's stop grace to exceed it, or systemd SIGKILLs the handoff
# half-finished and the next node has to recover those cells the slow way.
TimeoutStopSec=90
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# --- cloudflared -----------------------------------------------------------

echo "--- installing cloudflared"
# The .deb straight from the release, rather than Cloudflare's apt repo: one
# fewer key to rotate and one fewer thing to break a rebuild months from now.
curl -fsSL -o /tmp/cloudflared.deb \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i /tmp/cloudflared.deb
rm -f /tmp/cloudflared.deb

if [ "$TUNNEL_MODE" = "named" ]; then
    install -d -m 0700 /etc/cloudflared
    meta celld-tunnel-cred > /etc/cloudflared/cred.json
    chmod 0600 /etc/cloudflared/cred.json

    # A locally-managed config, not a dashboard-managed one. `tunnel run
    # --token` would fetch its ingress rules from Cloudflare, which means the
    # hostname mapping lives in a web UI instead of in this repo.
    cat > /etc/cloudflared/config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/cred.json
ingress:
  - hostname: ${TUNNEL_HOSTNAME}
    service: http://127.0.0.1:${PUBLIC_PORT}
  - service: http_status:404
EOF
    CLOUDFLARED_EXEC="/usr/bin/cloudflared --no-autoupdate --config /etc/cloudflared/config.yml tunnel run"
else
    # A quick tunnel: a random trycloudflare.com hostname, no Cloudflare
    # account and no domain. The URL is printed to the log and changes every
    # time this process restarts, which includes every VM start.
    CLOUDFLARED_EXEC="/usr/bin/cloudflared --no-autoupdate tunnel --url http://127.0.0.1:${PUBLIC_PORT}"
fi

cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=cloudflared tunnel to the celld public listener
After=network-online.target celld.service
Wants=network-online.target

[Service]
ExecStart=${CLOUDFLARED_EXEC}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now celld.service
systemctl enable --now cloudflared.service

touch "$DONE_MARKER"
echo "=== celld bootstrap done ==="
