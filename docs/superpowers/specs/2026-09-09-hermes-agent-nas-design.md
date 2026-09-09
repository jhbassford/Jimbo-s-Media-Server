# Hermes Agent on the NAS — Design

Date: 2026-09-09
Status: Approved (design); implementation plan pending

## 1. Goal

Run a self-hosted agentic assistant on the Synology DS920+ (`jimbos-server`,
192.168.1.104) serving three roles:

1. Personal assistant reachable from chat platforms.
2. Home/NAS ops assistant (read + restart containers).
3. Coding agent operating on local repositories.

It must be hardened on the NAS and, to whatever extent the topology genuinely
allows, on the UniFi Dream Machine.

## 2. Tool selection: Hermes Agent

Chosen: **Hermes Agent** (Nous Research), `nousresearch/hermes-agent`.

Rejected: **OpenClaw**. Its distinguishing advantage was messaging breadth, but
Hermes covers Telegram, Discord, Slack, WhatsApp, Signal, SMS, Email, Matrix,
Teams and Home Assistant — parity for home use. What remains is a materially
worse default posture:

- OpenClaw container images default to an exposed bind.
- CVE-2026-25253: unauthenticated Control-UI WebSocket RCE to host code exec.
- "ClawHavoc" (Jan 2026): supply-chain compromise of the ClawHub skill registry,
  including payloads that wrote into agent memory files.
- Its own docs state it "is not a hostile multi-tenant security boundary."

Hermes by contrast fails **closed**: since the June 2026 hardening a non-loopback
bind without an auth provider refuses to serve, and v0.20.4 performs license and
security scanning on skill installs.

## 3. Constraints discovered

These shaped the design and must not be silently reversed.

**C1 — The existing socket-proxy cannot express the required permission.**
`compose/udms/socket-proxy.yml` runs `tecnativa/docker-socket-proxy` with
`POST=1`, `CONTAINERS=1`, `IMAGES=1`, `VOLUMES=1`. That proxy filters by API
*path prefix only*; it cannot permit `POST /containers/*/restart` while denying
container create/delete. Anything able to create a container can mount `/` and is
root on the NAS. A separate, method-aware proxy is therefore required.

**C2 — Hermes' docker-terminal sandbox is unavailable.**
That backend sandboxes by *creating containers*, i.e. exactly the privilege C1
refuses. A nested rootless daemon is also unavailable: DSM runs kernel 4.4.302,
so no cgroup v2 and no rootless Docker. Consequence: the Hermes container is
itself the sandbox and is hardened accordingly.

**C3 — The router cannot see agent traffic.**
Docker containers SNAT to the NAS's own IP. The UDM cannot distinguish Hermes'
egress from Plex's. Per-agent egress filtering at the router is not achievable in
this topology; it belongs on the NAS.

**C4 — Ingress is Traefik-mediated.**
Tunnel ingress is `*.bassford.net` → Traefik at `https://localhost:4443`. Each
service needs a file rule in `apps.yml` (on the NAS, outside the synced tree) and
its own CNAME to `<tunnel-id>.cfargotunnel.com`.

**C5 — `push.sh` syncs the whole `compose/` tree.**
Seven compose files are modified locally and unpushed, including
`socket-proxy.yml` flipping `privileged: true → false`. Deploying Hermes via
`push.sh` would carry those changes to the NAS as a side effect. Must be resolved
deliberately before deployment.

## 4. Architecture

### 4.1 Placement and identity

- New `compose/hermes.yml`, included from `docker-compose.yml`.
- Runs as `PUID=1000` / `PGID=10`. Never root; `HERMES_ALLOW_ROOT_GATEWAY` unset.
- State: `/volume1/docker/appdata/hermes` → `/opt/data`, mode `0700`.
- Image pinned by **digest**, not `:latest`.
- Watchtower label deliberately omitted (`WATCHTOWER_LABEL_ENABLE=true` means no
  label = no auto-update). A self-updating agent is a supply-chain hole.

### 4.2 Container hardening

- `cap_drop: ALL`
- `security_opt: no-new-privileges:true`
- `read_only: true`, with tmpfs for `/tmp` and `/run`. The image uses s6-overlay
  as PID 1, which may require additional writable paths; if `read_only` prevents
  boot, the fallback is to add narrowly-scoped tmpfs mounts for exactly the paths
  s6 needs — not to drop `read_only`. Verify during implementation.
- `mem_limit: 4g`, `cpus: 2.0`, `pids_limit`
- Filesystem reach limited to `/opt/data` and a dedicated `/volume1/code` bind
  for the coding role. No media shares, no `/volume1/docker` root, no `/etc`.
- Browser/Playwright disabled initially (Chromium on a J4125 is impractical).
  If later enabled, requires `shm_size: 1g`.

### 4.3 Ops access — restricted socket proxy

A second proxy, `hermes-socket-proxy`, using **`wollomatic/socket-proxy`**, which
allowlists by HTTP method *and* path regex, runs non-root with a read-only
rootfs. On a private bridge shared only with Hermes.

Allowlist, exhaustively:

| Method | Path |
|---|---|
| GET | `/containers/json` |
| GET | `/containers/<id>/json` |
| GET | `/containers/<id>/logs` |
| GET | `/containers/<id>/stats` |
| GET | `/version`, `/info` |
| POST | `/containers/<id>/restart` |

Everything else returns 403: no exec, create, delete, images, volumes, build.
Hermes is **never** attached to the existing `socket_proxy` network, which
remains untouched.

### 4.4 Ingress

Defence in depth, outermost first:

1. **Cloudflare Access** on the hostname — single-user policy (owner's email),
   SSO + MFA, short session lifetime.
2. **Cloudflare WAF** rate limiting.
3. **Tunnel** — outbound-only; no UDM port-forward exists or is created.
4. **Traefik** file rule in `apps.yml` on `websecure`, using `chain-basic-auth`
   (rate limit + secure headers + basic auth).
5. **Hermes' own mandatory dashboard auth** at the origin
   (`HERMES_DASHBOARD_BASIC_AUTH_*`).

Hermes joins `t3_proxy` and publishes **no host ports at all** — not even
loopback. It is unreachable from the LAN; only Traefik can reach it, over the
Docker network. The API server (8642) is never published.
`dashboard.trusted_proxies` is bounded to Traefik's `t3_proxy` address; never
`0.0.0.0/0`.

Requires a CNAME for the chosen hostname → `<tunnel-id>.cfargotunnel.com`, per C4.

### 4.5 Egress

Per C3, enforced on the NAS, not the router.

Note that Hermes is attached to **two** networks — `t3_proxy` (ingress from
Traefik only) and its own `hermes_net` (egress). Filtering must therefore match
the **container's own source IPs**, not a bridge interface: blocking the
`t3_proxy` bridge would break every other proxied service on it, and a
multi-homed container's choice of egress interface is not otherwise guaranteed.

- Hermes is assigned a **static IP on each attached network**.
- `DOCKER-USER` rules deny direct outbound from those source IPs specifically.
- Traffic is forced through a small domain-allowlisting forward proxy.
- Allowlist: OpenRouter, the configured messaging platforms, package registries,
  GitHub. Nothing else.

This is a real containment boundary; an equivalent UDM rule would not be, because
the router cannot attribute the traffic.

### 4.6 UDM responsibilities

Three things the router genuinely contributes:

1. **Assert no inbound path.** Audit and remove any port-forward touching
   192.168.1.104. The tunnel is outbound-only and correctly bypasses the UDM.
2. **Lateral containment.** Zone policy restricting the NAS *as a source* from
   reaching UDM management and the IoT VLAN (192.168.2.0/24, VLAN 20), so an
   agent compromise cannot pivot to IoT devices or the router UI.
3. **Detection.** IDS/IPS and malicious-domain blocking on the Default zone, with
   the NAS's outbound logged so anomalous destinations surface.

### 4.7 Agent-level controls

- Messaging **sender allowlist** — owner's account IDs only. An open bot is an
  open shell.
- Remote skill auto-install **disabled**; manual install only, relying on
  v0.20.4 scanning.
- `tool_loop_guardrails.non_interactive_hard_stop_enabled: true`.
- Dedicated OpenRouter key with a hard monthly credit cap.
- Git access via fine-grained PAT or per-repo deploy keys — never an
  account-wide token.

## 5. Threat model

The design targets **prompt injection**, not port scanning — there is no inbound
path to scan. The realistic attack is the agent ingesting hostile instructions
from a web page, email, or chat message and acting on them.

Success criterion: a **fully hijacked agent** still cannot

- delete, create, or exec into any container (§4.3);
- escalate to root on the NAS (§4.2, C2);
- reach the IoT VLAN or the router UI (§4.6);
- exfiltrate to an arbitrary internet host (§4.5);
- read media shares or other services' config (§4.2);
- silently update its own code (§4.1).

## 6. Explicitly out of scope

- **Backups.** Per the settled decision of 2026-09-08, the NAS has no backup by
  choice. Not revisited here.
- **Local model inference.** The J4125 has no GPU; not viable for agentic work.
  Backend is OpenRouter (multi-provider).
- **Migration to a VMM VM on its own VLAN.** Considered and deferred. It is the
  only way to make the UDM a real enforcement point for the agent (C3), and this
  design is structured so the lift is non-destructive if wanted later.

## 7. Open items for implementation

- Choose the dashboard hostname and create its CNAME.
- Resolve C5 before the first `push.sh`.
- Select the forward-proxy implementation for §4.5.
- Decide which repos `/volume1/code` exposes.
