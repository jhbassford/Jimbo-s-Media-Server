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
| `scripts/hermes-firewall.sh` | `/volume1/docker/scripts/hermes-firewall.sh` | `root:root` | `0750` |

Directories:

| NAS path | Owner | Mode | Notes |
|---|---|---|---|
| `/volume1/docker/appdata/hermes-etc` | `root:root` | `0755` | read-only mount sources; the agent must never own this |
| `/volume1/docker/appdata/hermes-bin` | `root:root` | `0755` | read-only tool mount (`/opt/hermes-bin`); see below |
| `/volume1/docker/appdata/hermes-etc/profile` | `root:root` | `0644` | corrected `/etc/profile` (PATH); see below |
| `/volume1/docker/appdata/hermes` | `1000:10` | `0700` | the agent's read-write state (`/opt/data`) |
| `/volume1/docker/appdata/hermes/.cache` | `1000:10` | `0755` | tool caches (uv/pip/npm/XDG); **dotted** — `hermes/cache` is Hermes' own |
| `/volume1/docker/appdata/hermes/tmp` | `1000:10` | `0755` | `TMPDIR`; keeps large wheels off the 64 MB `/tmp` tmpfs |
| `/volume1/docker/appdata/hermes-egress` | `root:root` | `0755` | |
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

# the containment script
ssh nas 'sudo mkdir -p /volume1/docker/scripts'
ssh nas 'cat > /tmp/hermes-firewall.sh' < appdata-templates/scripts/hermes-firewall.sh
ssh nas 'sudo install -o root -g root -m 0750 /tmp/hermes-firewall.sh /volume1/docker/scripts/hermes-firewall.sh && rm -f /tmp/hermes-firewall.sh'

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

### `scripts/hermes-firewall.sh`
The containment boundary itself: `DOCKER-USER` + `INPUT` rules keyed on the
agent's static IPs. Read its header before touching it — it documents three
non-obvious properties of this host's iptables, including that built-in chains
cannot be addressed by name here. Needs **two** DSM Task Scheduler entries
(Boot-up, and daily repeating every 1 hour), both as root: a Docker package
restart or a `compose down/up` rebuilds the chains without a reboot.

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
