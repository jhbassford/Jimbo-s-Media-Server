# Jimbo's Media Server

A self-hosted media server stack that runs on any always-on computer — a NAS, a Raspberry Pi, an old PC, a rented VPS, whatever you've got. Once set up, you'll have your own personal streaming service — like Netflix, but for media you own — along with automatic downloads, subtitle management, and more, all accessible from anywhere in the world.

---

## What Does This Actually Do?

This sets up a collection of apps that work together. **Everything is optional** — use only what you need. Some apps depend on others, so those are noted below.

### Core Infrastructure

These underpin everything else. You can skip them, but you'll lose features like secure remote access and automatic HTTPS.

| App | What it does | Optional? |
|---|---|---|
| **Traefik** | The traffic controller — routes web requests to the right app and handles SSL (the padlock) | Yes — without it, you access services by IP:port only, with no HTTPS |
| **Socket Proxy** | Protects Docker from direct exposure — required by Traefik, Portainer, Dozzle, and Watchtower | Only if you're running any of those four |
| **Cloudflared** | Creates a secure tunnel so you can reach your server from anywhere without opening router ports | Yes — only needed for remote access outside your home |

### Media

| App | What it does | Optional? | Requires |
|---|---|---|---|
| **Plex** | Streams your movies and TV shows to any device — like your own personal Netflix | Yes | — |
| **Tautulli** | Shows stats on what's being watched, by who, and when | Yes | Plex |

### Download Automation

These work as a team. Radarr and Sonarr find content; SABnzbd actually downloads it. You need at least one of Radarr/Sonarr paired with SABnzbd for any of them to be useful.

| App | What it does | Optional? | Requires |
|---|---|---|---|
| **Radarr** | Monitors for movies and sends them to your downloader automatically | Yes | SABnzbd |
| **Sonarr** | Same as Radarr, but for TV shows | Yes | SABnzbd |
| **SABnzbd** | The actual downloader — fetches content from Usenet | Yes, but needed by Radarr/Sonarr | A Usenet provider |
| **Bazarr** | Automatically downloads subtitles for your media | Yes | Radarr and/or Sonarr |
| **Seerr** | A friendly interface to browse and request new movies/shows | Yes | Radarr and/or Sonarr |
| **Maintainerr** | Automatically removes watched/finished content from your library and stops it being re-downloaded | Yes | Plex, Sonarr and/or Radarr |

### Management & Utilities

| App | What it does | Optional? | Requires |
|---|---|---|---|
| **Portainer** | A visual web UI to manage all your Docker containers | Yes | Socket Proxy |
| **Dozzle** | View live logs from all containers in one place | Yes | Socket Proxy |
| **Watchtower** | Automatically updates all your containers to the latest version | Yes | Socket Proxy |
| **Pi-hole** | Blocks ads across your entire home network at the DNS level | Yes | — |
| **Redbot** | A Discord bot | Yes | A Discord account |

### Removing an App You Don't Want

To remove a service, open `docker-compose.yml` and delete its `include:` line, then delete the corresponding file from the `compose/` folder. For example, to remove Pi-hole:
1. Delete `- compose/pihole.yml` from `docker-compose.yml`
2. Delete `compose/pihole.yml`
3. Run `docker compose up -d` to apply

---

## What You'll Need

### Hardware
Any always-on computer running Linux (or a Linux-based OS) with Docker support. Examples:
- A NAS (Synology, QNAP, etc.)
- A Raspberry Pi (Model 4 or 5 recommended)
- An old PC or laptop repurposed as a server
- A rented VPS (Virtual Private Server) from a provider like Hetzner or Vultr

**Minimum specs:** 4GB RAM, enough storage for your media. 8GB+ RAM recommended if using Plex with video transcoding.

### Accounts (all free unless noted)
- **Cloudflare** — free — handles your domain's DNS and creates a secure tunnel so you can access your server from anywhere. Sign up at cloudflare.com.
- **A domain name** — typically $10–15/year — something like `yourdomain.com`. Buy from any registrar (Namecheap, Porkbun, etc.), then point the nameservers to Cloudflare.
- **Plex** — free — needed to activate your Plex server. Sign up at plex.tv.
- **Usenet provider** — paid — required for SABnzbd/Radarr/Sonarr to download content. Examples: Newshosting, Eweka, Frugal Usenet.
- **Discord** — free — only needed if you want the Redbot Discord bot.

### Software (on your everyday computer)
- A terminal. On **Windows**: Windows Terminal or PowerShell. On **Mac/Linux**: the built-in Terminal app.
- A text editor. **VS Code** is recommended (free, code.visualstudio.com).

---

## Concepts to Understand First

If you're new to self-hosting, these terms come up constantly:

**Docker & Containers** — Think of a container like a pre-packaged app in a box. Everything it needs to run is already inside. Docker is the system that runs these boxes. You don't install Plex, Radarr, etc. manually — Docker downloads and runs them automatically.

**Docker Compose** — A way to define and run multiple containers together using a single text file. Instead of starting each app one by one, you run one command and everything starts up.

**SSH** — A way to remotely control another computer from your everyday machine by typing commands. Like remote desktop, but text-only and much more powerful.

**Reverse Proxy (Traefik)** — Imagine you have 10 apps running on different ports. A reverse proxy sits in front of them all and routes incoming requests to the right app based on the URL — so `plex.yourdomain.com` goes to Plex, `radarr.yourdomain.com` goes to Radarr, etc. It also handles SSL (the padlock in your browser).

**Environment Variables (.env file)** — A file that stores settings and secrets (passwords, API keys) separately from the code. This lets you share the code publicly without exposing your private details.

---

## Setup Guide

> **Before you start:** All commands in this guide are run on your **server** (the machine running Docker), not your everyday computer — unless stated otherwise. You can either sit at the server with a keyboard and monitor, or connect to it remotely using SSH (see Step 1).

---

### Step 1 — Get Access to Your Server's Terminal

You need to be able to type commands on your server. There are two ways:

**Option A — Direct access** (you have a keyboard and screen plugged into the server): just open a terminal application on it directly.

**Option B — SSH** (manage remotely from your everyday computer): SSH lets you control the server by typing into a terminal window on your regular machine.

To connect via SSH, open a terminal on your everyday computer and run:
```bash
ssh yourusername@192.168.1.x
```
Replace `yourusername` with your account name on the server, and `192.168.1.x` with the server's IP address.

> **Finding your server's IP:** Log into your router's admin page (usually `192.168.1.1` or `192.168.0.1` in a browser) and look for connected devices. Your server will be listed there.

> **Enabling SSH on Synology:** Go to DSM → Control Panel → Terminal & SNMP → check "Enable SSH service".
> **Enabling SSH on Raspberry Pi / Ubuntu:** Run `sudo systemctl enable ssh && sudo systemctl start ssh`.

---

### Step 2 — Install Docker

Docker is what runs all the apps. How you install it depends on your system:

**Synology NAS:**
1. Open the DSM web interface
2. Go to **Package Center**
3. Search for **Container Manager** and click Install

**Raspberry Pi / Ubuntu / Debian / most Linux systems:**
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
```
Log out and back in after running this so the group change takes effect.

**Other systems:**
Follow the official guide at docs.docker.com/engine/install — pick your OS from the list.

**Check it worked:**
```bash
docker --version
```
You should see a version number. If you get "command not found", Docker isn't installed correctly.

---

### Step 3 — Get the Files

On your server, run:

```bash
mkdir -p ~/docker
cd ~/docker
git clone https://github.com/jhbassford/Jimbo-s-Media-Server.git .
```

> If `git` isn't available, install it with `sudo apt install git` (Debian/Ubuntu/Pi) or equivalent for your system.

> You can put the files anywhere you like — `~/docker` is just a suggestion. Whatever path you choose, use it consistently throughout the rest of this guide wherever you see `~/docker`.

---

### Step 4 — Create Your `.env` File

The `.env` file tells all your containers who you are, where your files live, and what your domain is. It's excluded from this repo because it contains personal details — you create it yourself.

In your terminal on the server:
```bash
nano ~/docker/.env
```

Paste the following and fill in your own values:

```env
# --------------------------------------------------------
# USER SETTINGS
# --------------------------------------------------------
# Your user ID and group ID — run the command `id` in your terminal to find these
PUID=1000
PGID=1000

# Your timezone — find yours at: en.wikipedia.org/wiki/List_of_tz_database_time_zones
TZ="America/New_York"

# Full path to your home directory on the server
USERDIR="/home/yourusername"

# --------------------------------------------------------
# PATHS
# --------------------------------------------------------
# Where all Docker config data lives — must match wherever you cloned the repo
DOCKERDIR="/home/yourusername/docker"

# Where your media library lives
DATADIR="/home/yourusername/docker/mediastack"

# A name for this machine — used to organise compose files, keep it as-is
HOSTNAME="udms"

# --------------------------------------------------------
# NETWORK
# --------------------------------------------------------
# Your domain name (must be managed by Cloudflare)
DOMAINNAME_1=yourdomain.com

# Your server's local IP address
SERVER_IP=192.168.1.x

# Leave these as-is — they define which IPs are trusted to send traffic
LOCAL_IPS=127.0.0.1/32,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12
CLOUDFLARE_IPS=173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22

# --------------------------------------------------------
# SECRETS
# --------------------------------------------------------
# Your Cloudflare tunnel token (see Step 7)
CF_TUNNEL_TOKEN=your-cloudflare-tunnel-token

# Password for the Pi-hole web interface
PIHOLE_WEBPASSWORD=choose-a-strong-password
```

Save and exit: press `Ctrl+X`, then `Y`, then `Enter`.

> **Finding your PUID/PGID:** Run `id` in your terminal. You'll see something like `uid=1000(yourusername) gid=1000(yourusername)`. Use the number after `uid=` as your PUID and after `gid=` as your PGID.

---

### Step 5 — Create Your Secrets Files

Some sensitive values (API tokens, passwords) are passed to containers as "secrets" — files on disk with strict permissions, rather than plain environment variables. This is more secure.

```bash
# Create the secrets folder
mkdir -p ~/docker/secrets

# 1. Cloudflare DNS API Token (for Let's Encrypt SSL certificates)
#    Go to: Cloudflare → My Profile → API Tokens → Create Token
#    Use the "Edit zone DNS" template, scoped to your domain
echo "paste-your-token-here" > ~/docker/secrets/cf_dns_api_token

# 2. Basic Auth credentials
#    ⚠️  THIS IS THE PASSWORD YOU'LL USE TO ACCESS SEVERAL SERVICES IN YOUR BROWSER ⚠️
#    Services protected by this: Dozzle, Bazarr, SABnzbd, Maintainerr, Homepage
#    (Services with their own login — Plex, Radarr, Sonarr, Portainer, Tautulli, Seerr — are not affected)
#
#    Choose a username and password, then generate a bcrypt hash:
#    → Go to: hostingcanada.org/htpasswd-generator
#    → Enter your username and password, select "bcrypt", click Generate
#    → Copy the result (it will look like: admin:$2y$05$abc123...)
echo "admin:your-hashed-password" > ~/docker/secrets/basic_auth_credentials

# 3. Discord bot token
#    Discord Developer Portal → Applications → New Application → Bot → Reset Token
echo "your-discord-bot-token" > ~/docker/secrets/discord_redbot_token

# 4. Plex claim token (links the server to your Plex account — expires in 4 minutes)
#    Get one at: plex.tv/claim
#    Only needed on first run, you can delete this file afterwards
echo "claim-xxxxxxxxxxxx" > ~/docker/secrets/plex_claim

# Lock down permissions so only root can read them
chmod 600 ~/docker/secrets/*
```

---

### Step 6 — Create Required Directories and Files

```bash
# Traefik config and SSL certificate storage
mkdir -p ~/docker/appdata/traefik3/acme
mkdir -p ~/docker/appdata/traefik3/rules/udms
mkdir -p ~/docker/logs/udms/traefik

# Media library folders
mkdir -p ~/docker/mediastack/library/movies
mkdir -p ~/docker/mediastack/library/tvshows
mkdir -p ~/docker/mediastack/library/downloads

# Traefik needs this file to exist before starting — it stores your SSL certificates
touch ~/docker/appdata/traefik3/acme/acme.json
chmod 600 ~/docker/appdata/traefik3/acme/acme.json
```

---

### Step 7 — Set Up Cloudflare

Cloudflare handles two things: **SSL certificates** (the padlock in your browser) and a **secure tunnel** so you can reach your server from anywhere without opening ports on your router.

#### 7a. DNS API Token (for SSL certificates)
1. Log into Cloudflare → click your profile icon → **My Profile → API Tokens**
2. Click **Create Token**
3. Use the **"Edit zone DNS"** template
4. Under Zone Resources, select your domain
5. Click **Continue to Summary → Create Token**
6. Copy the token and save it:
   ```bash
   echo "your-token" > ~/docker/secrets/cf_dns_api_token
   ```

#### 7b. Tunnel Token (for remote access without opening router ports)
1. In Cloudflare, go to **Zero Trust** (left sidebar)
2. Go to **Networks → Tunnels → Create a tunnel**
3. Choose **Cloudflared** → give it a name (e.g. `home-server`)
4. Copy the token and paste it into your `.env` as the value of `CF_TUNNEL_TOKEN`
5. On the **Private Networks** or **Configuration** tab, set the tunnel ingress to a single wildcard rule:
   - Hostname: `*.yourdomain.com` → Service: `https://localhost:4443`
   - Enable `noTLSVerify` and `matchSNItoHost` on the origin request settings
   - Add a catch-all `http_status:404` rule below it

   This routes all subdomain traffic into Traefik, which then directs it to the right app.

6. For each service you want accessible remotely, add a DNS CNAME record in Cloudflare:
   - Go to **DNS → Records** for your domain
   - Add a CNAME: name = `radarr`, content = `<your-tunnel-id>.cfargotunnel.com`, Proxied = on
   - Repeat for each service (sonarr, seerr, tautulli, etc.)

   > **Important:** The wildcard DNS record `*.yourdomain.com` does NOT route through the tunnel — it points to your public IP. Each service needs its own explicit CNAME pointing to the tunnel or it will get a 522 error.

---

### Step 8 — Set Up Traefik's Config Files

Traefik needs a handful of files to know how to handle security, authentication, and routing. Create each one:

```bash
cd ~/docker/appdata/traefik3/rules/udms
```

For each file below, run `nano filename.yml`, paste the contents, and save with `Ctrl+X → Y → Enter`.

**`tls-opts.yml`** — enforces modern, secure encryption:
```yaml
tls:
  options:
    tls-opts:
      minVersion: VersionTLS12
      cipherSuites:
        - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
        - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
```

**`middlewares-rate-limit.yml`** — limits requests per second (protects against attacks):
```yaml
http:
  middlewares:
    middlewares-rate-limit:
      rateLimit:
        average: 100
        burst: 50
```

**`middlewares-secure-headers.yml`** — adds security headers to every response:
```yaml
http:
  middlewares:
    middlewares-secure-headers:
      headers:
        accessControlAllowMethods:
          - GET
          - OPTIONS
          - PUT
        accessControlMaxAge: 100
        hostsProxyHeaders:
          - "X-Forwarded-Host"
        stsSeconds: 63072000
        stsIncludeSubdomains: true
        stsPreload: true
        forceSTSHeader: true
        customFrameOptionsValue: SAMEORIGIN
        contentTypeNosniff: true
        browserXssFilter: true
        referrerPolicy: "same-origin"
        permissionsPolicy: "camera=(), microphone=(), geolocation=(), payment=(), usb=(), vr=()"
        customResponseHeaders:
          X-Robots-Tag: "none,noarchive,nosnippet,notranslate,noimageindex,"
          server: ""
```

**`middlewares-basic-auth.yml`** — enables username/password protection:
```yaml
http:
  middlewares:
    middlewares-basic-auth:
      basicAuth:
        usersFile: "/run/secrets/basic_auth_credentials"
        realm: "Traefik Basic Auth"
```

**`chain-basic-auth.yml`** — bundles rate limiting + secure headers + auth:
```yaml
http:
  middlewares:
    chain-basic-auth:
      chain:
        middlewares:
          - middlewares-rate-limit
          - middlewares-secure-headers
          - middlewares-basic-auth
```

**`chain-no-auth.yml`** — rate limiting + secure headers, no password (for apps like Plex that handle their own login):
```yaml
http:
  middlewares:
    chain-no-auth:
      chain:
        middlewares:
          - middlewares-rate-limit
          - middlewares-secure-headers
```

**`apps.yml`** — routes each subdomain to the right container. Add one router + service block per app. Use `chain-no-auth` for apps with their own login, `chain-basic-auth` for apps without:
```yaml
http:
  routers:
    radarr-rtr-file:
      entryPoints: ["websecure"]
      rule: "Host(`radarr.yourdomain.com`)"
      middlewares: ["chain-no-auth@file"]
      service: radarr-svc-file
    # repeat for each service...

  services:
    radarr-svc-file:
      loadBalancer: { servers: [{ url: "http://radarr:7878" }] }
    # repeat for each service...
```

> Every route must use the `websecure` entrypoint and have a middleware chain — never leave a service exposed with no middleware.

---

### Step 9 — Create the Pi-hole Network

Pi-hole needs its own dedicated network with a fixed IP. Run this once:

```bash
sudo docker network create \
  --driver bridge \
  --subnet 192.168.1.0/24 \
  --gateway 192.168.1.1 \
  -o "com.docker.network.bridge.name"="pihole_net" \
  pihole_network
```

> Make sure the subnet matches your home network. If your router uses `192.168.0.x`, use `--subnet 192.168.0.0/24` instead. Pi-hole is assigned `192.168.1.105` in `pihole.yml` — update that to a free address on your network.

---

### Step 10 — Start Everything

```bash
cd ~/docker
sudo docker compose up -d
```

> **Note:** Older systems may use `docker-compose` (with a hyphen) instead of `docker compose` (with a space). If one doesn't work, try the other.

The first run will take several minutes as Docker downloads all the images. Once done, all your services will be running in the background.

---

## Accessing Your Services

### On Your Home Network

Open a browser and go to `http://your-server-ip:port`.

> **Password prompt:** Some services (Dozzle, Bazarr, SABnzbd, Maintainerr, Homepage) have no built-in login, so they're protected by HTTP basic auth — your browser will show a username/password prompt. Use the credentials from `secrets/basic_auth_credentials`. Services with their own login (Plex, Radarr, Sonarr, Portainer, Tautulli, Seerr) won't ask for this.

| Service | Port | Notes |
|---|---|---|
| Plex | `:32400/web` | Main media streaming interface |
| Portainer | `:9000` | Container management dashboard |
| Radarr | `:7878` | Movie management |
| Sonarr | `:8989` | TV show management |
| Bazarr | `:6767` | Subtitle management |
| Seerr | `:5055` | Request new movies/shows |
| Maintainerr | `:6246` | Watched content cleanup rules |
| SABnzbd | `:8084` | Download queue |
| Tautulli | `:8181` | Plex statistics |
| Dozzle | `:8082` | Live container logs |
| Pi-hole | `192.168.1.105/admin` | Ad blocking dashboard |

### From Anywhere (via Cloudflare Tunnel)

Once Cloudflare is set up, access services at `https://servicename.yourdomain.com` from any device, anywhere. No VPN needed, no ports to open on your router.

---

## Updates

Watchtower checks for updated images every 10 hours and automatically restarts any container that has a newer version available. You don't need to do anything.

To trigger an update manually right now:

```bash
cd ~/docker
sudo docker compose pull && sudo docker compose up -d
```

---

## Troubleshooting

**A container won't start:**
```bash
sudo docker logs container-name --tail 50
```
Replace `container-name` with the service name (e.g. `plex`, `radarr`, `traefik`). The logs will usually tell you exactly what's wrong.

**Can't reach a service in the browser:**
1. Check the container is actually running: `sudo docker ps | grep service-name`
2. Make sure you're using the right IP and port
3. Check the logs for errors

**Traefik isn't getting SSL certificates:**
- Confirm `acme.json` exists and has `chmod 600` permissions
- Confirm your Cloudflare DNS API token is correct and scoped to the right domain
- Check Traefik logs: `sudo docker logs traefik --tail 100`

**Services didn't come back after a reboot:**
All containers use `restart: unless-stopped` so they should restart automatically. If they don't:
```bash
cd ~/docker && sudo docker compose up -d
```

---

## Managing Remotely from Another Computer (Optional)

If you want to edit config files from your everyday computer without SSH-ing in every time:

1. Set up SSH key authentication so you don't need a password each time (search: "how to set up SSH keys")
2. Clone this repo to your everyday computer
3. Edit files locally in VS Code or any editor
4. Use `push.sh` to send your changes to the server:
   ```bash
   bash push.sh
   ```
5. Then apply the changes on the server:
   ```bash
   ssh yourusername@your-server-ip "cd ~/docker && sudo docker compose up -d"
   ```

> The sync scripts use `tar` over SSH rather than SFTP, since SFTP isn't always available.

---

## Security Notes

- The `.env` file and `secrets/` directory are **never committed to git** — back them up somewhere safe (e.g. a password manager)
- Secrets are passed to containers via Docker secrets, not plain environment variables
- The Docker socket (which gives full control over Docker) is protected by a proxy that grants only the minimum required access
- All containers run with `no-new-privileges:true` to prevent privilege escalation
- Traefik uses Cloudflare's DNS challenge for SSL certificates — your server is never directly exposed to the internet on ports 80 or 443
