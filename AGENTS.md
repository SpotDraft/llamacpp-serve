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
docker compose exec nginx nginx -t    # lint nginx config inside the container
docker compose exec nginx cat /etc/nginx/runtime/upstream.conf  # healthy routers
ls var/run/sockets                  # sockets must exist (llama-1.sock, llama-2.sock, webui.sock)
docker compose logs llama-1 llama-2 | grep -iE 'router|models-dir'  # router mode active
curl -k https://localhost:11437/v1/models  # smoke test the pool (needs a model)
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
  reload on demand. One model can be hot on both routers simultaneously (clients
  pinned to different routers via `ip_hash`) — that temporarily doubles VRAM for
  that model.
- Sharded/multi-file GGUFs are not auto-discovered; they need a presets INI
  (`LLAMA_ARG_MODELS_PRESET`) pointing at the first shard.

## Never commit

The README's security notes cover why secrets stay local; `.gitignore` excludes
the following, so keep it that way:

- `var/` — runtime data (model files, SQLite DB, sockets) and user chat data.
- `nginx/certs/` — private CA keys and certificates.
- Any `*.key`, `*.crt`, `*.pem`, `*.csr`, `*.sock`, `*.log`.

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
