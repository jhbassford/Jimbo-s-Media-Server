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
| `hermes-egress/tinyproxy.conf` | `/volume1/docker/appdata/hermes-egress/tinyproxy.conf` | `root:root` | `0644` |
| `hermes-egress/filter` | `/volume1/docker/appdata/hermes-egress/filter` | `root:root` | `0644` |
| `scripts/hermes-firewall.sh` | `/volume1/docker/scripts/hermes-firewall.sh` | `root:root` | `0750` |

Directories:

| NAS path | Owner | Mode | Notes |
|---|---|---|---|
| `/volume1/docker/appdata/hermes-etc` | `root:root` | `0755` | read-only mount sources; the agent must never own this |
| `/volume1/docker/appdata/hermes` | `1000:10` | `0700` | the agent's read-write state (`/opt/data`) |
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

for f in passwd group config.yaml; do
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
Every spec §4.7 control. Mounted `:ro` at `/opt/data/config.yaml`, deliberately
**not** inside `/volume1/docker/appdata/hermes`, which is the read-write
`/opt/data` mount — otherwise a prompt-injected agent could rewrite its own
guardrails and restart itself through the socket proxy to load them. Changing
any control is an operator action on the host plus a restart. That is the point.
The file itself records which key names are verified against the running image
and which are not.

### `hermes/hermes.env`
Secrets, mounted `:ro` at `/opt/data/.env`. **Template only** — every value is a
placeholder; real values are written on the NAS in plan Task 6 and never
committed.

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
ssh nas 'sudo /usr/local/bin/docker exec -u 1000:10 hermes sh -c "echo x >> /opt/data/config.yaml; echo x >> /opt/data/.env"'
```

Expected: `Permission denied` for both.
