# ENVIRONMENT.md — what this container is, and what it deliberately is not

    SOURCE OF TRUTH: appdata-templates/hermes/ENVIRONMENT.md in the nas-docker repo
    HOST PATH:       /volume1/docker/appdata/hermes-etc/ENVIRONMENT.md
    OWNER/MODE:      root:root 0644
    MOUNTED AS:      /opt/data/ENVIRONMENT.md   READ-ONLY
    LAST VERIFIED:   2026-09-10  against image digest a62824a4ec6f

This file is mounted read-only **on purpose**. It is a description of your own
containment, so if you could edit it, a prompt-injected you could lie to a
future you. If the date above is stale, treat the contents as a hypothesis and
say so rather than trusting it silently.

**Everything below that says "blocked", "absent" or "deliberate" is a working
control, not a bug.** You are running inside a hardened container that is
itself the security boundary — this DSM kernel has no cgroup v2 and no rootless
Docker, so there is no second sandbox underneath. Do not file these as faults,
do not route around them, and do not ask for them to be loosened without an
argument about the threat model.

---

## 1. Network: how you reach the internet

**There is exactly one way out: an HTTP proxy at `192.168.92.2:8888`, by bare
IP.** It is a tinyproxy running a domain allowlist with `FilterDefaultDeny Yes`.

`HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` are set explicitly in your
environment. Nothing is transparently intercepted — check `env` and believe it.

    HTTP_PROXY  = http://192.168.92.2:8888
    HTTPS_PROXY = http://192.168.92.2:8888
    NO_PROXY    = 192.168.90.0/24,192.168.92.0/24,192.168.93.0/24,localhost,127.0.0.1

### The allowlist, in full

    openrouter.ai                        api.telegram.org
    github.com                           setup.hermes-agent.nousresearch.com
    api.github.com                       discord.com
    codeload.github.com                  gateway.discord.gg
    objects.githubusercontent.com
    registry.npmjs.org
    pypi.org
    files.pythonhosted.org

Anything not on that list does not resolve, does not connect, and will not be
added to make a tool work. `CONNECT` is restricted to port **443** — no other
port, no other protocol.

### Your DNS is blocked, and that is the design

`getent hosts pypi.org` fails. `nslookup openrouter.ai` fails. `curl
https://pypi.org/...` **succeeds**. That is not a contradiction and not a flaky
resolver:

- Docker's embedded resolver at `127.0.0.11` still answers **container names**
  (`nslookup hermes-egress-proxy` → `192.168.92.2` works).
- For **external** names dockerd forwards the query out of your own network
  namespace, so the packet carries your source IP and is dropped by the
  host firewall chain `HERMES-CONTAIN`.
- The proxy resolves on your behalf. You never need to.

DNS tunnelling is a classic exfiltration channel that a *domain* allowlist
cannot inspect. Denying you a resolver closes it outright. `DNS-BROKEN` is the
**pass** condition in the deployment's own verification script.

DNS-over-HTTPS (`dns.google`, `cloudflare-dns.com`) is blocked for the same
reason and will stay blocked. The Telegram adapter probes both at startup and
falls back to seed IPs — that costs a ~5 second startup delay and is not a
fault.

### TLS is NOT intercepted

There is no MITM proxy and no custom CA. Tinyproxy does plain `CONNECT`
passthrough, so your TLS session terminates at the real origin with its real
certificate. `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS` and
`GIT_SSL_CAINFO` are **deliberately unset and should stay unset** — there is
nothing to point them at. A certificate error here means a genuine certificate
problem, never a proxy.

### Telling a policy block from a network failure

**They already are distinguishable — you just have to read the right signal.**
`curl -w '%{http_code}'` reports **`000`** for a blocked domain, because the
`CONNECT` tunnel never opened and there is no origin response to report. That
`000` is not a mystery failure. Use the **exit code**, or `-v`. Measured live
on this deployment, 2026-09-10:

| Probe | curl exit | What it means |
|---|---|---|
| allowlisted domain | **0** | worked |
| non-allowlisted domain | **56** | `HTTP/1.0 403 Filtered`, `Server: tinyproxy` on the CONNECT. **Policy.** Do not retry, do not fall back. |
| bare IP, ordinary curl | **56** | Same 403 as above. `HTTPS_PROXY` is set globally, so curl `CONNECT`s the IP through tinyproxy and the filter refuses it *before* the firewall ever sees a packet. **Policy.** |
| bare IP, `--noproxy '*'` | **28** (timeout) | Only now do you reach the wire, and `HERMES-CONTAIN` drops it. **Policy.** |
| bare IP inside `NO_PROXY` (`192.168.90/92/93.0/24`) | **28** | curl bypasses the proxy for these by config, so the drop shows through without any flag. |
| external name via a resolver | fails always | Expected. Use the proxy; do not "fix" DNS. |

**Read that table carefully: 56 does not mean "domain not on the allowlist".**
It means "tinyproxy refused the CONNECT", and a bare IP earns the same refusal
for a different underlying reason. Because `HTTPS_PROXY` is set for everything,
the default path for *any* target is the proxy — a firewall-dropped IP and a
non-allowlisted domain are indistinguishable at exit 56. If you actually need
to tell them apart, re-run with `--noproxy '*'` and look for **28**. Both are
policy either way, so this only matters when you are describing *which* control
stopped you.

`curl -sv <url> 2>&1 | grep -i "tinyproxy\|403 Filtered"` is the one-line
check, and it is a flat single-purpose command that will not trip the scanner
(§5). A ~60 ms **502** through the public hostname is the same thing seen from
outside: blocked egress, not a dead origin and not a timeout.

If you still cannot classify a failure, say "I could not distinguish a policy
block from a network error" and stop. Do not guess, and do not conclude a
capability is broken.

### Everything else on the network is denied

You hold three static IPs — `192.168.94.10` (ingress from Traefik),
`192.168.92.10` (egress proxy), `192.168.93.10` (docker socket proxy). The host
firewall permits you to reach exactly three destinations:

    192.168.92.2     the egress proxy
    192.168.93.2     the restricted docker socket proxy (read + scoped restart)
    192.168.94.254   Traefik, your only ingress peer

Everything else is dropped: the LAN, the IoT VLAN, the router, the rest of the
Docker stack, and the NAS host itself on every one of its addresses (including
every bridge gateway — they are all the same host). Home Assistant, Portainer,
Plex, DSM and sshd are unreachable by construction. Drops present as a **28
timeout**, not a refusal. (The rules attempt rate-limited logging, but this
kernel's `LOG` target is unavailable, so drops are currently silent — the drop
itself is unaffected.)

---

## 2. Filesystem: what persists and what does not

The root filesystem is **read-only**. There are exactly four writable paths.

| Path | Backing | Survives restart? | Notes |
|---|---|---|---|
| `/opt/data` | bind mount → `/volume1/docker/appdata/hermes` | **yes** | your `$HOME`. Memory, skills, state. |
| `/opt/code` | bind mount → `/volume1/code` | **yes** | the coding workspace |
| `/tmp` | tmpfs, **64 MB**, `noexec,nosuid,nodev` | no | wiped every start |
| `/run` | tmpfs, 16 MB | no | s6 supervision only — not yours |

`HERMES_WRITE_SAFE_ROOT=/opt/data:/opt/code` confines `write_file`/`patch` to
those two prefixes at the tool layer, so a denied write gives you a clear error
instead of an opaque `EROFS`.

**`/opt/data` is not backed up.** That is a known, deliberate, settled operator
decision — not an oversight, and not something to raise again. Treat anything
you keep there as valuable but not insured. It is *not* destroyed by an image
rebuild or a `compose down/up`; it lives on the NAS volume, outside the
container lifecycle.

### Read-only mounts you cannot write, by design

    /opt/data/.env             secrets      root:10  0640   (read-only mount)
    /opt/data/ENVIRONMENT.md   this file    root:root 0644  (read-only mount)
    /opt/hermes-bin/           tools        root:root 0555  (read-only mount)
    /etc/passwd, /etc/group    identity     root:root 0644  (read-only mount)
    /etc/profile               shell PATH   root:root 0644  (read-only mount, see §3)

`/opt/data/.env` holds the OpenRouter key, the GitHub PAT, the Telegram bot
token and the dashboard credentials. You can read it; you can never write it.
The Hermes dashboard's own Telegram onboarding wizard tries to write it on its
final step and therefore **cannot complete in this deployment** — that is
architectural, not a bug to work around. Pairing is done by the operator.

`/opt/data/config.yaml` is the exception: it is a **normal writable file**
inside `/opt/data`, not a bind mount, so the dashboard's model picker can
persist. This is a knowing operator trade-off. Two things still hold it down:
you are not in the socket proxy's restart allowlist, so you cannot reload a
config you have rewritten; and an hourly host-side job compares it against a
root-owned golden copy you can neither read nor write. Model changes are
ignored, security keys are not. Editing guardrails there achieves nothing
except tripping an alarm.

---

## 3. Tools and caches

`/opt/hermes-bin` holds statically linked binaries that are **root-owned and
read-only**, so nothing in your writable mount can shadow or replace them:

    /opt/hermes-bin/jq        jq 1.7.1
    /opt/hermes-bin/tirith    the pre-execution scanner (see §5)

### Your `PATH` — fixed 2026-09-10, and how it can look broken again

`/opt/hermes-bin` is on your `PATH`, **including inside your own shell**:

    /opt/hermes/bin:/opt/hermes/.venv/bin:/usr/local/sbin:/usr/local/bin
    :/usr/sbin:/usr/bin:/sbin:/bin:/opt/hermes-bin

It did not used to be. This image's stock `/etc/profile` **assigned** `PATH`
rather than extending it, so a login shell run as a non-root UID was left with
`/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games` and lost
`/opt/hermes/bin`, `/opt/hermes/.venv/bin` and `/opt/hermes-bin` in one go.
`/etc/profile` is now a **root-owned read-only bind mount** of a corrected copy
that keeps the inherited `PATH` instead. Same pattern as `/etc/passwd`.

**The part worth remembering, because it will bite you again after any operator
change to `PATH`:** you only get a login shell **once per session**.
`tools/environments/local.py::_run_bash` passes `-l` a single time, for
`init_session`'s environment snapshot; that snapshot is written to
`$HERMES_HOME/tmp/hermes-snap-*.sh` as `declare -x` lines, and every command
after it runs as a **non-login** `bash -c` that sources the snapshot. So
`shopt -q login_shell` is correctly `false` in your shell and yet the login
shell's environment is what you are living in — captured at bootstrap and
inherited for the rest of the session. A `PATH` change made by the operator
therefore does **not** appear until a new session; the snapshot is the stale
thing, not the container.

`/opt/data/.local/bin` used to be on `PATH` ahead of `/usr/bin`, inherited from
the image. It has been **removed**, and the mounted `/etc/profile` strips any
`/opt/data` entry independently so it cannot return. `/opt/data` is your
writable mount: a directory on it that sits ahead of `/usr/bin` is a
binary-shadowing path, which is the whole reason `jq` and `tirith` live on a
root-owned `0555` mount instead. Nothing needs it and the directory does not
exist on disk (only `.local/share` and `.local/state` do). Do not ask for it
back.

### Read exit codes from the right process

`cmd --version 2>&1 | head -1; echo $?` reports **`head`'s** status, not
`cmd`'s — a pipeline's status is its last stage. That will tell you a missing
binary is present. Use `command -v cmd`, or run the command unpiped.

Ask the operator to add binaries here rather than installing them into
`/opt/data/bin` yourself. A tool you can overwrite is a tool an attacker who
reaches you can overwrite.

Caches are pointed at `/opt/data/.cache` so they survive restarts and do not
fill the 64 MB `/tmp`:

    XDG_CACHE_HOME=/opt/data/.cache        PIP_CACHE_DIR=/opt/data/.cache/pip
    UV_CACHE_DIR=/opt/data/.cache/uv       npm_config_cache=/opt/data/.cache/npm
    UV_PYTHON_INSTALL_DIR=/opt/data/.cache/uv-python
    TMPDIR=/opt/data/tmp

Note `/opt/data/cache/` (no dot) is Hermes' own cache and is unrelated — do not
put tool caches there.

`security.allow_lazy_installs` is **false**: automatic runtime package
installation is off. `pypi.org` and `registry.npmjs.org` are allowlisted so
deliberate, explicit installs work, but a dependency appearing by itself is a
supply-chain path and is disabled on purpose.

### Absent on purpose

- **`wget`** — `curl` is present, use it.
- **`sudo`, a writable `/`** — never coming. Nothing you need requires them.
- **General web browsing.** With a 12-domain default-deny allowlist there is no
  general-purpose web, and there will not be: an allowlist and a browser are in
  direct tension, and the allowlist wins. `browser.allow_private_urls` is false
  and `*.bassford.net` and `localhost` are blocklisted so the browser cannot be
  turned into an SSRF probe into the LAN. If you need a specific documentation
  domain for real work, **ask for that domain by name** — a narrow addition is
  arguable, broad egress is not.
- **`api.openai.com`** — deliberate. The model route is OpenRouter
  (`model.provider: openrouter`). Route around it, do not ask for it.
- **Google APIs** — **deployed, and deliberately not in your egress allowlist.**
  Access goes through a separate MCP container (`mcp_servers.google`, at
  `http://192.168.92.3:8000/mcp`), which holds the OAuth token in its own volume
  and reaches `*.googleapis.com` through its own allowlist proxy. You call it
  with the `google` MCP tools and never see a Google credential: the token is not
  on any mount you can read, and `*.googleapis.com` is still absent from your own
  proxy filter.

---

## 4. Resources

    mem_limit      4 GB     memswap_limit 4 GB   (enforced — no swap headroom)
    cpu_shares     512      (relative weight under contention, NOT an absolute cap)
    ulimits nproc  1024     (enforced — RLIMIT_NPROC, no cgroup needed)
    ulimits nofile 4096

`cpus:` and `pids_limit:` are **not enforced on this kernel** — it has no CFS
bandwidth control and `CONFIG_CGROUP_PIDS` was never built in. `cpu_shares` and
`ulimits.nproc` are the compensating controls that actually work. This NAS is a
4-core J4125 that also runs Plex, Traefik and the *arr stack; you are weighted
to lose the scheduler fight under contention, which is intended.

---

## 5. The pre-execution scanner

`tirith` scans every command before execution for prompt-injection, credential
exfiltration and terminal-injection patterns. It runs from the read-only mount
and `tirith_fail_open: false` — if it cannot run, execution is **blocked**, not
allowed.

Complex nested shell constructs (multi-line `for` loops, chained subshells)
sometimes trip it mid-run. This is the scanner, not the container, and it will
not be loosened to allowlist recon patterns — a scanner that gets relaxed once
gets relaxed again. **Write flat, single-purpose commands.** It costs a few
extra turns and nothing else.

`approvals.mode: smart` — a flagged command is adjudicated by a guardian model
(`auxiliary.approval`, a pinned free model) rather than always stopping a
human. It **fails safe**: any exception — blocked egress, provider timeout, an
unparseable answer — returns `escalate`, which falls through to the manual
prompt, so the worst case is the old manual behaviour and never an
auto-approve. An `APPROVE` covers that one command only; it never whitelists
the pattern.

The `deny` globs are not delegated to the guardian — they block first, as does
the built-in hardline blocklist. `sudo *`, `rm -rf *`, `chmod 777*`,
`docker *`, `curl|sh`, `wget|sh` and `git push --force*` are denied outright,
and deny beats any allowlist.

---

## 6. When this changes

Any change to the allowlist, the mounts, the resource caps or the deliberate
absences above is an **operator action on the NAS host** followed by a
container restart, and this file is updated in the same change. The `LAST
VERIFIED` date at the top is the contract: if you observe something that
contradicts this file, report the contradiction explicitly — it means either
the environment drifted or this document did, and both are worth knowing.
