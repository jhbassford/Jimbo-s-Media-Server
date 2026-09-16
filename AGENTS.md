# NAS Docker Project Notes

## Start here

This repo is **Jimbo's Media Server** — a Docker Compose stack for a Synology
DS920+ NAS (`ssh nas`): Plex, Sonarr, Radarr, SABnzbd, etc., behind Traefik and
a Cloudflare tunnel.

It **also hosts Hermes** — a hardened, self-hosted LLM agent — under the `# AGENT`
heading in `docker-compose.yml`. Hermes is not part of the media stack. It is
assumed prompt-injectable, so it is contained rather than trusted. Read the
[Hermes agent](#hermes-agent) section below, and the spec, before changing
anything near it.

`CLAUDE.md` merely imports this file (`@AGENTS.md`), so this is the single source
of truth for both opencode and Claude Code — edit here, not there.

## Architecture

- **Traefik routing is managed via `apps.yml` on the NAS**, not docker labels.
  - Path: `/volume1/docker/appdata/traefik3/rules/udms/apps.yml`
  - This file is NOT synced by push.sh — edit it directly on the NAS via SSH.
  - Traefik watches this directory and reloads automatically on changes (no restart needed).
- Docker labels on containers have `traefik.enable=false` intentionally — they are reference/fallback config only.
- Do NOT set `traefik.enable=true` on containers that already have a file rule in `apps.yml`. It creates a duplicate router conflict and breaks routing.

## Cloudflare Tunnel

- cloudflared runs with `network_mode: host` (not on `t3_proxy`), connecting to Traefik at `https://localhost:4443`.
- Tunnel ingress: `*.bassford.net` → `https://localhost:4443` with `noTLSVerify` and `matchSNItoHost`.
- The wildcard DNS `*.bassford.net` points to `ddnsupdate.bassford.net` (DDNS/public IP), **NOT** the tunnel.
- **Each service exposed via the tunnel needs its own CNAME** in Cloudflare DNS pointing to `<tunnel-id>.cfargotunnel.com`. Without it, traffic bypasses the tunnel and you get a 522.
- When adding a new service: (1) add Traefik route in `apps.yml`, (2) create CNAME in Cloudflare DNS.

## Traefik Entrypoints

- All file rules in `apps.yml` must use `websecure` entrypoint — the Cloudflare tunnel connects to Traefik via HTTPS.
- The `web` entrypoint is HTTP-only and redirects to `websecure`. File rules on `web` will not be hit by Cloudflare traffic.

## Middleware Chains

Defined in `/volume1/docker/appdata/traefik3/rules/udms/`:
- `chain-no-auth` — rate limit + secure headers (for services with their own login)
- `chain-basic-auth` — rate limit + secure headers + HTTP basic auth (for services without login)

**Rule:** Every route in `apps.yml` must have a middleware chain. Use `chain-basic-auth` for any service that doesn't have its own login screen. Use `chain-no-auth` for any service that does (e.g. Sonarr, Radarr, Plex, Portainer, Tautulli, Seerr).

## Watchtower

- Watchtower uses `WATCHTOWER_LABEL_ENABLE=true` — only updates containers with `com.centurylinklabs.watchtower.enable=true`.
- Core infra (traefik, socket-proxy, portainer, dozzle, cloudflared, pihole) now have this label.

## Plex

- Intentionally on the `default` network (not `t3_proxy`) for local network discovery.
- Ports are exposed directly for local access. Do not change this.

## SSH / Docker

- SSH alias: `nas` → `bassfja33@192.168.1.104`
- `sudo` is passwordless: `ssh nas 'sudo ...'` works non-interactively.
- `sudo docker` does **not** work — use `sudo /usr/local/bin/docker` (Docker is not on root's PATH).
- File sync: `push.sh` / `pull.sh` in project root.
- `apps.yml` is outside the synced directory — edit it directly on the NAS.
- **Always `./pull.sh` and check `git status` before `./push.sh`.** The NAS has been
  ahead of git before; pushing blindly would have downgraded Traefik to an EOL
  version and reintroduced a broken `maintainerr.yml`.

## Docker API over the socket proxy

**There are two socket proxies on this box. Do not confuse them.**

| Proxy | Address | Scope |
|---|---|---|
| `socket-proxy` (tecnativa) | `localhost:2375` | **Permissive.** `POST=1`, `CONTAINERS=1`, `IMAGES=1`, `VOLUMES=1` — it can create containers, which on this host is equivalent to root (mount `/` into a new container). Serves Traefik, Portainer, Dozzle, Watchtower. This is the one described below. |
| `hermes-socket-proxy` (wollomatic) | `192.168.93.2:2375`, `hermes_socket` net only | **Restricted.** Read endpoints plus `restart` of eight named containers. Exists so the agent never touches the permissive one. Never point Hermes at `localhost:2375`. |

The permissive proxy is accessible at `localhost:2375` on the NAS — use it via SSH instead of `sudo docker`:

```bash
# Pull image
ssh nas "curl -s -X POST 'http://localhost:2375/images/create?fromImage=image%2Fname&tag=latest'"

# Create container
ssh nas "curl -s -X POST http://localhost:2375/containers/create?name=mycontainer \
  -H 'Content-Type: application/json' -d '{...}'"

# Start container
ssh nas "curl -s -X POST http://localhost:2375/containers/mycontainer/start"

# Stop / remove
ssh nas "curl -s -X POST http://localhost:2375/containers/mycontainer/stop"
ssh nas "curl -s -X DELETE http://localhost:2375/containers/mycontainer"

# Logs
ssh nas "curl -s 'http://localhost:2375/containers/mycontainer/logs?stdout=1&stderr=1&tail=50'"

# Inspect
ssh nas "curl -s http://localhost:2375/containers/mycontainer/json"
```

Networks are referenced by name (e.g. `t3_proxy`). Always create the appdata directory before starting if the image runs as non-root (e.g. `mkdir -p /volume1/docker/appdata/myservice && chmod 777 /volume1/docker/appdata/myservice`).

---

# Environment quirks — read before debugging

Learned the hard way on this specific box. Several of these silently produce
wrong results rather than errors.

## Docker / compose

- **Never put a top-level `networks:` block in an included compose file.** A stray
  one in `maintainerr.yml` once broke *every* compose command on this NAS.
  Networks are declared only in the root `docker-compose.yml`.
- **Never run a bare `docker compose up -d`** — always name the service. A bare up
  recreates the whole live stack (Plex mid-stream, *arr, Pi-hole DNS for the house).
- `pihole_network` is **macvlan**. The host cannot reach its own macvlan container,
  so `nslookup google.com 192.168.1.105` from the NAS times out even when Pi-hole
  is healthy. Test DNS from a real LAN client.
- Docker 24.0.2 (API 1.43), compose v2.20.1.

## Kernel — DSM 4.4.302

- **No `CONFIG_CGROUP_PIDS`.** `pids_limit` is silently discarded and
  `docker inspect` reads back `nil`. It fails quietly, so you will think it applied.
- **No CFS bandwidth control.** Setting `cpus:` makes compose **refuse to create the
  container at all**. At least that one is loud.
- Substitutes that do work: `ulimits: nproc` (POSIX rlimit, no cgroup dependency)
  and `cpu_shares` (needs `CONFIG_FAIR_GROUP_SCHED` — a different symbol from the
  missing CFS one; the `cpu` controller IS mounted).
- No cgroup v2, therefore no rootless Docker, therefore no nested sandbox.

## iptables — the nastiest gotchas here

- **Built-in chains cannot be addressed by name.** `-S INPUT` / `-S OUTPUT` error
  with "No chain by that name"; `-S FORWARD` prints `DEFAULT_FORWARD`'s rules.
  Custom chains are fine.
- **`iptables -D` against a built-in returns 0 UNCONDITIONALLY.** With no such rule
  present, `-C INPUT` correctly reports absent while `-D INPUT` claims success. The
  usual `while iptables -D ...; do :; done` idiom therefore **never terminates** —
  it hung a deploy until the session was killed. Never loop on `-D` against a
  built-in; never trust its exit status.
- So hook `INPUT_FIREWALL` (a custom chain, and the only rule in `INPUT`) rather
  than `INPUT`. A rule inserted into a built-in might also not be removable.
- Real forward path: `FORWARD → FORWARD_FIREWALL → DEFAULT_FORWARD → DOCKER-USER`.
- `DOCKER-USER` is reached only from `FORWARD`. **Container→host traffic goes via
  `INPUT`**, so host-published ports stay reachable unless you add an INPUT rule.
- `/usr/bin/iptables` is a Synology wrapper around `xtables-legacy-multi` that
  retries on EAGAIN.
- **Verify with `iptables-save`, never `iptables -L INPUT`.**
- DSM does not persist iptables rules across reboot.

## systemd

- DSM 7 runs **real systemd 219**.
- No `systemctl --now` — enable and start are separate commands.
- **`Type=oneshot` + `RemainAfterExit=yes` makes `start` a NO-OP** once the unit has
  run, which silently breaks any timer that activates it by starting it. Measured,
  not theorised.
- Custom units in `/etc/systemd/system` work, but a DSM major upgrade can remove
  them. Re-check `systemctl is-enabled` afterwards.
- **`synoschedtask` has no `--add`** — Task Scheduler entries are GUI-only. Prefer
  systemd units/timers; DSM also swallows non-zero exits unless "send run details
  by email" is ticked.
- Synology binaries live in `/usr/syno/bin`, off root's PATH.

## Missing tools on the NAS host

- `python3` has **no `yaml` module**. A script that parsed with PyYAML compared two
  identical `ModuleNotFoundError` strings and reported "unchanged" — a silent false
  pass. Prefer awk/sed host-side.
- `conntrack` not installed (cannot flush stale flows; restart the container).
- `crontab` the command is missing, but `crond` runs and `/etc/crontab` is real.
- `strings` not available.
- **`scp` to this NAS is broken** (SSH subsystem error). Use
  `ssh nas 'cat > /path/file' < localfile`.

## Traefik / Cloudflare testing

- Testing a route with only a `Host:` header returns **421 Misdirected Request** —
  Traefik uses `matchSNItoHost`, so SNI must match too. Use
  `curl --resolve host:443:192.168.90.254 https://host/`.
- Cloudflare Access changes take **minutes to propagate**. An early probe showing
  the origin's response does not mean the app is misconfigured.
- `/cdn-cgi/access/login` returns **404 even when Access IS active** — the real path
  includes the app hostname. Test the hostname root and look for a 302.
- `dozzle.bassford.net` currently returns 522 — it is missing its tunnel CNAME.

## Remote access to this NAS

There is **none**, verified four ways: QuickConnect not enabled, zero UDM VPN
servers, no DSM route on the tunnel, only the Plex `32400` port forward. Anything
needing the DSM GUI requires the operator on the LAN.

---

# Hermes agent

A hardened self-hosted LLM agent runs here (`compose/hermes.yml`, plus
`hermes-socket-proxy.yml` and `hermes-egress-proxy.yml`). It is assumed
prompt-injectable and contained accordingly — read the spec before changing
anything near it.

- Design + threat model: `docs/superpowers/specs/2026-09-09-hermes-agent-nas-design.md`
- Build plan with AS-BUILT notes: `docs/superpowers/plans/2026-09-09-hermes-agent-nas.md`
- Config templates with required ownership/mode: `appdata-templates/README.md`
  (git preserves neither — that file is the record)
- Containment regression suite: `docs/superpowers/verify/hermes-threat-model.sh`.
  Run it after any change near the agent; it must stay green.

Host-side scripts in `/volume1/docker/scripts/`, NOT synced by `push.sh` (sources
in `appdata-templates/scripts/`): `hermes-firewall.sh` — the egress-enforcement
boundary, and the one control here that fails OPEN if it goes missing —
`hermes-guardrail-check.sh`, and `hermes-set-model.sh`.

### The three services

| Service | What it is |
|---|---|
| `hermes-socket-proxy` | A **second, separate** Docker socket proxy — `wollomatic/socket-proxy`, which filters by HTTP method *and* path regex. It grants the agent read plus `POST /containers/<name>/restart` for an explicit list of media containers, and nothing else. The stack's existing `socket-proxy` filters by path prefix only and cannot express "restart but not delete"; anything that can create a container can mount `/` and is root on the NAS. The agent is **never** attached to `socket_proxy`. |
| `hermes-egress-proxy` | A Tinyproxy forward proxy with a default-deny domain allowlist and `ConnectPort 443` only, so it cannot be used as a generic TCP tunnel. This is the **allowlist**. |
| `hermes` | The agent itself: non-root (`1000:10`), `read_only: true`, `cap_drop: ALL`, `no-new-privileges`, memory/CPU/rlimit capped, **no published host ports at all** — reachable only as `http://hermes:9119` from Traefik. Pinned by digest, with no Watchtower label: a self-updating agent is a supply-chain hole. |

### Things that are easy to get wrong

- **The egress proxy is only the allowlist, not the enforcement.**
  `HTTP_PROXY`/`HTTPS_PROXY` are advisory — any library that ignores them walks
  straight past. Enforcement is `/volume1/docker/scripts/hermes-firewall.sh`,
  which drops traffic from the agent's static IPs in `DOCKER-USER` **and** on
  the `INPUT` path. Without that script the agent is completely uncontained,
  and nothing anywhere reports an error. It is the one part of this design that
  fails **open**.
- **`push.sh` syncs only `docker-compose.yml` and `compose/`.** Everything in
  `appdata-templates/` — the read-only config the agent is not allowed to
  rewrite, the egress allowlist, and the firewall script — must be delivered to
  the NAS **separately**, with specific ownership and modes. Git preserves
  neither, so `appdata-templates/README.md` is the only record. Follow it.
- **Bind-mount targets must exist on the host first.** Docker silently creates
  a *directory* at a bind-mount source that does not exist. A directory at
  `/etc/passwd` or `/opt/data/config.yaml` breaks the container.
- **The agent's guardrails are deliberately not writable by the agent.**
  `config.yaml` and `.env` live in `appdata/hermes-etc` (root-owned, mounted
  `:ro`), not in the read-write `/opt/data` state directory. Changing a control
  is an operator action on the host followed by a restart. That is intentional:
  otherwise a hijacked agent could rewrite its own limits and restart itself to
  load them.

### Status

Tasks 1–7 of 8 (`docs/superpowers/plans/2026-09-09-hermes-agent-nas.md`) are
implemented. Host firewall (Task 4), secrets (Task 6), the threat-model
acceptance test (Task 7), Cloudflare ingress and the UniFi work are done or
running live — **the Hermes container is RUNNING in production**, verified
2026-09-14 (`hermes-threat-model.sh`: 89 passed, 0 failed, including the
private SearXNG, private web extractor, PocketSmith and Hindsight sections).

`web_extract` works as of 2026-09-14, via a private trafilatura extractor at
`192.168.96.3` (`compose/hermes-extract.yml`, built from `build/hermes-extract/`).
It reads HTML (trafilatura) and PDF (pypdf); no OCR, no JS rendering.
It is wired in as `web.extract_backend: tavily` + `TAVILY_BASE_URL` — a
transport detail only; nothing reaches api.tavily.com. **The `firecrawl`
provider is not an option here**: it lazy-imports `firecrawl-py`, which cannot
be installed into a `read_only` container whose venv is on the image.
Unlike SearXNG, this peer is firewalled OUT of all private space — it fetches
arbitrary URLs, so unrestricted egress would make it SSRF-as-a-service. Note
that `tools/url_safety.is_safe_url` does **not** cover that: it returns True for
any hostname in this deployment, because the agent's DNS is blocked and it then
delegates resolution to the proxy. The "deliberately left
stopped" note below is stale history from before the firewall and secrets
landed; do not stop Hermes on its basis.
