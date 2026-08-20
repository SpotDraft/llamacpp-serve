# llamacpp-serve

A self-hosted, TLS-only [llama.cpp](https://github.com/ggml-org/llama.cpp) serving
stack for a single GPU host (NVIDIA DGX Spark / GB10). It runs two `llama-server`
instances in **router mode** behind an nginx reverse proxy with dynamic,
health-checked upstreams, plus Open WebUI for a browser interface. Every path
into the stack is HTTPS; nothing is published as plain HTTP.

An optional [LiteLLM](https://github.com/BerriAI/litellm) gateway can sit in
front of the GPU for auth, rate limits, concurrency caps and observability.
It is off by default — `docker compose up` does not start it. Enable it by
appending `docker-compose.litellm.yml` to `COMPOSE_FILE` (see
[Optional: LiteLLM gateway](#optional-litellm-gateway)).

## Highlights

- **2 GPU `llama-server` instances** on the same DGX Spark, each with full
  GPU access via NVIDIA CDI (`nvidia.com/gpu=all`) and a **32768** context.
- **One resident model per router** — `LLAMA_ARG_MODELS_MAX=1` caps how many
  models each `llama-server` keeps loaded, not how many it discovers. The
  default stack serves every standalone `.gguf` in `var/lib/llama` and
  LRU-evicts as needed.
- **At most two models *with LiteLLM*** — the pinning generator
  (`litellm/gen-models.sh`) maps one GGUF to one `api_base`, so it refuses a
  third standalone file. This bound is enforced by the generator, not by
  `docker-compose.yml`; the default stack has no such limit.
- **Shared model store** — both routers mount the same `var/lib/llama` host
  directory, so each GGUF lives on disk exactly once.
- **OpenAI-compatible API** — `llama-server` exposes `/v1/chat/completions`,
  `/v1/models`, and a `/health` endpoint, so any OpenAI client (and Open WebUI)
  can talk to it.
- **Two dedicated routers** — one resident GGUF each. A restart of `llama-1`
  only takes down its pinned model; `llama-2` keeps serving the other.
- **Dynamic upstream pool (default stack only)** — `healthcheck.sh` probes each
  instance's socket every 5 s and regenerates the nginx upstream, reloading only
  on change. Failed instances are dropped from the pool automatically. With the
  LiteLLM overlay nginx has no `llama_pool` at all — LiteLLM does the routing
  and the watcher is not run.
- **Request correlation** — nginx honours an inbound `X-Request-ID` (or mints
  one), forwards it upstream, echoes it back on the response, and logs it as
  `rid=` so a client-visible id ties the access log to the gateway log.
- **Pinned models with LiteLLM** — each GGUF has one `api_base`. LiteLLM always
  sends that model to its home `llama-server` and never fail over onto the
  neighbour (that would put two GGUFs on one GPU). Without LiteLLM, nginx
  round-robins and *can* load the same GGUF on both servers.
- **HTTPS-only entry points** on `:11437` (llama.cpp API) and `:11438` (Open WebUI),
  served by a self-signed local CA.
- **Hardened containers** — non-root user (`1000:1000`), `no-new-privileges`,
  and `cap_drop: ALL` on every default service.
- **No TCP ports published** except through nginx: containers talk over unix
  sockets bridged by socat.
- **Optional LiteLLM compose file** — auth, per-key RPM/TPM/budgets, concurrency
  caps, spend logs and OpenTelemetry, without changing the llama.cpp routers.

## Architecture

![Architecture](docs/diagrams/architecture.svg)

### Services and ports

| Service       | Container port | Host exposure                                  | Purpose                          |
| ------------- | -------------- | ---------------------------------------------- | -------------------------------- |
| `nginx`       | `:11437`, `:11438` | `:11437` (HTTPS), `:11438` (HTTPS)             | TLS front door for the whole stack |
| `llama-1..2`  | `:8080`        | none (reached via unix sockets)                | GPU routers (on-demand model children) |
| `socat-1..2`  | —              | `var/run/sockets/llama-N.sock` (unix)          | Bridge TCP `:8080` to sockets    |
| `webui`       | `:8080`        | none (reached via unix socket)                 | Open WebUI                       |
| `socat-webui` | —              | `var/run/sockets/webui.sock` (unix)            | Bridge TCP `:8080` to a socket   |

### Request flow (llama.cpp API)

![llama.cpp API request flow](docs/diagrams/request-flow.svg)

A client calls `https://localhost:11437/v1`. nginx terminates TLS, round-robins
across the healthy sockets, and streams the response back with
`proxy_buffering off` so SSE works end to end. Inside the chosen router,
the `"model"` field in the request selects a model: if it is not loaded yet, the
router spawns a child `llama-server` process for it (inheriting this stack's GPU
access, context, and parallelism settings) and proxies the request to it.

### Request flow (Open WebUI)

![WebUI request flow](docs/diagrams/webui-flow.svg)

The browser loads the UI over `https://localhost:11438`. Open WebUI then calls
back to `https://host.docker.internal:11437/v1` (the published nginx port on
the host) over TLS, using the CA baked into its image. The server certificate
includes `DNS:host.docker.internal` in its SANs; Linux containers get that name
via `extra_hosts: host.docker.internal:host-gateway`.

### Health checks and automatic failover

![Health check loop](docs/diagrams/healthcheck.svg)

`healthcheck.sh --watch` runs inside the nginx container. Every 5 s it curls
`/health` over each `llama-N.sock`. If the healthy set changed, it writes
`var/run/nginx/upstream.conf` and reloads nginx — a crashed or restarting
router is removed from the pool with zero downtime. When no router is healthy
the upstream keeps a placeholder `none.sock` so nginx stays valid.

## Repository layout

```
├── reload-models.sh             # After add/remove GGUFs: gen-models + compose down/up
├── docker-compose.yml           # Default stack (llama.cpp + webui + nginx)
├── docker-compose.litellm.yml   # Overlay: LiteLLM on :11437 + bundled Postgres
├── .env.example                 # Template for .env (LiteLLM secrets, gitignored)
├── litellm/
│   ├── config.yaml              # Gateway settings (used only with LiteLLM)
│   └── gen-models.sh            # Generates model_list from the GGUFs on disk
├── nginx/
│   ├── nginx.conf               # :11437 pool + :11438 webui, TLS-only
│   ├── nginx.litellm.conf       # :11437 LiteLLM + :11438 webui
│   ├── healthcheck.sh           # Dynamic upstream watcher
│   └── certs/                   # Local CA + server cert (gitignored)
├── webui/
│   └── Dockerfile               # Open WebUI + baked-in CA trust
├── var/                         # Runtime data (gitignored)
│   ├── lib/llama                # GGUF model files
│   ├── lib/llama-home           # writable $HOME for the llama containers
│   ├── lib/webui                # SQLite DB + uploads
│   ├── run/sockets              # unix sockets
│   ├── run/nginx                # generated upstream.conf
│   └── run/litellm              # generated models.generated.yaml
├── docs/diagrams/               # Mermaid sources + rendered SVG/PNG diagrams
└── opencode.json                # Example: point opencode at the local pool
```

## Prerequisites

- Docker + Docker Compose (v2.24+, for `env_file: required` / `!override`).
- NVIDIA Container Toolkit with CDI enabled (`driver: cdi`, `nvidia.com/gpu=all`).
- Run `./setup.sh` to create the required directories and self-signed
  certificates before starting the stack.

This stack is built for a **DGX Spark**. The CUDA image and CDI reservation
do not run on Docker Desktop / machines without an NVIDIA GPU.

## Getting started

```sh
# Run the setup script to create directories and generate self-signed certificates
./setup.sh

# Drop at most two GGUFs into the shared model store, e.g.
#   cp ~/qwen2.5-7b-instruct-q4_k_m.gguf var/lib/llama/
#   cp ~/qwen3-8b-q4_k_m.gguf            var/lib/llama/
# After the first start, add/remove GGUFs with ./reload-models.sh
# The model ID is the filename without the .gguf extension.

# Start the stack (builds the webui image first time)
docker compose up --build -d
# With LiteLLM instead, append :docker-compose.litellm.yml to COMPOSE_FILE
# (see Optional: LiteLLM gateway).

# Use it
curl -k https://localhost:11437/v1/models            # lists every discovered model
curl -k https://localhost:11437/v1/chat/completions -d '{
  "model": "qwen2.5-7b-instruct-q4_k_m",
  "messages": [{"role": "user", "content": "hello"}]
}'
```

Open the UI at <https://localhost:11438> (first-run: create the admin account).

## Configuration knobs

| Setting                               | Where                         | Effect                                   |
| ------------------------------------- | ----------------------------- | ---------------------------------------- |
| `LLAMA_ARG_MODELS_DIR=/models`        | compose `x-llama-base`        | Directory scanned for `.gguf` models (router mode) |
| `LLAMA_ARG_MODELS_MAX=1`              | compose `x-llama-base`        | Max models resident at once per router (one GGUF per server) |
| `LLAMA_ARG_CONTEXT_SIZE=32768`        | compose `x-llama-base`        | Context window inherited by every loaded model |
| `LLAMA_ARG_N_GPU_LAYERS=999`          | compose `x-llama-base`        | Offload all layers to the GPU (inherited) |
| `LLAMA_ARG_PARALLEL=2`                | compose `x-llama-base`        | Concurrent slots per loaded model (inherited) |
| `LLAMA_ARG_MODELS_PRESET` (optional)  | compose `x-llama-base`        | Per-model config INI (context, aliases, sharded GGUFs) |
| Number of instances (`llama-1`, `llama-2`) | compose `services`     | Two servers, one GGUF each               |
| Round-robin / `keepalive 32`      | generated `upstream.conf`     | Load balancing + connection reuse |
| `OPENAI_API_BASE_URL` / `WEBUI_URL`   | compose `webui`               | WebUI backend URL + public UI URL        |
| Probe interval (`INTERVAL=5`)         | `nginx/healthcheck.sh`        | Health-check cadence                     |
| `COMPOSE_FILE`                        | `.env`                        | `docker-compose.litellm.yml` appended = LiteLLM on |

With `LLAMA_ARG_MODELS_MAX=1`, the two routers hold at most two models in
VRAM. With LiteLLM, `gen-models.sh` pins each GGUF to one router (sorted
filename: 1st → `llama-1`, 2nd → `llama-2`) and refuses a third standalone
`.gguf`. Without LiteLLM, nginx round-robin can still place the *same* GGUF
on both routers.

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
  extension. With LiteLLM enabled, add `"apiKey": "{env:LITELLM_API_KEY}"` and
  `export LITELLM_API_KEY=sk-...` (a virtual key, not the master key).

## Optional: LiteLLM gateway

LiteLLM is **not** part of the default stack. Enable it when you want every
GPU-bound request authenticated, rate-limited, concurrency-capped, logged and
traced. The llama.cpp routers do not change; nginx `:11437` is pointed at
LiteLLM instead of the socket pool. Each GGUF is pinned to exactly one
router: two servers run two models, never two copies of the same one.

![LiteLLM architecture](docs/diagrams/architecture-litellm.svg)

```sh
./litellm/gen-models.sh
# COMPOSE_FILE=docker-compose.yml:docker-compose.litellm.yml
docker compose up -d
```

| Port     | Serves                                     | Auth                     |
| -------- | ------------------------------------------ | ------------------------ |
| `:11437` | LiteLLM OpenAI API (`/v1/...`) + Admin UI (`/ui`) | Virtual key / master key |
| `:11438` | Open WebUI                                 | Open WebUI accounts      |

llama.cpp is not published. Clients and Open WebUI only reach the GPU through
LiteLLM on `:11437`.

Postgres is **bundled** (no host port). LiteLLM keeps virtual keys, teams,
budgets, rate-limit counters and spend logs there, and migrates its own schema
on startup. To use a remote database instead, change `DATABASE_URL` on the
`litellm` service in `docker-compose.litellm.yml`.

![LiteLLM request flow](docs/diagrams/request-flow-litellm.svg)

A client calls `https://localhost:11437/v1` with a virtual key. nginx terminates
TLS and forwards to LiteLLM over `litellm.sock`. LiteLLM authenticates the key,
applies RPM/TPM/budget and concurrency caps (queueing overflow instead of
hitting the GPU), sends the request to that model's **pinned** router
(one `api_base` per GGUF), streams the response, then writes a spend log and an
OpenTelemetry span.

A pinned router that dies takes its models with it — LiteLLM does not fail
them over onto a neighbour, because that neighbour is already running a
different GGUF (`LLAMA_ARG_MODELS_MAX=1`).

Open WebUI keeps calling `:11437`, so it inherits the limits automatically
via `LITELLM_WEBUI_KEY`. `setup.sh` bootstraps that to the master key; create a
dedicated virtual key in the Admin UI afterwards.

### Adding or removing a model

`llama-server` scans `var/lib/llama` only at startup, and LiteLLM reads its
generated `model_list` only at startup, so both need restarting:

```sh
cp ~/new-model.gguf var/lib/llama/   # or rm var/lib/llama/old.gguf
./reload-models.sh                   # gen-models + restart routers (+ LiteLLM)
```

If you select the overlay with explicit `-f` flags instead of `COMPOSE_FILE`,
pass the same flags so the script acts on the same stack:

```sh
./reload-models.sh -f docker-compose.yml -f docker-compose.litellm.yml
```

`reload-models.sh` restarts rather than recreating: both the model store and
the generated `model_list` are bind mounts whose contents are already visible
inside the containers, so only a process restart is needed. It also asks
`docker compose config --services` whether `litellm` is in the active stack,
and only then treats a generator failure as fatal — the default stack does not
read `models.generated.yaml` at all.

`./litellm/gen-models.sh` prints the pin map (`model -> llama-N`). Assignment
is sorted filename order (1st file → `llama-1`, 2nd → `llama-2`), and the
script exits if a third standalone `.gguf` is present. There is no
replicate-onto-every-router mode: that would double VRAM for a hot model.
GGUF filenames must be usable as model IDs — letters, digits, `.`, `_`, `+`
and `-` only — since the filename minus `.gguf` is what clients send and what
is written into the generated YAML.

### Governing GPU access

The controls stack from broadest to narrowest — a request has to clear all of
them.

| Control                        | Where                                | What it bounds |
| ------------------------------ | ------------------------------------ | -------------- |
| `global_max_parallel_requests` | `litellm/config.yaml`                | In-flight requests across the entire proxy. The hard backstop. |
| `max_parallel_requests`        | generated per (model, router)         | In-flight requests to one model on one router. Set to `LLAMA_ARG_PARALLEL`. |
| Key / team RPM, TPM, budget    | Admin UI or `/key/generate`          | What one client may consume per minute, and its spend ceiling. |
| `allowed_fails` / `cooldown_time` | `litellm/config.yaml`             | How fast a failing *pinned* router is pulled out of rotation. |
| One `api_base` per GGUF                | `litellm/gen-models.sh`          | Sorted 1:1 pin onto `llama-1` / `llama-2`. |

Keep `max_parallel_requests` equal to `LLAMA_ARG_PARALLEL` (the generator's
default) so the queue forms in LiteLLM — where it is observable and subject to
the key's limits — instead of inside `llama-server`. If you change
`LLAMA_ARG_PARALLEL` in `docker-compose.yml`, re-run the generator with a
matching `MAX_PARALLEL`:

```sh
MAX_PARALLEL=4 ./litellm/gen-models.sh --reload
```

Create a rate-limited key:

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
- **OpenTelemetry** — a span per request, exported to `OTEL_ENDPOINT`. The
  generated deployment ids are `<model>@<router>`. **If you do not run a
  collector, comment out the `otel` entry under `litellm_settings.callbacks`
  in `litellm/config.yaml`** — otherwise LiteLLM logs an export failure for
  every request.
- **Structured logs** — `json_logs: true`, so `docker compose logs litellm` is
  machine-parseable.

Prometheus `/metrics` is a [LiteLLM enterprise feature](https://docs.litellm.ai/docs/proxy/prometheus)
and is not wired up here; the OTEL exporter covers the same ground for free.

### LiteLLM knobs

| Setting                             | Where                   | Effect                                        |
| ----------------------------------- | ----------------------- | --------------------------------------------- |
| `global_max_parallel_requests: 4`   | `litellm/config.yaml`   | Proxy-wide in-flight ceiling (n routers x PARALLEL) |
| `routing_strategy: least-busy`      | `litellm/config.yaml`   | Unused with one `api_base` per model                |
| `num_retries: 1`                    | `litellm/config.yaml`   | Retry the pinned router; no cross-server failover   |
| `request_timeout: 600`              | `litellm/config.yaml`   | Per-request timeout (matches nginx)                 |
| `callbacks` (off by default)        | `litellm/config.yaml`   | Uncomment `["otel"]` when a collector is running    |
| `store_model_in_db: false`          | `litellm/config.yaml`   | Keeps `model_list` file-owned, not DB-owned         |
| `background_health_checks: false`   | `litellm/config.yaml`   | **Leave off** — it would load every GGUF on a timer |
| `MAX_PARALLEL` (default 2)          | `litellm/gen-models.sh` | Per-deployment concurrency; match `LLAMA_ARG_PARALLEL` |
| `ROUTERS` (default `llama-1 llama-2`) | `litellm/gen-models.sh` | The two servers models are pinned across          |
| `LITELLM_MASTER_KEY` / `LITELLM_SALT_KEY` | `.env`            | Admin credential / credential encryption key  |
| `UI_USERNAME` / `UI_PASSWORD`       | `.env`                  | Admin UI login                                |
| `LITELLM_WEBUI_KEY`                 | `.env`                  | Virtual key Open WebUI authenticates with     |
| `OTEL_EXPORTER` / `OTEL_ENDPOINT` / `OTEL_HEADERS` | `.env`   | Where traces are exported                     |

LiteLLM's own `background_health_checks` is deliberately **off**. It works by
sending a real completion to every entry in `model_list`, which under router
mode would load every GGUF into VRAM on a timer and LRU-thrash the GPU.

## Troubleshooting

- **Upstream empty / all routers down** — check `var/run/nginx/upstream.conf`;
  the health checker only lists sockets whose `/health` probe succeeds. Verify
  the sockets exist (`ls var/run/sockets`) and the routers are up
  (`docker compose logs llama-1`). A 502 on `:11437` means the pool is empty.
- **No models listed in `/v1/models`** — the router scans `.gguf` files in
  `var/lib/llama/` (mounted read-only at `/models`) **at startup**. Drop a model
  in and run `./reload-models.sh`; it then
  appears in `/v1/models` and the Open WebUI dropdown and loads on its first
  request.
- **First request to a model is slow** — models load on demand into a child
  process; subsequent requests to the same model are served from memory until
  LRU-evicted (see `LLAMA_ARG_MODELS_MAX`).
- **Multi-file / sharded GGUFs** — `--models-dir` scans for standalone `.gguf`
  files only; for sharded models, define them in a presets INI
  (`LLAMA_ARG_MODELS_PRESET`) pointing at the first shard.
- **WebUI can't reach the pool** — Open WebUI calls
  `https://host.docker.internal:11437`. Confirm nginx published `:11437`, that
  the server certificate includes `DNS:host.docker.internal`, and (on Linux)
  that `extra_hosts: host.docker.internal:host-gateway` is present on `webui`.
- **TLS verification failures from the webui** — the baked-in CA must match
  `nginx/certs/ca.crt`; rebuild the image after rotating the CA
  (`docker compose build webui`).
- **Permission errors on writes** — the stack runs as `1000:1000`; make sure
  `var/` (and the sockets dir) are owned by that user (re-run `./setup.sh` as
  root on Linux).
- **`400 Invalid Model` in Open WebUI** — the model ID sent by the UI must match
  one listed in `GET /v1/models` (the GGUF filename without the `.gguf`
  extension). Pick the model from the dropdown instead of typing it.
- **`docker compose` tries to start LiteLLM / demands `LITELLM_WEBUI_KEY`** —
  `COMPOSE_FILE` in `.env` includes `docker-compose.litellm.yml`. Drop that
  file from the list and `docker compose up -d --remove-orphans`.
- **`gen-models.sh` exits with "at most 2 models"** — remove extra standalone
  `.gguf` files from `var/lib/llama/` (shards named `*-NNNNN-of-NNNNN` are
  skipped). This stack is two servers, one GGUF each.
- **CUDA / CDI errors** — this stack needs NVIDIA Container Toolkit with CDI
  on a DGX Spark. `nvidia.com/gpu=all` must be visible to Docker.

### LiteLLM

- **`401` / `400 Authentication Error`** — `:11437` requires a LiteLLM key
  when that compose file is in use. Pass `Authorization: Bearer sk-...`.
- **LiteLLM won't start / `prisma` or connection errors** — check
  `docker compose logs postgres litellm`. The bundled Postgres must be healthy
  before LiteLLM migrates.
- **`bind source path does not exist: .../models.generated.yaml`** — run
  `./litellm/gen-models.sh` (the mount uses `create_host_path: false` so Docker
  cannot silently create a directory there).
- **An OTEL export error per request** — no collector at `OTEL_ENDPOINT`.
  Comment out the `otel` callback in `litellm/config.yaml`.
- **Is LiteLLM the problem, or the router?** — `docker compose logs llama-1 llama-2`
  vs `docker compose logs litellm`. A 401/400 on `:11437` is LiteLLM auth;
  a 502 with LiteLLM up usually means the pinned router is down.

## Security notes

- TLS-only everywhere; no HTTP listeners are published.
- Every default service runs unprivileged with `no-new-privileges` and no
  capabilities.
- The certs are self-signed and the CA is private to this host — nothing leaves
  the machine.
- Data mounts (`var/lib/llama`, `var/lib/webui`) are plain host directories and
  contain model weights and user chat data; back them up accordingly.

With `docker-compose.litellm.yml`:

- **`:11437` is authenticated** — LiteLLM rejects requests without a valid
  virtual key. Keep `LITELLM_MASTER_KEY` for administration only. llama.cpp
  itself is not published.
- **`.env` holds the master key and the UI password.** It is gitignored and
  `setup.sh` creates it `chmod 600`. Spend logs live in the bundled Postgres
  volume.
- `litellm` runs as the image's default user rather than `1000:1000`: the
  non-root image variant has open issues with its startup Prisma migration.
  LiteLLM writes to no host bind mount, so nothing on the host ends up
  root-owned.
- Prompt and response *metadata* (not content) also leaves the host for your
  OTEL collector if you enable it.
- **The routers are not reachable by anything but LiteLLM.** A flat network
  would make the gateway optional: `llama-server` has no authentication and
  listens on `0.0.0.0:8080`, so any peer — including `webui`, which runs
  model-driven tool calls — could call `http://llama-1:8080/v1/...` directly
  and bypass auth, per-key rate limits, accounting and the concurrency cap.
  The overlay therefore splits the flat `llama` network into four segments:

  | Network    | Members                                          | Egress |
  | ---------- | ------------------------------------------------ | ------ |
  | `frontend` | `webui`, `socat-webui`                           | yes    |
  | `llama`    | `nginx`, `socat-litellm`, `litellm`              | yes    |
  | `backend`  | `llama-1`, `llama-2`, `socat-1/2`, `litellm`     | no (`internal`) |
  | `db`       | `postgres`, `litellm`                            | no (`internal`) |

  `litellm` is the only service spanning segments. The webui reaches the API
  the same way an external client does — TLS via `host.docker.internal:11437`
  — so it needs no route to the routers or the database.
- **Supporting images are pinned by digest** (`litellm`, `nginx`, `postgres`,
  `alpine/socat`) so a registry retag cannot change them on restart. The
  llama.cpp image deliberately stays on the rolling `server-cuda` tag; see the
  comment in `docker-compose.yml` for how to pin it too.

### Rotating the bundled Postgres password

`LITELLM_DB_PASSWORD` in `.env` feeds both `POSTGRES_PASSWORD` and LiteLLM's
`DATABASE_URL`. Postgres only applies `POSTGRES_PASSWORD` when `initdb` runs on
an **empty** volume, so editing `.env` alone does not rotate anything — it just
makes LiteLLM authenticate with the wrong password. Rotate inside the database
as well:

```sh
NEW=$(openssl rand -hex 24)                 # keep it URL-safe: it goes into a DSN
docker compose exec postgres psql -U litellm -d litellm \
  -c "ALTER USER litellm WITH PASSWORD '$NEW';"
sed -i "s|^LITELLM_DB_PASSWORD=.*|LITELLM_DB_PASSWORD=$NEW|" .env
docker compose up -d --force-recreate litellm
```

To start over instead, `docker compose down` and remove the `postgres-data`
volume — that discards virtual keys, teams, budgets and spend history.

Stacks created before this setting existed keep working: both the compose file
and `setup.sh`'s `.env` migration fall back to the historical `litellm`.
