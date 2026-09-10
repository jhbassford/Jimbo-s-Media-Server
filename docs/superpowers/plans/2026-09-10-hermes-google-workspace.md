# Hermes Google Workspace Access — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Hermes read access to Gmail, Calendar and Drive/Docs plus calendar writes and Gmail drafts/send, with the Google OAuth token held in a container Hermes cannot read.

**Architecture:** A hardened `hermes-google-mcp` container runs `taylorwilsdon/google_workspace_mcp` in streamable-HTTP mode, holding the OAuth token in a root-owned volume never mounted into Hermes. Hermes reaches it as a remote MCP server over the existing `hermes_net`. The MCP container's own egress is allowlisted to Google by a second tinyproxy on a dedicated two-member network, enforced by `DOCKER-USER` + `INPUT_FIREWALL` rules keyed to its two source IPs. Hermes' own egress filter and firewall rules are untouched.

**Tech Stack:** Docker Compose v2.20.1 (Docker 24.0.2), `taylorwilsdon/google_workspace_mcp`, Tinyproxy, Traefik 3.7 (file-provider rules), Cloudflare Tunnel + Access, iptables, Google OAuth 2.0.

**Spec:** `docs/superpowers/specs/2026-09-10-hermes-google-workspace-design.md`

## Global Constraints

- Host: `jimbos-server`, `192.168.1.104`, SSH alias `nas`. DSM kernel `4.4.302`.
- **`sudo docker` does NOT work — use `sudo /usr/local/bin/docker`.**
- **`scp` to this NAS is broken** (SSH subsystem error). Use `ssh nas 'cat > /path/file' < localfile`.
- Passwordless sudo works, so `ssh nas 'sudo ...'` is non-interactive.
- **Never put a top-level `networks:` block in an included compose file.** Networks are declared only in the root `docker-compose.yml`. A stray one previously broke *every* compose command on this NAS.
- **Never run a bare `docker compose up -d`** — always name the service, or you recreate the entire live stack (Plex, *arr, Pi-hole DNS for the house).
- **`pids_limit` and `cpus` are permanently unavailable on this kernel. Do not assert them.** Substitutes: `ulimits: nproc` (RLIMIT_NPROC) and `cpu_shares`.
- All images pinned by **digest**, never `:latest`. **No** `com.centurylinklabs.watchtower.enable` label on anything in this plan.
- Existing networks: `t3_proxy` `.90`, `socket_proxy` `.91`, `hermes_net` `.92`, `hermes_socket` `.93`, `hermes_ingress` `.94`. **New: `hermes_google` = `192.168.95.0/24`.**
- New static IPs: `hermes-google-mcp` = `192.168.92.3` (hermes_net) and `192.168.95.10` (hermes_google); `hermes-google-egress` = `192.168.95.2`.
- **Hermes' `appdata/hermes-egress/filter` and its `DOCKER-USER` rules must not change.** If a task appears to require it, stop — the design is being violated.
- Traefik routes live in `/volume1/docker/appdata/traefik3/rules/udms/apps.yml` **on the NAS**, outside the synced tree, edited via SSH.
- **Standing rule: run `./pull.sh` and reconcile `git status` before every `./push.sh`.** The NAS has been ahead of git before.
- The NAS's system `python3` has **no `yaml` module`.** Use awk/sed for host-side parsing.
- systemd 219 predates `systemctl --now`; enable and start are separate.
- Work on branch `hermes-agent`. Verification is by observed command output — no step is complete on assumption.
- **`<angle-bracket>` values are deliberate, not unfinished plan.** Every one is a
  tool name, image digest or UID that Task 1/3/4 *discovers from the live system*.
  Spec §5 forbids naming tools in advance for the same reason this repo treats an
  unread config key as a control that does not exist: an invented identifier is a
  control that silently does nothing. Fill each from the task named beside it;
  never guess one, and never proceed with a bracket still in a deployed file.
- **Spec §7.1 is a standing rule, not a task: no unattended mail reading.** No cron
  job, no scheduled brief, no webhook path may pull Gmail without the operator in
  the loop. Connecting mail means anyone who can email Jim can put text in front of
  the agent; a "morning brief" on a timer is precisely the unattended injection
  path. `approvals.unattended_mode: deny` supports this and is asserted in Task 9.
  If a later task or follow-up wants scheduled mail access, that is a spec change.
- **Note:** `appdata-templates/hermes-egress/filter` currently has one uncommitted line (`setup.hermes-agent.nousresearch.com`) from the Telegram work. Leave it alone; do not include it in this plan's commits.

---

### Task 1: Google OAuth client — the go/no-go (spec §9)

Blocks every other task. If durable refresh tokens are not obtainable for restricted scopes on this personal account, the design changes shape and is revised rather than worked around. **Build nothing until this passes.**

**Files:**
- Create: `docs/superpowers/verify/google-oauth-status.md` (a record of what was observed, since none of this lives in the repo)

**Interfaces:**
- Consumes: nothing.
- Produces: a Google Cloud OAuth 2.0 **Desktop-type client** in **In production** publishing status; `client_secret.json` on the NAS; the verified list of granted scopes.

- [ ] **Step 1: Create the project and enable exactly the APIs the design needs**

Operator action in the browser. At <https://console.cloud.google.com/>:
create a project (suggested name `hermes-nas`), then in **APIs & Services → Library** enable exactly these five and no others:

```
Gmail API
Google Calendar API
Google Drive API
Google Docs API
People API          <- required: the server calls userinfo to identify the account
```

Do **not** enable Sheets, Slides, Chat, Forms or Tasks. Spec §11 puts them out of scope, and an enabled API is a surface.

- [ ] **Step 2: Create the OAuth client**

**APIs & Services → Credentials → Create Credentials → OAuth 2.0 Client ID.**
Application type: **Web application** (not Desktop — this server receives the callback on a real HTTPS URL, and Desktop clients cannot register one).

Authorised redirect URI — add exactly one, and note the hostname is decided here and reused in Task 5:

```
https://gws.bassford.net/oauth2callback
```

- [ ] **Step 3: Publish to production — this is the go/no-go**

**APIs & Services → OAuth consent screen → Audience.** If publishing status reads **Testing**, click **Publish app** so it reads **In production**.

Expected: status becomes `In production`, with an "unverified app" notice and a 100-user cap. That is fine and expected for single-user use.

**STOP CONDITION.** If Google refuses to publish without verification for these scopes, or forces a verification submission for `gmail.readonly` / `drive.readonly`, do not proceed and do not work around it. Report back — spec §9 says the design is revised.

Why this matters: clients in **Testing** issue refresh tokens that **expire after 7 days**, which makes a headless agent useless.

- [ ] **Step 4: Record what was actually observed**

Create `docs/superpowers/verify/google-oauth-status.md`:

```markdown
# Google OAuth client status (spec §9 go/no-go)

Recorded: <DATE>

- Project: hermes-nas
- Client type: Web application
- Redirect URI: https://gws.bassford.net/oauth2callback
- Publishing status: In production   <- MUST be this, not "Testing"
- APIs enabled: Gmail, Calendar, Drive, Docs, People
- Scopes requested (spec §5):
    https://www.googleapis.com/auth/gmail.readonly
    https://www.googleapis.com/auth/gmail.compose
    https://www.googleapis.com/auth/calendar.events
    https://www.googleapis.com/auth/drive.readonly
    https://www.googleapis.com/auth/documents.readonly

## Durability re-check — DO THIS, it is the whole point of Task 1

Publishing status "In production" is the *reason* to expect durable refresh
tokens, not proof of it. Proof takes 8 days. After Task 6 completes, set a
reminder for +8 days and confirm the MCP container still serves a Gmail call
with no re-consent. Record the result here.

Re-check due: <DATE + 8 days>
Result: <PENDING>
```

- [ ] **Step 5: Download the client secret onto the NAS**

Download the client JSON from the Credentials page. Then (remember: `scp` is broken here):

```bash
ssh nas 'sudo mkdir -p /volume1/docker/appdata/hermes-google-etc'
ssh nas 'sudo tee /volume1/docker/appdata/hermes-google-etc/client_secret.json >/dev/null' < ~/Downloads/client_secret_*.json
ssh nas 'sudo chown root:root /volume1/docker/appdata/hermes-google-etc/client_secret.json && sudo chmod 0400 /volume1/docker/appdata/hermes-google-etc/client_secret.json'
ssh nas 'sudo ls -l /volume1/docker/appdata/hermes-google-etc/client_secret.json'
```

Expected: `-r-------- 1 root root ... client_secret.json`

- [ ] **Step 6: Commit the status record**

```bash
git add docs/superpowers/verify/google-oauth-status.md
git commit -m "Task 1: Google OAuth client published to production, go/no-go passed"
```

---

### Task 2: Google egress allowlist proxy

Built *before* the MCP server so that container never runs with unfiltered egress, mirroring how Task 2 preceded Task 3 in the parent plan.

**Files:**
- Create: `compose/hermes-google-egress.yml`
- Create: `appdata-templates/hermes-google-egress/tinyproxy.conf`
- Create: `appdata-templates/hermes-google-egress/filter`
- Modify: `docker-compose.yml` (networks block + `include:` list)

**Interfaces:**
- Consumes: nothing.
- Produces: service `hermes-google-egress` at `192.168.95.2:8888` on network `hermes_google`, accepting clients from `192.168.95.0/24` only.

- [ ] **Step 1: Write the filter**

Create `appdata-templates/hermes-google-egress/filter`. Tinyproxy `FilterExtended` regexes match the CONNECT hostname:

```
^oauth2\.googleapis\.com$
^www\.googleapis\.com$
^gmail\.googleapis\.com$
^docs\.googleapis\.com$
^accounts\.google\.com$
^openidconnect\.googleapis\.com$
```

`www.googleapis.com` covers Calendar, Drive and discovery documents; Gmail and Docs have their own hosts. `accounts.google.com` is needed for token revocation and some OIDC paths. Step 5 below discovers empirically whether anything is missing — do not guess additions in advance, and do not add a wildcard.

- [ ] **Step 2: Write the tinyproxy config**

Create `appdata-templates/hermes-google-egress/tinyproxy.conf`. **Derive it from `appdata-templates/hermes-egress/tinyproxy.conf` — read that file first and diff against it when done.** It is the proven-working config on this host; this one differs only in the ACL, and in pool sizes scaled to a single client. Do not write it from memory.

```
# SOURCE OF TRUTH: this file (and ./filter beside it) is the checked-in copy of
# /volume1/docker/appdata/hermes-google-egress/tinyproxy.conf. On a rebuild,
# copy both verbatim to that NAS path.
#
# Derived from appdata-templates/hermes-egress/tinyproxy.conf. Differences, all
# deliberate:
#   Allow 192.168.95.0/24  -- NOT .92. Load-bearing: tinyproxy's ACL is
#     source-IP based, so allowing the .92 net would let the Hermes agent use
#     this proxy to reach Google and defeat the whole design.
#   Pool sizes reduced (MaxClients 50->20, StartServers 5->2,
#     MaxSpareServers 10->5) -- this proxy has exactly ONE client, the MCP
#     container, where the other serves the agent itself.
#   FilterURLs Off added -- explicit statement of intent; the filter matches
#     CONNECT hostnames, never URL paths. Same as the default.
# Everything else is byte-identical to the working file, including the
# StartServers/MinSpare/MaxSpare/MaxRequestsPerChild block, without which
# tinyproxy refuses to start ("StartServers" must be greater than zero).
User nobody
Group nogroup
Port 8888
Listen 0.0.0.0
Timeout 600
MaxClients 20
Allow 192.168.95.0/24
Filter "/etc/tinyproxy/filter"
FilterDefaultDeny Yes
FilterExtended On
FilterCaseSensitive Off
FilterURLs Off
ConnectPort 443
DisableViaHeader Yes
StartServers 2
MinSpareServers 2
MaxSpareServers 5
MaxRequestsPerChild 0
```

`Allow 192.168.95.0/24` is the line that keeps Hermes out: it is on `192.168.92.0/24` and is therefore refused by source IP even if it discovers this proxy's address. `ConnectPort 443` alone means no CONNECT to any other port. `FilterDefaultDeny Yes` makes the filter an allowlist.

- [ ] **Step 3: Write the compose file**

Create `compose/hermes-google-egress.yml`. Every deviation below is inherited from `compose/hermes-egress-proxy.yml` and is already proven on this host — do not re-derive them:

```yaml
services:
  # Domain-allowlisting forward proxy for the Google MCP container ONLY.
  # This is the ALLOWLIST; the DOCKER-USER rules in Task 6 are the ENFORCEMENT.
  #
  # It is on hermes_google (a TWO-MEMBER network), NOT hermes_net, and that is
  # load-bearing: tinyproxy's ACL is source-IP based, so a proxy on hermes_net
  # would accept Hermes at 192.168.92.10 as a client and hand it a route to
  # Google -- defeating the design's core claim that Hermes' own egress
  # allowlist is unchanged. See spec section 3.
  #
  # Deviations from a naive config, all inherited from hermes-egress-proxy.yml
  # where they were established the hard way:
  #   1. entrypoint: invokes /usr/bin/tinyproxy directly. The image's default
  #      run.sh does `sed -i` on tinyproxy.conf, which fails "Read-only file
  #      system" against our :ro mount. Invoking the binary directly bypasses
  #      it and keeps the conf genuinely read-only -- the property that matters,
  #      since a compromised proxy must not rewrite its own allowlist.
  #   2. user: "65534:65533" (nobody:nogroup numeric). With cap_drop: ALL there
  #      is no CAP_SETUID/CAP_SETGID, so tinyproxy's own root->nobody drop fails
  #      ("Unable to change to group 'nogroup'"). Starting already-unprivileged
  #      sidesteps the drop with zero capabilities restored.
  #   3. tmpfs /tmp alongside read_only: true (NOT instead of it). tinyproxy's
  #      shared-memory allocator open()s a real file under /tmp, unlinks it and
  #      mmaps it; with no writable /tmp that fails EROFS and surfaces as
  #      "Could not allocate memory for child counting."
  hermes-google-egress:
    # Same pinned digest as hermes-egress-proxy (monokal/tinyproxy). Base is
    # Alpine 3.10, EOL -- pinning freezes it rather than fixing it. Replacing
    # both proxies with a maintained/self-built tinyproxy image is a known
    # follow-up carried over from the parent plan, not new debt from this one.
    image: monokal/tinyproxy@sha256:2c1b6f187fe18a993ec6e88cdb12c8f1d28d7416bd73492289aa5f74f687c672
    container_name: hermes-google-egress
    restart: unless-stopped
    user: "65534:65533"
    entrypoint: ["/usr/bin/tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]
    mem_limit: 64M
    read_only: true
    tmpfs:
      - /tmp:noexec,nosuid,nodev,size=16m
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    volumes:
      - $DOCKERDIR/appdata/hermes-google-egress/tinyproxy.conf:/etc/tinyproxy/tinyproxy.conf:ro
      - $DOCKERDIR/appdata/hermes-google-egress/filter:/etc/tinyproxy/filter:ro
    networks:
      hermes_google:
        ipv4_address: 192.168.95.2
```

- [ ] **Step 4: Declare the network and include the file**

In `docker-compose.yml`, add to the `networks:` block (matching the style of the existing `hermes_*` entries):

```yaml
  hermes_google:
    name: hermes_google
    driver: bridge
    ipam:
      config:
        - subnet: 192.168.95.0/24
```

and add `- compose/hermes-google-egress.yml` to the `include:` list.

- [ ] **Step 5: Deploy and verify it starts, denies by default, and allows Google**

```bash
./pull.sh && git status --short      # STANDING RULE - reconcile before push
./push.sh
ssh nas 'sudo mkdir -p /volume1/docker/appdata/hermes-google-egress'
ssh nas 'sudo tee /volume1/docker/appdata/hermes-google-egress/tinyproxy.conf >/dev/null' < appdata-templates/hermes-google-egress/tinyproxy.conf
ssh nas 'sudo tee /volume1/docker/appdata/hermes-google-egress/filter >/dev/null' < appdata-templates/hermes-google-egress/filter
ssh nas 'sudo chown -R root:root /volume1/docker/appdata/hermes-google-egress && sudo chmod 0644 /volume1/docker/appdata/hermes-google-egress/*'
ssh nas 'cd /volume1/docker && sudo /usr/local/bin/docker compose up -d hermes-google-egress'
ssh nas 'sudo /usr/local/bin/docker logs hermes-google-egress'
```

Expected in logs: `Not running as root, so not changing UID/GID`, then listening. **No** `StartServers` error, **no** `Could not allocate memory for child counting`.

Then prove the allowlist from a throwaway container on that network:

```bash
ssh nas 'sudo /usr/local/bin/docker run --rm --network hermes_google curlimages/curl:latest \
  -s -o /dev/null -w "google=%{http_code}\n" --max-time 10 \
  -x http://192.168.95.2:8888 https://www.googleapis.com/discovery/v1/apis'
ssh nas 'sudo /usr/local/bin/docker run --rm --network hermes_google curlimages/curl:latest \
  -s -o /dev/null -w "evil=%{http_code}\n" --max-time 10 \
  -x http://192.168.95.2:8888 https://example.com'
```

Expected: `google=200`, and `evil=403` (or a curl failure — tinyproxy refuses the CONNECT). If `evil` succeeds, `FilterDefaultDeny` is not in effect — stop and fix before Task 3.

- [ ] **Step 6: Commit**

```bash
git add compose/hermes-google-egress.yml appdata-templates/hermes-google-egress/ docker-compose.yml
git commit -m "Task 2: googleapis-only egress proxy on a two-member network"
```

---

### Task 3: Obtain and pin the MCP server image

**Files:**
- Create: `docs/superpowers/verify/google-mcp-image.md`

**Interfaces:**
- Consumes: nothing.
- Produces: an image reference pinned by digest, for use in Task 4.

- [ ] **Step 1: Prefer a published image; fall back to building**

Check for a published image first — fewer moving parts than a local build, and it can still be digest-pinned:

```bash
ssh nas 'sudo /usr/local/bin/docker pull ghcr.io/taylorwilsdon/google_workspace_mcp:latest' \
  || echo "NO PUBLISHED IMAGE - build from source instead"
```

If that fails, build from source on the NAS (the project's own documented path). `git` availability on DSM is not guaranteed — check first and fall back to a tarball, which needs no git:

```bash
ssh nas 'command -v git || echo NO-GIT'
ssh nas 'cd /tmp && curl -fsSL -o gwm.tar.gz https://github.com/taylorwilsdon/google_workspace_mcp/archive/refs/heads/main.tar.gz && tar xzf gwm.tar.gz'
ssh nas 'cd /tmp/google_workspace_mcp-main && sudo /usr/local/bin/docker build -t workspace-mcp:local .'
```

- [ ] **Step 2: Resolve and record the digest**

```bash
ssh nas 'sudo /usr/local/bin/docker images --digests | grep -i workspace-mcp'
ssh nas 'sudo /usr/local/bin/docker inspect --format="{{.Id}}" workspace-mcp:local'
```

A locally built image has no registry digest — record the image **ID** and pin the compose file to that ID. Note in the record which of the two applies, because they are pinned differently.

- [ ] **Step 3: Enumerate the real tool names — spec §5 requires this**

The design deliberately does not name tools. Get the actual list:

```bash
ssh nas 'sudo /usr/local/bin/docker run --rm workspace-mcp:local --help'
```

Record every gmail/calendar/drive/docs tool name verbatim. Map each to spec §1: keep search/read/draft/send for Gmail, all event operations for Calendar, read-only for Drive/Docs. Everything else — and specifically anything matching Drive share, Drive delete, Drive upload, Gmail label/filter/settings — goes into `--disabled-tools`.

- [ ] **Step 4: Write the record**

Create `docs/superpowers/verify/google-mcp-image.md` capturing: the image ref (digest or ID), how it was obtained, the full tool list, and the derived `--tools` / `--disabled-tools` values. Task 4 consumes this file; Task 9 asserts the live tool list still matches it.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/verify/google-mcp-image.md
git commit -m "Task 3: pin the Google Workspace MCP image and enumerate its tools"
```

---

### Task 4: The MCP container

**Files:**
- Create: `compose/hermes-google-mcp.yml`
- Modify: `docker-compose.yml` (`include:` list)
- Modify: `appdata-templates/README.md` (ownership/mode record — git preserves neither)

**Interfaces:**
- Consumes: image ref and tool lists from Task 3; `client_secret.json` from Task 1.
- Produces: service `hermes-google-mcp` at `http://192.168.92.3:8000/mcp`, credential volume at `$DOCKERDIR/appdata/hermes-google/credentials`.

- [ ] **Step 1: Write the compose file**

Create `compose/hermes-google-mcp.yml`. Substitute the digest/ID from Task 3 and the tool lists from Task 3 Step 3:

```yaml
services:
  # Holds the Google OAuth token. THIS CONTAINER IS THE CREDENTIAL BOUNDARY --
  # the entire design exists so that /opt/data (Hermes' writable mount) contains
  # no Google credential and a fully hijacked agent has nothing to steal.
  #
  # Reachable from Hermes ONLY as http://192.168.92.3:8000/mcp on hermes_net.
  # No ports: published. Its egress goes through hermes-google-egress on
  # hermes_google, a two-member network Hermes cannot join.
  #
  # NO watchtower label -- an auto-updating container that holds a send-capable
  # Gmail token is a supply-chain hole. Bump the pin by hand, then re-run
  # docs/superpowers/verify/hermes-threat-model.sh, which asserts the tool list
  # and will fail loudly if an upstream bump added tools.
  hermes-google-mcp:
    image: <DIGEST-OR-ID FROM TASK 3>
    container_name: hermes-google-mcp
    restart: unless-stopped
    read_only: true
    tmpfs:
      - /tmp:noexec,nosuid,nodev,size=64m
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    mem_limit: 1g
    memswap_limit: 1g   # without this Docker defaults swap to 2x memory
    cpu_shares: 256
    ulimits:
      nproc: 512
      nofile: 2048
    # cpus: and pids_limit deliberately absent -- unavailable on this kernel.
    command:
      - "--transport"
      - "streamable-http"
      - "--tools"
      - "gmail"
      - "calendar"
      - "drive"
      - "docs"
      - "--tool-tier"
      - "core"
      - "--disabled-tools"
      # EXACT names from Task 3 Step 3. Anything that shares, deletes, uploads,
      # or touches labels/filters/settings. Do not invent names here.
      - "<TOOL>"
      - "<TOOL>"
    environment:
      TZ: $TZ
      WORKSPACE_MCP_PORT: 8000
      # Consent callback. The Traefik route for this hostname exists ONLY during
      # Task 5 and is removed afterwards -- token refresh does not need it.
      WORKSPACE_EXTERNAL_URL: "https://gws.bassford.net"
      GOOGLE_OAUTH_REDIRECT_URI: "https://gws.bassford.net/oauth2callback"
      GOOGLE_CLIENT_SECRET_PATH: /config/client_secret.json
      # OAuth 2.1 multi-user auth is NOT wanted -- single user, plain OAuth 2.0.
      # Leaving MCP_ENABLE_OAUTH21 unset also means only /oauth2callback needs
      # forwarding in Task 5, not /oauth2/* and /.well-known/*.
      HTTPS_PROXY: http://192.168.95.2:8888
      HTTP_PROXY: http://192.168.95.2:8888
      NO_PROXY: 192.168.92.0/24,192.168.95.0/24,localhost,127.0.0.1
    volumes:
      # Credential store. Root-owned 0700. NEVER mounted into hermes -- that is
      # the whole point. Writable because the server persists the refreshed
      # token here.
      - $DOCKERDIR/appdata/hermes-google/credentials:/credentials
      # client_secret.json root:root 0400 :ro -- the agent never sees it and
      # neither does this container's own write path.
      - $DOCKERDIR/appdata/hermes-google-etc/client_secret.json:/config/client_secret.json:ro
    networks:
      hermes_net:
        ipv4_address: 192.168.92.3
      hermes_google:
        ipv4_address: 192.168.95.10
```

- [ ] **Step 2: Create the credential directory with the right ownership**

The container's runtime UID comes from the image — read it, then chown to match, because `read_only: true` plus `cap_drop: ALL` means it cannot fix permissions itself:

```bash
ssh nas 'sudo /usr/local/bin/docker inspect --format="{{.Config.User}}" workspace-mcp:local'
ssh nas 'sudo mkdir -p /volume1/docker/appdata/hermes-google/credentials'
ssh nas 'sudo chown -R <UID>:<GID> /volume1/docker/appdata/hermes-google/credentials'
ssh nas 'sudo chmod 0700 /volume1/docker/appdata/hermes-google/credentials'
ssh nas 'sudo ls -ld /volume1/docker/appdata/hermes-google/credentials'
```

Expected: `drwx------ ... <UID> <GID>`.

If the image runs as root, add `user: "<uid>:<gid>"` to the compose file and re-check — a root-running credential container contradicts the house standard. If the image refuses a non-root UID, record why and treat it as a finding to report, not something to silently accept.

- [ ] **Step 3: Deploy**

```bash
./pull.sh && git status --short
./push.sh
ssh nas 'cd /volume1/docker && sudo /usr/local/bin/docker compose up -d hermes-google-mcp'
ssh nas 'sudo /usr/local/bin/docker logs hermes-google-mcp'
```

Expected: the server binds `0.0.0.0:8000` and reports no credentials yet. Not being authenticated is the expected state until Task 5 — that is not a defect.

- [ ] **Step 4: Verify it is reachable from Hermes and nowhere else**

```bash
# From Hermes -- MUST succeed (this is the only path that matters).
ssh nas 'sudo /usr/local/bin/docker exec -u 1000:10 hermes curl -s -o /dev/null -w "%{http_code}\n" --max-time 8 http://192.168.92.3:8000/mcp'
# From the host LAN side -- MUST fail; no ports are published.
ssh nas 'curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://192.168.1.104:8000/ || echo REFUSED'
```

Expected: a real HTTP status from Hermes (405/406/400 are all fine — it proves reachability), and `REFUSED` from the host.

- [ ] **Step 5: Verify the credential boundary now, before a token exists**

```bash
ssh nas 'sudo /usr/local/bin/docker exec -u 1000:10 hermes ls /credentials 2>&1 || echo "NO SUCH PATH - correct"'
ssh nas 'sudo /usr/local/bin/docker inspect hermes --format="{{range .Mounts}}{{.Source}} {{end}}" | tr " " "\n" | grep -i google || echo "NO GOOGLE MOUNT IN HERMES - correct"'
```

Expected: both print the "correct" message.

- [ ] **Step 6: Record ownership/mode in the templates README and commit**

Add a `hermes-google` section to `appdata-templates/README.md` recording: `credentials/` → `<uid>:<gid>` `0700`, `client_secret.json` → `root:root` `0400`. Git preserves neither; that README is the only record.

```bash
git add compose/hermes-google-mcp.yml docker-compose.yml appdata-templates/README.md
git commit -m "Task 4: Google MCP container, credential volume unreachable from Hermes"
```

---

### Task 5: OAuth consent through a temporary route

**Files:**
- Modify (on the NAS, outside the synced tree): `/volume1/docker/appdata/traefik3/rules/udms/apps.yml`
- Modify: `docs/superpowers/verify/google-oauth-status.md`

**Interfaces:**
- Consumes: the container from Task 4, the OAuth client from Task 1.
- Produces: a persisted, scope-verified token in the credential volume.

- [ ] **Step 1: Add the CNAME**

In Cloudflare DNS: `gws` → `<tunnel-id>.cfargotunnel.com`, proxied. Same tunnel id as `hermes.bassford.net`.

- [ ] **Step 2: Put the hostname behind Cloudflare Access**

Add `gws.bassford.net` to the same single-user Access policy that protects `hermes.bassford.net`. Do this **before** the Traefik route exists, so the endpoint is never briefly open.

- [ ] **Step 3: Attach the container to hermes_ingress and add the temporary route**

Traefik can only reach containers on a shared network. Add to `compose/hermes-google-mcp.yml` under `networks:`:

```yaml
      hermes_ingress:
        ipv4_address: 192.168.94.11
```

Per spec §8 this ends `hermes_ingress`'s two-member property and grants no new capability, since Hermes already reaches this container on `hermes_net`.

Then, on the NAS, add to `apps.yml` — matching the existing `hermes-rtr-file@file` entry's shape and using `chain-no-auth` per this repo's convention:

```yaml
    gws-rtr:
      rule: "Host(`gws.bassford.net`)"
      entryPoints: ["websecure"]
      middlewares: ["chain-no-auth@file"]
      service: gws-svc
      tls: {}
```

and under `services:`:

```yaml
    gws-svc:
      loadBalancer:
        servers:
          - url: "http://192.168.94.11:8000"
```

Traefik's file provider hot-reloads `apps.yml`, so the *route* needs no restart. The **container does** — a running container does not join a new network without being recreated, and skipping this makes consent fail with no obvious cause:

```bash
./pull.sh && git status --short
./push.sh
ssh nas 'cd /volume1/docker && sudo /usr/local/bin/docker compose up -d hermes-google-mcp'
ssh nas 'sudo /usr/local/bin/docker inspect hermes-google-mcp --format="{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}}={{\$v.IPAddress}} {{end}}"'
```

Expected: all three networks listed, including `hermes_ingress=192.168.94.11`. Do not open the browser until this prints.

- [ ] **Step 4: Complete consent in the browser**

Open `https://gws.bassford.net/` and follow the server's auth start URL. Authenticate through Cloudflare Access first, then Google. Accept the "unverified app" warning (expected — Task 1 Step 3).

Expected: redirect to `/oauth2callback` succeeds and the server reports an authenticated account.

- [ ] **Step 5: Verify the granted scopes — spec §7.5, this is not optional**

Issue #4718 documents tokens being silently downgraded to narrower scopes on re-auth, leaving a setup that looks healthy until calls fail. Assert the scope set, not just that a token exists:

```bash
ssh nas 'sudo cat /volume1/docker/appdata/hermes-google/credentials/*.json | python3 -c "import sys,json; d=json.load(sys.stdin); print(chr(10).join(sorted(d.get(\"scopes\", d.get(\"scope\",\"\").split()))))"'
```

Expected, exactly these five and nothing more:

```
https://www.googleapis.com/auth/calendar.events
https://www.googleapis.com/auth/documents.readonly
https://www.googleapis.com/auth/drive.readonly
https://www.googleapis.com/auth/gmail.compose
https://www.googleapis.com/auth/gmail.readonly
```

If a `drive` (write) or `gmail.modify` scope appears, **stop** — the ceiling in spec §5 is breached and the tool selection in Task 4 needs correcting before going further.

- [ ] **Step 6: Remove the route — the hardening step, do not skip it**

Token refresh does not need the callback. Delete the `gws-rtr` and `gws-svc` blocks from `apps.yml`, then confirm:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://gws.bassford.net/
```

Expected: a Cloudflare Access redirect or a 404 from Traefik — **not** a response from the MCP server. The container now has no internet-facing surface.

Leave the CNAME and the Access policy in place; they are inert without a route and re-consent then needs only the two YAML blocks restored.

- [ ] **Step 7: Update the record and commit**

Fill in the observed scope list and the `+8 days` re-check date in `google-oauth-status.md`.

```bash
git add compose/hermes-google-mcp.yml docs/superpowers/verify/google-oauth-status.md
git commit -m "Task 5: OAuth consent complete, scopes verified, temporary route removed"
```

---

### Task 6: Egress enforcement for the MCP container

The filter in Task 2 is policy; this is enforcement. Without it, a library that ignores `HTTPS_PROXY` reaches the internet directly.

**Files:**
- Modify: `appdata-templates/scripts/hermes-firewall.sh`

**Interfaces:**
- Consumes: the container from Task 4.
- Produces: `DOCKER-USER` + `INPUT_FIREWALL` rules denying `192.168.92.3` and `192.168.95.10` all outbound except to `192.168.95.2`.

- [ ] **Step 1: Read the existing script before editing it**

```bash
sed -n '1,60p' appdata-templates/scripts/hermes-firewall.sh
```

Note the header's warning: on this NAS `iptables -D` against a **built-in** chain returns success unconditionally, so the hook targets `INPUT_FIREWALL`, a custom chain. Follow the existing idempotent delete-then-insert pattern exactly; do not invent a new one.

- [ ] **Step 2: Add rules for both MCP source IPs**

Both are required. A multi-homed container's choice of egress interface is not guaranteed, which is why the parent design keys on source IPs rather than interfaces. Following the existing pattern in the script:

```bash
GOOGLE_MCP_IPS="192.168.92.3 192.168.95.10"
GOOGLE_PROXY="192.168.95.2"

for ip in $GOOGLE_MCP_IPS; do
  # Permit the proxy hop, then deny everything else from this source.
  iptables -D DOCKER-USER -s "$ip" -d "$GOOGLE_PROXY" -j RETURN 2>/dev/null
  iptables -I DOCKER-USER 1 -s "$ip" -d "$GOOGLE_PROXY" -j RETURN
  iptables -D DOCKER-USER -s "$ip" -j DROP 2>/dev/null
  iptables -A DOCKER-USER -s "$ip" -j DROP

  # Container-to-HOST traffic never traverses DOCKER-USER -- it goes via INPUT.
  # Without this the MCP container reaches Home Assistant (host-networked),
  # DSM on :5000/:5001, sshd and every bridge gateway. Not optional.
  iptables -D INPUT_FIREWALL -s "$ip" -j DROP 2>/dev/null
  iptables -I INPUT_FIREWALL 1 -s "$ip" -j DROP
done
```

Order matters: the `RETURN` for the proxy must be inserted at position 1, ahead of the `DROP`.

- [ ] **Step 3: Deploy and apply**

```bash
ssh nas 'sudo tee /volume1/docker/scripts/hermes-firewall.sh >/dev/null' < appdata-templates/scripts/hermes-firewall.sh
ssh nas 'sudo chown root:root /volume1/docker/scripts/hermes-firewall.sh && sudo chmod 0700 /volume1/docker/scripts/hermes-firewall.sh'
ssh nas 'sudo /volume1/docker/scripts/hermes-firewall.sh'
ssh nas 'sudo iptables -L DOCKER-USER -n --line-numbers | head -20'
ssh nas 'sudo iptables -L INPUT_FIREWALL -n --line-numbers | head -20'
```

- [ ] **Step 4: Prove enforcement from inside the MCP container**

```bash
# Direct egress bypassing the proxy -- MUST fail.
ssh nas 'sudo /usr/local/bin/docker exec hermes-google-mcp sh -c "env -u HTTPS_PROXY -u HTTP_PROXY curl -s -o /dev/null -w %{http_code} --max-time 8 https://example.com" || echo "BLOCKED - correct"'
# Reaching the NAS host -- MUST fail.
ssh nas 'sudo /usr/local/bin/docker exec hermes-google-mcp sh -c "curl -s -o /dev/null --max-time 5 http://192.168.1.104:5000" || echo "HOST UNREACHABLE - correct"'
# Google THROUGH the proxy -- MUST still work.
ssh nas 'sudo /usr/local/bin/docker exec hermes-google-mcp curl -s -o /dev/null -w "proxied=%{http_code}\n" --max-time 10 https://www.googleapis.com/discovery/v1/apis'
```

Expected: `BLOCKED - correct`, `HOST UNREACHABLE - correct`, `proxied=200`.

**If `proxied` fails but direct also fails**, the server may not honour `HTTPS_PROXY` (spec §3, open item 4). In that case the proxy is decoration, not enforcement — record it and report back rather than removing the DROP rules to make things work.

- [ ] **Step 5: Confirm the hourly timer re-applies these**

```bash
ssh nas 'sudo systemctl restart hermes-firewall.service && sudo systemctl status hermes-firewall.service --no-pager | head -15'
```

- [ ] **Step 6: Commit**

```bash
git add appdata-templates/scripts/hermes-firewall.sh
git commit -m "Task 6: DOCKER-USER + INPUT_FIREWALL enforcement for the Google MCP container"
```

---

### Task 7: Wire Hermes to the MCP server

**Files:**
- Modify (on the NAS): `/volume1/docker/appdata/hermes-etc/config.yaml`
- Modify: `appdata-templates/hermes/config.yaml`

**Interfaces:**
- Consumes: the running MCP server; the tool list from Task 3.
- Produces: Google tools visible to the agent, bounded by `tools.include`.

- [ ] **Step 1: Add the mcp_servers block to the template**

Append to `appdata-templates/hermes/config.yaml`. Note this is the **weaker** of the two allowlist layers — `config.yaml` is writable by the agent on this deployment, so Task 8 adds detection behind it. The enforcing layer is the container flags from Task 4:

```yaml
# Google Workspace via an isolated MCP container (spec 2026-09-10 section 5).
# The token lives in hermes-google-mcp's own volume and is NOT reachable from
# this container -- that is the point of the whole design.
#
# THIS IS LAYER 2 AND IT IS THE WEAKER ONE. config.yaml is agent-writable here,
# so this include list is advisory-until-restart, exactly like security.*.
# The enforcing layer is --tools/--disabled-tools in compose/hermes-google-mcp.yml,
# which is root-owned and which the agent cannot touch. Guardrail drift on this
# block is detected hourly by hermes-guardrail-check.sh (Task 8).
mcp_servers:
  google:
    url: "http://192.168.92.3:8000/mcp"
    enabled: true
    timeout: 120
    tools:
      # EXACT names from Task 3 Step 3. Belt and braces with the server flags.
      include:
        - "<gmail search tool>"
        - "<gmail read tool>"
        - "<gmail draft tool>"
        - "<calendar list tool>"
        - "<calendar create tool>"
        - "<calendar update tool>"
        - "<calendar delete tool>"
        - "<drive search tool>"
        - "<drive read tool>"
        - "<docs read tool>"
      resources: false
      prompts: false
```

`resources: false` and `prompts: false` drop utility wrappers that are not needed and would otherwise add third-party model-facing text (spec §7.4).

**The send tool is deliberately NOT in this list yet.** It is added in Task 8 only after the gate exists.

- [ ] **Step 2: Deploy the config and restart Hermes**

Config changes are an operator action on the host — the agent cannot restart itself, by design:

```bash
ssh nas 'sudo tee /volume1/docker/appdata/hermes-etc/config.yaml >/dev/null' < appdata-templates/hermes/config.yaml
ssh nas 'sudo chown root:root /volume1/docker/appdata/hermes-etc/config.yaml && sudo chmod 0644 /volume1/docker/appdata/hermes-etc/config.yaml'
ssh nas 'cd /volume1/docker && sudo /usr/local/bin/docker compose restart hermes'
ssh nas 'sudo /usr/local/bin/docker logs --tail 40 hermes'
```

Expected: Hermes logs the `google` MCP server connecting and the registered tool count.

- [ ] **Step 3: Verify the tools are live and bounded**

```bash
ssh nas 'sudo /usr/local/bin/docker exec -u 1000:10 hermes hermes mcp list 2>&1 | head -30'
```

Expected: the `google` server listed, with **only** the `include` tools registered. If a disabled tool appears, `tools.include` is not being applied — stop and resolve before Task 8.

- [ ] **Step 4: End-to-end test through Telegram**

Message the bot: *"What's on my calendar this week?"* and *"Find the most recent email from <known sender> and summarise it."*

Expected: both work. Then try a write that should be impossible: *"Share my most recent Drive doc with a public link."*

Expected: refused because no such tool exists — not because the model declined. Confirm which it was by checking whether a tool call was attempted in the logs.

- [ ] **Step 5: Commit**

```bash
git add appdata-templates/hermes/config.yaml
git commit -m "Task 7: register the Google MCP server with Hermes, reads and calendar writes only"
```

---

### Task 8: The send gate (spec §6)

**Files:**
- Modify: `appdata-templates/scripts/hermes-guardrail-check.sh`
- Modify: `appdata-templates/hermes/config.yaml`
- Possibly create: `compose/hermes-google-approve.yml` + shim (branch B only)

**Interfaces:**
- Consumes: Task 7's working MCP wiring.
- Produces: Gmail send available and gated, or a recorded decision not to expose it.

- [ ] **Step 1: Resolve the spike — does `approvals.mode: manual` cover MCP tool calls?**

Spec §6 leaves this unverified deliberately. Determine it empirically rather than from docs. Temporarily add the send tool to `tools.include`, restart Hermes, and ask the agent via Telegram to send a test mail to your own address.

```bash
ssh nas 'sudo /usr/local/bin/docker logs --tail 60 hermes'
```

Expected outcome A: Hermes pauses and asks for approval → the gate exists.
Expected outcome B: the mail sends with no prompt → the gate does not exist.

Record which, with the log evidence, in `docs/superpowers/verify/google-mcp-image.md`.

- [ ] **Step 2A (if the gate exists): pin it and move on**

Keep the send tool in `tools.include`, and pin the approval keys in `appdata-templates/hermes/config.yaml` so a future image default-flip cannot open them silently:

```yaml
approvals:
  mode: "manual"          # already set; MCP tool calls confirmed covered <DATE>
  unattended_mode: "deny" # already set; governs the webhook/messaging path
```

Then proceed to Step 3.

- [ ] **Step 2B (if the gate does not exist): remove the send tool and stop**

```yaml
      # Send is NOT exposed. approvals.mode: manual was verified on <DATE> NOT to
      # intercept MCP tool calls, so exposing it would mean an ungated send path
      # for a hijacked agent. Spec section 6's fallback -- a shim with its own
      # Telegram bot token that Hermes cannot see -- is the way to add it, and is
      # deliberately deferred rather than half-built.
```

Remove the send tool from `tools.include` **and** add it to `--disabled-tools` in `compose/hermes-google-mcp.yml`, so both layers agree. Report the finding: sending needs the §6 shim as its own piece of work, and the operator decides whether it is worth building. Drafts remain available and ungated, which is most of the value.

- [ ] **Step 3: Extend the guardrail check to `mcp_servers.*` — spec §5, required either way**

`hermes-guardrail-check.sh` currently diffs only the security keys against a root-owned golden copy the agent cannot read or write. `config.yaml` is agent-writable, so without this the Layer 2 allowlist has no detection behind it.

Read the existing script first and follow its pattern. Remember: **the NAS's `python3` has no `yaml` module** — a previous monitoring script that used PyYAML silently compared two identical error strings and reported a false pass. Use awk/sed:

```bash
# Extract the mcp_servers block and diff it against the golden copy.
# awk, not python+yaml -- see the plan's Global Constraints.
#
# The flag is cleared BEFORE printing, not after. The obvious ordering
# (`f{print}` then `f=0`) emits the first line of the NEXT top-level block
# before the flag clears, so an unrelated edit to whatever key follows
# mcp_servers reports as drift here. A guardrail that cries wolf trains the
# operator to ignore it, which is worse than not having it.
extract_mcp() {
  awk '
    /^mcp_servers:/ { f = 1; print; next }
    f && /^[^[:space:]#]/ { f = 0 }
    f { print }
  ' "$1"
}
if ! diff <(extract_mcp "$LIVE_CONFIG") <(extract_mcp "$GOLDEN_CONFIG") >/dev/null; then
  echo "GUARDRAIL DRIFT: mcp_servers block differs from golden copy"
  drift=1
fi
```

- [ ] **Step 4: Deploy, refresh the golden copy, and prove drift is caught**

```bash
ssh nas 'sudo tee /volume1/docker/scripts/hermes-guardrail-check.sh >/dev/null' < appdata-templates/scripts/hermes-guardrail-check.sh
ssh nas 'sudo chown root:root /volume1/docker/scripts/hermes-guardrail-check.sh && sudo chmod 0700 /volume1/docker/scripts/hermes-guardrail-check.sh'
# Refresh the golden copy to include the new block, or every run reports drift.
ssh nas 'sudo cp /volume1/docker/appdata/hermes-etc/config.yaml /volume1/docker/appdata/hermes-etc/.config.yaml.golden'
ssh nas 'sudo /volume1/docker/scripts/hermes-guardrail-check.sh; echo "exit=$?"'
```

Expected: clean, `exit=0`.

Now prove it actually detects tampering — a check that has never failed is not known to work:

```bash
ssh nas 'sudo cp /volume1/docker/appdata/hermes-etc/config.yaml /tmp/cfg.bak'
ssh nas 'sudo sed -i "s|      resources: false|      resources: true|" /volume1/docker/appdata/hermes-etc/config.yaml'
ssh nas 'sudo /volume1/docker/scripts/hermes-guardrail-check.sh; echo "exit=$?"'
ssh nas 'sudo cp /tmp/cfg.bak /volume1/docker/appdata/hermes-etc/config.yaml && sudo rm /tmp/cfg.bak'
ssh nas 'sudo /volume1/docker/scripts/hermes-guardrail-check.sh; echo "exit=$?"'
```

Expected: `GUARDRAIL DRIFT` and a non-zero exit on the tampered run, clean again after restore.

- [ ] **Step 5: Commit**

```bash
git add appdata-templates/scripts/hermes-guardrail-check.sh appdata-templates/hermes/config.yaml compose/hermes-google-mcp.yml docs/superpowers/verify/google-mcp-image.md
git commit -m "Task 8: resolve the send gate and extend guardrail detection to mcp_servers"
```

---

### Task 9: Threat-model regression (spec §10)

Extends the existing suite rather than adding a parallel one — if this change reduces containment, that suite is what should say so.

**Files:**
- Modify: `docs/superpowers/verify/hermes-threat-model.sh`

**Interfaces:**
- Consumes: everything above.
- Produces: a passing suite covering the old 47 checks plus the new ones.

- [ ] **Step 1: Add the new assertions**

Append to `hermes-threat-model.sh`, before the final tally, using the existing `ok`/`bad`/`cdeny`/`callow` helpers. Every check runs **inside the Hermes container as uid 1000:10** — the reach a hijacked agent actually has:

```bash
echo "== cannot reach the Google credential (spec 2026-09-10 section 4) =="
# The entire design exists to make this true. /opt/data holds no Google token.
# NOTE ON cdeny AND TIMEOUTS: cdeny treats command FAILURE as PASS, so any
# check that can time out can pass without having looked. An unbounded
# `find /` under `timeout 8` is exactly that -- it reports containment it
# never verified. Every path below is bounded and deterministic. The
# authoritative check that no Google mount exists at all is the mount-list
# assertion in Task 4 Step 5; these confirm it from the inside.
cdeny "no /credentials path"         ls /credentials
cdeny "no /config path"              ls /config
cdeny "no client_secret in /config"  cat /config/client_secret.json
cdeny "no google token in /opt/data" sh -c 'find /opt/data -maxdepth 3 \( -iname "*google*" -o -iname "*token*.json" -o -iname "*credential*" \) | grep -q .'

echo "== still cannot reach Google directly (Hermes egress unchanged) =="
# The MCP container talks to Google; Hermes must not. If this starts passing,
# someone added googleapis to Hermes' own filter -- which the design forbids.
cdeny "direct googleapis"    sh -c 'curl -s --max-time 8 -x http://192.168.92.2:8888 https://www.googleapis.com/discovery/v1/apis'
cdeny "google egress proxy"  sh -c 'curl -s --max-time 8 -x http://192.168.95.2:8888 https://www.googleapis.com/discovery/v1/apis'

echo "== the MCP server is reachable, and exposes only the agreed tools =="
callow "mcp reachable" sh -c 'curl -s -o /dev/null --max-time 8 http://192.168.92.3:8000/mcp'

echo "== mail is not readable unattended (spec 2026-09-10 section 7.1) =="
# Connecting Gmail means anyone who can email the operator can put text in front
# of the agent. The mitigation is that no unattended path may pull mail: an
# unattended session that hits a dangerous call must deny, not proceed.
callow "unattended denies"  sh -c 'hermes config get approvals.unattended_mode | grep -q "^deny$"'
callow "cron denies"        sh -c 'hermes config get approvals.cron_mode | grep -q "^deny$"'
callow "no scheduled mail"  sh -c '! hermes cron list 2>/dev/null | grep -qiE "gmail|mail|inbox|brief"'
# Fails loudly if an upstream version bump adds tools. Compare against the
# recorded list in docs/superpowers/verify/google-mcp-image.md.
callow "tool list matches policy" sh -c '
  hermes mcp list 2>/dev/null | grep -q "<a known-good tool name>" &&
  ! hermes mcp list 2>/dev/null | grep -qiE "share|permission|trash|delete_file|upload"'
```

Replace `<a known-good tool name>` with a real name from Task 3.

- [ ] **Step 2: Add the send assertion matching the Task 8 outcome**

If Task 8 took branch A (gate exists):

```bash
callow "send tool present" sh -c 'hermes mcp list 2>/dev/null | grep -q "<send tool name>"'
callow "approvals mode is manual" sh -c 'hermes config get approvals.mode | grep -q "^manual$"'
```

If Task 8 took branch B (no gate, send not exposed):

```bash
cdeny "send tool absent" sh -c 'hermes mcp list 2>/dev/null | grep -q "<send tool name>"'
```

- [ ] **Step 3: Run the whole suite**

```bash
ssh nas 'sudo /usr/local/bin/docker exec -i -u 1000:10 hermes bash /dev/stdin' \
  < docs/superpowers/verify/hermes-threat-model.sh
```

Expected: `passed=<47 + new count> failed=0` and `CONTAINED: spec section 5 criterion holds.`

**Any failure among the original 47 means this work reduced containment.** Fix the cause; do not weaken the check.

- [ ] **Step 4: Confirm nothing else was disturbed**

```bash
ssh nas 'sudo /usr/local/bin/docker ps --format "{{.Names}}\t{{.Status}}"'
```

Expected: plex, radarr, sonarr, bazarr, sabnzbd, traefik, cloudflared, pihole and the rest showing uptimes predating this work. Only the hermes-google-* containers and hermes itself should be freshly started.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/verify/hermes-threat-model.sh
git commit -m "Task 9: extend the threat-model suite to cover the Google credential boundary"
```

---

## Post-deployment follow-ups

Not part of this plan's definition of done, but recorded so they are not lost:

1. **The +8 day durable-token re-check** from Task 1 Step 4. This is the actual proof of spec §9; publishing status is only the reason to expect it. If the token has died, the design needs revisiting.
2. **Spec §12 open item 7** — whether the server's own scope minimisation narrows the requested scope set when tools are disabled. If it does, some of §5's Layer 0 may tighten for free at no cost.
3. **The `monokal/tinyproxy` base is Alpine 3.10, EOL since 2021**, and this plan adds a second container using it. Replacing both with a maintained or self-built tinyproxy image is now worth more than it was.
4. **Bitwarden Secrets Manager at the operator layer** (spec §11) — `client_secret.json` would become one of its inputs.
5. **The `hermes_ingress` two-member property** ended in Task 5 Step 3. If the temporary-route pattern proves annoying in practice, the alternative is a dedicated consent network attached only when needed.

## Definition of done

- `hermes-google-mcp` and `hermes-google-egress` running, hardened, pinned by digest or image ID, no watchtower labels.
- Hermes can read mail, list and modify calendar events, and read Drive/Docs, demonstrated end to end through Telegram.
- Hermes **cannot** read the Google token, reach Google directly, or invoke any share/delete/upload tool — demonstrated, not asserted.
- Granted OAuth scopes match spec §5 exactly.
- The Gmail send question is resolved one way or the other, with evidence, and both allowlist layers agree with the outcome.
- `hermes-guardrail-check.sh` covers `mcp_servers.*` and has been proven to catch tampering.
- `hermes-threat-model.sh` passes in full, original 47 included.
- No other container disturbed.
- Committed on branch `hermes-agent` with the reasoning in the messages.
