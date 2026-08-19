# AGENTS.md

Guidance for AI agents working in this repository.

## Read the README first

[`README.md`](README.md) is the source of truth: it documents what the stack is,
the full architecture, setup, configuration knobs, and troubleshooting. Read it
before working here. This file only adds the operational details agents need
that the README does not cover.

## Verification commands

There is no test suite and no linter. Verification = validating the Compose
file, the nginx config, and the rendered diagrams:

```sh
docker compose config                 # lint the compose file (main check)
docker compose -f docker-compose.yml -f docker-compose.otel.yml config  # ...with the telemetry overlay
docker compose exec nginx nginx -t    # lint nginx config inside the container
docker compose exec nginx cat /etc/nginx/runtime/upstream.conf  # healthy routers
ls var/run/sockets                  # sockets must exist (llama-1.sock, llama-2.sock, webui.sock)
docker compose logs llama-1 llama-2 | grep -iE 'router|models-dir'  # router mode active
curl -k https://localhost:11437/v1/models  # smoke test the pool (needs a model)
```

Validate a collector pipeline without starting the stack (the config files
reference `${env:...}`, so the vars must be present):

```sh
docker run --rm -v "$(pwd)/otel/collector:/etc/collector:ro" \
  -e COLLECTOR_LOG_LEVEL=info -e COLLECTOR_DEBUG_VERBOSITY=basic \
  -e LLAMA_SCRAPE_INTERVAL=15s -e LLAMA_SCRAPE_MODEL= -e 'LLAMA_SCRAPE_TARGETS=[]' \
  otel/opentelemetry-collector-contrib:0.158.0 validate --config=/etc/collector/local.yaml
```

After changing behavior, start the stack (`docker compose up --build -d`) and run
the smoke tests from the README.

## Stack notes

- Both `llama-server` instances run in **router mode** (no `LLAMA_ARG_MODEL`):
  models are discovered from `var/lib/llama` at startup and served on demand.
- **Adding a model is a zero-config change** (no compose edit): drop a `.gguf`
  into `var/lib/llama/` then `docker compose restart llama-1 llama-2`. The
  model ID is the filename without the `.gguf` extension. Discovery happens at
  startup only — the running server has no live rescan endpoint.
- Models load into their own child `llama-server` process on first request and
  are LRU-evicted per router when `LLAMA_ARG_MODELS_MAX` is reached. Two routers
  means up to `2 x MODELS_MAX` models can be resident across the pool (each
  router evicts independently) — total is bounded by GPU memory.
- Two routers are kept for redundancy: the nginx health checker drops a
  restarting router from the pool, the other keeps serving, and its models
  reload on demand. With round-robin balancing, a model can be hot on both
  routers simultaneously — that temporarily doubles VRAM for that model.
- Sharded/multi-file GGUFs are not auto-discovered; they need a presets INI
  (`LLAMA_ARG_MODELS_PRESET`) pointing at the first shard.

## Telemetry overlay notes

- `docker-compose.otel.yml` is **additive and off by default** (gated by
  `COMPOSE_FILE` in `.env`). Keep it that way: the base stack must run
  identically with the overlay absent. It is not standalone either — it attaches
  the collector to the `llama` network, which `docker-compose.yml` defines.
- OBI discovery cannot key on port alone here: the routers and the webui both
  listen on 8080, so `otel/obi/config.yaml` pairs each with an `exe_path` glob
  (`*/llama-server`, `*/python*`). Selectors within one entry are ANDed. If you
  change images, re-check those globs.
- The per-model child processes take an ephemeral port, so they are outside
  `open_ports: 8080` on purpose — instrumenting them would double-count the
  router -> child hop.
- `nginx.conf` denies `location = /metrics` on `:11437` on purpose, so engine
  metrics stay inside the `llama` network. Keep the exact-match form: a prefix
  match would also swallow paths like `/metrics-foo`, and the collector needs
  the endpoint reachable container-to-container, not through nginx.
- Any scrape of a router's `/metrics` **must** pass `autoload=false`. Router mode
  loads a model on demand for a plain `GET /metrics?model=X`, so a recurring
  scrape without that guard pulls LRU-evicted models back into VRAM on a timer.
- `.env` is the only knob surface. Nothing in `otel/` should need editing for a
  routine change; if it does, add an env var with a default instead.

## Never commit

The README's security notes cover why secrets stay local; `.gitignore` excludes
the following, so keep it that way:

- `var/` — runtime data (model files, SQLite DB, sockets) and user chat data.
- `nginx/certs/` — private CA keys and certificates.
- Any `*.key`, `*.crt`, `*.pem`, `*.csr`, `*.sock`, `*.log`.
- `.env` — local settings, and the only file that may hold an OTLP backend token
  (`OTLP_FORWARD_AUTHORIZATION`). `.env.example` is the tracked template.

## Diagrams

Diagram sources are Mermaid `.mmd` files in `docs/diagrams/`; the README
references the rendered `*.svg`. When you change a `.mmd`, regenerate both
formats:

```sh
docker run --rm --user 1000:1000 \
  -v "$(pwd):/data" minlag/mermaid-cli \
  -i /data/docs/diagrams/NAME.mmd -o /data/docs/diagrams/NAME.svg
docker run --rm --user 1000:1000 \
  -v "$(pwd):/data" minlag/mermaid-cli \
  -i /data/docs/diagrams/NAME.mmd -o /data/docs/diagrams/NAME.png -b white
```

Note: the mermaid-cli image runs as uid 1001 by default; the `--user 1000:1000`
flag is required so it can write into the bind-mounted `docs/` tree.
