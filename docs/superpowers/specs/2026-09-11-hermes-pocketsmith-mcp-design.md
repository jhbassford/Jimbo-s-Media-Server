# Hermes PocketSmith MCP — Design

Date: 2026-09-11
Status: Approved (design); implementation plan pending
Supersedes nothing. Extends `2026-09-09-hermes-agent-nas-design.md`, whose
threat model and invariants remain in force except where §5 records a delta.

## 1. Goal

Give the Hermes agent access to the operator's PocketSmith financial data
(accounts, transactions, categories, budgets, forecasts) so it can answer
questions and act on it in natural language.

**Operator decisions taken up front (2026-09-11):**

1. **Full access** — all 66 PocketSmith tools, read *and* write
   (`create/update/delete_transaction`, `create/update/delete_event`,
   `create/update/delete_account`, category and rule management). This is a
   larger blast radius than the read-only Google/Health grants and is accepted
   knowingly; §5 records what it costs.
2. **Direct remote MCP** — Hermes connects straight to PocketSmith's hosted
   endpoint with `auth: oauth`. No isolated bridge container. §2 records why and
   what that trades away.

## 2. Approach selection

Chosen: **the hosted PocketSmith MCP server**, added to Hermes' own
`mcp_servers` as a remote HTTP server with OAuth.

PocketSmith hosts the server; there is no self-hosted or open-source
equivalent, so the isolated-credential-container pattern used for Google
Workspace and Google Health (`compose/hermes-google-mcp.yml`,
`compose/hermes-health-mcp.yml`) is **not available here without reimplementing
the 66-tool surface** — which is out of proportion to this task. That pattern's
whole value was owning the server; against a vendor-hosted endpoint it would be
a custom proxy holding the same token, i.e. more code, not less exposure.

The cost, recorded plainly: **Hermes' standard OAuth token cache lives under
`$HERMES_HOME`, which on this deployment is `/opt/data` — the agent's own
read-write mount.** So the PocketSmith refresh token will sit inside the blast
radius, exactly the shape §2 of the Google design rejected. §5 explains why this
is accepted and how it is bounded.

Rejected alternatives:

- **Read-only endpoint** (`mcp-readonly.pocketsmith.com`, 40 tools) — declines
  the operator's stated goal of "agent stuff", i.e. categorisation and budget
  edits. Available for free later by changing one URL; noted in §8.
- **Isolated bridge container holding the token.** Would reproduce the Google
  pattern but requires a stdio→HTTP MCP bridge (`mcp-remote` + `supergateway`
  or equivalent), a second egress proxy, new firewall entries and new digest
  pins — a much larger supply-chain and moving-parts surface whose only
  security gain is moving a token that the agent can already *use* out of a
  directory the agent can *read*. Rejected as disproportionate for now.

## 3. Architecture

```
Hermes (192.168.92.10)
  │  HTTPS_PROXY=192.168.92.2:8888   (existing, unchanged)
  ▼
hermes-egress-proxy (192.168.92.2:8888)   Tinyproxy, default-deny, ConnectPort 443
  │  filter gains exactly one line: ^mcp\.pocketsmith\.com$
  ▼
mcp.pocketsmith.com:443
   ├─ POST /mcp                       MCP endpoint (streamable HTTP)
   ├─ /oauth/register                 Dynamic Client Registration (RFC 7591)
   ├─ /oauth/authorize  /oauth/token  OAuth 2.0 + PKCE (S256)
   └─ /.well-known/oauth-*            discovery
```

**One host covers everything.** Verified from PocketSmith's published metadata
2026-09-11:

```
GET https://mcp.pocketsmith.com/.well-known/oauth-authorization-server
{
  "issuer":"https://mcp.pocketsmith.com",
  "authorization_endpoint":"https://mcp.pocketsmith.com/oauth/authorize",
  "token_endpoint":"https://mcp.pocketsmith.com/oauth/token",
  "registration_endpoint":"https://mcp.pocketsmith.com/oauth/register",
  "response_types_supported":["code"],
  "grant_types_supported":["authorization_code","refresh_token"],
  "code_challenge_methods_supported":["S256"],
  "token_endpoint_auth_methods_supported":["none"]
}
```

Consequences, each load-bearing:

- **One egress-filter line.** MCP, registration, authorize and token are all on
  `mcp.pocketsmith.com`. No new firewall entry is needed: Hermes already reaches
  its egress proxy, and the proxy does the domain filtering. This preserves the
  parent design's central property that Hermes' direct network reach is
  unchanged.
- **Dynamic Client Registration is supported**, so `auth: oauth` needs no
  pre-registered `client_id`/`client_secret` (unlike the Google Drive MCP
  pitfall). Hermes' Client ID Metadata Document / DCR fallback both work.
- **`token_endpoint_auth_methods_supported: ["none"]`** — public PKCE client,
  no secret to manage.
- **No `device_code` grant.** `hermes mcp login --flow device` is therefore
  unavailable; the one-time consent must use the browser with **paste-back**
  (or a loopback relay). See §4.

## 4. OAuth consent on a headless host

The token is acquired **once**, by the operator, from an interactive terminal:

```
sudo /usr/local/bin/docker exec -it hermes hermes mcp login pocketsmith
```

Hermes prints the authorize URL and waits. Because the agent runs on the NAS and
the browser runs on the operator's machine, the loopback callback cannot reach
the agent; the interactive CLI offers paste-back — open the URL, approve, copy
the full failed-redirect URL, paste it at the prompt. This is the documented
Hermes remote-host path. (`DCR` means no console setup is required first.)

Tokens are then cached at `/opt/data/mcp-tokens/pocketsmith.json` (Hermes stores
MCP OAuth tokens under `$HERMES_HOME/mcp-tokens/`, verified `HERMES_HOME=/opt/data`
inside the container) and refreshed silently by the running gateway thereafter.
Re-auth, if ever needed, is the same command (`hermes mcp reauth pocketsmith`).

After consent the operator restarts `hermes` (it is deliberately absent from the
socket proxy's restart allowlist, so the agent cannot reload config itself), and
the `mcp_servers.pocketsmith` block takes effect on the next `hermes mcp` /
gateway discovery.

## 5. Threat-model delta

The parent design's success criteria are unchanged; this section records only
what is new, most significant first.

**5.1 — A financial-data grant with write permission now exists.**
Full access exposes `delete_transaction`, `delete_account`, `delete_category`,
`create/update/delete_event` and their kin. A prompt-injected agent — and this
deployment assumes injection is possible — can now *alter* the operator's
financial records, not merely read them. This is the single largest capability
increase since the agent was built and is accepted by explicit operator choice.

*Bound.* PocketSmith's own API is the enforcement layer: the token is scoped to
the operator's PocketSmith account only, and nothing here can move money or
touch a bank. Worst case is corrupted/absent records inside PocketSmith, which
PocketSmith's own history and the operator's bank feed can be reconciled
against. There is no equivalent of the Google send/public-share exfiltration
path in this surface.

**5.2 — The refresh token is inside the blast radius.**
`/opt/data/mcp-tokens/pocketsmith.json` is readable by the agent process and
writable in its mount. A fully hijacked agent can read it. It is *already* able
to use those tools through Hermes, so the incremental gain to an attacker is
out-of-band use of the token (from outside the container) and persistence
surviving container destruction.

*Bound.* Egress remains default-deny. The token has value only if it can be
transmitted somewhere the attacker controls; the agent's only allowed
destinations are OpenRouter, GitHub, PyPI/npm, Telegram, Discord and now
PocketSmith itself. No generic paste/transfer destination is allowlisted. The
token is independently revocable at
<https://my.pocketsmith.com/security/manage_apps>. This is materially weaker
than the Google credential-absence property and is recorded as a knowing
regression, not a non-issue.

**5.3 — PocketSmith becomes a second untrusted-content ingestion path.**
Transaction descriptions and payees are attacker-influenced text (anyone who can
pay the operator can put a string in the ledger). Like Gmail in the Google
design, this is untrusted content arriving in front of the agent. The same rule
applies: **no unattended financial reading or mutation.** No cron job, brief or
webhook path reads or edits PocketSmith without the operator in the loop.
`approvals.unattended_mode: deny` and `cron_mode: deny` remain in force. The
agent's existing `approvals` controls do **not** cover MCP tool calls (resolved
during the Google work), so this rule, plus the operator's supervision, is the
control.

**5.4 — Tool descriptions are third-party, model-facing text** and therefore an
injection surface (same as Google §7.4). Mitigated by the fact that the tool
list is vendor-scoped to one account; not filtered at the config layer because
the operator chose full access.

**5.5 — Scope downgrade / silent re-auth.** The Google design's issue #4718 note
applies in spirit: post-setup verification asserts the granted token exists and
a live tool call succeeds, not merely that login completed.

## 6. Verification

Extend the existing suites rather than adding parallel ones.

`docs/superpowers/verify/hermes-egress.sh` — add: PocketSmith is **allowed**
through the proxy (proves the new filter line is live), and a control domain
still denied (proves default-deny is intact).

`docs/superpowers/verify/hermes-threat-model.sh` — add a PocketSmith section:

1. `mcp.pocketsmith.com` reachable through the egress proxy from inside Hermes
   (the filter change is deployed and effective).
2. `hermes mcp test pocketsmith` reports connected (token valid, endpoint up).
3. The tool surface is the expected full-access set — assert a representative
   writer (`update_transaction`, `create_event`) is present, so a silent
   downgrade to read-only fails loudly.
4. The token file exists at `/opt/data/mcp-tokens/pocketsmith.json`, and the
   suite states *why* this is expected here (contrast: Google still asserts
   absence). This is the deliberate §5.2 delta made explicit rather than
   accidentally covered by a loose glob.
5. Existing Google checks (no Google credential in `/opt/data`, Google still
   not directly reachable) still pass — no regression.

## 7. Delivery / ownership

`apps.yml`, CNAMEs and the tunnel are **not** involved: this is outbound only,
initiated by Hermes. No ingress surface is added.

The changed files and their delivery:

| Repo path | Delivered to NAS as | Why it is not in `push.sh` |
|---|---|---|
| `appdata-templates/hermes-egress/filter` | `/volume1/docker/appdata/hermes-egress/filter` | egress allowlist lives in appdata-templates; README records it |
| `appdata-templates/hermes/config.yaml` | seed only; **live** `/volume1/docker/appdata/hermes/config.yaml` is the running copy | config.yaml is agent-writable state, not a bind mount |

`hermes-guardrail-check.sh` already diffs `mcp_servers.*` (added 2026-09-10), so
the new block is covered by hourly drift detection once the golden copy is
re-accepted after the change.

## 8. Explicitly out of scope

- **Read-only mode.** Changing the URL to
  `https://mcp-readonly.pocketsmith.com/mcp` and re-consenting gives the
  40-tool read surface. Deferred as an option, not built.
- **An isolated token-holding container.** Rejected in §2; revisitable if the
  §5.2 residual proves unacceptable.
- **PocketSmith API-key auth instead of OAuth.** PocketSmith also offers
  personal API keys (`X-Developer-Key`), but the hosted MCP is OAuth-only;
  building on the REST API would mean reimplementing the tool surface for no
  gain.
- **Cron/briefing automations** against financial data — excluded by §5.3.
