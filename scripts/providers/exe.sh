#!/usr/bin/env bash
# exe.dev provider: NOT IMPLEMENTED. This file exists to keep the seam honest.
#
# celld.dev's own suggested prompt reaches for exe.dev ("create a distributed
# chat app with vite, use celld.dev and exe.dev, 2 VMs"), and for a demo it is
# the shorter road: `ssh exe.dev` gets you a root Linux box with systemd, and
# HTTPS plus a domain come with the VPS tier, so cloudflared, the GCP project,
# the service account and the firewall reasoning all disappear.
#
# We are on GCP instead for three reasons, recorded here so the choice can be
# revisited rather than rediscovered:
#
#   1. The point of this repo is what celld costs and how it behaves on the
#      infrastructure we already run. exe.dev would test celld, not that.
#   2. Sandboxes bill per second, so the `stop` verb -- the whole cost story
#      here -- has no equivalent. You delete and recreate instead.
#   3. exe.dev has no VPC. celld's internal listener carries peer replication
#      and an *unauthenticated* operator API (/state, /evict), and the security
#      doc is explicit that it belongs on a trusted private network or an
#      encrypted overlay. On GCP that is an internal IP and one firewall rule.
#      On exe.dev it means standing up Tailscale or WireGuard first.
#
# Implementing this means filling in the contract below. The pieces that differ
# from providers/gcp.sh:
#
#   - Node lifecycle over `ssh exe.dev` instead of `gcloud compute instances`.
#     hive (https://hive.butttons.dev/) automates this as `hive exe new` /
#     `hive exe share` / `hive exe domain` and is worth reading first.
#   - Ingress from exe.dev's built-in HTTPS proxy instead of cloudflared, which
#     means scripts/bootstrap-vm.sh grows a branch, or exe.dev grows its own.
#   - An overlay network for provider_internal_ip / provider_advertise_addr,
#     per (3) above. This is the real work.
#   - Storage stays whatever CD_STORAGE_BACKEND says: provider and backend are
#     independent axes, so exe.dev + GCS or exe.dev + Silo both make sense.

_exe_todo() {
    die "CD_PROVIDER=exe is not implemented.

scripts/providers/exe.sh documents what it would take and why we did not.
Use CD_PROVIDER=gcp, or implement the provider_* contract in that file."
}

provider_preflight()        { _exe_todo; }
provider_ensure_bucket()    { _exe_todo; }
provider_ensure_firewall()  { _exe_todo; }
provider_ensure_node()      { _exe_todo; }
provider_node_status()      { _exe_todo; }
provider_node_exists()      { _exe_todo; }
provider_internal_ip()      { _exe_todo; }
provider_advertise_addr()   { _exe_todo; }
provider_start_node()       { _exe_todo; }
provider_stop_node()        { _exe_todo; }
provider_delete_node()      { _exe_todo; }
provider_ssh()              { _exe_todo; }
provider_ssh_interactive()  { _exe_todo; }
provider_list_nodes()       { _exe_todo; }
provider_bucket_usage()     { _exe_todo; }
provider_teardown()         { _exe_todo; }
provider_delete_bucket()    { _exe_todo; }
