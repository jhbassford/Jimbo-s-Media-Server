# Hermes Agent on the NAS — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Hermes Agent on the Synology DS920+ as a chat + NAS-ops + coding assistant, contained such that a fully prompt-injected agent cannot escalate, pivot, or exfiltrate.

**Architecture:** A hardened, non-root `hermes` container publishes no host ports. Ingress is Cloudflare Access → Cloudflare Tunnel → Traefik → the container over the `t3_proxy` Docker network. Docker access is mediated by a second, method-aware socket proxy that permits only read plus `restart`. Egress is allowlisted by a Tinyproxy forward proxy and *enforced* by `DOCKER-USER` iptables rules keyed on the container's static IPs.

**Tech Stack:** Docker Compose v2.20.1 (Docker 24.0.2, API 1.43), `nousresearch/hermes-agent`, `wollomatic/socket-proxy`, Tinyproxy, Traefik 3.7 (file-provider rules), Cloudflare Tunnel + Access, iptables.

**Spec:** `docs/superpowers/specs/2026-09-09-hermes-agent-nas-design.md`

## Global Constraints

- Host: `jimbos-server`, `192.168.1.104`, SSH alias `nas`. DSM kernel `4.4.302` — **no cgroup v2, no rootless Docker**.
- Docker socket: `/var/run/docker.sock`, `srw-rw---- root root`, **gid `0`**.
- Existing networks: `t3_proxy` = `192.168.90.0/24` (Traefik at **`192.168.90.254`**), `socket_proxy` = `192.168.91.0/24`. New networks must not collide.
- Hermes runs as `PUID=1000` / `PGID=10`. `HERMES_ALLOW_ROOT_GATEWAY` must remain **unset**.
- Hermes image pinned by **digest**, never `:latest`.
- **No** `com.centurylinklabs.watchtower.enable` label on any container in this plan (`WATCHTOWER_LABEL_ENABLE=true` means absent label = no auto-update).
- Hermes publishes **no host ports whatsoever**, not even loopback.
- Hermes is **never** attached to the `socket_proxy` network.
- `/volume1/docker` is **not** mounted into Hermes in any mode (it contains `secrets/`).
- Dashboard hostname: **`hermes.bassford.net`**.
- Traefik routes live in `/volume1/docker/appdata/traefik3/rules/udms/apps.yml` **on the NAS** — outside the synced tree, edited via SSH. Every route needs a middleware chain and the `websecure` entrypoint.
- **Standing rule: run `pull.sh` and reconcile before every `push.sh`.**
- Work on branch `hermes-agent`. Verification is by observed command output — no step is complete on assumption.

---

### Task 1: Restricted Docker socket proxy

Gives Hermes read + `restart` and nothing else. This is the control that makes "ops assistant" safe, so it is built and proven *before* Hermes exists.

**Files:**
- Create: `compose/hermes-socket-proxy.yml`
- Modify: `docker-compose.yml` (networks block; `include:` list)

**Interfaces:**
- Consumes: nothing.
- Produces: service `hermes-socket-proxy` reachable at `http://hermes-socket-proxy:2375` on network `hermes_socket` (`192.168.93.0/24`), proxy at `192.168.93.2`.

- [ ] **Step 1: Write the failing verification**

Create `docs/superpowers/verify/hermes-socket-proxy.sh` locally:

```bash
#!/bin/bash
# Asserts the restricted proxy allows exactly read + restart.
# Run from a container ON the hermes_socket network — the proxy is started with
# -allowfrom=192.168.93.0/24, so a host-side test via a published port may be
# rejected on source IP and produce misleading 403s on the "allow" checks.
set -u
P=http://192.168.93.2:2375
fail=0
chk() { # name expected_code method url
  code=$(curl -s -o /dev/null -w '%{http_code}' -X "$3" "$P$4")
  if [ "$code" = "$2" ]; then echo "PASS $1 ($code)"; else echo "FAIL $1: got $code want $2"; fail=1; fi
}
chk "GET /version"              200 GET    /version
chk "GET /info"                 200 GET    /info
chk "GET /containers/json"      200 GET    "/containers/json?all=1"
chk "GET plex inspect"          200 GET    /containers/plex/json
chk "GET plex logs"             200 GET    "/containers/plex/logs?stdout=1&tail=1"
chk "DENY container create"     403 POST   "/containers/create?name=pwn"
chk "DENY container delete"     403 DELETE /containers/plex
chk "DENY exec create"          403 POST   /containers/plex/exec
chk "DENY images list"          403 GET    /images/json
chk "DENY volumes list"         403 GET    /volumes
chk "DENY networks list"        403 GET    /networks
chk "DENY container stop"       403 POST   /containers/plex/stop
chk "DENY build"                403 POST   /build
exit $fail
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
scp docs/superpowers/verify/hermes-socket-proxy.sh nas:/tmp/
ssh nas 'sudo docker run --rm --network hermes_socket -v /tmp/hermes-socket-proxy.sh:/t.sh:ro curlimages/curl:8.8.0 sh /t.sh'
```

Expected: failure — the network `hermes_socket` does not exist yet.

- [ ] **Step 3: Write the compose file**

`compose/hermes-socket-proxy.yml`. Note there is **no top-level `networks:` block** — networks are declared only in the root `docker-compose.yml`, matching `socket-proxy.yml` and `traefik.yml`. A stray top-level networks block in `maintainerr.yml` previously broke every compose command on this NAS; do not reintroduce it.

```yaml
services:
  # Restricted Docker socket proxy for Hermes: read + restart ONLY.
  # Deliberately separate from the stack's tecnativa socket-proxy, which
  # filters by path prefix only and cannot express "restart but not delete".
  hermes-socket-proxy:
    image: wollomatic/socket-proxy:1.13.1
    container_name: hermes-socket-proxy
    restart: unless-stopped
    user: "65534:0"            # nobody; gid 0 required to read docker.sock (root:root 660)
    mem_limit: 64M
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    command:
      - '-loglevel=info'
      - '-listenip=0.0.0.0'
      - '-allowfrom=192.168.93.0/24'
      # Read surface. Patterns are anchored automatically (^...$).
      - '-allowGET=/(v1\.[0-9]{1,2}/)?version'
      - '-allowGET=/(v1\.[0-9]{1,2}/)?info'
      - '-allowGET=/(v1\.[0-9]{1,2}/)?containers/json.*'
      - '-allowGET=/(v1\.[0-9]{1,2}/)?containers/[a-zA-Z0-9_.-]+/json'
      - '-allowGET=/(v1\.[0-9]{1,2}/)?containers/[a-zA-Z0-9_.-]+/logs.*'
      - '-allowGET=/(v1\.[0-9]{1,2}/)?containers/[a-zA-Z0-9_.-]+/stats.*'
      # The ONLY mutation permitted.
      - '-allowPOST=/(v1\.[0-9]{1,2}/)?containers/[a-zA-Z0-9_.-]+/restart'
      - '-watchdoginterval=3600'
      - '-stoponwatchdog'
    # No ports: — reachable only from the hermes_socket network.
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      hermes_socket:
        ipv4_address: 192.168.93.2
```

- [ ] **Step 4: Add the network and include to `docker-compose.yml`**

In the `networks:` block, after the `t3_proxy` entry:

```yaml
  hermes_socket:
    name: hermes_socket
    driver: bridge
    ipam:
      config:
        - subnet: 192.168.93.0/24
```

In `include:`, under a new `# AGENT` heading before `# THE REST`:

```yaml
 # AGENT
  - compose/hermes-socket-proxy.yml
```

- [ ] **Step 5: Deploy and run the verification**

```bash
./pull.sh                      # reconcile first — standing rule
git diff --stat                # expect: no changes. If there are, STOP and reconcile.
./push.sh
ssh nas 'cd /volume1/docker && sudo docker compose up -d hermes-socket-proxy'
ssh nas 'sudo docker run --rm --network hermes_socket -v /tmp/hermes-socket-proxy.sh:/t.sh:ro curlimages/curl:8.8.0 sh /t.sh'
```

Expected: **all 13 checks PASS.** If any DENY check returns 200, the regex is too broad — fix before continuing. Do not proceed with a failing deny.

- [ ] **Step 6: Confirm it is not reachable from the host**

```bash
ssh nas 'curl -s -o /dev/null -w "%{http_code}\n" --max-time 3 http://localhost:2376/version'
```

Expected: `000` — the proxy publishes no host port.

- [ ] **Step 7: Commit**

```bash
git add compose/hermes-socket-proxy.yml docker-compose.yml docs/superpowers/verify/hermes-socket-proxy.sh
git commit -m "Add restricted docker socket proxy for Hermes (read + restart only)"
```

---

### Task 2: Egress allowlist proxy

**Files:**
- Create: `compose/hermes-egress-proxy.yml`
- Create (on NAS): `/volume1/docker/appdata/hermes-egress/tinyproxy.conf`, `/volume1/docker/appdata/hermes-egress/filter`
- Modify: `docker-compose.yml` (networks block; `include:` list)

**Interfaces:**
- Consumes: nothing.
- Produces: forward proxy at `http://192.168.92.2:8888` on network `hermes_net` (`192.168.92.0/24`). Hermes consumes it via `HTTP_PROXY` / `HTTPS_PROXY`.

- [ ] **Step 1: Write the failing verification**

Create `docs/superpowers/verify/hermes-egress.sh`:

```bash
#!/bin/bash
# Asserts the forward proxy allows only allowlisted domains.
set -u
PX=192.168.92.2:8888
fail=0
chk() { # name expected_result url
  if curl -s -o /dev/null --max-time 10 -x "$PX" "$3" 2>/dev/null; then r=allow; else r=deny; fi
  if [ "$r" = "$2" ]; then echo "PASS $1 ($r)"; else echo "FAIL $1: got $r want $2"; fail=1; fi
}
chk "openrouter allowed"  allow https://openrouter.ai/api/v1/models
chk "github allowed"      allow https://api.github.com/
chk "evil.com denied"     deny  https://example.com/
chk "pastebin denied"     deny  https://pastebin.com/
exit $fail
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
scp docs/superpowers/verify/hermes-egress.sh nas:/tmp/ && ssh nas 'sudo docker run --rm --network hermes_net -v /tmp/hermes-egress.sh:/t.sh:ro curlimages/curl:8.8.0 sh /t.sh'
```

Expected: fails — network `hermes_net` does not exist yet.

- [ ] **Step 3: Create the config on the NAS**

```bash
ssh nas 'mkdir -p /volume1/docker/appdata/hermes-egress && cat > /volume1/docker/appdata/hermes-egress/tinyproxy.conf <<EOF
User nobody
Group nogroup
Port 8888
Listen 0.0.0.0
Timeout 600
MaxClients 50
Allow 192.168.92.0/24
Filter "/etc/tinyproxy/filter"
FilterDefaultDeny Yes
FilterExtended On
FilterCaseSensitive Off
ConnectPort 443
DisableViaHeader Yes
EOF
cat > /volume1/docker/appdata/hermes-egress/filter <<EOF
^openrouter\.ai\$
^api\.github\.com\$
^github\.com\$
^codeload\.github\.com\$
^objects\.githubusercontent\.com\$
^registry\.npmjs\.org\$
^pypi\.org\$
^files\.pythonhosted\.org\$
^api\.telegram\.org\$
^discord\.com\$
^gateway\.discord\.gg\$
EOF
echo written'
```

Note: `ConnectPort 443` only — CONNECT to any other port is refused, so the proxy cannot be used as a generic TCP tunnel. Add messaging domains here as channels are enabled in Task 6.

- [ ] **Step 4: Write the compose file**

`compose/hermes-egress-proxy.yml`:

```yaml
services:
  # Domain-allowlisting forward proxy for Hermes. This is the ALLOWLIST;
  # the DOCKER-USER rules in Task 4 are the ENFORCEMENT. A library that
  # ignores HTTP_PROXY does not get out — it just fails.
  hermes-egress-proxy:
    image: monokal/tinyproxy:latest
    container_name: hermes-egress-proxy
    restart: unless-stopped
    command: ANY
    mem_limit: 64M
    read_only: true
    tmpfs:
      - /var/run
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    volumes:
      - $DOCKERDIR/appdata/hermes-egress/tinyproxy.conf:/etc/tinyproxy/tinyproxy.conf:ro
      - $DOCKERDIR/appdata/hermes-egress/filter:/etc/tinyproxy/filter:ro
    networks:
      hermes_net:
        ipv4_address: 192.168.92.2
```

No top-level `networks:` block — see the note in Task 1 Step 3.

- [ ] **Step 5: Add the network and include to `docker-compose.yml`**

In `networks:`:

```yaml
  hermes_net:
    name: hermes_net
    driver: bridge
    ipam:
      config:
        - subnet: 192.168.92.0/24
```

In `include:`, under `# AGENT`:

```yaml
  - compose/hermes-egress-proxy.yml
```

- [ ] **Step 6: Deploy and verify**

```bash
./pull.sh && git diff --stat && ./push.sh
ssh nas 'cd /volume1/docker && sudo docker compose up -d hermes-egress-proxy'
ssh nas 'sudo docker run --rm --network hermes_net -v /tmp/hermes-egress.sh:/t.sh:ro curlimages/curl:8.8.0 sh /t.sh'
```

Expected: **all 4 checks PASS.** If `example.com` is allowed, `FilterDefaultDeny` is not in effect — stop and fix.

- [ ] **Step 7: Commit**

```bash
git add compose/hermes-egress-proxy.yml docker-compose.yml docs/superpowers/verify/hermes-egress.sh
git commit -m "Add domain-allowlisting egress proxy for Hermes"
```

---

### Task 3: The Hermes container

**Files:**
- Create: `compose/hermes.yml`
- Modify: `docker-compose.yml` (`include:` list)

**Interfaces:**
- Consumes: `hermes_socket` (Task 1), `hermes_net` (Task 2).
- Produces: container `hermes`, dashboard on port `9119` reachable **only** as `http://hermes:9119` from `t3_proxy`. Static IPs: `192.168.90.10` (t3_proxy), `192.168.92.10` (hermes_net), `192.168.93.10` (hermes_socket).

- [ ] **Step 1: Prepare state directories and resolve the image digest**

```bash
ssh nas 'mkdir -p /volume1/docker/appdata/hermes /volume1/code \
  && chown -R 1000:10 /volume1/docker/appdata/hermes /volume1/code \
  && chmod 700 /volume1/docker/appdata/hermes'
ssh nas 'sudo docker pull nousresearch/hermes-agent:latest && sudo docker inspect --format="{{index .RepoDigests 0}}" nousresearch/hermes-agent:latest'
```

Record the printed `nousresearch/hermes-agent@sha256:...` value — it is used verbatim in Step 2. **Do not substitute `:latest`.**

- [ ] **Step 2: Write the compose file**

`compose/hermes.yml`, replacing `<DIGEST>` with the value from Step 1:

```yaml
services:
  hermes:
    image: nousresearch/hermes-agent@sha256:<DIGEST>   # pinned; no watchtower label by design
    container_name: hermes
    restart: unless-stopped
    command: gateway run
    user: "1000:10"
    read_only: true
    tmpfs:
      - /tmp
      - /run
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    mem_limit: 4g
    cpus: 2.0
    pids_limit: 512
    # NO ports: — reachable only via Traefik on t3_proxy.
    volumes:
      - $DOCKERDIR/appdata/hermes:/opt/data
      - /volume1/code:/opt/code
    environment:
      PUID: 1000
      PGID: 10
      TZ: $TZ
      HERMES_DASHBOARD: 1
      HERMES_DASHBOARD_HOST: 0.0.0.0        # container-internal only; no host port is published
      HERMES_DASHBOARD_PORT: 9119
      HTTP_PROXY: http://192.168.92.2:8888
      HTTPS_PROXY: http://192.168.92.2:8888
      NO_PROXY: 192.168.90.0/24,192.168.92.0/24,192.168.93.0/24,localhost,127.0.0.1
      DOCKER_HOST: tcp://192.168.93.2:2375
    networks:
      t3_proxy:
        ipv4_address: 192.168.90.10
      hermes_net:
        ipv4_address: 192.168.92.10
      hermes_socket:
        ipv4_address: 192.168.93.10
```

No top-level `networks:` block — see the note in Task 1 Step 3.

Dashboard auth credentials are **not** set here — they are secrets, added in Task 6 via the NAS-side `.env`, which `push.sh` does not sync.

- [ ] **Step 3: Add the include**

In `docker-compose.yml` under `# AGENT`:

```yaml
  - compose/hermes.yml
```

- [ ] **Step 4: Deploy**

```bash
./pull.sh && git diff --stat && ./push.sh
ssh nas 'cd /volume1/docker && sudo docker compose up -d hermes'
ssh nas 'sleep 20; curl -s "http://localhost:2375/containers/hermes/logs?stdout=1&stderr=1&tail=60"'
```

- [ ] **Step 5: Verify hardening actually took effect**

```bash
ssh nas 'curl -s http://localhost:2375/containers/hermes/json | python3 -c "
import sys,json; d=json.load(sys.stdin); h=d[\"HostConfig\"]
print(\"ReadonlyRootfs:\", h[\"ReadonlyRootfs\"])
print(\"CapDrop:\", h[\"CapDrop\"])
print(\"SecurityOpt:\", h[\"SecurityOpt\"])
print(\"Memory:\", h[\"Memory\"])
print(\"PidsLimit:\", h[\"PidsLimit\"])
print(\"Ports:\", d[\"NetworkSettings\"][\"Ports\"])
print(\"User:\", d[\"Config\"][\"User\"])
print(\"Networks:\", sorted(d[\"NetworkSettings\"][\"Networks\"]))
"'
```

Expected exactly: `ReadonlyRootfs: True`, `CapDrop: ['ALL']`, `SecurityOpt` contains `no-new-privileges:true`, `Memory: 4294967296`, `PidsLimit: 512`, **`Ports: {}`**, `User: 1000:10`, `Networks: ['hermes_net', 'hermes_socket', 't3_proxy']`.

**If the container fails to boot under `read_only`:** s6-overlay may need more writable paths. Read the logs, add a narrowly-scoped `tmpfs` entry for the specific path named, and retry. **Do not drop `read_only: true`** — that is a spec requirement (§4.2).

- [ ] **Step 6: Commit**

```bash
git add compose/hermes.yml docker-compose.yml
git commit -m "Add hardened Hermes agent container, no published ports"
```

---

### Task 4: Egress enforcement and lateral containment (iptables)

The proxy in Task 2 is opt-in; this task makes it inescapable. Runs after Task 3 because it keys on Hermes' static IPs.

**Files:**
- Create (on NAS): `/volume1/docker/scripts/hermes-firewall.sh`
- Create: `compose/../docs/superpowers/verify/hermes-containment.sh`

**Interfaces:**
- Consumes: Hermes static IPs from Task 3.
- Produces: `DOCKER-USER` rules; a DSM boot-up task that reapplies them.

- [ ] **Step 1: Write the failing verification**

Create `docs/superpowers/verify/hermes-containment.sh`:

```bash
#!/bin/bash
# Run INSIDE the hermes container's network namespace.
# Asserts a hijacked agent cannot reach the internet directly or pivot to the LAN.
set -u
fail=0
chk() { # name expected(allow|deny) command...
  if timeout 8 "${@:3}" >/dev/null 2>&1; then r=allow; else r=deny; fi
  if [ "$r" = "$2" ]; then echo "PASS $1 ($r)"; else echo "FAIL $1: got $r want $2"; fail=1; fi
}
chk "direct internet blocked"  deny  curl -s --max-time 5 https://example.com/
chk "direct openrouter blocked" deny curl -s --max-time 5 https://openrouter.ai/
chk "via proxy allowed"        allow curl -s --max-time 8 -x 192.168.92.2:8888 https://openrouter.ai/api/v1/models
chk "LAN host blocked"         deny  curl -s --max-time 5 http://192.168.1.1/
chk "IoT VLAN blocked"         deny  curl -s --max-time 5 http://192.168.2.1/
chk "UDM mgmt blocked"         deny  curl -s --max-time 5 https://192.168.1.1:443/
chk "socket proxy reachable"   allow curl -s --max-time 5 http://192.168.93.2:2375/version
exit $fail
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
scp docs/superpowers/verify/hermes-containment.sh nas:/tmp/
ssh nas 'sudo docker run --rm --network container:hermes -v /tmp/hermes-containment.sh:/t.sh:ro curlimages/curl:8.8.0 sh /t.sh'
```

Expected: the four "blocked" checks FAIL (currently allowed) — that is the gap this task closes.

- [ ] **Step 3: Write the firewall script on the NAS**

```bash
ssh nas 'mkdir -p /volume1/docker/scripts && cat > /volume1/docker/scripts/hermes-firewall.sh <<EOF
#!/bin/bash
# Containment for the Hermes agent. Keyed on the container IPs, NOT on a bridge
# interface: hermes shares t3_proxy with every other proxied service, so an
# interface-based rule would take the whole stack down.
set -e
HERMES_IPS="192.168.90.10 192.168.92.10 192.168.93.10"

# Remove any previous generation (idempotent re-apply).
while iptables -D DOCKER-USER -m comment --comment "hermes-containment" 2>/dev/null; do :; done

# Return replies to connections hermes did not initiate outbound.
iptables -I DOCKER-USER 1 -m conntrack --ctstate ESTABLISHED,RELATED \
  -m comment --comment "hermes-containment" -j RETURN

i=2
for ip in \$HERMES_IPS; do
  # Permitted: its own egress proxy, the restricted socket proxy, Traefik replies.
  for dst in 192.168.92.0/24 192.168.93.0/24 192.168.90.0/24; do
    iptables -I DOCKER-USER \$i -s \$ip -d \$dst \
      -m comment --comment "hermes-containment" -j RETURN
    i=\$((i+1))
  done
  # Everything else: internet, LAN, IoT VLAN, the router itself.
  iptables -I DOCKER-USER \$i -s \$ip \
    -m comment --comment "hermes-containment" -j DROP
  i=\$((i+1))
done
echo "hermes containment applied"
EOF
chmod +x /volume1/docker/scripts/hermes-firewall.sh'
```

- [ ] **Step 4: Apply and verify**

```bash
ssh nas 'sudo /volume1/docker/scripts/hermes-firewall.sh && sudo iptables -L DOCKER-USER -n --line-numbers | head -20'
ssh nas 'sudo docker run --rm --network container:hermes -v /tmp/hermes-containment.sh:/t.sh:ro curlimages/curl:8.8.0 sh /t.sh'
```

Expected: **all 7 checks PASS.** In particular `direct openrouter blocked = deny` *and* `via proxy allowed = allow` — together they prove the proxy is the only way out.

- [ ] **Step 5: Persist across reboot**

DSM does not persist iptables rules. In **DSM → Control Panel → Task Scheduler → Create → Triggered Task → User-defined script**, create:
- Task name: `hermes-firewall`
- User: `root`
- Event: `Boot-up`
- Script: `/volume1/docker/scripts/hermes-firewall.sh`

Then confirm it survives:

```bash
ssh nas 'sudo synoschedtask --get | grep -i hermes'
```

Expected: the task is listed. (A full reboot test is worthwhile but is the operator's call on timing.)

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/verify/hermes-containment.sh
git commit -m "Add Hermes egress enforcement and containment verification"
```

Note: `/volume1/docker/scripts/` is outside the `push.sh`-synced tree (`docker-compose.yml` + `compose/` only). Record the script's content in the commit message body or copy it into `docs/` if you want it version-controlled.

---

### Task 5: Ingress — Traefik route, CNAME, Cloudflare Access

**Files:**
- Modify (on NAS): `/volume1/docker/appdata/traefik3/rules/udms/apps.yml`
- Cloudflare dashboard: DNS record + Access application

**Interfaces:**
- Consumes: container `hermes` on `t3_proxy` port `9119` (Task 3).
- Produces: `https://hermes.bassford.net`, gated.

- [ ] **Step 1: Confirm Traefik can reach Hermes at all**

```bash
ssh nas 'sudo docker exec traefik wget -qS -O /dev/null http://hermes:9119/ 2>&1 | head -5'
```

Expected: an HTTP status line — `401` is a **good** result here (Hermes auth is mandatory). A connection error means the `t3_proxy` attachment is wrong; fix before continuing.

- [ ] **Step 2: Add the router and service to `apps.yml`**

Edit on the NAS (this file is not synced). Under `routers:`, in the "no built-in auth" group:

```yaml
    hermes-rtr-file:
      entryPoints: ["websecure"]
      rule: "Host(`hermes.bassford.net`)"
      middlewares: ["chain-basic-auth@file"]
      service: hermes-svc-file
```

Under `services:`:

```yaml
    hermes-svc-file:
      loadBalancer: { servers: [{ url: "http://hermes:9119" }] }
```

`chain-basic-auth` is deliberate: it stacks Traefik basic auth on top of Hermes' own mandatory auth, per spec §4.4.

- [ ] **Step 3: Verify Traefik loaded the rule**

```bash
ssh nas 'sleep 5; curl -s "http://localhost:2375/containers/traefik/logs?stderr=1&tail=30" | tr -d "\000-\010\013\014\016-\037" | grep -i -E "error|hermes" | tail'
```

Expected: no errors mentioning `hermes`. Traefik hot-reloads the rules directory; no restart needed.

- [ ] **Step 4: Create the DNS record**

In the Cloudflare dashboard for `bassford.net`, add a **CNAME**: name `hermes`, target the **same `<tunnel-id>.cfargotunnel.com` value used by the existing `dozzle` record**, proxy status **Proxied**. (The wildcard `*.bassford.net` points at DDNS, not the tunnel — without its own CNAME this returns 522.)

- [ ] **Step 5: Create the Cloudflare Access application**

Zero Trust → Access → Applications → Add → Self-hosted:
- Application domain: `hermes.bassford.net`
- Session duration: **24 hours or less**
- Policy: Action **Allow**, rule `Emails` = `jhbassford@gmail.com` only
- Identity provider: Google SSO with MFA enforced

Then add a WAF rate-limiting rule on `hermes.bassford.net` (e.g. 20 requests/minute per IP).

- [ ] **Step 6: Verify the full chain end-to-end**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://hermes.bassford.net/
```

Expected: **`302`** (redirect to the Cloudflare Access login), **not** `200` and not `401`. A `200` means Access is not enforcing — stop and fix. A `522` means the CNAME is missing.

Then open `https://hermes.bassford.net` in a browser and confirm you are challenged **three** times in sequence: Cloudflare Access → Traefik basic auth → Hermes dashboard login.

- [ ] **Step 7: Commit the documentation of the route**

```bash
git add docs/
git commit -m "Document Hermes ingress: apps.yml route, CNAME, Access policy"
```

---

### Task 6: Agent configuration and secrets

**Files:**
- Modify (on NAS): `/volume1/docker/appdata/hermes/.env`, `/volume1/docker/appdata/hermes/config.yaml`
- Modify (on NAS): `/volume1/docker/appdata/hermes-egress/filter`

**Interfaces:**
- Consumes: running `hermes` container (Task 3), egress filter (Task 2).
- Produces: an authenticated, model-backed, sender-allowlisted agent.

- [ ] **Step 1: Create the OpenRouter key with a hard cap**

In the OpenRouter dashboard, create a **dedicated key for Hermes** with a hard monthly credit limit. Do not reuse an existing key — this key lives on an internet-exposed agent and must be independently revocable and capped.

- [ ] **Step 2: Write secrets to the NAS-side `.env`**

`push.sh` syncs only `docker-compose.yml` and `compose/`, so `appdata` secrets never enter git. Generate strong values:

```bash
ssh nas 'umask 077; cat >> /volume1/docker/appdata/hermes/.env <<EOF
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=jim
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$(openssl rand -base64 24)
HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(openssl rand -hex 32)
OPENROUTER_API_KEY=<paste-key-from-step-1>
EOF
chown 1000:10 /volume1/docker/appdata/hermes/.env
chmod 600 /volume1/docker/appdata/hermes/.env
grep -c . /volume1/docker/appdata/hermes/.env'
```

Retrieve the generated password for your password manager:

```bash
ssh nas 'sudo grep BASIC_AUTH_PASSWORD /volume1/docker/appdata/hermes/.env'
```

- [ ] **Step 3: Write `config.yaml`**

```bash
ssh nas 'cat > /volume1/docker/appdata/hermes/config.yaml <<EOF
model:
  provider: openrouter
  model: anthropic/claude-sonnet-5

dashboard:
  public_url: "https://hermes.bassford.net"
  trusted_proxies:
    - "192.168.90.254"    # Traefik on t3_proxy. Bounded — never 0.0.0.0/0.

terminal:
  backend: local          # docker backend deliberately unused: it sandboxes by
                          # CREATING containers, the exact privilege the socket
                          # proxy refuses. The container is itself the sandbox.

tool_loop_guardrails:
  non_interactive_hard_stop_enabled: true

skills:
  auto_install: false     # manual install only; ClawHavoc-class registry risk

browser:
  enabled: false          # Chromium on a J4125 is impractical; also removes the
                          # single largest untrusted-content parsing surface.
                          # Re-enabling requires shm_size: 1g in compose.
EOF
chown 1000:10 /volume1/docker/appdata/hermes/config.yaml
chmod 600 /volume1/docker/appdata/hermes/config.yaml'
```

- [ ] **Step 4: Restart and verify auth is enforced**

```bash
ssh nas 'curl -s -X POST http://localhost:2375/containers/hermes/restart && sleep 20'
ssh nas 'sudo docker exec traefik wget -qS -O /dev/null http://hermes:9119/ 2>&1 | head -3'
```

Expected: `401 Unauthorized`. If it returns `200`, the dashboard is unauthenticated — **stop immediately** and fix before it is reachable.

- [ ] **Step 5: Provision scoped git credentials**

The coding role needs git access. Create a **fine-grained GitHub PAT** scoped to only the repos you intend to clone into `/volume1/code`, with `Contents: read/write` and nothing else. Never an account-wide classic token — that key sits on an internet-reachable agent.

```bash
ssh nas 'umask 077; echo "GITHUB_TOKEN=<fine-grained-pat>" >> /volume1/docker/appdata/hermes/.env'
```

- [ ] **Step 6: Connect one messaging channel and allowlist yourself**

Enable a single channel first (Telegram is simplest). Create the bot via BotFather, then:

```bash
ssh nas 'umask 077; echo "TELEGRAM_BOT_TOKEN=<token-from-botfather>" >> /volume1/docker/appdata/hermes/.env'
```

Get your own numeric Telegram user ID (message `@userinfobot`), then append to `config.yaml`:

```yaml
messaging:
  telegram:
    enabled: true
    allowed_users:
      - 123456789        # your numeric Telegram ID — replace
    reject_unknown: true
```

Add the channel's API domain to the egress filter:

```bash
ssh nas 'grep -q telegram /volume1/docker/appdata/hermes-egress/filter || echo "^api\.telegram\.org\$" >> /volume1/docker/appdata/hermes-egress/filter'
ssh nas 'curl -s -X POST http://localhost:2375/containers/hermes-egress-proxy/restart'
```

Verify from a *different* account that the bot ignores non-allowlisted senders. An open bot is an open shell.

- [ ] **Step 7: Verify the model backend works end-to-end**

Send the agent a trivial message on the connected channel (e.g. "reply with the word pong"). Expected: a reply. If it times out, check the egress filter contains `openrouter.ai` and the proxy was restarted.

- [ ] **Step 8: Commit**

```bash
git add docs/
git commit -m "Document Hermes agent configuration and secret handling"
```

---

### Task 7: Threat-model acceptance test

Proves the spec §5 success criterion: a **fully hijacked** agent stays contained. Every check runs from inside the agent's own context, i.e. with everything an attacker would have.

**Files:**
- Create: `docs/superpowers/verify/hermes-threat-model.sh`

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: a repeatable containment regression test.

- [ ] **Step 1: Write the acceptance test**

```bash
#!/bin/bash
# Spec §5: assert a fully-hijacked agent cannot escalate, pivot, or exfiltrate.
# Run: sudo docker exec -u 1000:10 hermes bash /opt/data/hermes-threat-model.sh
set -u
fail=0
chk() { # name expected(allow|deny) command...
  if timeout 8 "${@:3}" >/dev/null 2>&1; then r=allow; else r=deny; fi
  if [ "$r" = "$2" ]; then echo "PASS $1 ($r)"; else echo "FAIL $1: got $r want $2"; fail=1; fi
}
D=http://192.168.93.2:2375

echo "-- cannot mutate containers --"
chk "delete container"   deny curl -sf -X DELETE $D/containers/plex
chk "create container"   deny curl -sf -X POST "$D/containers/create?name=pwn"
chk "exec into container" deny curl -sf -X POST $D/containers/plex/exec
chk "stop container"     deny curl -sf -X POST $D/containers/plex/stop
chk "list images"        deny curl -sf $D/images/json
echo "-- but ops still works --"
chk "list containers"    allow curl -sf "$D/containers/json?all=1"
chk "read logs"          allow curl -sf "$D/containers/plex/logs?stdout=1&tail=1"

echo "-- cannot pivot --"
chk "router UI"          deny curl -s --max-time 5 https://192.168.1.1/
chk "IoT VLAN"           deny curl -s --max-time 5 http://192.168.2.1/
chk "other LAN host"     deny curl -s --max-time 5 http://192.168.1.104:9000/

echo "-- cannot exfiltrate --"
chk "arbitrary host"     deny curl -s --max-time 5 https://example.com/
chk "non-allowlisted via proxy" deny curl -s --max-time 8 -x 192.168.92.2:8888 https://pastebin.com/

echo "-- cannot read what it should not --"
chk "stack secrets"      deny cat /volume1/docker/secrets/cf_dns_api_token
chk "media library"      deny ls /data/media
chk "host etc shadow"    deny cat /etc/shadow
echo "-- but its own workspace works --"
chk "code mount"         allow ls /opt/code

echo "-- cannot escalate --"
chk "write to rootfs"    deny touch /usr/local/bin/pwn
chk "sudo"               deny sudo -n true

exit $fail
```

- [ ] **Step 2: Run it**

```bash
scp docs/superpowers/verify/hermes-threat-model.sh nas:/volume1/docker/appdata/hermes/
ssh nas 'sudo docker exec -u 1000:10 hermes bash /opt/data/hermes-threat-model.sh'
```

Expected: **every check PASSes.** Any FAIL is a containment hole — fix it before considering the deployment live. Note the two `allow` checks in the ops section: if those fail, the proxy is too tight and the ops role is broken.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/verify/hermes-threat-model.sh
git commit -m "Add Hermes threat-model acceptance test for spec section 5"
```

- [ ] **Step 4: Update the spec's open items**

Mark §7's forward-proxy item resolved (Tinyproxy, Task 2). Commit.

---

### Task 8: Dream Machine hardening (spec §4.6)

Task 4 contains Hermes at the NAS. This task is the router-side complement: it limits what a *NAS-level* compromise can reach, and resolves an inbound path the spec wrongly assumed did not exist.

**Files:** none in-repo — UniFi controller configuration. Record outcomes in `docs/`.

**Interfaces:**
- Consumes: nothing from earlier tasks; can run in parallel with Tasks 1–7.
- Produces: an audited inbound surface and a lateral-movement boundary.

- [ ] **Step 1: Record the current inbound surface**

```
Audited 2026-09-09 — exactly one port forward exists:
  "Plex Remote Access"  tcp/32400  src=any  ->  192.168.1.104:32400  (enabled)
```

This **contradicts spec §4.6's assumption that no inbound path exists.** The Cloudflare tunnel is outbound-only and correctly bypasses the UDM, but Plex remote access is a genuine internet-facing listener on the same host that will run the agent.

- [ ] **Step 2: Decide on the Plex forward**

This is an operator decision, not an automatic removal — deleting it breaks remote Plex playback.

- **Keep it** (likely): accept the surface, and in exchange commit to keeping the Plex container current. Note that Plex now runs `network_mode: host`, so the forward reaches Plex directly rather than via a Docker NAT hop.
- **Remove it**: remote Plex then works only via Plex's own relay, which is bandwidth-limited.

Whichever is chosen, record it. Do **not** leave it unexamined — it is the single inbound path to the host running the agent.

- [ ] **Step 3: Verify no other forward or UPnP mapping targets the NAS**

```
Settings → Routing & Firewall → Port Forwarding   (expect: only the Plex rule)
Settings → Networks → Default → advanced          (confirm UPnP is DISABLED)
```

UPnP matters specifically here: a compromised container that could speak SSDP would otherwise be able to open its own inbound port. Confirm it is off.

- [ ] **Step 4: Add the lateral-containment policy**

In **Settings → Firewall & Security → Policy**, create a rule limiting the NAS *as a source*:

- Name: `NAS-no-lateral`
- Action: **Block**
- Source: the NAS — `192.168.1.104`
- Destination: `192.168.2.0/24` (IoT VLAN 20) **and** the gateway's management address `192.168.1.1`
- Logging: **enabled**

Exclude any port the NAS legitimately needs (e.g. Home Assistant reaching IoT devices — HA runs `network_mode: host` on this NAS, so verify before enabling or you will break it).

- [ ] **Step 5: Enable detection**

```
Settings → Firewall & Security → Intrusion Prevention → enable IPS on the Default zone
Settings → Firewall & Security → enable malicious-domain / threat blocking
```

- [ ] **Step 6: Verify containment from the agent's own context**

```bash
ssh nas 'sudo docker run --rm --network container:hermes curlimages/curl:8.8.0 \
  sh -c "curl -s --max-time 5 https://192.168.1.1/ || echo BLOCKED-OK"'
```

Expected: `BLOCKED-OK`. Note this is already enforced by Task 4 at the NAS; the UDM rule is defence in depth for the case where the NAS host itself, not just the container, is compromised.

- [ ] **Step 7: Commit the audit record**

```bash
git add docs/
git commit -m "Document UDM hardening: inbound audit, lateral policy, IPS"
```

---

## Post-deployment follow-ups

Not part of this plan; recorded so they are not lost.

1. **Unstash the parked hardening.** `git stash pop` recovers the localhost-only bind changes for `bazarr`/`dozzle`/`sabnzbd`/`maintainerr` and `socket-proxy privileged: false`. Review and deploy as their own change — they are unrelated to Hermes and were parked, not rejected.
2. **Image updates.** The digest pin means no auto-updates by design. Establish a cadence: re-pull, read the changelog for security fixes, re-pin, re-run Task 7's acceptance test.
3. **Reboot test.** Task 4's iptables rules are reapplied by a DSM boot-up task. Confirm at the next planned reboot that `iptables -L DOCKER-USER -n` still shows the `hermes-containment` rules, and re-run Task 7.
