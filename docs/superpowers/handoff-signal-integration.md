# Handoff: add Signal messaging to the Hermes agent

You are picking up work on a hardened self-hosted AI agent running on a Synology
NAS. Everything below is verified against the live system unless explicitly
marked UNVERIFIED. Read the whole brief before touching anything — several of
these facts were learned the hard way and cost real debugging time.

---

## 1. Your task

Give the Hermes agent a **Signal** channel, so the operator can talk to it from
Signal on their phone.

Signal is **not** a Hermes plugin — it is built into the core gateway.
`/opt/hermes/plugins/platforms/` has 22 entries (telegram, whatsapp, slack,
discord, matrix, …) and **no `signal` directory**, but `hermes_cli/config.py`,
`hermes_cli/gateway.py`, `hermes_cli/status.py` and
`hermes_cli/web_routers/messaging.py` all read `SIGNAL_*` variables.

Environment variables the core actually reads (extracted from the image, this is
the complete list):

```
SIGNAL_ACCOUNT                        SIGNAL_MAX_ATTACHMENTS_PER_MSG
SIGNAL_HTTP_URL                       SIGNAL_MAX_ATTACHMENT_SIZE
SIGNAL_ALLOWED_USERS                  SIGNAL_MIN_CONTRAST
SIGNAL_GROUP_ALLOWED_USERS            SIGNAL_NAME_BY_NUM
SIGNAL_HOME_CHANNEL                   SIGNAL_RATE_LIMIT_BUCKET_CAPACITY
SIGNAL_HOME_CHANNEL_NAME              SIGNAL_RATE_LIMIT_DEFAULT_RETRY_AFTER
SIGNAL_IGNORE_STORIES                 SIGNAL_RATE_LIMIT_MAX_ATTEMPTS
SIGNAL_INTERRUPT_GRACE_TIMEOUT        SIGNAL_REACTIONS
SIGNAL_BATCH_PACING_NOTICE_THRESHOLD  SIGNAL_REQUIRE_MENTION
SIGNAL_RPC_ERROR_RATELIMIT
```

### The intended shape

1. A **separate `signal-cli` container** on the `hermes_net` network running a
   daemon that speaks whatever protocol Hermes expects (see UNVERIFIED below).
2. Hermes reaches it at `http://signal-cli:8080`. This is already permitted —
   the firewall allows `hermes → 192.168.92.0/24`. **No egress-allowlist change
   is needed**: signal-cli is a separate container, not covered by Hermes'
   `DOCKER-USER` DROP rules, so it does its own egress to Signal's servers
   normally.
3. `SIGNAL_ACCOUNT`, `SIGNAL_HTTP_URL` and `SIGNAL_ALLOWED_USERS` go into
   `hermes.env` (root-owned, read-only to the agent).
4. Restart `hermes`.
5. The operator links the device by scanning a QR code with their phone.

### CRITICAL UNVERIFIED ITEM — resolve this first

**Which wire protocol does Hermes speak to signal-cli?** The docs say
`signal-cli --account +NNN daemon --http 127.0.0.1:8080`, described as "SSE and
JSON-RPC". The popular Docker image `bbernhard/signal-cli-rest-api` exposes a
**different, REST** API. If you point `SIGNAL_HTTP_URL` at the REST wrapper and
Hermes expects native signal-cli JSON-RPC, it will fail in confusing ways.

Read `/opt/hermes/` for the Signal client implementation and confirm the exact
endpoints and payloads before choosing an image. Find it with:

```bash
ssh nas 'sudo /usr/local/bin/docker exec -u 1000:10 hermes sh -c \
  "grep -rln SIGNAL_HTTP_URL /opt/hermes/ | head"'
```

Choose the image that matches the protocol Hermes implements. Do not guess.

### Security requirement specific to this task

signal-cli will hold **linked-device credentials for the operator's personal
Signal account** — it can read and send as them. Treat its data directory as a
credential store: root-owned, mode `0700`, **not** reachable from the Hermes
container, and not inside `/opt/data` or `/volume1/code`. Harden the container
like the others: non-root where the image allows, `cap_drop: ALL`,
`no-new-privileges`, `read_only` with targeted tmpfs if it will boot that way,
and a `mem_limit`.

`SIGNAL_ALLOWED_USERS` is not optional. Without it the agent answers anyone who
messages the number. There is also `GATEWAY_ALLOWED_USERS` (cross-platform,
verified real in the image). **Never** set `GATEWAY_ALLOW_ALL_USERS`.

---

## 2. The system you are working on

**Repo:** `C:\Users\jhbas\Documents\claude-projects\nas-docker`, branch
`hermes-agent`. It is a git-tracked mirror of the NAS at `/volume1/docker`.
`push.sh` tars `docker-compose.yml` + `compose/` onto the NAS; `pull.sh` is the
reverse.

**STANDING RULE: run `./pull.sh` and check `git status` before every
`./push.sh`.** The NAS has been ahead of git before; pushing blindly would have
downgraded Traefik to an EOL version and reintroduced a config that broke every
compose command.

**Host:** `ssh nas` → `bassfja33@192.168.1.104`, Synology DS920+, DSM 7,
kernel **4.4.302**, Docker 24.0.2, compose v2.20.1, systemd 219.

### Environment quirks — do not rediscover these

- **`sudo docker` does not work.** Use `sudo /usr/local/bin/docker`.
- **`scp` to this NAS is broken** (SSH subsystem error). Use
  `ssh nas 'cat > /path/file' < localfile`.
- Passwordless sudo works, so `ssh nas 'sudo ...'` is non-interactive.
- **Never put a top-level `networks:` block in an included compose file.** A
  stray one in `maintainerr.yml` previously broke *every* compose command on
  this NAS. Networks are declared only in the root `docker-compose.yml`.
- **Never run a bare `docker compose up -d`** — always name the service, or you
  recreate the entire live stack (Plex, *arr, Pi-hole DNS for the house).
- The NAS's system `python3` has **no `yaml` module**. A monitoring script that
  used PyYAML silently compared two identical error strings and reported
  "unchanged" — a false pass. Prefer awk/sed for host-side parsing.
- systemd 219 predates `systemctl --now`; enable and start are separate.
- `hermes model` and `hermes config edit` **require a real TTY** and refuse to
  run through a pipe.

---

## 3. The Hermes deployment as it stands

Container `hermes`, image pinned **by digest** (`nousresearch/hermes-agent@sha256:a62824a4…`),
deliberately no watchtower label so it never auto-updates.

**Networks (three, all static IPs):**

| Network | Hermes IP | Peer |
|---|---|---|
| `hermes_ingress` 192.168.94.0/24 | `.10` | Traefik `.254` — two-member network, ingress only |
| `hermes_net` 192.168.92.0/24 | `.10` | Tinyproxy egress allowlist `.2:8888` |
| `hermes_socket` 192.168.93.0/24 | `.10` | Restricted docker socket proxy `.2:2375` |

Hermes is **not** on `t3_proxy` — it was moved off deliberately (finding C1),
because that network also holds Portainer (backed by the *permissive* socket
proxy = container create = root on the NAS) and an unauthenticated Dozzle.

**Mounts:**

| Host | Container | Mode |
|---|---|---|
| `appdata/hermes` | `/opt/data` | rw — holds `config.yaml` |
| `appdata/hermes-etc/hermes.env` | `/opt/data/.env` | **ro** — secrets |
| `appdata/hermes-etc/{passwd,group}` | `/etc/{passwd,group}` | ro |
| `appdata/hermes-bin` | `/opt/hermes-bin` | ro — tirith scanner |
| `/volume1/code` | `/opt/code` | rw — coding role |

Runs as `1000:10`, `read_only: true`, `cap_drop: ALL`,
`no-new-privileges:true`, `mem_limit: 4g`, `memswap_limit: 4g`,
`cpu_shares: 512`, `ulimits nproc 1024/nofile 4096`, **no published ports**.

`pids_limit` and `cpus` are impossible on this kernel (no `CONFIG_CGROUP_PIDS`,
no CFS bandwidth) — setting `cpus:` makes compose refuse to create the container
outright. The rlimit/cpu_shares pair above is the substitute. Do not "fix" this.

`HERMES_WRITE_SAFE_ROOT=/opt/data:/opt/code` is set **in compose, not in
`hermes.env`** — that file's loader truncates values at the first `:`, silently
turning the pair into `/opt/data`.

**Ingress:** Cloudflare Access (one-time PIN) → Cloudflare Tunnel → Traefik
(`chain-no-auth`: rate limit + secure headers) → Hermes' own form login.
Traefik routes live in `/volume1/docker/appdata/traefik3/rules/udms/apps.yml`
**on the NAS**, outside the synced tree.

**Model:** `deepseek/deepseek-v4.1-flash` via OpenRouter.

---

## 4. Security invariants — do not break these

The threat model is **prompt injection**: assume the agent is fully hijacked and
ask what it can still do. All of this is asserted by a test suite (§5).

1. **Socket proxy allowlist.** Read endpoints plus `POST /containers/<name>/restart`
   for exactly eight containers (`plex|radarr|sonarr|bazarr|sabnzbd|seerr|tautulli|maintainerr`).
   `hermes` itself, both its proxies, `traefik`, `cloudflared`, `pihole`,
   `socket-proxy`, `watchtower`, `portainer` and `dozzle` are all excluded.
2. **Egress.** Tinyproxy domain allowlist is the *policy*; `DOCKER-USER` +
   `INPUT_FIREWALL` DROP rules keyed on Hermes' three source IPs are the
   *enforcement*. Applied by `/volume1/docker/scripts/hermes-firewall.sh`,
   re-applied hourly by `hermes-firewall.service` + `.timer`.
3. **External DNS from Hermes is blocked on purpose.** Tinyproxy resolves on its
   behalf; internal container names still resolve. This closes DNS tunnelling.
   `DNS-BROKEN` from inside the container is the PASS condition.
4. **`hermes.env` stays read-only.** `config.yaml` was made writable at the
   operator's request so the dashboard's model picker works — that knowingly
   reopened one leg of finding C3. Two compensating controls exist and must
   stay: the agent cannot restart itself to reload a rewritten config, and
   `/volume1/docker/scripts/hermes-guardrail-check.sh` diffs the security keys
   hourly against a root-owned golden copy.
5. **tirith** (pre-exec scanner) is mounted read-only from a root-owned `0555`
   file with `security.tirith_path` pinned, specifically so the agent cannot
   overwrite its own scanner. `tirith_fail_open: false`.

If your work requires relaxing any of these, **stop and ask the operator** with
the trade-off spelled out. Do not decide it yourself.

---

## 5. Definition of done

- signal-cli container running and hardened; its credential directory
  root-owned and unreachable from Hermes.
- `SIGNAL_ACCOUNT`, `SIGNAL_HTTP_URL`, `SIGNAL_ALLOWED_USERS` set in
  `hermes.env`; `GATEWAY_ALLOW_ALL_USERS` **not** set.
- Operator has linked the device (their step — you prepare a single command and
  tell them exactly what to expect).
- Verified end to end: the operator messages the number and gets a reply, and a
  message from a **non-allowlisted** sender is ignored.
- **`docs/superpowers/verify/hermes-threat-model.sh` still passes 47/47.** Run it
  as the agent's own uid inside the container:
  ```bash
  ssh nas 'sudo /usr/local/bin/docker exec -i -u 1000:10 hermes bash /dev/stdin' \
    < docs/superpowers/verify/hermes-threat-model.sh
  ```
  If your change reduces containment, the suite is the thing that should tell
  you — extend it rather than weakening it.
- No other container disturbed (check uptimes before and after).
- Committed on branch `hermes-agent` with the reasoning in the message.

## 6. Background reading in this repo

- `docs/superpowers/specs/2026-09-09-hermes-agent-nas-design.md` — design and
  threat model
- `docs/superpowers/plans/2026-09-09-hermes-agent-nas.md` — the build plan, with
  AS-BUILT notes recording where reality diverged
- `appdata-templates/README.md` — which config file goes where, with required
  ownership and mode (git preserves neither)
- `CLAUDE.md` — Traefik/tunnel conventions for this stack
