# llamacpp-serve

A self-hosted, TLS-only [llama.cpp](https://github.com/ggml-org/llama.cpp) serving
stack for a single GPU host (NVIDIA DGX Spark / GB10). It runs two `llama-server`
instances in **router mode** behind a [LiteLLM](https://github.com/BerriAI/litellm)
gateway that handles auth, rate limits, concurrency caps and observability, all
fronted by nginx for TLS, plus Open WebUI for a browser interface. Every path
into the stack is HTTPS; nothing is published as plain HTTP.

The GPU is the scarce resource, so no client talks to `llama-server` directly:
LiteLLM meters every request, which is what keeps a runaway script or an
enthusiastic teammate from saturating the DGX.

## Highlights

- **LiteLLM gateway in front of the GPU** — every request is authenticated with
  a virtual key, counted against per-key/team RPM, TPM and budget limits, capped
  by a global concurrency ceiling, written to a spend log, and traced to
  OpenTelemetry. See [Governing GPU access](#governing-gpu-access).
- **Concurrency caps matched to the hardware** — `max_parallel_requests` per
  (model, router) mirrors `LLAMA_ARG_PARALLEL`, and
  `global_max_parallel_requests` bounds the whole proxy, so excess load queues
  in LiteLLM instead of thrashing the GPU.
- **2 GPU `llama-server` instances in router mode** on the same host, each with
  full GPU access via NVIDIA CDI (`nvidia.com/gpu=all`).
- **Multi-model serving from one endpoint** — add any `.gguf` to the shared
  model store, run `./litellm/gen-models.sh --reload`, and it shows up in
  `/v1/models` and Open WebUI. Models load on demand (each into its own child
  `llama-server` process) and are LRU-evicted when `--models-max` is reached.
- **Shared model store** — both routers mount the same `var/lib/llama` host
  directory, so each GGUF lives on disk exactly once and either router can serve
  any model.
- **OpenAI-compatible API** — `llama-server` exposes `/v1/chat/completions`,
  `/v1/models`, and a `/health` endpoint, so any OpenAI client (and Open WebUI)
  can talk to it.
- **Redundant routers** — if one router restarts, LiteLLM retries on the other
  and cools the failed one out of rotation; its models reload on demand.
- **Dynamic upstream pool** — `healthcheck.sh` probes each instance's socket
  every 5 s and regenerates the nginx upstream, reloading only on change. This
  now backs the `:11439` debug listener; LiteLLM handles failover for `:11437`.
- **Load-balanced routers** — LiteLLM sends each request to whichever router has
  the fewest calls in flight (`least-busy`), retries on the other one, and cools
  a failing router out of rotation.
- **HTTPS-only entry points** on `:11437` (LiteLLM API + Admin UI) and `:11438`
  (Open WebUI), served by a self-signed local CA. `:11439` exposes the raw
  router pool for debugging only.
- **Hardened containers** — `no-new-privileges` and `cap_drop: ALL` on every
  service, running as non-root `1000:1000` everywhere except `litellm` (see
  [Security notes](#security-notes) for why).
- **No TCP ports published** except through nginx: containers talk over unix
  sockets bridged by socat.

## Architecture

![Architecture](docs/diagrams/architecture.svg)

### Services and ports

| Service         | Container port | Host exposure                                       | Purpose                          |
| --------------- | -------------- | --------------------------------------------------- | -------------------------------- |
| `nginx`         | —              | `:11437`, `:11438`, `:11439` (all HTTPS)            | TLS front door for the whole stack |
| `litellm`       | `:4000`        | none (reached via unix socket)                      | Gateway: auth, limits, logging, OTEL |
| `socat-litellm` | —              | `var/run/sockets/litellm.sock` (unix)               | Bridge TCP `:4000` to a socket   |
| `llama-1..2`    | `:8080`        | none (LiteLLM reaches them on the compose network)  | GPU routers (on-demand model children) |
| `socat-1..2`    | —              | `var/run/sockets/llama-N.sock` (unix)               | Bridge TCP `:8080` to sockets (for `:11439` + health checks) |
| `webui`         | `:8080`        | none (reached via unix socket)                      | Open WebUI                       |
| `socat-webui`   | —              | `var/run/sockets/webui.sock` (unix)                 | Bridge TCP `:8080` to a socket   |

External dependency: a **remote PostgreSQL database** (`DATABASE_URL` in `.env`).
LiteLLM keeps virtual keys, teams, budgets, rate-limit counters and spend logs
there, and migrates its own schema on startup.

| Port     | Serves                                     | Auth                     |
| -------- | ------------------------------------------ | ------------------------ |
| `:11437` | LiteLLM OpenAI API (`/v1/...`) + Admin UI (`/ui`) | Virtual key / master key |
| `:11438` | Open WebUI                                 | Open WebUI accounts      |
| `:11439` | Raw `llama_pool` — **debugging only**      | None                     |

### Request flow (llama.cpp API)

![llama.cpp API request flow](docs/diagrams/request-flow.svg)

A client calls `https://localhost:11437/v1` with a virtual key. nginx terminates
TLS and forwards to LiteLLM over `litellm.sock`. LiteLLM then:

1. **Authenticates** the key against Postgres and rejects unknown or expired keys.
2. **Applies limits** — the key's RPM/TPM/budget, then the per-deployment
   `max_parallel_requests` and the proxy-wide `global_max_parallel_requests`.
   Requests over the cap queue inside LiteLLM rather than reaching the GPU.
3. **Picks a router** — `least-busy` sends the request to whichever of
   `llama-1`/`llama-2` has fewer calls in flight, skipping any router in cooldown.
4. **Streams the response back** with `proxy_buffering off` at every hop, so SSE
   works end to end.
5. **Records** the call in the spend log (tokens, latency, key, deployment) and
   emits an OpenTelemetry span.

Inside the chosen router, the `"model"` field selects a model: if it is not
loaded yet, the router spawns a child `llama-server` process for it (inheriting
this stack's GPU access, context, and parallelism settings) and proxies the
request to it.

The `:11439` listener skips LiteLLM entirely and hits the nginx `llama_pool`
directly. It has no auth, no limits and no logging — it exists to answer "is the
router itself healthy?" when you need to rule LiteLLM out. Do not point clients
at it.

### Request flow (Open WebUI)

![WebUI request flow](docs/diagrams/webui-flow.svg)

The browser loads the UI over `https://localhost:11438`. Open WebUI then calls
back out through the host bridge gateway (`172.31.0.1`) to `:11437` over TLS,
using the CA baked into its image and its own LiteLLM virtual key
(`LITELLM_WEBUI_KEY`). This is why the compose bridge subnet is pinned: the
gateway `172.31.0.1` must be deterministic and present in the server
certificate's SANs.

Because the UI has its own key, all of its traffic is attributable and
rate-limitable separately from API clients — you can cap the UI without
throttling batch jobs, or vice versa.

### Health checks and automatic failover

![Health check loop](docs/diagrams/healthcheck.svg)

`healthcheck.sh --watch` runs inside the nginx container. Every 5 s it curls
`/health` over each `llama-N.sock`. If the healthy set changed, it writes
`var/run/nginx/upstream.conf` and reloads nginx — a crashed or restarting
router is removed from the pool with zero downtime. When no router is healthy
the upstream keeps a placeholder `none.sock` so nginx stays valid.

This pool now backs only the `:11439` debug listener. Failover for real traffic
on `:11437` is LiteLLM's job: `num_retries` retries the request on the other
router, and `allowed_fails`/`cooldown_time` take a failing router out of
rotation. The two mechanisms are independent and complementary — nginx probes
liveness on a timer, LiteLLM reacts to actual request failures.

LiteLLM's own `background_health_checks` is deliberately **off**. It works by
sending a real completion to every entry in `model_list`, which under router mode
would load every GGUF into VRAM on a timer and LRU-thrash the GPU.

## Repository layout

```
├── docker-compose.yml      # The whole stack
├── .env.example            # Template for .env (DSN + secrets, gitignored)
├── litellm/
│   ├── config.yaml         # Gateway settings: limits, callbacks, routing
│   └── gen-models.sh       # Generates model_list from the GGUFs on disk
├── nginx/
│   ├── nginx.conf          # :11437 litellm + :11438 webui + :11439 raw pool
│   ├── healthcheck.sh      # Dynamic upstream watcher (backs :11439)
│   └── certs/              # Local CA + server cert (gitignored)
├── webui/
│   └── Dockerfile          # Open WebUI + baked-in CA trust
├── var/                    # Runtime data (gitignored)
│   ├── lib/llama           # GGUF model files
│   ├── lib/llama-home      # writable $HOME for the llama containers
│   ├── lib/webui           # SQLite DB + uploads
│   ├── run/sockets         # unix sockets
│   ├── run/nginx           # generated upstream.conf
│   └── run/litellm         # generated models.generated.yaml
├── docs/diagrams/          # Mermaid sources + rendered SVG/PNG diagrams
└── opencode.json           # Example: point opencode at the gateway
```

## Prerequisites

- Docker + Docker Compose (v2.24+, for the `env_file: required` syntax).
- NVIDIA Container Toolkit with CDI enabled (used for `driver: cdi`).
- A reachable **PostgreSQL** database for LiteLLM, with rights to create its own
  schema. Any managed Postgres works; it holds keys, budgets, counters and spend
  logs, not model weights, so it stays small.
- Run `./setup.sh` to create the directories, self-signed certificates, `.env`
  and the generated model list before starting the stack.

## Getting started

```sh
# 1. Create directories, certs, .env (with generated secrets), and the model list
./setup.sh

# 2. Point LiteLLM at your Postgres. This is the one value setup.sh cannot guess.
$EDITOR .env        # set DATABASE_URL=postgresql://user:pass@host:5432/litellm

# 3. Drop GGUFs into the shared model store, e.g.
#      cp ~/qwen2.5-7b-instruct-q4_k_m.gguf var/lib/llama/
#      cp ~/qwen3-8b-q4_k_m.gguf            var/lib/llama/
#    then regenerate the LiteLLM model list from what is on disk.
#    The model ID is the filename without the .gguf extension.
./litellm/gen-models.sh

# 4. Start the stack (builds the webui image first time)
docker compose up --build -d

# 5. Use it. Authentication is required now, so pass a key.
KEY=$(grep '^LITELLM_MASTER_KEY=' .env | cut -d= -f2)

curl -k -H "Authorization: Bearer $KEY" https://localhost:11437/v1/models
curl -k -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  https://localhost:11437/v1/chat/completions -d '{
  "model": "qwen2.5-7b-instruct-q4_k_m",
  "messages": [{"role": "user", "content": "hello"}]
}'
```

Then:

- **LiteLLM Admin UI**: <https://localhost:11437/ui> — log in with `UI_USERNAME`
  / `UI_PASSWORD` from `.env`. Create a virtual key per client here.
- **Open WebUI**: <https://localhost:11438> (first-run: create the admin account).

`setup.sh` starts Open WebUI on the master key so the stack comes up in one shot.
Once you are running, create a dedicated key for it in the Admin UI, set
`LITELLM_WEBUI_KEY` in `.env` to that key, and `docker compose up -d webui`.

### Adding a model

`llama-server` scans `var/lib/llama` only at startup, and LiteLLM reads its
generated `model_list` only at startup, so both need a restart:

```sh
cp ~/new-model.gguf var/lib/llama/
./litellm/gen-models.sh --reload    # regenerate + restart llama-1, llama-2, litellm
```

## Governing GPU access

This is the part that stops the DGX being hammered. The controls stack from
broadest to narrowest — a request has to clear all of them.

| Control                        | Where                                | What it bounds |
| ------------------------------ | ------------------------------------ | -------------- |
| `global_max_parallel_requests` | `litellm/config.yaml`                | In-flight requests across the entire proxy. The hard backstop. |
| `max_parallel_requests`        | generated per (model, router)         | In-flight requests to one model on one router. Set to `LLAMA_ARG_PARALLEL`. |
| Key / team RPM, TPM, budget    | Admin UI or `/key/generate`          | What one client may consume per minute, and its spend ceiling. |
| `allowed_fails` / `cooldown_time` | `litellm/config.yaml`             | How fast a failing router is pulled out of rotation. |

Concurrency is the lever that matters most here. A loaded model has exactly
`LLAMA_ARG_PARALLEL` (2) slots per router; requests beyond that queue *inside*
`llama-server`, where LiteLLM can neither see nor account for them. Keeping
`max_parallel_requests` equal to `LLAMA_ARG_PARALLEL` (the generator's default)
means the queue forms in LiteLLM instead — where it is observable, fair, and
subject to the key's limits. If you change `LLAMA_ARG_PARALLEL` in
`docker-compose.yml`, re-run the generator with a matching `MAX_PARALLEL`:

```sh
MAX_PARALLEL=4 ./litellm/gen-models.sh --reload
```

Create a rate-limited key for a client:

```sh
KEY=$(grep '^LITELLM_MASTER_KEY=' .env | cut -d= -f2)
curl -k -X POST https://localhost:11437/key/generate \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"key_alias": "batch-job", "rpm_limit": 10, "tpm_limit": 100000, "max_budget": 0}'
```

### Observability

- **Admin UI** (<https://localhost:11437/ui>) — per-key and per-model request
  logs, token usage, latency and error rates, backed by the spend log in
  Postgres. Writes are batched every 60 s (`proxy_batch_write_at`).
- **OpenTelemetry** — a span per request (model, deployment id, latency, token
  counts, errors), exported to `OTEL_ENDPOINT`. The generated deployment ids are
  `<model>@<router>`, so you can see which physical router served each call.
  **If you do not run a collector, comment out the `otel` entry under
  `litellm_settings.callbacks` in `litellm/config.yaml`** — otherwise LiteLLM
  logs an export failure for every request.
- **Structured logs** — `json_logs: true`, so `docker compose logs litellm` is
  machine-parseable.

Prometheus `/metrics` is a [LiteLLM enterprise feature](https://docs.litellm.ai/docs/proxy/prometheus)
and is not wired up here; the OTEL exporter covers the same ground for free.

## Configuration knobs

| Setting                               | Where                         | Effect                                   |
| ------------------------------------- | ----------------------------- | ---------------------------------------- |
| `LLAMA_ARG_MODELS_DIR=/models`        | compose `x-llama-base`        | Directory scanned for `.gguf` models (router mode) |
| `LLAMA_ARG_MODELS_MAX=4`              | compose `x-llama-base`        | Max models resident at once per router (LRU eviction) |
| `LLAMA_ARG_CONTEXT_SIZE=32768`        | compose `x-llama-base`        | Context window inherited by every loaded model |
| `LLAMA_ARG_N_GPU_LAYERS=999`          | compose `x-llama-base`        | Offload all layers to the GPU (inherited) |
| `LLAMA_ARG_PARALLEL=2`                | compose `x-llama-base`        | Concurrent slots per loaded model (inherited) |
| `LLAMA_ARG_MODELS_PRESET` (optional)  | compose `x-llama-base`        | Per-model config INI (context, aliases, sharded GGUFs) |
| Number of instances (`1..2`)          | compose `services`            | Scale the router pool (and `INSTANCES` in `healthcheck.sh`, `ROUTERS` in `gen-models.sh`) |
| Round-robin / `keepalive 32`      | generated `upstream.conf`     | Load balancing + connection reuse for `:11439` |
| `OPENAI_API_BASE_URL` / `WEBUI_URL`   | compose `webui`               | WebUI backend URL + public UI URL        |
| Probe interval (`INTERVAL=5`)         | `nginx/healthcheck.sh`        | Health-check cadence                     |

### LiteLLM gateway

| Setting                             | Where                   | Effect                                        |
| ----------------------------------- | ----------------------- | --------------------------------------------- |
| `global_max_parallel_requests: 8`   | `litellm/config.yaml`   | Proxy-wide in-flight request ceiling          |
| `routing_strategy: least-busy`      | `litellm/config.yaml`   | Router selection; no Redis required           |
| `num_retries` / `allowed_fails` / `cooldown_time` | `litellm/config.yaml` | Retry + router cooldown behavior  |
| `request_timeout: 600`              | `litellm/config.yaml`   | Per-request timeout (matches nginx)           |
| `callbacks: ["otel"]`               | `litellm/config.yaml`   | OpenTelemetry tracing; comment out if no collector |
| `store_model_in_db: false`          | `litellm/config.yaml`   | Keeps `model_list` file-owned, not DB-owned   |
| `background_health_checks: false`   | `litellm/config.yaml`   | **Leave off** — it would load every GGUF on a timer |
| `MAX_PARALLEL` (default 2)          | `litellm/gen-models.sh` | Per-(model, router) concurrency; match `LLAMA_ARG_PARALLEL` |
| `ROUTERS` (default `llama-1 llama-2`) | `litellm/gen-models.sh` | Which routers get a deployment per model    |
| `DATABASE_URL`                      | `.env`                  | Remote Postgres for keys, budgets, spend logs  |
| `LITELLM_MASTER_KEY` / `LITELLM_SALT_KEY` | `.env`            | Admin credential / credential encryption key  |
| `UI_USERNAME` / `UI_PASSWORD`       | `.env`                  | Admin UI login                                |
| `LITELLM_WEBUI_KEY`                 | `.env`                  | Virtual key Open WebUI authenticates with     |
| `OTEL_EXPORTER` / `OTEL_ENDPOINT` / `OTEL_HEADERS` | `.env`   | Where traces are exported                     |

With two routers, up to `2 x LLAMA_ARG_MODELS_MAX` models can be resident at
once across the pool (each router LRU-evicts independently). The total is
bounded by GPU memory.

## Trusting the CA

- **Host / browsers**: add `nginx/certs/ca.crt` to your system/browser trust
  store, then `https://localhost:11437` and `https://localhost:11438` validate
  without warnings.
- **WebUI container**: done automatically via `webui/Dockerfile`
  (`update-ca-certificates` + `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE`).
- **opencode**: see `opencode.json`, which points `baseURL` at
  `https://localhost:11437/v1` with the local CA trusted by the system store.
  Set `model` (and the model key under `provider.llamacpp.models`) to one of the
  model IDs from `GET /v1/models` — the GGUF filename without the `.gguf`
  extension. It reads its virtual key from `LITELLM_API_KEY`, so export that in
  your shell (use a dedicated key, not the master key):
  `export LITELLM_API_KEY=sk-...`

## Troubleshooting

- **`401` / `400 Authentication Error`** — `:11437` now requires a LiteLLM key.
  Pass `Authorization: Bearer sk-...` (a virtual key, or `LITELLM_MASTER_KEY`
  from `.env`). A missing key gives 401; a key LiteLLM does not recognise gives
  400. Clients still using the old placeholder `none` key will fail this way.
- **LiteLLM won't start / `prisma` or connection errors** — almost always
  `DATABASE_URL`. Check `docker compose logs litellm`; the user needs rights to
  create its schema, and managed Postgres usually needs `?sslmode=require`.
- **`bind source path does not exist: .../models.generated.yaml`** — you skipped
  `./setup.sh`. Run `./litellm/gen-models.sh` (this is deliberate: the mount uses
  `create_host_path: false` so Docker cannot silently create a directory there).
- **New model missing from `/v1/models`** — LiteLLM serves only what is in its
  generated `model_list`. Run `./litellm/gen-models.sh --reload`. Confirm with
  `cat var/run/litellm/models.generated.yaml`. Note `:11439` may list a model
  that `:11437` does not — that gap *is* the stale generated file.
- **`400` on a model that exists** — the ID must match `GET /v1/models` exactly
  (GGUF filename minus `.gguf`). Sharded GGUFs are skipped by the generator and
  logged as `skip (sharded GGUF, ...)`; use `LLAMA_ARG_MODELS_PRESET` for those.
- **Requests are queueing / feel slow under load** — expected, and the point.
  Check the Admin UI for the key's RPM/TPM and how close the proxy is to
  `global_max_parallel_requests`. Raise it only if the GPU is actually idle.
- **An OTEL export error per request** — no collector at `OTEL_ENDPOINT`. Either
  start one or comment out the `otel` callback in `litellm/config.yaml`.
- **`not in built-in cost map` warnings at LiteLLM startup** — harmless and
  expected. The generated `model_info` declares zero cost for each deployment,
  but LiteLLM also registers the bare `openai/<model>` name internally, which
  no config entry can annotate. Local inference is free; spend stays at 0.00.
- **Is LiteLLM the problem, or the router?** — compare `:11437` (governed) with
  `:11439` (raw pool, no auth). If `:11439` answers and `:11437` does not, the
  issue is in LiteLLM or its config, not in `llama-server`.
- **Upstream empty / all routers down** — check `var/run/nginx/upstream.conf`;
  the health checker only lists sockets whose `/health` probe succeeds. Verify
  the sockets exist (`ls var/run/sockets`) and the routers are up
  (`docker compose logs llama-1`). A 502 on `:11437` means the pool is empty.
- **No models listed in `/v1/models`** — the router scans `.gguf` files in
  `var/lib/llama/` (mounted read-only at `/models`) **at startup**, and LiteLLM
  reads its generated `model_list` at startup too. Drop a model in and run
  `./litellm/gen-models.sh --reload`; it then appears in `/v1/models` and the
  Open WebUI dropdown and loads on its first request.
- **First request to a model is slow** — models load on demand into a child
  process; subsequent requests to the same model are served from memory until
  LRU-evicted (see `LLAMA_ARG_MODELS_MAX`).
- **Multi-file / sharded GGUFs** — `--models-dir` scans for standalone `.gguf`
  files only; for sharded models, define them in a presets INI
  (`LLAMA_ARG_MODELS_PRESET`) pointing at the first shard.
- **WebUI can't reach the pool** — confirm the bridge gateway is `172.31.0.1`
  (it is pinned to subnet `172.31.0.0/24`) and that the server certificate
  includes it in its SANs.
- **TLS verification failures from the webui** — the baked-in CA must match
  `nginx/certs/ca.crt`; rebuild the image after rotating the CA
  (`docker compose build webui`).
- **Permission errors on writes** — the stack runs as `1000:1000`; make sure
  `var/` (and the sockets dir) are owned by that user (re-run `./setup.sh`).
- **`400 Invalid Model` in Open WebUI** — the model ID sent by the UI must match
  one listed in `GET /v1/models` (the GGUF filename without the `.gguf`
  extension). Pick the model from the dropdown instead of typing it.

## Security notes

- TLS-only everywhere; no HTTP listeners are published.
- **`:11437` is authenticated** — LiteLLM rejects requests without a valid
  virtual key. Give each client its own key so access can be revoked and
  metered individually, and keep `LITELLM_MASTER_KEY` for administration only.
- **`:11439` is not authenticated.** It is a raw path to the GPU, published on
  all interfaces like the other listeners. If this host is not on a trusted
  network, firewall the port or delete that `server` block from
  `nginx/nginx.conf` — nothing in the stack depends on it.
- **`.env` holds the Postgres DSN, the master key and the UI password.** It is
  gitignored and `setup.sh` creates it `chmod 600`. Rotating `LITELLM_SALT_KEY`
  after keys exist makes the stored credentials unreadable.
- Every service runs unprivileged with `no-new-privileges` and no capabilities,
  **except** that `litellm` runs as the image's default user rather than
  `1000:1000`: the non-root image variant runs as `nobody` and has open issues
  with its startup Prisma migration. LiteLLM writes to no host bind mount — its
  state is in the remote Postgres and both of its mounts are read-only — so
  nothing on the host ends up root-owned.
- The certs are self-signed and the CA is private to this host — nothing leaves
  the machine.
- Data mounts (`var/lib/llama`, `var/lib/webui`) are plain host directories and
  contain model weights and user chat data; back them up accordingly. Prompt and
  response *metadata* (not content) also leaves the host for your Postgres and
  your OTEL collector.
