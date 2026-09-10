# Hermes Google Workspace Access — Design

Date: 2026-09-10
Status: Approved (design); implementation plan pending
Supersedes nothing. Extends `2026-09-09-hermes-agent-nas-design.md`, whose
threat model and invariants remain in force except where §7 records a delta.

## 1. Goal

Give the Hermes agent useful access to the operator's Google account — Gmail,
Calendar, Drive/Docs — without putting a Google credential anywhere a
prompt-injected agent can reach it.

Capability ceiling, decided by the operator and fixed by this design:

| Surface | Agent may | Agent may not |
|---|---|---|
| Gmail | search, read, create drafts, **send (gated)** | delete, modify labels, filters |
| Calendar | list, create, update, delete events | change calendar settings or ACLs |
| Drive/Docs | search, read metadata, read/export | write, share, delete |

## 2. Approach selection

Chosen: **a self-hosted `taylorwilsdon/google_workspace_mcp` container**, holding
the OAuth token, reachable from Hermes only as an MCP server over `hermes_net`.

Two alternatives were considered and rejected.

**Rejected — the bundled `google-workspace` skill.** It is the mainstream path
and it is wrong for this deployment for one decisive reason: it stores
`google_token.json` under `${HERMES_HOME}`, which on this NAS is `/opt/data` —
the agent's own read-write mount. That places a long-lived Google **refresh
token** inside the blast radius. A rewritten `config.yaml` is bounded by the
container; an exfiltrated refresh token is persistent, out-of-band access to the
operator's account that outlives the container entirely and is revoked only if
someone notices. Root-owning the file `0640` `:ro` stops tampering but not
exfiltration, because the agent process must be able to read it to use it.

Its safety story is also prose. `SKILL.md` Rule 1 says "never send email, delete
Drive files, or share files without confirming with the user" — an instruction to
a model this deployment assumes is hijacked. `$GAPI drive share FILE_ID --type
anyone --role reader` is one command, matches nothing in `approvals.deny`, and
produces a public link to any file **inside an allowlisted domain**, where the
tinyproxy filter structurally cannot see it. Community guidance around this skill
(e.g. the Build Lean SaaS course) frames the whole problem as a trust-boundary
question and does not address isolation, containerisation, or token containment
at all.

**Rejected — hosted MCP (Composio and similar).** "Authentication handled for
you" means a third-party SaaS holds the Google tokens. That inverts this
deployment's threat model and adds an egress dependency.

**Chosen — self-hosted MCP server.** It provides, as shipped, the controls this
design would otherwise have had to hand-write: `--tools <service>`,
`--tool-tier core|extended|complete`, `--disabled-tools <name>...`,
`--transport streamable-http`, credential storage in its own `~/.credentials/`,
a stateless mode with zero disk writes, and unconditional blocking of `.env*`,
`~/.ssh/` and `~/.aws/`. It also ships a global `--read-only` flag, which this
design does **not** use — §1 permits calendar writes and Gmail drafts, so the
ceiling is set by tool selection instead. An earlier draft of this design specified a
hand-written broker; it was withdrawn once this server was found, because
maintaining ~400 lines of credential-holding code is a worse position than
pinning a maintained one.

Feasibility confirmed: Hermes supports **remote HTTP MCP servers** — `url:`,
`headers:`, `transport:`, `ssl_verify:`, and a `tools.include` / `tools.exclude`
allowlist supporting fnmatch globs (Hermes MCP config reference). Without this
the design would not work at all, since the server runs in a separate container.

## 3. Architecture

```
Hermes (192.168.92.10)  ──MCP / streamable-HTTP──>  hermes-google-mcp (192.168.92.3:8000)
                                                              │
                                                        HTTPS_PROXY
                                                              ▼
                                                hermes-google-egress (192.168.92.4:8888)
                                                              │  googleapis.com only
                                                              ▼
                                                           Google
```

**Hermes' own egress allowlist and `DOCKER-USER` rules are unchanged.** This is
the central structural win and it is not incidental: because the MCP server is a
separate container, `*.googleapis.com` never enters Hermes' tinyproxy filter, and
the Drive-public-share exfiltration path is not merely blocked but **absent** —
the server never exposes that tool. `hermes → 192.168.92.0/24` is already
permitted by the firewall, so no firewall change is required either. Same
reasoning as the Signal integration brief.

`hermes-google-egress` is a second tinyproxy instance reusing the existing
pattern with a googleapis-only filter. As with Hermes itself, the filter is the
*policy* and iptables is the *enforcement*: a `DOCKER-USER` DROP keyed to the MCP
container's own source IP denies it direct outbound, so a library that ignores
`HTTPS_PROXY` does not get out — it fails. Rationale: that container holds a send-capable Gmail
token, and by the logic applied everywhere else in this stack a credential of
that value gets its own egress boundary rather than free internet access. It is
the cheapest element here to cut if the operator later decides a
container with no LLM in it does not warrant one; if cut, the direct egress must
be documented rather than left implicit.

UNVERIFIED: that the server's HTTP stack honours `HTTPS_PROXY`. `google-auth`
uses `requests`, which does, but this must be confirmed live before the proxy is
treated as enforcement rather than decoration.

## 4. Credential containment

| Host path | Owner / mode | Mounted into Hermes |
|---|---|---|
| `appdata/hermes-google/credentials/` | `root:<mcp gid>` `0700` | **never** |
| `appdata/hermes-google-etc/client_secret.json` | `root:root` `0400`, `:ro` | **never** |

`/opt/data` contains no Google credential of any kind. This is the property the
whole design exists to produce: a fully hijacked Hermes has nothing to steal.

Container hardening matches the house standard and the reasons recorded in
`compose/hermes.yml` apply unchanged — `cap_drop: ALL`,
`no-new-privileges:true`, non-root, `read_only: true` with targeted tmpfs,
`mem_limit` + `memswap_limit` pinned together, no watchtower label, no published
ports, image pinned by digest. `cpus:` and `pids_limit` remain unavailable on
this kernel; use `cpu_shares` and `ulimits.nproc` as elsewhere.

Built from source rather than pulled from a registry — that is the project's own
documented install path, and it keeps the supply chain consistent with the rest
of this stack.

## 5. Capability ceiling — three layers

**Layer 0 — Google (strongest; the agent cannot argue with it).**
Token scopes: `gmail.readonly`, `gmail.compose`, `calendar.events`,
`drive.readonly`, `documents.readonly`. No Drive write scope, no sharing scope,
no permanent-delete scope.

Recorded finding: **no Gmail scope grants drafts without also granting send.**
`gmail.compose` is documented as "Manage drafts *and send* emails"; `gmail.modify`
likewise. So Layer 0 cannot enforce "drafts but not send" — that enforcement
exists only at Layer 1. Calendar has the same shape at much lower stakes
(`calendar.events` covers create, update and delete; worst case is a junk event),
and is accepted.

**Layer 1 — MCP server flags (agent cannot touch; set in compose, root-owned).**
`--tools`, `--tool-tier`, `--disabled-tools`.

**Layer 2 — Hermes `mcp_servers.google.tools.include` (agent-writable).**
`config.yaml` is writable on this deployment by an earlier operator decision, so
this layer is advisory-until-restart, exactly like the `security.*` keys. It is
still worth setting, but it is not the boundary.

**Gap this creates, and the design's answer:**
`/volume1/docker/scripts/hermes-guardrail-check.sh` currently diffs only the
security keys against the root-owned golden copy. It **must** be extended to
cover `mcp_servers.*`, or Layer 2 has no detection behind it.

**Tool names are deliberately not specified in this design.** This repo's
standing rule is that a key the application ignores is a control that does not
exist; the same applies to a tool name that does not exist. The implementation
plan enumerates the live tool list by querying the running server and maps it to
the policy above. The design fixes policy, not identifiers.

## 6. The send gate

The MCP server does not provide approval gating. One question decides the shape,
and it is **UNVERIFIED**:

> Does `approvals.mode: manual` intercept **MCP tool calls**, or only shell
> commands?

- **If it does** — configure it, assert it in the test suite, done.
- **If it does not** — a minimal shim in front of the send tool only. Its own
  Telegram bot token, held by the shim and never visible to Hermes, so the agent
  cannot approve itself. The confirmation renders what the shim will actually
  transmit (recipients, subject, body), not what the agent claims. Nonce goes
  only to Telegram, is never returned to the agent, is single-use and
  time-boxed. Pending approvals and requests/hour are capped.

This must be resolved by a spike before the send tool is exposed.

**Drafts are ungated; sends are the only gated call.** The real threat to an
approval gate is fatigue, and drafts land in the operator's own Gmail where they
would be reviewed anyway — a hijacked agent creating junk drafts is noise, not
damage. Keeping confirmations rare is what keeps them read.

## 7. Threat model delta

The parent design's success criteria are unchanged and must still hold. This
section records only what is new. Residuals are listed in order of significance.

**7.1 — Google becomes an untrusted-content ingestion path.**
This is the largest change to this deployment's threat model since it was built.
Before it, the agent's inbound untrusted content was essentially what the
operator sent it. After it, **anyone who can email the operator can place text
in front of the agent.** That is the third leg of the combination that makes
agents dangerous: access to private data, exposure to attacker-controlled
content, and a channel out. The first was always present; the third is the
parent design's already-accepted residual that allowlisted destinations are
themselves exfiltration channels. This change adds the second, deliberately and
knowingly.

Direct mitigation, and it is a design rule rather than a suggestion:
**no unattended mail reading.** No cron job, no scheduled brief, no webhook path
that pulls Gmail without the operator in the loop. `approvals.unattended_mode:
deny` supports this; the rule makes it explicit, because a "morning brief" that
reads mail on a timer is precisely the unattended injection path.

**7.2 — A send-capable token exists.** Single-lock, because Layer 0 cannot
express drafts-without-send (§5). The lock is the MCP server's tool allowlist
plus the §6 gate. Accepted knowingly; asserted by a test so it cannot regress
silently.

**7.3 — Third-party code holds that token.** The supply chain moves rather than
vanishing. Mitigated by building from source and pinning by digest — the same
answer given to every other image in this stack.

**7.4 — MCP tool descriptions are third-party, model-facing text**, and
therefore a prompt-injection surface by construction. Mitigated by the Layer 2
`include` allowlist and by reading the descriptions during implementation rather
than trusting them.

**7.5 — Scope downgrade on re-auth.** `NousResearch/hermes-agent` issue #4718
documents Google tokens being silently replaced by narrower-scoped ones on
re-authorisation, leaving the setup looking healthy until calls fail. Post-setup
verification must assert the granted scope set, not merely that the token
authenticates.

## 8. OAuth consent, and a hardening opportunity

Google requires a public HTTPS redirect URI. The existing stack pattern applies:
CNAME → tunnel → Traefik file rule in `apps.yml` (on the NAS, outside the synced
tree, per parent C4) → container, behind Cloudflare Access on the single-user
policy.

**The route is temporary, and this is a deliberate hardening choice.** Token
refresh does not need the callback — only initial consent and re-consent do. The
container is attached to `hermes_ingress` with **no Traefik router by default**;
the router is added for the consent flow and removed afterwards. The MCP server
therefore has **no standing internet-facing surface at all**.

Two consequences, both accepted:

- `hermes_ingress` stops being a two-member network. This grants no new
  capability: Hermes can already reach this container on `hermes_net`, and the
  property that mattered — Hermes not sharing a network with Portainer and
  Dozzle — is unaffected.
- Plain OAuth 2.0 is used rather than OAuth 2.1, so only `/oauth2callback` needs
  forwarding, not `/oauth2/*` and `/.well-known/*`. `MCP_ENABLE_OAUTH21` stays
  unset. Multi-user auth is not wanted here.

Redirect URI is set via `WORKSPACE_EXTERNAL_URL` or `GOOGLE_OAUTH_REDIRECT_URI`
and must match the Google Cloud Console entry exactly.

## 9. Go/no-go prerequisite

**OAuth clients left in "Testing" publishing status issue refresh tokens that
expire after 7 days.** For a headless agent that means weekly manual re-consent,
which would make this deployment pointless. The standard escape is publishing
the client to "In production" unverified — one scary consent screen, a 100-user
cap, durable refresh tokens. The wrinkle is that `gmail.readonly` and
`drive.readonly` are both **restricted** scopes, where Google's verification
policy is most aggressive and has been tightening.

This is confirmed against the live console **before any container is built**. If
durable tokens are not obtainable for these scopes on a personal account, the
design changes shape and this document is revised rather than worked around.

## 10. Verification

Extend `docs/superpowers/verify/hermes-threat-model.sh` (currently 47/47) rather
than adding a parallel script — if this change reduces containment, that suite
is what should say so.

New assertions:

1. Hermes has no mount, no filesystem path, and no network route to the MCP
   credential volume.
2. Hermes still cannot reach `googleapis.com` directly; the tinyproxy filter is
   unchanged, and that is the proof.
3. The MCP server's **live** tool list matches the §1 policy exactly — this fails
   loudly if an upstream version bump adds tools.
4. Send is gated or absent, demonstrated rather than asserted.
5. `config.yaml`'s `mcp_servers` block matches the root-owned golden copy, via
   the extended `hermes-guardrail-check.sh`.
6. Granted OAuth scopes match §5 exactly (see §7.5).
7. The existing 47 still pass.
8. No other container disturbed — uptimes checked before and after.

## 11. Explicitly out of scope

- **Additional messaging channels** (WhatsApp, Instagram, Messenger). A separate
  project. Recorded finding: personal Instagram and Messenger DMs are not
  reachable by any sanctioned API — Instagram's Messaging API requires a
  Professional account linked to a Facebook Page, and Messenger's Platform API
  acts as a Page rather than as a person. Only WhatsApp is genuinely available,
  via either the official Cloud API (a separate number, not the operator's
  personal account) or an unofficial companion-device bridge (works, violates
  ToS, real ban risk).
- **Google Keep.** No usable API on a personal account; the Keep API is
  Workspace-only and requires admin enrolment.
- **Sheets, Slides, Chat, Forms, Tasks.** The server supports them; this design
  does not enable them. Adding a surface is a scope change, not a config tweak.
- **Backups.** Per the settled decision of 2026-09-08, unchanged.
- **Bitwarden Secrets Manager.** Raised 2026-09-10, deferred to its own project,
  and one conclusion is settled: Hermes' **native** `secrets.bitwarden`
  integration is rejected for this deployment. It puts `BWS_ACCESS_TOKEN` in
  `hermes.env`, which the agent can read (mode `0640`, group 10 is the agent's
  only group) — trading three scoped, individually revocable keys for one token
  that fetches the whole project. It auto-downloads `bws` to `~/.hermes/bin/`,
  which resolves to `/opt/data/bin` here, with **no configurable path** — the
  tirith problem again, minus the `tirith_path` pin that solved it, on a binary
  that handles secrets. And it would add `vault.bitwarden.com` to the egress
  allowlist. BSM remains worth doing at the **operator layer** — materialising
  `$DOCKERDIR/secrets/*` at deploy time from a host-side machine account whose
  token never enters a container — which gains central rotation, audit and
  per-integration revocation while leaving containment unchanged. When that
  project happens, this design's `client_secret.json` becomes one of its inputs.

## 12. Open items for implementation

1. **§9 go/no-go** — durable refresh tokens for restricted scopes. Blocks
   everything.
2. **§6 spike** — does `approvals.mode: manual` cover MCP tool calls?
   Determines whether the Telegram shim is needed.
3. **§5** — enumerate the live tool list; map to policy; pin
   `--disabled-tools`.
4. **§3 UNVERIFIED** — confirm the server honours `HTTPS_PROXY`.
5. Extend `hermes-guardrail-check.sh` to `mcp_servers.*` (§5).
6. Choose the consent hostname and its CNAME (§8).
7. Confirm whether the server's own scope minimisation narrows the requested
   scope set when tools are disabled — if it does, some of §5's Layer 0 may
   tighten for free.
