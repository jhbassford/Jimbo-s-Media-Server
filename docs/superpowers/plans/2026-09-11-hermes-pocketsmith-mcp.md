# Hermes PocketSmith MCP — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans, task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect Hermes to PocketSmith's hosted MCP server with full-access OAuth, reachable through the existing default-deny egress proxy, with one added allowlist domain and no firewall change.

**Architecture:** Hermes' own remote-HTTP MCP client (`mcp_servers.pocketsmith`, `auth: oauth`) talks to `https://mcp.pocketsmith.com/mcp` through the existing `hermes-egress-proxy`. The only network change is one line in the proxy filter. OAuth uses Dynamic Client Registration + PKCE; consent is a one-time operator paste-back because the server advertises no device-code grant. The token caches at `/opt/data/mcp-tokens/pocketsmith.json` (accepted delta, spec §5.2).

**Tech Stack:** Hermes Agent v0.21.1 (upstream bbf91b76), Tinyproxy (`monokal/tinyproxy@sha256:2c1b6f18...`), Docker 24.0.2 / API 1.43, host iptables (unchanged), PocketSmith hosted MCP + OAuth 2.0.

**Spec:** `docs/superpowers/specs/2026-09-11-hermes-pocketsmith-mcp-design.md`

## Global Constraints

- Host `nas` = `bassfja33@192.168.1.104`, DSM 4.4.302. Passwordless sudo: `ssh nas 'sudo ...'`.
- **`sudo docker` does not work — use `sudo /usr/local/bin/docker`.** (`docker` is off root's PATH.)
- **`scp` to this NAS is broken.** Use `ssh nas 'cat > /path' < localfile`.
- `push.sh` syncs only `docker-compose.yml` and `compose/`. Everything in `appdata-templates/` is **not** synced — copy it to the NAS by hand with the ownership/mode `appdata-templates/README.md` records.
- **Outbound-only change: do NOT touch `apps.yml`, Cloudflare DNS, or the tunnel.** PocketSmith is initiated by Hermes; no ingress surface is created.
- **Do NOT edit `hermes-firewall.sh`.** Hermes already reaches its egress proxy; the proxy does the new domain filtering. An edit here means the design is being violated.
- **Never run a bare `docker compose up -d`** — always name the service.
- `cpus:` and `pids_limit` are unavailable on this kernel. Not relevant here (no new container).
- Work on branch `hermes-agent`. No step is complete until its output is observed.
- **No unattended financial reads/writes (spec §5.3).** No cron/brief/webhook may touch PocketSmith without the operator in the loop.

**Known pre-existing drift, not introduced here:** the git seed
`appdata-templates/hermes/config.yaml` still lists an `mcp_servers.health`
block, but the live `/volume1/docker/appdata/hermes/config.yaml` has only
`mcp_servers.google` (plus runtime keys `platforms`, `_config_version`). The
live file is Hermes-canonicalised and authoritative. This plan adds the block to
**both**; it does not reconcile the unrelated `health` drift.

---

### Task 1: Add the domain to the egress allowlist and prove it

**Files:**
- Modify: `appdata-templates/hermes-egress/filter` (repo seed)
- Modify (NAS): `/volume1/docker/appdata/hermes-egress/filter`

**Interfaces:**
- Consumes: nothing.
- Produces: `mcp.pocketsmith.com:443` allowed through `192.168.92.2:8888`; every other non-allowlisted domain still refused.

- [ ] **Step 1: Add the line to the repo seed**

Append to `appdata-templates/hermes-egress/filter`:

```
^mcp\.pocketsmith\.com$
```

One host covers `/mcp`, `/oauth/register`, `/oauth/authorize` and
`/oauth/token` (verified via `.well-known/oauth-authorization-server`,
2026-09-11). Do not add a broad `pocketsmith` wildcard, and do not add
`my.pocketsmith.com` — that host is only ever hit by the **browser** during
consent, never by Hermes.

- [ ] **Step 2: Deliver it to the NAS**

```bash
ssh nas 'cat > /tmp/filter' < appdata-templates/hermes-egress/filter
ssh nas 'sudo install -o root -g root -m 0644 /tmp/filter /volume1/docker/appdata/hermes-egress/filter && sudo rm /tmp/filter'
ssh nas 'sudo diff /volume1/docker/appdata/hermes-egress/filter <(printf "%s\n" "^openrouter\\.ai$" ...)'   # visual check
```

- [ ] **Step 3: Reload Tinyproxy and prove both directions**

**Do NOT trust `SIGHUP` alone after a file replacement.** The filter is a
bind-mounted *file*; `install`/`cp` creates a **new inode**, and the running
container keeps pointing at the old one (measured 2026-09-11: the container
still served the pre-PocketSmith filter after a `SIGHUP` because the host file
had been replaced). The reliable sequence is: write the host file, then
**restart the proxy** so Docker remounts the new inode.

```bash
ssh nas 'sudo /usr/local/bin/docker restart hermes-egress-proxy'
ssh nas 'sudo /usr/local/bin/docker exec hermes-egress-proxy tail -1 /etc/tinyproxy/filter'   # must show ^mcp\.pocketsmith\.com$
ssh nas 'sudo /usr/local/bin/docker ps --filter name=hermes-egress --format "{{.Status}}"'
```

(If you instead edit the file *in place* — e.g. `cat > file`, same inode, no
rename — a `SIGHUP` reload is sufficient and avoids the brief egress drop. The
in-place path was not used here because `install` was used for ownership/mode.)

Prove from inside Hermes, through the proxy (must be `200`, not `000`):

```bash
ssh nas 'sudo /usr/local/bin/docker exec hermes sh -c "curl -s -o /dev/null -w \"%{http_code}\n\" --max-time 10 -x http://192.168.92.2:8888 https://mcp.pocketsmith.com/.well-known/oauth-protected-resource"'
```

Expected `200`. Control — a still-denied domain must stay refused (`000`):

```bash
ssh nas 'sudo /usr/local/bin/docker exec hermes sh -c "curl -s -o /dev/null -w \"%{http_code}\n\" --max-time 10 -x http://192.168.92.2:8888 https://pastebin.com/"'
```

Expected `000` (denied). If the first is `000`, the container is still on the
old inode or the line is malformed — stop.

---

### Task 2: Add the MCP server to Hermes config

**Files:**
- Modify: `appdata-templates/hermes/config.yaml` (seed)
- Modify (NAS): `/volume1/docker/appdata/hermes/config.yaml` (live, agent-writable, `1000:10 0640`)

**Interfaces:**
- Consumes: Task 1 (the endpoint must be reachable, or `mcp add` discovery is noisy — harmless, but Task 1 makes it clean).
- Produces: an `mcp_servers.pocketsmith` block with `url`, `auth: oauth`, `enabled: true`.

- [ ] **Step 1: Add the block (live config)**

`hermes mcp add` is **discovery-first and interactive**, so run it with answers
piped. Pre-auth discovery cannot connect, so it saves the server **disabled and
without `auth`** — Steps 2 finalise it. This is expected, not a failure.

```bash
ssh nas "printf 'y\ny\n' | sudo /usr/local/bin/docker exec -i hermes hermes mcp add pocketsmith --url https://mcp.pocketsmith.com/mcp --auth oauth"
```

Expected tail: `✓ Saved 'pocketsmith' to config (disabled)`. If it aborts without
saving, add the block by hand as in Step 3 and continue.

- [ ] **Step 2: Enable it and set the standard MCP options**

`hermes config set` is the sanctioned writer (writes correct YAML types and
`auth: oauth` properly — `mcp add` dropped `auth` in its disabled fallback):

```bash
for kv in "enabled true" "auth oauth" "timeout 120" "tools.resources false" "tools.prompts false"; do
  ssh nas "sudo /usr/local/bin/docker exec hermes hermes config set mcp_servers.pocketsmith.${kv} 2>&1 | head -1"
done
```

A `config set` line may print `***` for the value (secret redaction); inspect the
file to confirm it is real:

```bash
ssh nas 'sudo /usr/local/bin/docker exec hermes sed -n "/pocketsmith:/,/platforms:/p" /opt/data/config.yaml'
```

Expected block:

```yaml
  pocketsmith:
    url: https://mcp.pocketsmith.com/mcp
    enabled: true
    auth: oauth
    timeout: 120
    tools:
      resources: false
      prompts: false
```

Full access is expressed by **not** writing a `tools.include`/`exclude` list
(spec §1). If `resources`/`prompts` cannot be set cleanly, leaving them at
default is acceptable — Hermes only registers those wrappers when the server
supports the capability.

- [ ] **Step 3: Mirror the same block into the repo seed**

Edit `appdata-templates/hermes/config.yaml`'s `mcp_servers:` section, adding a
`pocketsmith:` entry with the same values and a comment block recording: the
hosted endpoint, the spec reference, the full-access decision, and the
`/opt/data/mcp-tokens` token-location delta. Keep the file's existing comment
style.

- [ ] **Step 4: Note the live config is gateway-managed and volatile**

Hermes rewrites `/opt/data/config.yaml` in canonical form (comments stripped,
keys reordered) when the CLI or dashboard touches it — observed during this
task, and it means the **repo seed is documentation, not the deployed config**.
Always make live changes through `hermes config set` / `hermes mcp`, never by
hand-editing the live file while the gateway runs.

---

### Task 3: Complete OAuth consent (operator, interactive)

**Interfaces:**
- Consumes: Task 1 + 2 (`pocketsmith` configured, endpoint reachable).
- Produces: `/opt/data/mcp-tokens/pocketsmith.json`.

This step needs the operator's browser and PocketSmith login; it cannot be
scripted.

- [ ] **Step 1: Run the login and paste back**

From a real interactive terminal (TTY required):

```
ssh -t nas 'sudo /usr/local/bin/docker exec -it hermes hermes mcp login pocketsmith'
```

On the operator's machine: open the printed authorize URL, sign in to
PocketSmith, approve, then copy the full `http://127.0.0.1:.../callback?code=...`
URL the browser lands on (the page will show a connection error — expected) and
paste it at the prompt. A bare `?code=...&state=...` string is also accepted.

Expected: `hermes mcp login` reports the token stored. If it offers a choice of
flow, choose **browser** (`device` is not offered by PocketSmith).

- [ ] **Step 2: Confirm the token landed**

```bash
ssh nas 'sudo ls -l /volume1/docker/appdata/hermes/mcp-tokens/'
```

Expected: `pocketsmith.json` owned `1000:10`, mode `0600`. If it is missing,
login did not complete — do not proceed.

- [ ] **Step 3: Restart Hermes to load the tool surface**

`hermes` is deliberately not in the socket-proxy restart allowlist, so this is
an operator action:

```bash
ssh nas 'sudo /usr/local/bin/docker restart hermes'
```

Wait for the gateway to come back (`docker ps`, logs), then:

```bash
ssh nas 'sudo /usr/local/bin/docker exec hermes hermes mcp test pocketsmith 2>&1 | head -40'
```

Expected: connected, tools listed, no auth error.

- [ ] **Step 4: Re-accept the guardrail golden copy**

The `mcp_servers` block is covered by hourly drift detection; accept the
intended new baseline after confirming the diff is only this change:

```bash
ssh nas 'sudo /volume1/docker/scripts/hermes-guardrail-check.sh'       # may alert: expected until accepted
ssh nas 'sudo diff <(sudo cat /volume1/docker/appdata/hermes-etc/config.yaml.golden) <(sudo cat /volume1/docker/appdata/hermes/config.yaml)'
ssh nas 'sudo /volume1/docker/scripts/hermes-guardrail-check.sh --accept'
```

---

### Task 4: Verification

**Files:**
- Modify: `docs/superpowers/verify/hermes-egress.sh`
- Modify: `docs/superpowers/verify/hermes-threat-model.sh`

- [ ] **Step 1: Extend `hermes-egress.sh`**

Add alongside the existing checks:

```bash
chk "pocketsmith allowed"  allow https://mcp.pocketsmith.com/.well-known/oauth-protected-resource
```

- [ ] **Step 2: Extend `hermes-threat-model.sh`**

Append a PocketSmith section implementing spec §6:

```bash
echo "== PocketSmith MCP (spec 2026-09-11) =="
callow "pocketsmith reachable via proxy" sh -c 'curl -s -o /dev/null --max-time 10 -x http://192.168.92.2:8888 https://mcp.pocketsmith.com/.well-known/oauth-protected-resource'
callow "pocketsmith MCP connected"        sh -c 'hermes mcp test pocketsmith 2>/dev/null | grep -qi "connected"'
# Full-access is a deliberate choice; assert a representative writer is present so
# a silent downgrade to the read-only endpoint cannot pass as healthy.
callow "full-access writer present"       sh -c 'hermes mcp test pocketsmith 2>/dev/null | grep -qE "update_transaction|create_event"'
# DELIBERATE DELTA (spec 5.2): unlike Google, the OAuth token DOES live in the
# agent-writable mount. Assert it is the expected file, not a surprise, and that
# nothing Google-shaped appeared.
callow "pocketsmith token expected path"  sh -c 'test -f /opt/data/mcp-tokens/pocketsmith.json'
cdeny  "no google token in /opt/data"     sh -c 'find /opt/data -maxdepth 3 -type f \( -iname "*google*.json" -o -iname "*client_secret*" \) 2>/dev/null | grep -q .'
```

Note the existing Google check already matches `*token*.json`; the PocketSmith
file is `pocketsmith.json`, so the two assertions are independent. If that
existing glob is tightened later, keep the explicit PocketSmith expectation.

- [ ] **Step 3: Run both suites with observed output**

```bash
ssh nas 'cat > /tmp/hermes-threat-model.sh' < docs/superpowers/verify/hermes-threat-model.sh
ssh nas 'sudo /usr/local/bin/docker exec -i -u 1000:10 hermes bash /dev/stdin' < docs/superpowers/verify/hermes-threat-model.sh
ssh nas 'cat > /tmp/hermes-egress.sh' < docs/superpowers/verify/hermes-egress.sh
ssh nas 'bash /tmp/hermes-egress.sh'
```

Expected: threat-model suite green including the new checks and the pre-existing
Google checks; egress suite green.

- [ ] **Step 4: Functional smoke test (read-only, operator-supervised)**

From a Hermes session, ask a benign read-only question that exercises the new
tools (e.g. "what is my current net worth?"). Confirm a real PocketSmith answer,
not an auth/tool error, before declaring done. Do **not** run an unattended or
mutating test.

---

### Task 5: Documentation

**Files:**
- Modify: `appdata-templates/hermes/ENVIRONMENT.md`

- [ ] **Step 1: Update the egress allowlist section**

Add `mcp.pocketsmith.com` to the enumerated allowlist in §1 of
`ENVIRONMENT.md`, and state that it is a full-access financial-data MCP reached
directly by Hermes (no isolated container), with the token at
`/opt/data/mcp-tokens/pocketsmith.json`.

- [ ] **Step 2: State the delta, do not paper over it**

Add a short note under the "credentials" discussion in §2 recording that the
PocketSmith OAuth token is the one credential intentionally allowed inside
`/opt/data`, why (spec §2/§5.2), and that it is independently revocable at
<https://my.pocketsmith.com/security/manage_apps>. Bump the `LAST VERIFIED`
date.

- [ ] **Step 3: Deliver ENVIRONMENT.md to the NAS**

```bash
ssh nas 'cat > /tmp/ENVIRONMENT.md' < appdata-templates/hermes/ENVIRONMENT.md
ssh nas 'sudo install -o root -g root -m 0644 /tmp/ENVIRONMENT.md /volume1/docker/appdata/hermes-etc/ENVIRONMENT.md && sudo rm /tmp/ENVIRONMENT.md'
```

Restart `hermes` once more so the read-only mount reflects the new copy.
