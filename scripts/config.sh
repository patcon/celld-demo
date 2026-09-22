#!/usr/bin/env bash
# Shared configuration for the celld demo fleet.
#
# This file holds committed defaults only. Anything specific to one person (GCP
# project, bucket, preferred zone) has no default here and is written to
# local.env by `./celld-demo init` on first run. local.env is gitignored.
#
# Precedence, highest first:
#   1. An env var:        CD_NODE_COUNT=2 ./celld-demo create
#   2. local.env          (written by init, gitignored, per-person)
#   3. The defaults below (committed)
#
# Nothing here is secret. The one secret in play is the Cloudflare tunnel
# token, which init writes to local.env and create ships to the VMs.

# --- Per-person. No defaults on purpose. Set by `./celld-demo init`. ------

# The GCP project that owns the fleet. This is a throwaway sandbox, so there
# is deliberately no default: a wrong guess bills someone else's project.
: "${CD_PROJECT:=}"

# The Google account every gcloud call runs as. Empty means "whichever account
# is active", which is the right default for someone with one account and a
# trap for someone with two: the active account is global gcloud state that
# another project, another tool, or a stray `gcloud config set account` can
# change between two runs of this CLI. init pins it here when it finds more
# than one signed in, and from then on this tool names the account explicitly
# on every call instead of inheriting it.
: "${CD_GCLOUD_ACCOUNT:=}"

# Zone for the VMs. Everything is single-zone: this is a test fleet, and
# celld's internal listener wants a low-latency private network between nodes.
: "${CD_ZONE:=}"

# Fleet bucket, as a celld URL (gs://NAME or s3://NAME). All durable state
# lives here. Whoever can read it controls the fleet.
: "${CD_BUCKET:=}"
: "${CD_BUCKET_LOCATION:=}"

# --- Provider ------------------------------------------------------------

# Which providers/<name>.sh implements the VM lifecycle.
#   gcp  the real one
#   exe  a stub for exe.dev; see providers/exe.sh for what it would take
: "${CD_PROVIDER:=gcp}"

# --- Storage backend -----------------------------------------------------

# Which bucket celld talks to, and how it authenticates.
#   gcs   Google Cloud Storage, Application Default Credentials. On a node
#         that is the attached service account; locally it is
#         `gcloud auth application-default login`. No keys on disk either way.
#   silo  Pigsty's maintained MinIO fork, or any other S3-compatible endpoint.
#         Not wired up yet: see the "Next" section of the README.
: "${CD_STORAGE_BACKEND:=gcs}"

# Only read when CD_STORAGE_BACKEND=silo.
: "${CD_S3_ENDPOINT:=}"
: "${CD_S3_REGION:=auto}"
: "${CD_S3_ACCESS_KEY_ID:=}"
: "${CD_S3_SECRET_ACCESS_KEY:=}"

# --- Fleet ---------------------------------------------------------------

# Nodes are 1-indexed and named <prefix>-1, <prefix>-2, ...
#
# One node is the cheap default and is enough to deploy an app and watch state
# survive a stop/start. It is not enough to see what celld is actually for: a
# single node has no peer to replicate to, so every durable write waits on the
# bucket, and there is nothing to hand cells off to at shutdown. Two nodes gets
# you fleet durability and ~20s failover:
#
#   CD_NODE_COUNT=2 ./celld-demo create
#
# Every script loops over the count, so scaling up is that one command. Scaling
# *down* is not automatic: lower the count and `destroy` leaves the extra VMs
# behind, because deleting a node nobody asked about is how you lose data.
: "${CD_NODE_COUNT:=1}"

# GCE names allow lowercase letters, digits and hyphens only and must start
# with a letter, so the username is slugged. `tr -c` also rewrites the trailing
# newline, hence the trim.
CD_USER_SLUG="$(whoami | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')"
: "${CD_INSTANCE_PREFIX:=celld-${CD_USER_SLUG}}"

# celld reports 0.47 MB of RAM per resident cell, so the demo is nowhere near
# memory-bound. e2-small (2 vCPU burst / 2GB) is about $13/month running and
# close to $0 stopped. Upsize by editing local.env and re-running create on a
# fresh fleet; there is no resize verb, because this is a sandbox.
: "${CD_MACHINE_TYPE:=e2-small}"

# You pay for the disk even while the VM is stopped, so an oversized boot disk
# is the bill that never goes away. celld's own state lives in the bucket; the
# local disk only holds the binary, the OS, and SQLite working files.
: "${CD_DISK_SIZE:=20GB}"
: "${CD_DISK_TYPE:=pd-balanced}"

: "${CD_IMAGE_FAMILY:=ubuntu-2404-lts-amd64}"
: "${CD_IMAGE_PROJECT:=ubuntu-os-cloud}"

# Service account attached to the nodes. Created by `create`, and granted
# objectAdmin on the fleet bucket and nothing else: celld's security doc asks
# for credentials restricted to one bucket, because holding them is equivalent
# to controlling the fleet.
: "${CD_SERVICE_ACCOUNT:=celld-node}"

# Empty means the latest release. Pin a tag (v0.4.0) to make create repeatable,
# which matters because celld has had two upgrades that required stopping the
# whole fleet rather than rolling: 0.1->0.2 and 0.3->0.4.
: "${CD_CELLD_VERSION:=}"

# --- Listeners -----------------------------------------------------------

# The public listener binds loopback only. cloudflared reaches it from the same
# host, so the VM needs no ingress firewall rule at all.
: "${CD_PUBLIC_PORT:=8080}"

# The internal listener carries peer replication and the operator API, and the
# operator API is unauthenticated (/state, /evict). It binds the VM's internal
# IP and is reachable only from inside the VPC.
: "${CD_INTERNAL_PORT:=8081}"

# --- Ingress (Cloudflare) ------------------------------------------------

# How cloudflared exposes the public listener.
#   quick  a random https://<words>.trycloudflare.com URL, no domain and no
#          Cloudflare login needed. The URL changes every time cloudflared
#          restarts, so it changes on every `start`.
#   named  a stable hostname on a domain in your Cloudflare account. Every node
#          runs the same tunnel credentials, so Cloudflare load-balances across
#          the connectors for free, which is the multi-node ingress story. It
#          also means the URL survives a stop/start, which `quick` does not.
: "${CD_TUNNEL_MODE:=quick}"

# Set by `init` when CD_TUNNEL_MODE=named. CD_TUNNEL_ID is the tunnel UUID that
# `cloudflared tunnel create` returns; its credentials JSON stays in
# ~/.cloudflared/<id>.json on this machine and is shipped to the nodes by
# `create`. Deleting that file means recreating the tunnel.
: "${CD_TUNNEL_NAME:=}"
: "${CD_TUNNEL_HOSTNAME:=}"
: "${CD_TUNNEL_ID:=}"
