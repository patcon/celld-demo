# celld-demo

A test deployment of [celld](https://celld.dev) — Deno's self-hosted, distributed
implementation of Cloudflare Durable Objects — on our own GCP infrastructure,
with a small app deployed to it.

The question this repo exists to answer: **what does celld cost and how does it
behave on the infrastructure we already run?** Not whether celld works. That is
why it is on GCP rather than on [exe.dev](https://exe.dev), which celld's own
docs suggest and which would be considerably less work — see
`scripts/providers/exe.sh` for that argument in full.

```
./celld-demo init      # once: project, zone, bucket, ingress
./celld-demo create    # bucket + service account + VMs
./celld-demo deploy    # build app/ and roll it out
./celld-demo stop      # when you finish for the day
```

## How it fits together

```
   your laptop                          Cloudflare
   ┌──────────────────┐                 ┌─────────────┐
   │ ./celld-demo     │                 │  edge (TLS) │
   │   celld deploy ──┼──┐              └──────┬──────┘
   └──────────────────┘  │                     │ tunnel (outbound only)
                         │                     │
                         │   GCP  ┌────────────▼──────────────┐
                         │        │ VM: celld-<you>-1          │
                         │        │   cloudflared              │
                         │        │   celld  :8080 (loopback)  │
                         │        │          :8081 (VPC only)  │
                         │        └────────────┬───────────────┘
                         │                     │
                         └────────► gs://celld-demo-<project>
                                   every cell's SQLite database,
                                   the deployment pointer, node leases
```

Three things worth noticing:

- **The VMs have no open ingress port.** celld's public listener binds
  `127.0.0.1`, and `cloudflared` dials out to Cloudflare. There is no
  load balancer, no public IP to whitelist, and no TLS certificate to renew.
- **`deploy` never touches a VM.** `celld deploy` writes the bundle into the
  bucket from your laptop; nodes poll for it. Deploying to a stopped fleet
  works fine — the app is there when it starts.
- **Nothing durable is on the disks.** Which is what makes `stop` safe, and
  what makes the boot disks small.

## Verbs

| Verb | What it does |
|---|---|
| `init` | Interactive setup → `scripts/local.env` (gitignored) |
| `create` | Bucket, service account, firewall, VMs. Idempotent; also how you add a node |
| `deploy` | Bundle `app/` and roll it out; pokes `/reload` so it lands immediately |
| `status` | Nodes, services, health, cells, memory, public URL, bucket size |
| `up` / `down` | Start/stop the services, leaving the VMs running |
| `start` / `stop` | VM power. **`stop` is the cost lever** |
| `logs` / `ssh` | `journalctl -fu celld` / a shell on a node |
| `destroy` | Delete the VMs; `--bucket` to offer the bucket too |

`./celld-demo <verb> --help` prints that verb's reasoning.

## Cost

Per node, `e2-small`, us-central1, rounded:

| State | Monthly |
|---|---|
| Running 24/7 | ~$13 compute + ~$2 disk |
| Stopped | ~$2 disk only |
| Destroyed | $0 |

The bucket is pennies at demo volume. celld quotes ~$0.02 per resident
cell-month at scale, which is the number the whole exercise is really about.

`stop` is the difference between the first row and the second, and it is
lossless: all durable state is in the bucket.

## Security posture

- The fleet bucket is the crown jewel. Whoever can read it controls the fleet,
  so it gets a dedicated service account with `objectAdmin` on that one bucket
  and nothing else. The VMs authenticate with it via ADC — no key files.
- The internal listener (`:8081`) carries peer replication **and an
  unauthenticated operator API** (`/state`, `/evict`). It binds the VPC address
  and is firewalled to the `celld-node` tag only. Do not put it on a public
  network.
- Named-tunnel credentials go to the VMs through instance metadata, readable by
  anyone with project viewer. Fine for a sandbox. Move it to Secret Manager if
  this outlives the test.
- TLS is Cloudflare's. celld terminates none.

## Configuration

Three layers, highest first:

1. An env var — `CD_NODE_COUNT=2 ./celld-demo create`
2. `scripts/local.env` — yours, gitignored, written by `init`
3. `scripts/config.sh` — committed defaults, with the reasoning next to each one

Two independent axes:

- **`CD_PROVIDER`** — where the VMs come from. `gcp` is real; `exe` is a
  documented stub.
- **`CD_STORAGE_BACKEND`** — where durable state lives. `gcs` is real; `silo`
  is wired through `storage_env()` but not yet stood up.

## Local development

No cloud needed:

```sh
curl -fsSL celld.dev/install.sh | sh   # → ~/.local/bin/celld
cd app
pnpm install        # esbuild, which celld shells out to
celld dev           # http://127.0.0.1:9876, state in app/.celld/dev
```

Worth doing before `create`: it tells you whether a failure is the app or the
infrastructure.

**On an Intel Mac the installer will refuse.** celld publishes three targets —
`x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`, `aarch64-apple-darwin` —
so a Darwin x86_64 machine gets `no prebuilt release exists for Darwin x86_64
yet` and no flag changes it. The binary has to be built; [this
run](https://github.com/patcon/celld/actions/runs/34000069189) is one such
build. `install -m 755 <the binary> ~/.local/bin/celld` and everything here
works normally. `./celld-demo deploy` says as much if celld is missing.

Note this only affects the CLI on your laptop. The VMs are Linux x86_64, where
the official installer is what `scripts/bootstrap-vm.sh` uses.

## Troubleshooting

**`celld did not become healthy`.** Health is 503 until a node joins the fleet
and settles, so a slow first boot looks like this. `./celld-demo logs 1`, and
`./celld-demo logs 1 --boot` for the one-time install log.

**`No Application Default Credentials`.** Your gcloud login and ADC are
separate. `gcloud auth application-default login`.

**The public URL changed.** Expected on a quick tunnel: the hostname is
assigned when `cloudflared` starts, so every `start` gets a new one. Use a
named tunnel (`./celld-demo init`) for a stable hostname.

**It's running as the wrong Google account.** `CD_GCLOUD_ACCOUNT` in
`local.env` pins the identity, and every gcloud call names it explicitly, so
your active account can move without dragging this fleet with it. `init` asks
which account when it sees more than one signed in. ADC is a *second*
credential chosen by the browser, not the CLI — `init` checks it matches and
warns if not, because a mismatch only surfaces as a 403 from `deploy`.

**`Reauthentication failed` on every command.** An expired token makes every
project and instance look missing. `gcloud auth login <your-account>` — naming
the account matters.

## Next

- **Silo.** Swap GCS for [Silo](https://silo.pgsty.com/), Pigsty's maintained
  MinIO fork, via `CD_STORAGE_BACKEND=silo`. The seam (`storage_env()`,
  `celld_bucket_args()`) is already there. One thing to settle first: celld's
  docs say MinIO community edition passes their test suite but is not
  production-qualified, while [hive](https://hive.butttons.dev/) claims it
  fails outright. The requirement in dispute is conditional writes; point
  `celld diagnose` at a Silo bucket and find out.
- **Two nodes.** `CD_NODE_COUNT=2 ./celld-demo create` is the whole change.
  That is where peer replication, cell handoff and ~20s failover become
  observable — and where single-node bucket-latency writes stop being the
  bottleneck.
- **exe.dev.** If the goal ever becomes "a working demo by Friday" rather than
  "what does this cost us", `scripts/providers/exe.sh` says what to fill in.
