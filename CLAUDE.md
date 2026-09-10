# NAS Docker Project Notes

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

**Rule:** Every route in `apps.yml` must have a middleware chain. Use `chain-basic-auth` for any service that doesn't have its own login screen. Use `chain-no-auth` for services that do (e.g. Sonarr, Radarr, Plex, Portainer, Tautulli, Seerr).

## Watchtower

- Watchtower uses `WATCHTOWER_LABEL_ENABLE=true` — only updates containers with `com.centurylinklabs.watchtower.enable=true`.
- Core infra (traefik, socket-proxy, portainer, dozzle, cloudflared, pihole) now have this label.

## Plex

- Intentionally on the `default` network (not `t3_proxy`) for local network discovery.
- Ports are exposed directly for local access. Do not change this.

## SSH / Docker

- SSH alias: `nas` → `bassfja33@192.168.1.104`
- **Passwordless sudo IS configured** — `ssh nas 'sudo ...'` works non-interactively.
  (An earlier version of this file said sudo was interactive. It is not.)
- **`sudo docker` does NOT work — use `sudo /usr/local/bin/docker`.** Docker is not
  on root's PATH. This is the single most common time-waster on this box.
- File sync: `push.sh` / `pull.sh` in project root.
- `apps.yml` is outside the synced directory — edit it directly on the NAS.
- **Always `./pull.sh` and check `git status` before `./push.sh`.** The NAS has been
  ahead of git before; pushing blindly would have downgraded Traefik to an EOL
  version and reintroduced a broken `maintainerr.yml`.

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

A hardened self-hosted AI agent runs here (`compose/hermes.yml`, plus
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

---

# Docker API over the socket proxy

> Belongs with **SSH / Docker** above — it is a general convenience for this NAS,
> not part of the Hermes section that precedes it.

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
