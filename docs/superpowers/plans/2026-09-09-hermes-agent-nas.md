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
- **Resource limits: `pids_limit` and `cpus` are permanently unavailable on this
  kernel. Do not assert them anywhere.** DSM's 4.4.302 kernel was built without
  `CONFIG_CGROUP_PIDS` (there is no `pids` line in `/proc/cgroups` at all), so
  `pids_limit` is silently discarded and `docker inspect` returns
  `HostConfig.PidsLimit: nil`; and it has no CFS bandwidth control, so setting
  `cpus:` makes `docker compose up` **refuse to create the container at all**
  ("NanoCPUs can not be set, as your kernel does not support CPU CFS
  scheduler"). A plan replay that keeps `cpus:` cannot start Hermes.
  The enforced substitutes, both verified live in-container, are:
  `ulimits: nproc: 1024` (RLIMIT_NPROC — a POSIX rlimit with no cgroup
  dependency, unraisable without `CAP_SYS_RESOURCE`, which `cap_drop: ALL` +
  `no-new-privileges` remove) and `cpu_shares: 512` (`CONFIG_FAIR_GROUP_SCHED`,
  a different kernel symbol from the missing CFS-bandwidth one; the `cpu`
  cgroup v1 controller IS mounted). Assert them as:
  `/proc/self/limits` shows `Max processes 1024`, and
  `/sys/fs/cgroup/cpu/cpu.shares` reads `512`.
- `/volume1/docker` is **not** mounted into Hermes in any mode (it contains `secrets/`).
- Dashboard hostname: **`hermes.bassford.net`**.
- Traefik routes live in `/volume1/docker/appdata/traefik3/rules/udms/apps.yml` **on the NAS** — outside the synced tree, edited via SSH. Every route needs a middleware chain and the `websecure` entrypoint.
- **Host quirks, established the hard way — do not rediscover:** `sudo docker`
  does NOT work; use `sudo /usr/local/bin/docker`. `scp` to this NAS is broken;
  use `ssh nas 'cat > /path/file' < localfile`. Passwordless sudo works.
  `iptables` cannot address the built-in chains by name here — see Task 4.
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
# scp to this NAS is broken; use a redirected cat.
ssh nas 'cat > /tmp/hermes-socket-proxy.sh' < docs/superpowers/verify/hermes-socket-proxy.sh
ssh nas 'sudo /usr/local/bin/docker run --rm --network host -v /tmp/hermes-socket-proxy.sh:/t.sh:ro curlimages/curl:8.8.0 sh /t.sh'
```

Expected: failure — the network `hermes_socket` does not exist yet.

`--network host`, **not** `--network hermes_socket`. The shipped script reaches
two proxies from one container: the restricted proxy at `192.168.93.2:2375`
(under test) and the PERMISSIVE `socket-proxy` at `127.0.0.1:2375`, used only
to create and destroy a disposable canary container so that `POST .../restart`
can be proven for real without restarting a live service. The permissive proxy
is published on `127.0.0.1` only and is unreachable from a bridge; a
host-network container reaches it on loopback while still egressing to
`192.168.93.2` with source `192.168.93.1`, which is inside
`-allowfrom=192.168.93.0/24`. Also note `sudo docker` does not work on this
host — use `sudo /usr/local/bin/docker`.

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
      # The ONLY mutation permitted. NOTE: the shipped file scopes this to an
      # EXPLICIT NAME ALLOWLIST, not the wildcard shown here — a wildcard also
      # covers hermes itself, pihole, traefik, cloudflared, watchtower and the
      # permissive socket-proxy. See compose/hermes-socket-proxy.yml.
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
ssh nas 'cd /volume1/docker && sudo /usr/local/bin/docker compose up -d hermes-socket-proxy'
ssh nas 'sudo /usr/local/bin/docker run --rm --network host -v /tmp/hermes-socket-proxy.sh:/t.sh:ro curlimages/curl:8.8.0 sh /t.sh'
```

`--network host` again — see Step 2 for why `--network hermes_socket` fails.

Expected: **29/29 checks PASS** (the script has grown well past the 13 sketched
in Step 1: a real canary restart and stats call, two path-traversal denials, and
ten checks proving the restart allowlist genuinely excludes hermes itself,
pihole, traefik, cloudflared, both hermes proxies, socket-proxy, watchtower,
portainer and dozzle). If any DENY check returns 200, the regex is too broad —
fix before continuing. Do not proceed with a failing deny.

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
ssh nas 'cat > /tmp/hermes-egress.sh' < docs/superpowers/verify/hermes-egress.sh && ssh nas 'sudo /usr/local/bin/docker run --rm --network hermes_net -v /tmp/hermes-egress.sh:/t.sh:ro curlimages/curl:8.8.0 sh /t.sh'
```

Expected: fails — network `hermes_net` does not exist yet.

- [ ] **Step 3: Create the config on the NAS**

> **SUPERSEDED — source of truth is `appdata-templates/hermes-egress/` (delivery
> instructions in `appdata-templates/README.md`); do not replay this block.**
> The heredoc that used to live here is missing the
> `StartServers`/`MinSpareServers`/`MaxSpareServers`/`MaxRequestsPerChild`
> block, without which tinyproxy exits at startup with `"StartServers" must be
> greater than zero` and the proxy crash-loops. Once Task 4's rules are applied
> this proxy is the agent's ONLY internet path, so replaying the stale heredoc
> on a rebuild produces a silently dead agent. Copy the two checked-in files
> instead, as `root:root 0644`:

```bash
ssh nas 'sudo mkdir -p /volume1/docker/appdata/hermes-egress'
for f in tinyproxy.conf filter; do
  ssh nas "cat > /tmp/$f" < "appdata-templates/hermes-egress/$f"
  ssh nas "sudo install -o root -g root -m 0644 /tmp/$f /volume1/docker/appdata/hermes-egress/$f && rm -f /tmp/$f"
done
```

Still true and worth keeping in mind: `ConnectPort 443` only — CONNECT to any
other port is refused, so the proxy cannot be used as a generic TCP tunnel.
Messaging domains are added to `filter` as channels are enabled in Task 6.

- [ ] **Step 4: Write the compose file**

> **SUPERSEDED — source of truth is `compose/hermes-egress-proxy.yml`; do not
> replay this block.** The YAML that used to be reproduced here is materially
> wrong now. It is missing the `entrypoint:` override (the image's default
> `run.sh` `sed -i`-edits the `:ro`-mounted config and dies), `user:
> "65534:65533"` (tinyproxy's own root->nobody drop fails under
> `cap_drop: ALL`), the `/tmp` tmpfs with its `noexec,nosuid,nodev,size=16m`
> options (required under `read_only: true`, root-caused with strace), and the
> image digest pin. The shipped file carries the full reasoning for each.

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
ssh nas 'cd /volume1/docker && sudo /usr/local/bin/docker compose up -d hermes-egress-proxy'
ssh nas 'sudo /usr/local/bin/docker run --rm --network hermes_net -v /tmp/hermes-egress.sh:/t.sh:ro curlimages/curl:8.8.0 sh /t.sh'
```

Expected: **all 5 checks PASS** (the shipped script adds a fifth beyond the four sketched in Step 1: an allowlisted host on a non-443 port, which proves `ConnectPort 443` is genuinely enforced and the proxy cannot be used as a generic TCP tunnel). If `example.com` is allowed, `FilterDefaultDeny` is not in effect — stop and fix.

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

- [ ] **Step 1: Prepare state directories, deliver `hermes-etc`, and resolve the image digest**

**`hermes-etc` is not optional and is easy to miss.** `compose/hermes.yml`
bind-mounts FOUR individual files out of
`/volume1/docker/appdata/hermes-etc/`. Docker silently creates a **directory**
at any bind-mount source that does not exist, so a literal replay that skips
this leaves Docker creating directories over `/etc/passwd`, `/etc/group`,
`/opt/data/config.yaml` and `/opt/data/.env` — the container will not start.
Every file, its NAS path, and its required owner and mode are recorded in
`appdata-templates/README.md`, which is the only record of ownership and mode
because git preserves neither.

```bash
# 1. Agent state + workspace.
ssh nas 'sudo mkdir -p /volume1/docker/appdata/hermes /volume1/code   && sudo chown -R 1000:10 /volume1/docker/appdata/hermes /volume1/code   && sudo chmod 0700 /volume1/docker/appdata/hermes'

# 2. hermes-etc — root-owned, and populated BEFORE any compose up.
ssh nas 'sudo mkdir -p /volume1/docker/appdata/hermes-etc   && sudo chown root:root /volume1/docker/appdata/hermes-etc   && sudo chmod 0755 /volume1/docker/appdata/hermes-etc'

for f in passwd group config.yaml; do
  ssh nas "cat > /tmp/$f" < "appdata-templates/hermes/$f"
  ssh nas "sudo install -o root -g root -m 0644 /tmp/$f /volume1/docker/appdata/hermes-etc/$f && rm -f /tmp/$f"
done

# hermes.env is root:10 0640 — group 10 is the container's PGID and the ONLY
# group the agent process holds, so it is the only group that can grant read.
# root:1000 would leave the file unreadable. 0640 keeps secrets off world-read.
ssh nas 'cat > /tmp/hermes.env' < appdata-templates/hermes/hermes.env
ssh nas 'sudo install -o root -g 10 -m 0640 /tmp/hermes.env /volume1/docker/appdata/hermes-etc/hermes.env && rm -f /tmp/hermes.env'

# 3. Confirm all four are FILES, not directories.
ssh nas 'ls -la /volume1/docker/appdata/hermes-etc/'

# 4. Resolve the image digest.
ssh nas 'sudo /usr/local/bin/docker pull nousresearch/hermes-agent:latest && sudo /usr/local/bin/docker inspect --format="{{index .RepoDigests 0}}" nousresearch/hermes-agent:latest'
```

`passwd`/`group` are edited copies of the image's own files with the baked-in
`hermes` account remapped from `10000:10000` to `1000:10`; without them the
image's `stage2-hook.sh` rejects `--user 1000:10` as an arbitrary UID and
refuses to start. `config.yaml`/`hermes.env` are the read-only guardrail and
secret files — see Task 6, which writes to `hermes-etc`, never to `/opt/data`.

Record the printed `nousresearch/hermes-agent@sha256:...` value — it is used
verbatim in Step 2. **Do not substitute `:latest`.**

- [ ] **Step 2: Write the compose file**

> **SUPERSEDED — source of truth is `compose/hermes.yml`; do not replay this
> block.** The YAML reproduced here would not start the container. It sets
> `cpus: 2.0`, which makes `docker compose up` **refuse to create the container
> at all** on this kernel, and `pids_limit: 512`, which is silently discarded.
> It is also missing: `ulimits` (`nproc: 1024`, `nofile: 4096`) and
> `cpu_shares: 512` — the substitutes that actually enforce the intent;
> `memswap_limit: 4g`, without which Docker silently grants 4 GB RAM **plus**
> 4 GB swap; the explicit tmpfs options
> (`/tmp:noexec,nosuid,nodev,size=64m` and
> `/run:exec,nosuid,nodev,size=16m,mode=0755,uid=1000,gid=10` — s6-overlay is
> PID 1 and execs from `/run`, and Docker forces `noexec` on every tmpfs unless
> `exec` is given explicitly); and the four `hermes-etc` read-only mounts
> (`/etc/passwd`, `/etc/group`, `/opt/data/config.yaml`, `/opt/data/.env`)
> without which the container either refuses the non-root UID or leaves its own
> guardrails writable. The shipped file documents each deviation with the
> evidence for it.

Dashboard auth credentials are **not** set in compose — they are secrets, added
in Task 6 via `hermes-etc/hermes.env`, which `push.sh` does not sync.

- [ ] **Step 3: Add the include**

In `docker-compose.yml` under `# AGENT`:

```yaml
  - compose/hermes.yml
```

- [ ] **Step 4: Deploy**

```bash
./pull.sh && git diff --stat && ./push.sh
ssh nas 'cd /volume1/docker && sudo /usr/local/bin/docker compose up -d hermes'
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
print(\"MemorySwap:\", h[\"MemorySwap\"])
print(\"CpuShares:\", h[\"CpuShares\"])
print(\"Ports:\", d[\"NetworkSettings\"][\"Ports\"])
print(\"User:\", d[\"Config\"][\"User\"])
print(\"Networks:\", sorted(d[\"NetworkSettings\"][\"Networks\"]))
"'

# The two resource limits that are ENFORCED here must be read from inside the
# container, not from `docker inspect` — see Global Constraints.
ssh nas 'sudo /usr/local/bin/docker exec -u 1000:10 hermes sh -c "grep \"Max processes\" /proc/self/limits; cat /sys/fs/cgroup/cpu/cpu.shares"'

# And the guardrail files must be genuinely unwritable by the agent.
ssh nas 'sudo /usr/local/bin/docker exec -u 1000:10 hermes sh -c "echo x >> /opt/data/config.yaml; echo x >> /opt/data/.env"'
```

Expected exactly: `ReadonlyRootfs: True`, `CapDrop: ['ALL']`, `SecurityOpt`
contains `no-new-privileges:true`, `Memory: 4294967296`, `MemorySwap:
4294967296`, `CpuShares: 512`, **`Ports: {}`**, `User: 1000:10`,
`Networks: ['hermes_net', 'hermes_socket', 't3_proxy']`.

From the in-container reads: `Max processes 1024 1024` and `512`.

**Do NOT assert `PidsLimit: 512`** — it reads back `nil` on this kernel and
always will; see Global Constraints. `docker compose up` also prints "Your
kernel does not support PIDs limit capabilities... PIDs limit discarded." on
every start. That message is expected, not a fault.

Both write attempts must fail with `Permission denied`. If either succeeds, the
guardrails are advisory and the containment story is broken — stop and fix.

**If the container fails to boot under `read_only`:** s6-overlay may need more writable paths. Read the logs, add a narrowly-scoped `tmpfs` entry for the specific path named, and retry. **Do not drop `read_only: true`** — that is a spec requirement (§4.2).

- [ ] **Step 6: Commit**

```bash
git add compose/hermes.yml docker-compose.yml
git commit -m "Add hardened Hermes agent container, no published ports"
```

---

### Task 4: Egress enforcement and lateral containment (iptables)

The proxy in Task 2 is opt-in; this task makes it inescapable. Runs after Task 3
because it keys on Hermes' static IPs.

**This is the one part of the design that fails OPEN.** Everywhere else, a
missing piece crash-loops a container and you notice. If these rules are absent
— or are silently rebuilt away by a Docker restart — the result is a fully
functional, wholly uncontained agent and no error anywhere.

**Files:**
- Version-controlled: `appdata-templates/scripts/hermes-firewall.sh` (**the
  source of truth**; delivery per `appdata-templates/README.md`)
- Deploy to (on NAS): `/volume1/docker/scripts/hermes-firewall.sh`, `root:root 0750`
- Create: `docs/superpowers/verify/hermes-containment.sh`

**Interfaces:**
- Consumes: Hermes static IPs from Task 3.
- Produces: a `HERMES-CONTAIN` chain jumped from `DOCKER-USER` **and** from the
  `INPUT` path; two DSM scheduled tasks that reapply it.

#### Host facts you must not rediscover the hard way

1. **`DOCKER-USER` is only reached from `FORWARD`.** Container-to-**HOST**
   traffic goes via `INPUT` and never traverses `DOCKER-USER` at all. A
   `DOCKER-USER`-only script therefore does **not** block the agent from
   reaching `192.168.1.104:8123` (Home Assistant, `network_mode: host` — full
   IoT control), `:9000` (Portainer, backed by the *permissive* socket proxy,
   i.e. container create, i.e. root on the NAS), `:32400` (Plex), DSM
   `:5000/:5001`, or `:22` (sshd). Task 8's UniFi rule cannot see any of this
   either, because no packet ever reaches VLAN 20. An `INPUT` companion is
   mandatory.
   Note also that every **docker bridge gateway** address — `192.168.90.1`,
   `192.168.92.1`, `192.168.93.1`, `172.17.0.1` — *is* the host, so a rule
   written against `192.168.1.104` alone is trivially bypassed. The shipped
   script drops all host-bound traffic from the agent IPs instead.
2. **DNS is unaffected.** Docker's embedded resolver at `127.0.0.11` lives
   inside the container's own network namespace, so the agent's queries never
   appear as packets sourced from a hermes IP. dockerd forwards them upstream
   from the *host's* namespace with the host's own source address, matching no
   rule here. Verify anyway, in Step 4.
3. **On this host, `iptables` cannot address the built-in chains by name.**
   Confirmed 2026-09-09: `iptables -S INPUT` and `-S OUTPUT` both return
   `"No chain/target/match by that name."`, and `-S FORWARD` prints
   `DEFAULT_FORWARD`'s rules instead — while `iptables-save` shows all three
   perfectly well and custom chains (`DOCKER-USER`, `INPUT_FIREWALL`,
   `DEFAULT_FORWARD`) behave normally. So `-I INPUT 1 -j ...` may not work.
   The script tries it, **verifies the result with `iptables-save`** (which is
   authoritative), and falls back to `INPUT_FIREWALL` — the single custom chain
   `INPUT` unconditionally jumps to (`-A INPUT -j INPUT_FIREWALL`). Always
   audit with `iptables-save`, never `iptables -L INPUT`.
4. The real forward path is `FORWARD -> FORWARD_FIREWALL -> DEFAULT_FORWARD ->
   DOCKER-USER`; Synology inserts its own chains. `/usr/bin/iptables` is a
   Synology **shell wrapper** around `/usr/bin/xtables-legacy-multi`.

- [ ] **Step 1: Write the failing verification**

Create `docs/superpowers/verify/hermes-containment.sh`:

```bash
#!/bin/bash
# Run INSIDE the hermes container network namespace.
# Asserts a hijacked agent cannot reach the internet directly or pivot to the
# LAN, to the IoT VLAN, or to the HOST ITSELF.
set -u
command -v curl >/dev/null 2>&1 || { echo "ABORT: no curl in this image"; exit 2; }
fail=0
chk() { # name expected(allow|deny) command...
  if timeout 8 "${@:3}" >/dev/null 2>&1; then r=allow; else r=deny; fi
  if [ "$r" = "$2" ]; then echo "PASS $1 ($r)"; else echo "FAIL $1: got $r want $2"; fail=1; fi
}
chk "direct internet blocked"   deny  curl -s --max-time 5 https://example.com/
chk "direct openrouter blocked" deny  curl -s --max-time 5 https://openrouter.ai/
chk "via proxy allowed"         allow curl -s --max-time 8 -x 192.168.92.2:8888 https://openrouter.ai/api/v1/models
chk "LAN host blocked"          deny  curl -s --max-time 5 http://192.168.1.1/
chk "IoT VLAN blocked"          deny  curl -s --max-time 5 http://192.168.2.1/
chk "UDM mgmt blocked"          deny  curl -s --max-time 5 https://192.168.1.1:443/
# --- the HOST, which DOCKER-USER alone does not cover (finding I1) ---
chk "host Home Assistant blocked" deny curl -s --max-time 5 http://192.168.1.104:8123/
chk "host portainer blocked"    deny  curl -s --max-time 5 http://192.168.1.104:9000/
chk "host plex blocked"         deny  curl -s --max-time 5 http://192.168.1.104:32400/
chk "host DSM blocked"          deny  curl -s --max-time 5 http://192.168.1.104:5000/
# Every bridge gateway is also the host — a LAN-address rule alone misses these.
chk "bridge gw 92.1 blocked"    deny  curl -s --max-time 5 http://192.168.92.1:9000/
chk "bridge gw 90.1 blocked"    deny  curl -s --max-time 5 http://192.168.90.1:9000/
# --- must still work ---
chk "socket proxy reachable"    allow curl -s --max-time 5 http://192.168.93.2:2375/version
chk "DNS still resolves"        allow nslookup openrouter.ai
exit $fail
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
ssh nas 'cat > /tmp/hermes-containment.sh' < docs/superpowers/verify/hermes-containment.sh
ssh nas 'sudo /usr/local/bin/docker run --rm --network container:hermes -v /tmp/hermes-containment.sh:/t.sh:ro curlimages/curl:8.8.0 sh /t.sh'
```

Expected: every "blocked" check FAILS (currently allowed) — that is the gap this
task closes. The two `allow` checks should already pass.

- [ ] **Step 3: Deliver the firewall script to the NAS**

> **SUPERSEDED — source of truth is
> `appdata-templates/scripts/hermes-firewall.sh`; do not replay the heredoc that
> used to be here.** It was wrong in three ways, each of which silently produced
> a *less* contained agent than it appeared to:
>
> - **(a)** `DOCKER-USER` only — see host fact 1. It did not block the host at
>   all, so Home Assistant, Portainer, Plex, DSM and sshd were all reachable.
> - **(b)** Its idempotency loop
>   `while iptables -D DOCKER-USER -m comment --comment "hermes-containment"`
>   was a **no-op**: `iptables -D` needs a full rule spec or a rule number, and
>   a bare `--comment` match is neither. It deleted nothing, so every re-run
>   appended another twelve rules and the listing became unauditable. The
>   shipped script owns a dedicated `HERMES-CONTAIN` chain instead
>   (`-N` / `-F` / refill, with the jumps deleted by full rule spec and
>   re-inserted at position 1), which makes flush-and-refill genuinely
>   idempotent and the whole policy readable with `iptables -S HERMES-CONTAIN`.
> - **(c)** It allowed the entire `192.168.90.0/24` outbound, which is not just
>   Traefik — it is also Portainer, an unauthenticated Dozzle and every *arr
>   API. The shipped script narrows that to Traefik's address alone. That is a
>   partial, firewall-only mitigation of review finding C1 and **not** a
>   substitute for moving Hermes off the shared `t3_proxy` network.

```bash
ssh nas 'sudo mkdir -p /volume1/docker/scripts'
ssh nas 'cat > /tmp/hermes-firewall.sh' < appdata-templates/scripts/hermes-firewall.sh
ssh nas 'sudo install -o root -g root -m 0750 /tmp/hermes-firewall.sh /volume1/docker/scripts/hermes-firewall.sh && rm -f /tmp/hermes-firewall.sh'
```

- [ ] **Step 4: Apply and verify**

```bash
ssh nas 'sudo /volume1/docker/scripts/hermes-firewall.sh'
ssh nas 'sudo iptables -S HERMES-CONTAIN'
ssh nas 'sudo iptables-save -t filter | grep -E "^-A (INPUT|INPUT_FIREWALL|DOCKER-USER) -j HERMES-CONTAIN$"'
ssh nas 'sudo /usr/local/bin/docker run --rm --network container:hermes -v /tmp/hermes-containment.sh:/t.sh:ro curlimages/curl:8.8.0 sh /t.sh'
```

Expected: **all 14 checks PASS.** In particular
`direct openrouter blocked = deny` *and* `via proxy allowed = allow` — together
they prove the proxy is the only way out — plus `DNS still resolves = allow`,
which proves the rules did not take the embedded resolver with them.

Then prove idempotency, which the previous script did not have:

```bash
ssh nas 'sudo iptables -S HERMES-CONTAIN | wc -l'
ssh nas 'sudo /volume1/docker/scripts/hermes-firewall.sh >/dev/null && sudo iptables -S HERMES-CONTAIN | wc -l'
```

Expected: the same number both times.

- [ ] **Step 5: Persist — boot-up AND hourly**

DSM does not persist iptables rules, **and** a Docker package restart or a
`docker compose down/up` rebuilds the Docker chains without a reboot, silently
dropping containment while Hermes keeps running. A boot-up task alone is
therefore not enough. Create **two** tasks in
**DSM → Control Panel → Task Scheduler**, both User: `root`, both running
`/volume1/docker/scripts/hermes-firewall.sh`:

| # | Type | Trigger | Name |
|---|---|---|---|
| 1 | Triggered Task → User-defined script | Event: **Boot-up** | `hermes-firewall-boot` |
| 2 | Scheduled Task → User-defined script | **Daily**, "repeat every **1 hour**" | `hermes-firewall-hourly` |

(The existing `DNS rego` task on this NAS already uses the daily +
"repeat every N hours" form, so this pattern is known to work here.)

The script reports loudly when it had to repair a gap: if the chain or either
jump was missing on entry it logs three `CONTAINMENT WAS MISSING` lines to
stdout — captured in the task output — and to syslog via `logger`. Check for
them after any Docker package update:

```bash
ssh nas 'sudo grep -h "CONTAINMENT WAS MISSING" /var/log/messages* 2>/dev/null | tail'
```

Confirm both tasks exist (note: `synoschedtask` is **not** on root PATH):

```bash
ssh nas 'sudo /usr/syno/bin/synoschedtask --get | grep -i -A2 hermes'
```

A full reboot test is worthwhile but is the operator's call on timing.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/verify/hermes-containment.sh appdata-templates/scripts/hermes-firewall.sh
git commit -m "Add Hermes egress enforcement and containment verification"
```

The script is version-controlled deliberately — `/volume1/docker/scripts/` is
outside the `push.sh`-synced tree (`docker-compose.yml` + `compose/` only), so
a NAS rebuild that restores `compose/` restores everything *except* the one
control that fails open.

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
ssh nas 'sudo /usr/local/bin/docker exec traefik wget -qS -O /dev/null http://hermes:9119/ 2>&1 | head -5'
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
- Modify (on NAS): `/volume1/docker/appdata/hermes-etc/hermes.env` (**not**
  `/volume1/docker/appdata/hermes/.env`)
- Modify (on NAS): `/volume1/docker/appdata/hermes-etc/config.yaml` (**not**
  `/volume1/docker/appdata/hermes/config.yaml`)
- Modify (on NAS): `/volume1/docker/appdata/hermes-egress/filter`
- Templates in git: `appdata-templates/hermes/{config.yaml,hermes.env}`

> **THE PATHS CHANGED, AND THAT IS THE WHOLE POINT.** Earlier versions of this
> task wrote both files into `/volume1/docker/appdata/hermes`, which is
> bind-mounted **read-write** at `/opt/data`. Those two files carry every spec
> §4.7 control — `skills.auto_install`, `messaging.*.allowed_users`,
> `tool_loop_guardrails.non_interactive_hard_stop_enabled`,
> `dashboard.trusted_proxies`, `browser.enabled` — plus the OpenRouter key, the
> GitHub PAT and the dashboard credentials. An agent that can rewrite them and
> then restart itself through the socket proxy is reloading guardrails of its
> own choosing, which makes every one of them advisory rather than enforced
> (review finding C3).
>
> They now live in `hermes-etc`, root-owned and mounted `:ro`:
> `hermes-etc/config.yaml -> /opt/data/config.yaml:ro` and
> `hermes-etc/hermes.env -> /opt/data/.env:ro`.
>
> **Consequence, by design: changing agent configuration is now an OPERATOR
> ACTION ON THE HOST, followed by a container restart. There is no in-container
> write path and there is not meant to be** — the bind mounts are `:ro`, the
> rootfs is `read_only: true`, and `cap_drop: ALL` removes `CAP_DAC_OVERRIDE`.
> If you find yourself wanting the agent to edit its own config, that is the
> control working, not a bug.
>
> Ownership and mode are load-bearing and git records neither — see
> `appdata-templates/README.md`. `config.yaml` is `root:root 0644`;
> `hermes.env` is `root:10 0640` (group 10 is the container PGID and the only
> group the agent process holds, so it is the only group that can grant read;
> `root:1000` would leave it unreadable, and `0644` would put secrets on the
> world-read bit).

**Interfaces:**
- Consumes: `hermes` container (Task 3), egress filter (Task 2).
- Produces: an authenticated, model-backed, sender-allowlisted agent.

- [ ] **Step 1: Create the OpenRouter key with a hard cap**

In the OpenRouter dashboard, create a **dedicated key for Hermes** with a hard
monthly credit limit. Do not reuse an existing key — this key lives on an
internet-exposed agent and must be independently revocable and capped.

- [ ] **Step 2: Verify the config keys are actually read before relying on them**

Do this **first**. A key the application silently ignores is a control that does
not exist, and three of the §4.7 controls have not yet been confirmed against
this image. The image writes its own fully-commented example config to
`/opt/data/config.yaml` on first boot; that example contains `model.default`,
`model.provider`, `terminal.backend`,
`tool_loop_guardrails.non_interactive_hard_stop_enabled` and
`browser.extension_control.enabled` — but has **no** top-level `messaging:`
section, no `skills.auto_install` and no `dashboard.trusted_proxies`.

`model.default`, `model.provider` and `dashboard.public_url` are confirmed live:
with the checked-in `config.yaml` mounted, the container quotes all three back
in its own startup log. The remaining three are not. Confirm each, e.g. by
setting a deliberately invalid value and checking the container complains, or
via the image own config tooling:

```bash
ssh nas 'sudo /usr/local/bin/docker exec -u 1000:10 hermes hermes config get skills.auto_install'
ssh nas 'sudo /usr/local/bin/docker exec -u 1000:10 hermes hermes config get browser.enabled'
ssh nas 'sudo /usr/local/bin/docker exec -u 1000:10 hermes hermes config get dashboard.trusted_proxies'
```

If a key is not recognised, find the real one before continuing. Record the
outcome in `appdata-templates/hermes/config.yaml`, which tracks verification
status per key.

- [ ] **Step 3: Write secrets to `hermes-etc/hermes.env`**

`push.sh` syncs only `docker-compose.yml` and `compose/`, so these never enter
git. Write the file as root, then install it with the right owner and mode —
note the agent must **not** own it:

```bash
ssh nas 'umask 077; cat > /tmp/hermes.env <<EOF
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=jim
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$(openssl rand -base64 24)
HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(openssl rand -hex 32)
OPENROUTER_API_KEY=<paste-key-from-step-1>
EOF
sudo install -o root -g 10 -m 0640 /tmp/hermes.env /volume1/docker/appdata/hermes-etc/hermes.env
rm -f /tmp/hermes.env
ls -l /volume1/docker/appdata/hermes-etc/hermes.env'
```

Retrieve the generated password for your password manager:

```bash
ssh nas 'sudo grep BASIC_AUTH_PASSWORD /volume1/docker/appdata/hermes-etc/hermes.env'
```

> **KNOWN GAP — the dashboard auth provider is NOT configured by these
> variables.** Observed on this image (digest `a62824a4ec6f`): with
> `HERMES_DASHBOARD_HOST=0.0.0.0` and no auth provider registered, the container
> refuses to bind and prints the configuration it actually wants —
> `dashboard.basic_auth.username` plus `dashboard.basic_auth.password_hash` in
> **config.yaml**, the hash produced by the image own
> `plugins.dashboard_auth.basic.hash_password`. The
> `HERMES_DASHBOARD_BASIC_AUTH_*` environment variables above come from the
> plan, not from the image. This fails **closed** — an unconfigured dashboard
> serves nothing — but it means this step as written will not produce a working
> dashboard. Generate the hash, put it in `hermes-etc/config.yaml`, and keep the
> env vars only if they turn out to be read. A password *hash* is not a bearer
> secret, so config.yaml is the right home for it.

- [ ] **Step 4: Write `config.yaml`**

The checked-in template already carries the §4.7 controls. Edit it in git, then
deliver it — do **not** hand-write a divergent copy on the NAS, or the git copy
stops being the source of truth:

```bash
ssh nas 'cat > /tmp/config.yaml' < appdata-templates/hermes/config.yaml
ssh nas 'sudo install -o root -g root -m 0644 /tmp/config.yaml /volume1/docker/appdata/hermes-etc/config.yaml && rm -f /tmp/config.yaml'
```

The controls it must carry, all per spec §4.7:

```yaml
model:      { default: "anthropic/claude-sonnet-5", provider: "openrouter" }
dashboard:
  public_url: "https://hermes.bassford.net"
  trusted_proxies: ["192.168.90.254"]   # Traefik on t3_proxy. Bounded — never 0.0.0.0/0.
terminal:   { backend: "local" }        # the docker backend sandboxes by CREATING
                                        # containers — exactly the privilege the socket
                                        # proxy refuses. The container is the sandbox.
tool_loop_guardrails: { non_interactive_hard_stop_enabled: true }
skills:     { auto_install: false }     # manual install only; ClawHavoc-class registry risk
browser:    { enabled: false }          # Chromium on a J4125 is impractical, and this
                                        # removes the largest untrusted-content parsing
                                        # surface. Re-enabling needs shm_size: 1g.
```

- [ ] **Step 5: Restart and verify auth is enforced**

```bash
ssh nas 'sudo /usr/local/bin/docker restart hermes && sleep 25'
ssh nas 'sudo /usr/local/bin/docker exec traefik wget -qS -O /dev/null http://hermes:9119/ 2>&1 | head -3'
```

Expected: `401 Unauthorized`. If it returns `200`, the dashboard is
unauthenticated — **stop immediately** and fix before it is reachable. If the
container logs "Refusing to bind dashboard to 0.0.0.0", the auth provider is
still not configured — see the gap noted in Step 3.

Note the restart is done over SSH, not through the socket proxy: `hermes` is
deliberately **not** in the proxy restart allowlist.

Then confirm the guardrails really are immutable from inside:

```bash
ssh nas 'sudo /usr/local/bin/docker exec -u 1000:10 hermes sh -c "echo x >> /opt/data/config.yaml; echo x >> /opt/data/.env"'
```

Expected: `Permission denied` for both.

- [ ] **Step 6: Provision scoped git credentials**

The coding role needs git access. Create a **fine-grained GitHub PAT** scoped to
only the repos you intend to clone into `/volume1/code`, with
`Contents: read/write` and nothing else. Never an account-wide classic token —
that key sits on an internet-reachable agent.

```bash
ssh nas 'sudo sh -c "umask 077; echo GITHUB_TOKEN=<fine-grained-pat> >> /volume1/docker/appdata/hermes-etc/hermes.env"'
ssh nas 'sudo chown root:10 /volume1/docker/appdata/hermes-etc/hermes.env && sudo chmod 0640 /volume1/docker/appdata/hermes-etc/hermes.env'
```

- [ ] **Step 7: Connect one messaging channel and allowlist yourself**

Enable a single channel first (Telegram is simplest). Create the bot via
BotFather, then append the token to `hermes-etc/hermes.env` exactly as in Step 6.

Get your own numeric Telegram user ID (message `@userinfobot`), then add the
sender allowlist to `appdata-templates/hermes/config.yaml` and redeliver it per
Step 4. **The allowlist belongs in the read-only config**, never in `/opt/data`
— it is the control that stops the bot being an open shell:

```yaml
messaging:
  telegram:
    enabled: true
    allowed_users:
      - 123456789        # your numeric Telegram ID — replace
    reject_unknown: true
```

Add the channel API domain to the egress filter (edit
`appdata-templates/hermes-egress/filter` in git first, then deliver it), and
restart the proxy:

```bash
ssh nas 'cat > /tmp/filter' < appdata-templates/hermes-egress/filter
ssh nas 'sudo install -o root -g root -m 0644 /tmp/filter /volume1/docker/appdata/hermes-egress/filter && rm -f /tmp/filter'
ssh nas 'sudo /usr/local/bin/docker restart hermes-egress-proxy'
```

Verify from a *different* account that the bot ignores non-allowlisted senders.
An open bot is an open shell.

- [ ] **Step 8: Verify the model backend works end-to-end**

Send the agent a trivial message on the connected channel (e.g. "reply with the
word pong"). Expected: a reply. If it times out, check the egress filter
contains `openrouter.ai` and that the proxy was restarted.

- [ ] **Step 9: Commit**

```bash
git add docs/ appdata-templates/
git commit -m "Document Hermes agent configuration and secret handling"
```

Only templates and documentation are committed — no real secret ever is.

---

### Task 7: Threat-model acceptance test

Proves the spec §5 success criterion: a **fully hijacked** agent stays
contained. Every check runs from inside the agent own context, i.e. with
everything an attacker would have.

**Files:**
- Create: `docs/superpowers/verify/hermes-threat-model.sh`

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: a repeatable containment regression test.

- [ ] **Step 1: Write the acceptance test**

```bash
#!/bin/bash
# Spec §5: assert a fully-hijacked agent cannot escalate, pivot, or exfiltrate.
# Run: sudo /usr/local/bin/docker exec -u 1000:10 hermes bash /opt/data/hermes-threat-model.sh
set -u

# Without this preamble most checks below pass VACUOUSLY: chk treats any
# non-zero exit as "deny", and "curl: not found" is non-zero. An image with no
# curl would report near-perfect containment while proving nothing at all.
command -v curl >/dev/null 2>&1 || { echo "ABORT: no curl in this image; every network check would pass vacuously"; exit 2; }

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
echo "-- and restart is SCOPED, not universal --"
chk "restart self"          deny curl -sf -X POST $D/containers/hermes/restart
chk "restart pihole (DNS)"  deny curl -sf -X POST $D/containers/pihole/restart
chk "restart traefik"       deny curl -sf -X POST $D/containers/traefik/restart
chk "restart cloudflared"   deny curl -sf -X POST $D/containers/cloudflared/restart
chk "restart egress proxy"  deny curl -sf -X POST $D/containers/hermes-egress-proxy/restart
echo "-- but ops still works --"
chk "list containers"    allow curl -sf "$D/containers/json?all=1"
chk "read logs"          allow curl -sf "$D/containers/plex/logs?stdout=1&tail=1"

echo "-- cannot pivot to the LAN or the router --"
chk "router UI"          deny curl -s --max-time 5 https://192.168.1.1/
chk "IoT VLAN"           deny curl -s --max-time 5 http://192.168.2.1/

echo "-- cannot pivot to the HOST (DOCKER-USER alone does not cover this) --"
chk "host Home Assistant" deny curl -s --max-time 5 http://192.168.1.104:8123/
chk "host portainer"      deny curl -s --max-time 5 http://192.168.1.104:9000/
chk "host plex"           deny curl -s --max-time 5 http://192.168.1.104:32400/
chk "host DSM"            deny curl -s --max-time 5 http://192.168.1.104:5000/
# Every docker bridge gateway IS the host, by a different address.
chk "bridge gw 192.168.92.1" deny curl -s --max-time 5 http://192.168.92.1:9000/
chk "bridge gw 192.168.90.1" deny curl -s --max-time 5 http://192.168.90.1:9000/

echo "-- cannot exfiltrate --"
chk "arbitrary host"     deny curl -s --max-time 5 https://example.com/
chk "non-allowlisted via proxy" deny curl -s --max-time 8 -x 192.168.92.2:8888 https://pastebin.com/

echo "-- cannot read what it should not --"
chk "stack secrets"      deny cat /volume1/docker/secrets/cf_dns_api_token
chk "media library"      deny ls /data/media
# NOTE: this reads the CONTAINER /etc/shadow, not the host one. The host file
# is not reachable from here at all -- that is the point -- so this is an
# in-container privilege check, not a host-escape check. It was previously
# mislabelled "host etc shadow", which overstated what it proves.
chk "container /etc/shadow" deny cat /etc/shadow
echo "-- and cannot rewrite its own guardrails --"
chk "rewrite config.yaml" deny sh -c 'echo x >> /opt/data/config.yaml'
chk "rewrite .env"        deny sh -c 'echo x >> /opt/data/.env'
echo "-- but its own workspace works --"
chk "code mount"         allow ls /opt/code

echo "-- cannot escalate --"
chk "write to rootfs"    deny touch /usr/local/bin/pwn
chk "sudo"               deny sudo -n true

echo "-- resource limits that this kernel ACTUALLY enforces --"
# NOT PidsLimit: DSM 4.4.302 has no pids cgroup, docker inspect returns nil,
# and asserting it fails permanently. See Global Constraints.
grep -q "Max processes  *1024" /proc/self/limits \
  && echo "PASS rlimit nproc 1024" || { echo "FAIL rlimit nproc"; fail=1; }
[ "$(cat /sys/fs/cgroup/cpu/cpu.shares)" = "512" ] \
  && echo "PASS cpu.shares 512" || { echo "FAIL cpu.shares"; fail=1; }

exit $fail
```

- [ ] **Step 2: Run it**

```bash
ssh nas 'cat > /tmp/hermes-threat-model.sh' < docs/superpowers/verify/hermes-threat-model.sh
ssh nas 'sudo cp /tmp/hermes-threat-model.sh /volume1/docker/appdata/hermes/ && sudo chown 1000:10 /volume1/docker/appdata/hermes/hermes-threat-model.sh'
ssh nas 'sudo /usr/local/bin/docker exec -u 1000:10 hermes bash /opt/data/hermes-threat-model.sh'
```

Expected: **every check PASSes.** Any FAIL is a containment hole — fix it before
considering the deployment live. Note the three `allow` checks: if
`list containers`, `read logs` or `code mount` fail, the containment is too
tight and the ops/coding roles are broken.

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
ssh nas 'sudo /usr/local/bin/docker run --rm --network container:hermes curlimages/curl:8.8.0 \
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
