# Project Instructions

## What this is

Docker Compose "core" stack for a home Linux server: AdGuard Home (DNS +
ad blocking), Homepage (start page on `HOMEPAGE_PORT` 3002, reachable as
`http://server.home:3002` via an AdGuard DNS rewrite; port 80 is avoided —
it causes bind errors), plus optional profile-gated services: Cloudflare
Tunnel (`tunnel`), Tailscale (`tailscale`). Public exposure goes through
Cloudflare Tunnel only; there is no reverse proxy in the stack. It is one of
several sibling stacks (e.g. `rnvegter/nextcloud`) and never shares a Docker
network with them.

## Files

- `docker-compose.yml` — 5 services; every value comes from `.env`
- `.env.example` — template, the committed source of all settings; `.env` holds secrets, never committed
- `setup.sh` — install (`--no-start` to prepare only) and `--update`; interactive, safe defaults when no TTY
- `backup.sh` — local tar.gz of `config/` + optional encrypted restic offsite to Hetzner Storage Box (includes `.env`); run with sudo on Linux
- `homepage/` — Homepage config templates, copied by setup.sh into `config/homepage/` (never overwritten later)
- `README.md` — the real documentation: step-by-step guides per service, written in simple English for non-technical readers. Keep that style.

## Conventions

- Bash scripts: `set -euo pipefail`, `cd "$(dirname "$0")"`, `info`/`warn`/`fail` helpers, `ask()` prompts that default to "no" without a TTY, portable sed in `set_env`.
- Compose: optional services go in a `profiles:` group; everything parameterized via `.env`; `restart: unless-stopped`.
- Commit style: short imperative subject, sometimes `Area: summary`. Direct commits to `main`, push to `origin`.

## Invariants when editing

- AdGuard admin: container port 80 ↔ host `ADGUARD_WEB_PORT` (8053); first-run wizard always port 3000.
- Homepage lives on `HOMEPAGE_PORT` (3002; avoid port 80 — it causes bind errors); `http://server.home:<port>` works via the AdGuard DNS rewrite.
- Homepage's `HOMEPAGE_ALLOWED_HOSTS` is an exact Host-header match: non-standard ports must appear as `host:port` (the compose lists `${SERVER_NAME}:${HOMEPAGE_PORT}` and `${SERVER_IP}:${HOMEPAGE_PORT}`).
- Any new hostname Homepage is opened on must be added to `HOMEPAGE_EXTRA_HOSTS` (feeds `HOMEPAGE_ALLOWED_HOSTS`).
- Apps reached via the tunnel use `host.docker.internal:host-gateway` (`extra_hosts`), not the Docker socket.
- Homepage container status goes through the read-only `socket-proxy` (CONTAINERS=1, POST=0), never the raw socket.
- New env var ⇒ add to `.env.example` (setup.sh's `sync_env` appends it to existing installs) and to the README settings table.
- New service ⇒ add a `*_TAG` var, decide always-on vs profile, update README table/guides, consider a Homepage tile in `homepage/services.yaml`.
- Never commit `config/`, `backups/`, `.env*`.
- Local backups = `config/` only; offsite snapshots = `config/` + `.env`, encrypted with `RESTIC_PASSWORD`.
- Public access goes through Cloudflare Tunnel; never forward ports on the router (docs-level rule the README enforces).

## Common commands

```bash
./setup.sh --no-start   # prepare .env, folders, config
./setup.sh              # install and start
./setup.sh --update     # pull images, recreate changed containers, prune
sudo ./backup.sh        # backup (local + offsite if enabled)
docker compose up -d    # apply .env changes
```
