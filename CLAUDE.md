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

## Watchtower

- Watchtower uses `WATCHTOWER_LABEL_ENABLE=true` — only updates containers with `com.centurylinklabs.watchtower.enable=true`.
- Core infra (traefik, socket-proxy, portainer, dozzle, cloudflared, pihole) now have this label.

## Plex

- Intentionally on the `default` network (not `t3_proxy`) for local network discovery.
- Ports are exposed directly for local access. Do not change this.

## SSH / Docker

- SSH alias: `nas` → `bassfja33@192.168.1.104`
- Docker commands require sudo (interactive password — must be run in user's own terminal).
- File sync: `push.sh` / `pull.sh` in project root.
- `apps.yml` is outside the synced directory — edit it directly on the NAS.
