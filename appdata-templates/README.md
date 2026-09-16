# `appdata-templates/` — NAS-side files that git cannot deliver

Everything in this directory belongs **on the NAS**, not in a container image
and not in `compose/`.

**`push.sh` does not sync this directory.** It tars only `docker-compose.yml`
and `compose/`. These files must be copied across by hand, and `scp` to this
NAS is broken, so use:

```bash
ssh nas 'cat > /path/on/nas/file' < appdata-templates/<local file>
```

**Git preserves neither ownership nor mode.** The manifest below is therefore
the *only* record of what each file must be owned by and set to. Several of
these files are security boundaries whose entire value comes from the agent
being unable to write them — a wrong `chown` silently turns an enforced control
back into an advisory one, with no error anywhere. Copy the file, then run the
`install` line.

## Manifest

| Repo file | NAS path | Owner | Mode |
|---|---|---|---|
| `hermes/passwd` | `/volume1/docker/appdata/hermes-etc/passwd` | `root:root` | `0644` |
| `hermes/group` | `/volume1/docker/appdata/hermes-etc/group` | `root:root` | `0644` |
| `hermes/config.yaml` | `/volume1/docker/appdata/hermes-etc/config.yaml` | `root:root` | `0644` |
| `hermes/hermes.env` | `/volume1/docker/appdata/hermes-etc/hermes.env` | `root:10` | `0640` |
| `hermes/ENVIRONMENT.md` | `/volume1/docker/appdata/hermes-etc/ENVIRONMENT.md` | `root:root` | `0644` |
| `hermes-egress/tinyproxy.conf` | `/volume1/docker/appdata/hermes-egress/tinyproxy.conf` | `root:root` | `0644` |
| `hermes-egress/filter` | `/volume1/docker/appdata/hermes-egress/filter` | `root:root` | `0644` |
| `hermes-searxng/settings.yml` | `/volume1/docker/appdata/hermes-searxng/settings.yml` | `root:root` | `0644` |
| `scripts/hermes-firewall.sh` | `/volume1/docker/scripts/hermes-firewall.sh` | `root:root` | `0750` |
| `scripts/ha-install-midea-ac-lan.sh` | `/volume1/docker/scripts/ha-install-midea-ac-lan.sh` | `root:root` | `0750` |
| `hermes-hindsight/passwd` | `/volume1/docker/appdata/hermes-hindsight-etc/passwd` | `root:root` | `0644` |
| `hermes-hindsight/group` | `/volume1/docker/appdata/hermes-hindsight-etc/group` | `root:root` | `0644` |
| `hermes-hindsight/hindsight.env` | `/volume1/docker/appdata/hermes-hindsight/hindsight.env` | `root:root` | `0600` |

Directories:

| NAS path | Owner | Mode | Notes |
|---|---|---|---|
| `/volume1/docker/appdata/hermes-etc` | `root:root` | `0755` | read-only mount sources; the agent must never own this |
| `/volume1/docker/appdata/hermes-bin` | `root:root` | `0755` | read-only tool mount (`/opt/hermes-bin`); see below |
| `/volume1/docker/appdata/hermes-etc/profile` | `root:root` | `0644` | corrected `/etc/profile` (PATH); see below |
| `/volume1/docker/appdata/hermes` | `1000:10` | `0700` | the agent's read-write state (`/opt/data`) |
| `/volume1/docker/appdata/hermes/skills` | `1000:10` | `0755` | operator-installed skills (`/opt/data/skills`); see below |
| `/volume1/docker/appdata/hermes/.cache` | `1000:10` | `0755` | tool caches (uv/pip/npm/XDG); **dotted** — `hermes/cache` is Hermes' own |
| `/volume1/docker/appdata/hermes/tmp` | `1000:10` | `0755` | `TMPDIR`; keeps large wheels off the 64 MB `/tmp` tmpfs |
| `/volume1/docker/appdata/hermes-egress` | `root:root` | `0755` | |
| `/volume1/docker/appdata/hermes-searxng` | `root:root` | `0755` | read-only SearXNG settings; the agent must never own this |
| `/volume1/docker/appdata/hermes-hindsight` | `1200:1200` | `0700` | Hindsight's embedded PostgreSQL, mounted at `/home/hindsight/.pg0`; the memory store — never mounted into hermes |
| `/volume1/docker/appdata/hermes-hindsight/hfcache` | `1200:1200` | `0755` | copy of the image's own HF model cache (see seed command below); writable scratch for the 1200 runtime |
| `/volume1/docker/appdata/hermes-hindsight-etc` | `root:root` | `0755` | read-only `/etc/passwd` + `/etc/group` mount sources |
| `/volume1/docker/appdata/hermes-health/credentials` | `1100:1100` | `0700` | health MCP OAuth token; never mounted into hermes (see below) |
| `/volume1/docker/scripts` | `root:root` | `0755` | |
| `/volume1/code` | `1000:10` | `0755` | the coding role's workspace (`/opt/code`) |

### Why those owners and modes

- **`hermes-etc/*` is `root`-owned, never `1000`.** The container runs as
  `user: "1000:10"`. Everything in `hermes-etc` is bind-mounted `:ro`, but a
  read-only bind mount plus a root-owned file is two independent reasons the
  agent cannot write it; either alone is one config change away from being
  undone. `cap_drop: ALL` removes `CAP_DAC_OVERRIDE`, so root ownership is
  genuinely enforced against the container.
- **`hermes.env` is `root:10 0640`, not `root:root 0644` and not `root:1000`.**
  The agent's process holds exactly one group, **GID 10** (its `PGID`; it shows
  as `uucp` inside the container and `wheel` on the DSM host). GID 10 is
  therefore the only group that can grant it read access — `root:1000` would
  grant nothing, because the agent is not *in* group 1000, and the file would
  be unreadable. `0640` rather than `0644` keeps API keys and tokens off the
  world-read bit. Host-side this grants read to `wheel` (administrators), which
  passwordless `sudo` already grants anyway.
- **`config.yaml` is `0644`** because it holds no secrets — only the §4.7
  controls and, once Task 6 runs, a *password hash*. The agent reads it via the
  other-read bit.
- **`hermes` (the data dir) is `1000:10 0700`** — the agent owns its own state
  and nothing else on the box can read it.
- **`hermes-firewall.sh` is `0750`**, not `0755`: it is executed by root from
  the DSM Task Scheduler and there is no reason for a non-admin account to be
  able to read the containment policy.

### Install commands

```bash
# hermes-etc (create the directory root-owned FIRST — see the warning below)
ssh nas 'sudo mkdir -p /volume1/docker/appdata/hermes-etc && sudo chown root:root /volume1/docker/appdata/hermes-etc && sudo chmod 0755 /volume1/docker/appdata/hermes-etc'

for f in passwd group config.yaml ENVIRONMENT.md; do
  ssh nas "cat > /tmp/$f" < "appdata-templates/hermes/$f"
  ssh nas "sudo install -o root -g root -m 0644 /tmp/$f /volume1/docker/appdata/hermes-etc/$f && rm -f /tmp/$f"
done

ssh nas 'cat > /tmp/hermes.env' < appdata-templates/hermes/hermes.env
ssh nas 'sudo install -o root -g 10 -m 0640 /tmp/hermes.env /volume1/docker/appdata/hermes-etc/hermes.env && rm -f /tmp/hermes.env'

# egress proxy config
ssh nas 'sudo mkdir -p /volume1/docker/appdata/hermes-egress'
for f in tinyproxy.conf filter; do
  ssh nas "cat > /tmp/$f" < "appdata-templates/hermes-egress/$f"
  ssh nas "sudo install -o root -g root -m 0644 /tmp/$f /volume1/docker/appdata/hermes-egress/$f && rm -f /tmp/$f"
done

# SearXNG search backend. Create the directory and files before starting the
# service so Docker cannot silently replace a missing file with a directory.
# Generate the secret_key on the NAS; it is intentionally not committed.
ssh nas 'sudo mkdir -p /volume1/docker/appdata/hermes-searxng && sudo chown root:root /volume1/docker/appdata/hermes-searxng && sudo chmod 0755 /volume1/docker/appdata/hermes-searxng'
ssh nas 'cat > /tmp/searxng-settings.yml' < appdata-templates/hermes-searxng/settings.yml
ssh nas 'sudo install -o root -g root -m 0644 /tmp/searxng-settings.yml /volume1/docker/appdata/hermes-searxng/settings.yml && rm -f /tmp/searxng-settings.yml'
ssh nas 'KEY=$(/usr/bin/openssl rand -hex 32) && sudo /bin/sed -i "s/REPLACE_WITH_A_RANDOM_64_HEX_CHARACTER_SECRET/$KEY/" /volume1/docker/appdata/hermes-searxng/settings.yml'

# the containment script
ssh nas 'sudo mkdir -p /volume1/docker/scripts'
ssh nas 'cat > /tmp/hermes-firewall.sh' < appdata-templates/scripts/hermes-firewall.sh
ssh nas 'sudo install -o root -g root -m 0750 /tmp/hermes-firewall.sh /volume1/docker/scripts/hermes-firewall.sh && rm -f /tmp/hermes-firewall.sh'

# the Home Assistant custom-integration installer. Only this script is delivered
# here: it fetches and checksum-verifies its own payload at run time, so the
# component itself is never copied into this directory.
ssh nas 'cat > /tmp/ha-install-midea-ac-lan.sh' < appdata-templates/scripts/ha-install-midea-ac-lan.sh
ssh nas 'sudo install -o root -g root -m 0750 /tmp/ha-install-midea-ac-lan.sh /volume1/docker/scripts/ha-install-midea-ac-lan.sh && rm -f /tmp/ha-install-midea-ac-lan.sh'

# Hindsight memory server: passwd/group remap (uid 1200, not the image's 1000),
# its separate OpenRouter key, and the pg0 data volume.
ssh nas 'sudo mkdir -p /volume1/docker/appdata/hermes-hindsight-etc && sudo chown root:root /volume1/docker/appdata/hermes-hindsight-etc && sudo chmod 0755 /volume1/docker/appdata/hermes-hindsight-etc'
for f in passwd group; do
  ssh nas "cat > /tmp/$f" < "appdata-templates/hermes-hindsight/$f"
  ssh nas "sudo install -o root -g root -m 0644 /tmp/$f /volume1/docker/appdata/hermes-hindsight-etc/$f && rm -f /tmp/$f"
done
ssh nas 'cat > /tmp/hindsight.env' < appdata-templates/hermes-hindsight/hindsight.env
ssh nas 'sudo install -o root -g root -m 0600 /tmp/hindsight.env /volume1/docker/appdata/hermes-hindsight/hindsight.env && rm -f /tmp/hindsight.env'
# .pg0 must be owned by the container's uid BEFORE first start (it is rootless
# and cannot chown); the parent stays 0700.
ssh nas 'sudo mkdir -p /volume1/docker/appdata/hermes-hindsight/.pg0 /volume1/docker/appdata/hermes-hindsight/hfcache \
  && sudo chown -R 1200:1200 /volume1/docker/appdata/hermes-hindsight \
  && sudo chmod 0700 /volume1/docker/appdata/hermes-hindsight /volume1/docker/appdata/hermes-hindsight/.pg0 \
  && sudo chmod 0755 /volume1/docker/appdata/hermes-hindsight/hfcache'
# Seed the writable HuggingFace model cache from the PINNED image's own layers
# (WHY: the bundled weights ship non-root-owned; the 1200 runtime cannot use
# them in place. A tmpfs would mask them and force a network re-download).
# Re-run after every digest bump, then `docker restart hermes-hindsight`.
# The `tar` form preserves everything `cp -a` would, including symlinks.
IMG=ghcr.io/vectorize-io/hindsight@sha256:84ab276b8f501546deb6ea9c64a57291718b4e16a59dd9e02a02fdd5adfe9028
ssh nas "ID=\$(sudo /usr/local/bin/docker create --rm $IMG true) \
  && sudo /usr/local/bin/docker cp \"\$ID:/home/hindsight/.cache/huggingface/.\" /volume1/docker/appdata/hermes-hindsight/hfcache/ \
  && sudo /usr/local/bin/docker rm \"\$ID\" \
  && sudo chown -R 1200:1200 /volume1/docker/appdata/hermes-hindsight/hfcache"
ssh nas 'du -sh /volume1/docker/appdata/hermes-hindsight/hfcache; ls /volume1/docker/appdata/hermes-hindsight/hfcache/hub'

# agent state + workspace
ssh nas 'sudo mkdir -p /volume1/docker/appdata/hermes /volume1/code \
  && sudo chown -R 1000:10 /volume1/docker/appdata/hermes /volume1/code \
  && sudo chmod 0700 /volume1/docker/appdata/hermes'

# tool caches + TMPDIR (see the compose environment block). Owned by the agent
# — these are the only two directories under hermes/ this README creates, and
# the dot on .cache matters: hermes/cache is Hermes' own.
ssh nas 'sudo mkdir -p /volume1/docker/appdata/hermes/.cache /volume1/docker/appdata/hermes/tmp \
  && sudo chown 1000:10 /volume1/docker/appdata/hermes/.cache /volume1/docker/appdata/hermes/tmp \
  && sudo chmod 0755 /volume1/docker/appdata/hermes/.cache /volume1/docker/appdata/hermes/tmp'

# operator-installed skills (agent state, NOT a security boundary). Installed
# as 1000:10 to match the /opt/data mount so the agent can read them at load.
ssh nas 'sudo mkdir -p /volume1/docker/appdata/hermes/skills/nas/nas-ops \
  && sudo chown -R 1000:10 /volume1/docker/appdata/hermes/skills'
ssh nas 'cat > /tmp/SKILL.md' < appdata-templates/hermes/skills/nas/nas-ops/SKILL.md
ssh nas 'sudo install -o 1000 -g 10 -m 0644 /tmp/SKILL.md /volume1/docker/appdata/hermes/skills/nas/nas-ops/SKILL.md && rm -f /tmp/SKILL.md'
ssh nas 'cat > /tmp/DESCRIPTION.md' < appdata-templates/hermes/skills/nas/DESCRIPTION.md
ssh nas 'sudo install -o 1000 -g 10 -m 0644 /tmp/DESCRIPTION.md /volume1/docker/appdata/hermes/skills/nas/DESCRIPTION.md && rm -f /tmp/DESCRIPTION.md'

# read-only tool mount. NOT in git — these are binaries, and tirith is ~38 MB.
# Fetch on the NAS, verify against the publisher's own checksum file, THEN
# install root-owned and non-writable. Never install a binary the agent will
# later execute into a directory the agent can write.
ssh nas 'sudo mkdir -p /volume1/docker/appdata/hermes-bin && sudo chown root:root /volume1/docker/appdata/hermes-bin && sudo chmod 0755 /volume1/docker/appdata/hermes-bin'

# jq 1.7.1 (x86_64). /tmp on this NAS is noexec, so the binary cannot be
# smoke-tested before install — test it inside the container afterwards.
ssh nas 'cd /tmp \
  && curl -fsSL -o jq-linux-amd64 https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 \
  && curl -fsSL -o jq-sha256.txt https://github.com/jqlang/jq/releases/download/jq-1.7.1/sha256sum.txt \
  && grep -E "jq-linux-amd64$" jq-sha256.txt | sha256sum -c - \
  && sudo install -o root -g root -m 0555 jq-linux-amd64 /volume1/docker/appdata/hermes-bin/jq \
  && rm -f jq-linux-amd64 jq-sha256.txt'
```

> **WARNING — create every bind-mount target before `docker compose up`.**
> Docker silently creates a **directory** at any bind-mount source path that
> does not exist on the host. A directory at `/etc/passwd`,
> `/opt/data/config.yaml` or `/opt/data/.env` breaks the container. This is why
> `hermes-etc` and all four files in it must exist *first*.

## What each file is

### `hermes/passwd`, `hermes/group`
Edited copies of the image's own `/etc/passwd` and `/etc/group`, with the
baked-in `hermes` account remapped from `10000:10000` to `1000:10`. The image's
`stage2-hook.sh` refuses any `--user` UID it considers "arbitrary", and its
documented alternative (root + internal `usermod` + `s6-setuidgid` drop) needs
`CAP_SETUID`/`CAP_SETGID`, which `cap_drop: ALL` removes. Pre-editing these two
files means the container starts *already* at `1000:10` with no privilege
transition attempted at all.

### `hermes/config.yaml`
Every spec §4.7 control. The file itself records which key names are verified
against the running image and which are not.

**This is no longer a read-only bind mount, and this section previously said it
was.** A bind-mounted *file* can never be atomically replaced (`os.replace` →
`Errno 16`), so the dashboard's model picker could not persist and Hermes fell
back to `copyfile`. It is now copied into `/volume1/docker/appdata/hermes/` and
is a normal writable file at `/opt/data/config.yaml`; the copy here in
`hermes-etc` is the source it is seeded from, alongside a root-owned
`config.yaml.golden` the agent can neither read nor write.

That knowingly reopens the first leg of review finding C3 — the agent *can*
rewrite its own guardrails. Two things hold it down: `hermes` is not in the
socket proxy's restart allowlist, so it cannot reload a config it has
tampered with (a change takes effect only at the next operator restart), and
`hermes-guardrail-check.sh` diffs it hourly against the golden copy, ignoring
model changes and alarming on security keys.

### `hermes/hermes.env`
Secrets, mounted `:ro` at `/opt/data/.env`. **Template only** — every value is a
placeholder; real values are written on the NAS in plan Task 6 and never
committed.

### `hermes/ENVIRONMENT.md`
The agent-facing manifest of its own containment, mounted `:ro` at
`/opt/data/ENVIRONMENT.md`: the egress allowlist in full, why its DNS is
blocked, that TLS is **not** intercepted, what persists across restarts, the
resource caps that this kernel does and does not enforce, and what is
deliberately absent (browsing, OpenAI, `sudo`, `wget`).

Written because an undocumented control is indistinguishable from a bug: the
agent read the deliberate DNS block as a flaky resolver, and went hunting for a
proxy CA that does not exist. Each missing fact cost a failed attempt *and* a
wrong diagnosis.

Read-only for the same reason as `.env`: a description of the agent's own
containment that the agent can rewrite is a channel for a prompt-injected agent
to lie to its successor. **Update the `LAST VERIFIED` date in the header
whenever the allowlist, mounts, caps or absences change** — the date is the
contract that tells the agent whether to trust the contents.

> **TRAP — do not use `install` to update this file on a running container.**
> It is a bind-mounted **file**, and the mount is pinned to the *inode* that
> existed when the container started. `install` (like `mv`, and like any
> atomic-replace) unlinks the original and creates a **new** inode: the host
> file updates, and the container keeps reading the old, now-unlinked one, with
> no error anywhere. Measured here: host showed 260 lines while
> `docker exec hermes wc -l` still showed 247.
>
> Update it **in place**, which truncates and rewrites the same inode:
>
> ```bash
> ssh nas 'sudo tee /volume1/docker/appdata/hermes-etc/ENVIRONMENT.md > /dev/null' \
>   < appdata-templates/hermes/ENVIRONMENT.md
> ```
>
> In-place writes preserve owner and mode, so no `chown`/`chmod` is needed. If
> you already replaced the inode, only `docker restart hermes` re-resolves the
> mount. The same hazard applies to every file bind mount here — `passwd`,
> `group`, `hermes.env` — and it is the same `Errno 16` property that forced
> `config.yaml` out of a bind mount in the first place.

### `hermes/skills/` — operator-installed skills

Skills the agent loads from its own state mount (`/opt/data/skills/`). They are
**not** security boundaries: that mount is agent-writable, so treat them as
operator guidance, not an enforced control, and never put secrets in them.

`nas/nas-ops` teaches the agent the NAS-ops role — the container inventory, the
restricted socket proxy at `192.168.93.2:2375`, the eight-name restart
allowlist, and the read-logs/restart procedure. Without it the agent does not
know the proxy exists or which containers it may touch.

Delivery is the `install` pair in the commands above. The loader rescans on a new
session; `docker restart hermes` forces it. Verify with
`docker exec -u 1000:10 hermes hermes skills list`, and confirm the agent can
quote the skill with `skill_view`.

### `hermes-bin/` (not in git — binaries)
Root-owned `0555` tools on a read-only mount at `/opt/hermes-bin`, appended to
the container's `PATH`. Currently `tirith` (the pre-execution scanner) and `jq`.

Both are here rather than in `/opt/data/bin` for the same reason: Hermes
*auto-installs* tirith to `$HERMES_HOME/bin`, which resolves to the agent's own
writable mount, so a prompt-injected agent could overwrite its own scanner.
Pinning `security.tirith_path` to an explicit non-default path disables that
download entirely. The same argument applies to every future tool — **never
install a binary the agent will execute into a directory the agent can write.**
`/opt/data/.local/bin` was on the image's stock `PATH` ahead of `/usr/bin` and
has been **removed** from the container `PATH` (2026-09-10). It is inside the
agent's writable mount, so it is the same shadowing exposure this ro mount
exists to close; inheriting it from the image was never a justification. The
directory does not exist on disk anyway (only `.local/share`, `.local/state`).

### `profile` — corrected `/etc/profile`, root:root 0644
Mounted read-only at `/etc/profile`. Byte-identical to the image's own file
except the `PATH` block. The stock block **assigns** `PATH` for non-root UIDs
(`/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games`), which deleted
`/opt/hermes/bin`, `/opt/hermes/.venv/bin` and `/opt/hermes-bin` from the
agent's shell — no `jq`, no `tirith`, and bare `python3` resolving to
`/usr/bin/python3`, which cannot import `hermes_cli` (it lives in the read-only
venv at `/opt/hermes/.venv`).

The blast radius was larger than "login shells only" implies.
`tools/environments/local.py::_run_bash` uses `bash -l` exactly **once** per
session, for `init_session`'s env snapshot; the result is cached to
`$HERMES_HOME/tmp/hermes-snap-*.sh` and every later command is a non-login
`bash -c` that sources it. One wipe at bootstrap was inherited by every command
for the life of the session. **Consequence for operators: a `PATH` change does
not reach the agent until a new session, and the cached snapshot survives a
container recreate — delete `/opt/data/tmp/hermes-snap-*.sh` after changing it.**

The replacement keeps the inherited `PATH` minus any `/opt/data` entry and
minus duplicates. Restoring it verbatim would have been a regression rather
than a fix, for the `.local/bin` reason above.

    ssh nas 'sudo install -o root -g root -m 0644 /dev/stdin       /volume1/docker/appdata/hermes-etc/profile' < appdata-templates/hermes/profile

Same failure mode as `passwd`/`group`: if the file is missing at `compose up`,
Docker creates a **directory** at `/etc/profile` and every login shell in the
container breaks.

Verify:

    ssh nas 'sudo /usr/local/bin/docker exec hermes bash -lc "echo \$PATH; command -v jq python3"'
    # expect ...:/opt/hermes-bin, /opt/hermes-bin/jq, /opt/hermes/.venv/bin/python3

Verify each binary against the publisher's own checksum file before installing;
the install commands above do this for `jq`.

### `hermes-egress/tinyproxy.conf`, `hermes-egress/filter`
The domain allowlist and the proxy config that enforces it. The plan's Task 2
heredoc is stale (it omits the `StartServers`/`MinSpareServers`/
`MaxSpareServers`/`MaxRequestsPerChild` block, without which tinyproxy exits at
startup with `"StartServers" must be greater than zero`). **These files are the
source of truth — do not replay the plan's heredoc.** Once the containment
rules are applied this proxy is the agent's only internet path, so a crash-loop
after a rebuild means a silently dead agent.

The filter now also carries the HuggingFace hosts (`huggingface.co`,
`cdn-lfs*.huggingface.co`, `cas-bridge.xethub.hf.co`) because the
`hermes-hindsight` container routes through this proxy too. Its embedding and
reranking models are **bundled in the image** (verified: ~215 MB at
`/home/hindsight/.cache/huggingface`), so these entries are only a fallback for
a cache miss or an image bump — they are not a bootstrap requirement.

### `hermes-searxng/` — private search backend

SearXNG is a separate, search-only peer for Hermes. Hermes reaches it at
`http://192.168.96.2:8080` over `hermes_search`; the SearXNG container is not
on Hermes' domain-allowlisting proxy path. It makes direct requests only to
the two engines retained in its settings (`brave` and `duckduckgo`). This is a
trusted-service boundary, not a claim that SearXNG itself has no internet
access. It has no published port, image proxying is disabled, and the firewall
blocks SearXNG from initiating connections back to Hermes.

The settings file is a root-owned read-only mount. Generate the SearXNG
`server.secret_key` on the NAS during installation; never commit the live
value. SearXNG's limiter is disabled because Hermes does not send the proxy
headers that limiter requires; Hermes' own per-turn search cap remains active.
The image is pinned by digest in `compose/hermes-searxng.yml` and intentionally
has no Watchtower label.

### `hermes-extract` — private web extractor (no appdata, build-only)

Backs `web_extract`. Hermes reaches it at `http://192.168.96.3:8080` over
`hermes_search`, as a third member alongside SearXNG and the agent. It has **no
appdata directory, no volumes and no credentials of any kind** — that is the
design, since it parses hostile HTML with lxml and is assumed exploitable.

It is wired in through the **`tavily`** provider, not `firecrawl`. Both accept a
self-hosted base URL, but the firecrawl provider lazy-imports
`firecrawl-py==4.17.0`, which is absent from the hermes image and cannot be
installed there: `/opt/hermes/.venv` is read-only (`touch` → EROFS, measured)
because the container is `read_only: true`, and the only writable import path is
`/opt/data` — the agent's own mount. The tavily provider is pure `httpx`, which
is already installed, and honours `TAVILY_BASE_URL`. `TAVILY_API_KEY` is a dummy
string the shim ignores; nothing is sent to api.tavily.com, and
`web.keyless_rescue: false` removes the cloud fallback that would otherwise fire
on a shim failure.

**SSRF is the whole risk, and it is handled in two places.** SearXNG queries two
fixed engines and is therefore given unrestricted egress; this service fetches
whatever URL the agent supplies, so it is **not** given the SearXNG treatment.
`hermes-firewall.sh` DROPs `192.168.96.3` to all of RFC1918, loopback,
link-local, CGNAT and the reserved ranges — that is the enforcement. The shim's
own resolve-then-pin check (reject unless every DNS answer is public; connect to
the vetted IP with `Host`/SNI on the real name; re-vet every redirect hop) is
the policy on top. Do not rely on the agent-side gate: `is_safe_url` returns
True for any *hostname* in this deployment, because the agent's DNS is blocked
and the function then delegates resolution to the proxy.

`build/` is **not** synced by `push.sh` (only `docker-compose.yml` + `compose/`).
Deliver and build it by hand, then pin the resulting image ID in
`compose/hermes-extract.yml`:

```bash
ssh nas 'mkdir -p /volume1/docker/build/hermes-extract'
ssh nas 'cat > /volume1/docker/build/hermes-extract/Dockerfile'      < build/hermes-extract/Dockerfile
ssh nas 'cat > /volume1/docker/build/hermes-extract/extract_shim.py' < build/hermes-extract/extract_shim.py
ssh nas 'cd /volume1/docker/build/hermes-extract && sudo /usr/local/bin/docker build -t hermes-extract:local .'
ssh nas 'sudo /usr/local/bin/docker inspect --format="{{.Id}}" hermes-extract:local'   # pin this
```

**Discover-then-pin for the dependency versions.** The Dockerfile pins exact
versions, and those pins are read back from a real resolve on this NAS rather
than guessed:

```bash
ssh nas 'sudo /usr/local/bin/docker run --rm python:3.12-slim sh -c "pip install -q --no-cache-dir trafilatura httpx pypdf && pip freeze | grep -iE \"^(trafilatura|httpx|pypdf|lxml)==\""'
```

Last run 2026-09-14: `trafilatura==2.2.0`, `httpx==0.28.1`, `pypdf==6.18.1`,
resolving `lxml==6.1.3`. Image 201 MB; measured 83.7 MiB RSS after a 23k-char
Wikipedia article plus an 18k-char PDF datasheet.

**PDFs are read, images and archives are not.** pypdf is deliberately the only
addition and pulls nothing transitively — notably not `cryptography`, so
AES-encrypted PDFs are refused rather than adding a large C dependency to a
container whose whole job is parsing hostile input. There is no OCR, so a
scanned-image PDF returns "No extractable text in this PDF" rather than an empty
success. `application/octet-stream` is accepted at the content-type gate because
CDNs mislabel PDFs (Synology's own datasheet CDN does), but the body is then
sniffed for the `%PDF-` magic and anything else is refused.

**After changing `web:` in config.yaml**, re-accept the guardrail baseline or the
hourly check alerts forever — `web` is one of the sections
`hermes-guardrail-check.sh` watches:

```bash
ssh nas 'sudo /volume1/docker/scripts/hermes-guardrail-check.sh --accept'
```

### `hermes-hindsight/` — the self-hosted Hindsight memory server

Backs Hermes' native Hindsight memory provider in `local_external` mode. The
container is defined in `compose/hermes-hindsight.yml`; these three files are
`push.sh`-excluded and must be delivered by hand.

- **`passwd`, `group`** — edited copies of the image's own files with the
  `hindsight` account remapped from `1000:1000` to **`1200:1200`**. Required
  because the upstream image only ships UID 1000 and crashes under any other
  UID (`getpwuid(): uid not found`); 1200 is used so Hindsight does not share
  the per-UID `RLIMIT_NPROC` ceiling with Hermes and the Google MCP (which
  already fight over UID 1000 on this kernel). REQUIRED: `root:root 0644`, and
  both must exist before `compose up` or Docker creates a **directory** at
  `/etc/passwd`.
- **`hindsight.env`** — the **separate** OpenRouter key (operator decision
  2026-09-14) that funds Hindsight's extraction/consolidation/reflect calls,
  isolated from the agent's key so its spend can be capped or revoked on its
  own. REAL VALUES ONLY ON THE NAS, `root:root 0600`. Read via `env_file:`, so
  it is visible in `docker inspect hermes-hindsight` — accepted, because the
  agent's restricted socket proxy does not expose this container.
- **Data** — `/volume1/docker/appdata/hermes-hindsight/.pg0`, owned
  `1200:1200 0700`. Only `.pg0` is mounted; the image's bundled models live one
  level up at `/home/hindsight/.cache` and mounting the whole home would mask
  them and force a re-download.

The Hermes side is two changes, neither of which lives in this directory:
`memory.provider: hindsight` (plus the built-in flat-file stores off) in the
live `config.yaml`, and `$HERMES_HOME/hindsight/config.json` with
`{"mode":"local_external","api_url":"http://192.168.92.11:8888",...}`. The
config.json must exist because Hindsight's `_load_config()` returns it
wholesale and never reads the `HINDSIGHT_*` env vars when it does.

### `hermes-health-mcp` — read-only Google Health server

A second, minimal MCP server (`build/hermes-health-mcp/{Dockerfile,health_mcp.py}`)
that holds a **health-only** OAuth token and exposes four read tools to Hermes
(`whoami`, `list_nutrition_entries`, `nutrition_daily_totals`, `list_workouts`).
The data is the operator's own Fitbit/Pixel metrics plus apps writing to Health
Connect — including MacroFactor (`com.sbs.diet` nutrition, `com.sbs.train`
workouts).

**Why it is not folded into `hermes-google-mcp`:** the Google Health API rejects
any OAuth token that also carries Gmail/Calendar/Drive scopes (measured 403
`DISALLOWED_OAUTH_SCOPES`), and the Workspace server has no health tools. It
reuses the same GCP project, OAuth client, and googleapis-only egress proxy; only
the server and its credential are new.

`build/` is **not** synced by `push.sh` (only `docker-compose.yml` + `compose/`).
Deliver and build it by hand, then pin the resulting image ID in
`compose/hermes-health-mcp.yml`:

```bash
ssh nas 'sudo mkdir -p /volume1/docker/build/hermes-health-mcp'
# copy Dockerfile + health_mcp.py there (ssh cat, as with appdata-templates)
ssh nas 'cd /volume1/docker/build/hermes-health-mcp && sudo /usr/local/bin/docker build -t hermes-health-mcp:local .'
ssh nas 'sudo /usr/local/bin/docker inspect --format="{{.Id}}" hermes-health-mcp:local'   # pin this
```

**Token bootstrap (not in git).** The token is minted by a loopback OAuth consent
against the existing Web client (redirect `http://127.0.0.1:8765/`, scopes
`googlehealth.nutrition.readonly` + `googlehealth.activity_and_fitness.readonly`,
`access_type=offline`, and deliberately **without** `include_granted_scopes` — or
the token carries the Workspace scopes and the Health API refuses it). It is
written as an `authorized_user` JSON to:

    /volume1/docker/appdata/hermes-health/credentials/token.json   (1100:1100 0600)

The server refreshes it in place; the volume is the credential boundary and is
**never** mounted into Hermes.

### `scripts/hermes-firewall.sh`
The containment boundary itself: `DOCKER-USER` + `INPUT` rules keyed on the
agent's static IPs. Read its header before touching it — it documents three
non-obvious properties of this host's iptables, including that built-in chains
cannot be addressed by name here. Needs **two** DSM Task Scheduler entries
(Boot-up, and daily repeating every 1 hour), both as root: a Docker package
restart or a `compose down/up` rebuilds the chains without a reboot.

### `scripts/ha-install-midea-ac-lan.sh`
Reinstalls the "Midea AC LAN" Home Assistant custom integration into
`/volume1/docker/appdata/homeassistant/custom_components/midea_ac_lan`. Needs
`root` (it chowns the result) and is safe to re-run: an existing install is
first moved aside to `custom_components.bak/midea_ac_lan-<timestamp>`. The
backup deliberately does **not** sit next to the live install — HA resolves the
manifest `domain` of every non-dot entry in `custom_components/`, so a sibling
backup is discovered as a second copy of `midea_ac_lan` and silently wins or
loses by `readdir` order. Measured 2026-09-16: a `.bak-` sibling made the
loader log the integration twice.

The *integration* is version- and checksum-pinned inside the script — version,
release URL, and GitHub's own published `sha256` for the asset. There is no
partial install: a checksum mismatch aborts before anything is moved. Bump the
pin deliberately (the header records how), and note the fork: the integration
most guides link to, `georgezhao2010/midea_ac_lan`, is abandoned (last release
2023-10-16). The live one is `wuwentao/midea_ac_lan`, which is the repository
HACS itself ships under the "Midea AC LAN" name.

**It does not configure the appliance.** Retrieving the Token/Key needs the
operator's Midea cloud account, so that stays a UI step. Deployment specifics
established 2026-09-16:

- HA is `network_mode: host` at `192.168.1.104`; the AC is on the IoT VLAN at
  `192.168.2.237`. Inter-VLAN routing works — a TCP connect to the appliance's
  `:6444` succeeds and `ping` answers in one hop via the UDM — but **UDP
  broadcast discovery cannot cross the VLAN**. Auto-discovery therefore finds
  nothing, which reads as "device unsupported". Enter the IP directly instead.
- Only personal *Meiju* / *SmartHome* accounts can fetch tokens. The AU app is
  MSmartHome, i.e. the `SmartHome` cloud. An account *migrated* from another app
  can never retrieve tokens; a fresh account with the appliance re-bound is the
  fix. (`NetHome Plus` cannot retrieve tokens at all.)
- Only the TCP control path is guaranteed across the VLAN. If remote-initiated
  state changes lag, lower the integration's refresh interval (default 30s) —
  the device's own LAN notifications may not survive the VLAN hop.
- Midea is progressively closing the token API. Once added, copy the appliance's
  generated `.json` out of HA: for a v3-protocol device it is the only way to
  re-add the appliance if that service ends.

## Verifying delivery

```bash
ssh nas 'ls -la /volume1/docker/appdata/hermes-etc /volume1/docker/appdata/hermes-egress /volume1/docker/scripts; ls -ld /volume1/docker/appdata/hermes /volume1/code'
```

Compare against the manifest above. Then confirm the agent genuinely cannot
write its own guardrails:

```bash
ssh nas 'sudo /usr/local/bin/docker exec -u 1000:10 hermes sh -c "echo x >> /opt/data/.env; echo x >> /opt/data/ENVIRONMENT.md; echo x >> /opt/hermes-bin/jq"'
```

Expected: `Permission denied` for all three. (`/opt/data/config.yaml` is
**writable** by design — see its section above — so it is deliberately not in
this list.)

Then confirm the tool mount and caches resolved:

```bash
ssh nas 'sudo /usr/local/bin/docker exec hermes sh -c "command -v jq && jq --version && echo \$UV_CACHE_DIR && head -1 /opt/data/ENVIRONMENT.md"'
```

Expected: `/opt/hermes-bin/jq`, `jq-1.7.1`, `/opt/data/.cache/uv`, and the
manifest's first heading.
