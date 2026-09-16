---
name: nas-ops
description: Diagnose and restart broken Plex or download containers.
version: 0.1.0
author: James Bassford, Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [NAS, Docker, Plex, downloads, ops, restart, Synology]
    category: nas
---

# NAS Ops Skill

You maintain the home Synology NAS Docker stack. Through a restricted Docker
socket proxy you can **read** any container's state and logs and **restart** a
fixed allowlist of media containers. You cannot edit configuration, run commands
inside a container, or reach the Plex/*arr/SAB web UIs — when a fix needs any of
those, say so and hand it to the operator instead of thrashing.

## When to Use

- Operator says Plex will not play, buffers, or will not load.
- Operator says downloads are broken, stuck, or not grabbing.
- Operator asks you to check the NAS or a specific container's health.
- Don't use for: config/credential/indexer fixes, adding or removing containers,
  backups, or non-media services (Traefik, Pi-hole, Home Assistant, …). Those are
  outside this skill's reach by design.

## Prerequisites

- Everything here runs through the `terminal` tool. The `docker` CLI is **not**
  available and `docker *` is on the deny list — **use `curl` against the socket
  proxy, never the `docker` binary.**
- Proxy base URL: `http://192.168.93.2:2375`. It is directly reachable (it is in
  `NO_PROXY`) and needs no credentials.
- `jq` is available at `/opt/hermes-bin/jq`.
- Sanity check: `curl -s -o /dev/null -w '%{http_code}\n' http://192.168.93.2:2375/version` → `200`.

## How to Run

Every action is a `terminal` call issuing `curl` (optionally piped to `jq`) at the
proxy. Read requests are always allowed. The **only** write is a restart of one of
these names:

    plex  radarr  sonarr  bazarr  sabnzbd  seerr  tautulli  maintainerr

The proxy refuses everything else (403/404/405) and there is no way around it.
That refusal is policy, not a fault — do not retry it.

## Container Map

| Container | Role | Restarts? |
|---|---|---|
| `plex` | Plex Media Server (playback) | yes |
| `sabnzbd` | Usenet download client (the actual downloader) | yes |
| `radarr` | Movie library manager (sends to SAB) | yes |
| `sonarr` | TV library manager (sends to SAB) | yes |
| `bazarr` | Subtitles only (never blocks downloads) | yes |
| `seerr` | Media request UI | yes |
| `tautulli` | Plex watch stats | yes |
| `maintainerr` | Media cleanup | yes |
| `traefik`, `cloudflared`, `pihole`, `socket-proxy`, `dozzle`, `portainer`, `watchtower`, `homeassistant`, `redbot`, `hermes*` | infra — **not restartable** | no |

## Quick Reference

```bash
# List every container and its state (run via terminal)
curl -s 'http://192.168.93.2:2375/containers/json?all=1' \
  | jq -r '.[] | [(.Names[0] | ltrimstr("/")), .State, .Status] | @tsv'

# One container's status, health and restart count
curl -s http://192.168.93.2:2375/containers/sabnzbd/json \
  | jq -r '[.State.Status, (.State.Health.Status // "no-healthcheck"), (.RestartCount | tostring)] | @tsv'

# Last 100 log lines with timestamps (strip the API stream framing bytes)
curl -s 'http://192.168.93.2:2375/containers/sabnzbd/logs?stdout=1&stderr=1&timestamps=1&tail=100' \
  | tr -d '\000-\010\013\014\016-\037'

# Restart one container (expect HTTP 204, no body)
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  'http://192.168.93.2:2375/containers/sabnzbd/restart?t=30'
```

## Procedure

1. **Map the complaint to a container.** Plex playback → `plex`. "Downloads
   broken" → `sabnzbd` first, then `radarr`/`sonarr` (they hand downloads to SAB).
   Completion: you have named the one container you will investigate.
2. **Read its current state** with the inspect call above. Completion: you know
   `running`/`exited`/`restarting`, health, and `RestartCount`.
3. **Read the last ~100 log lines** and classify the failure. Look for: a clean
   crash loop, an out-of-memory kill, a database/lock error, or a
   **config/credential/permission error** (bad API key, indexer 401/403, "no
   space left", "permission denied"). Completion: one sentence naming the
   failure class and the log line that shows it.
4. **If the failure is a transient wedge or crash**, restart that one container
   (the POST above). Do not restart healthy neighbours. Completion: you received
   `204`.
5. **Re-check after ~15 seconds**: state is `running`, and `RestartCount` went up
   by exactly 1. Completion: both true.
6. **Report**: container, what you saw, the log line, what you did, and the
   current state.

## Pitfalls

- **Never use the `docker` CLI** — it is denied and absent. `curl` only.
- **Restart only the eight allowlisted names.** Attempting Traefik, Pi-hole,
  Cloudflare or `hermes*` fails and, for Pi-hole/Traefik, would take down DNS or
  remote access for the whole household if it ever worked.
- **A restart is not a fix for a config problem.** If step 3 found a
  credential/indexer/permission/disk error, restarting will not help. Stop and
  report the cause to the operator — do not loop restarts.
- **Restart at most once per incident**, then re-check. A rising `RestartCount`
  means a crash loop, not something another restart will cure.
- **Read logs before restarting anything.** Restarting first destroys the
  evidence (log tail) that explains the failure.
- **Raw log output is framed** with non-printable stream headers; always pipe it
  through `tr -d '\000-\010\013\014\016-\037'` or it is unreadable.
- **External DNS is blocked.** Do not resolve hostnames; use the proxy IP.
- Restarting media containers briefly interrupts the household — act
  deliberately, one container at a time.

## Verification

- The `POST .../restart` returned `204`.
- `containers/json` shows the container `running` with `Status` like
  `Up N seconds`.
- `RestartCount` increased by exactly 1.
- The fresh log tail shows a normal startup, not the previous fatal error
  repeating.
