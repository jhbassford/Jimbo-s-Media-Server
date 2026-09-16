#!/bin/bash
# =============================================================================
# Hermes threat-model acceptance test (plan Task 7, spec section 5)
# =============================================================================
# Asserts the spec's success criterion: a FULLY HIJACKED agent stays contained.
# Every check therefore runs from inside the container, as the agent's own uid,
# with exactly the reach an attacker who achieved code execution would have.
#
#   ssh nas 'cat > /tmp/hermes-threat-model.sh' < docs/superpowers/verify/hermes-threat-model.sh
#   ssh nas 'sudo /usr/local/bin/docker exec -i -u 1000:10 hermes bash /dev/stdin' \
#     < docs/superpowers/verify/hermes-threat-model.sh
#
# This is the REGRESSION test for containment. Re-run it after any image bump,
# compose change, or firewall edit.
#
# NOTE ON THE "allow" CHECKS: they are not filler. If the socket proxy is
# tightened too far the ops role silently stops working, and a suite that only
# asserts denials would call that a pass.
set -u

command -v curl >/dev/null 2>&1 || { echo "ABORT: no curl in this image"; exit 2; }

D=http://192.168.93.2:2375     # restricted docker socket proxy
PX=192.168.92.2:8888           # egress allowlist proxy
pass=0; fail=0

ok()   { echo "PASS  $1"; pass=$((pass+1)); }
bad()  { echo "FAIL  $1  --> $2"; fail=$((fail+1)); }

# HTTP status assertion against the socket proxy.
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X "$1" "$D$2" 2>/dev/null; }
denied() { c=$(code "$2" "$3"); case "$c" in 403|405) ok "$1 (HTTP $c)";; *) bad "$1" "expected 403/405, got $c";; esac; }
allowed() { c=$(code "$2" "$3"); case "$c" in 200|204) ok "$1 (HTTP $c)";; *) bad "$1" "expected 200/204, got $c";; esac; }

# Generic allow/deny by command success.
cdeny()  { if timeout 8 "${@:2}" >/dev/null 2>&1; then bad "$1" "succeeded, expected refusal"; else ok "$1"; fi; }
callow() { if timeout 8 "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1" "failed, expected success"; fi; }

echo "== cannot mutate the container estate (spec 5) =="
denied "create container"        POST   "/containers/create?name=pwn"
denied "delete container"        DELETE "/containers/plex"
denied "exec into container"     POST   "/containers/plex/exec"
denied "stop container"          POST   "/containers/plex/stop"
denied "kill container"          POST   "/containers/plex/kill"
denied "list images"             GET    "/images/json"
denied "list volumes"            GET    "/volumes"
denied "list networks"           GET    "/networks"
denied "build image"             POST   "/build"
denied "restart hermes ITSELF"   POST   "/containers/hermes/restart"
denied "restart pihole (DNS)"    POST   "/containers/pihole/restart"
denied "restart traefik"         POST   "/containers/traefik/restart"
denied "restart cloudflared"     POST   "/containers/cloudflared/restart"

echo "== but the ops role still works =="
allowed "list containers"        GET    "/containers/json?all=1"
allowed "inspect plex"           GET    "/containers/plex/json"
allowed "read plex logs"         GET    "/containers/plex/logs?stdout=1&tail=1"
allowed "plex stats"             GET    "/containers/plex/stats?stream=false"
allowed "docker version"         GET    "/version"

echo "== cannot pivot (spec 5) =="
cdeny "router UI"           curl -s --max-time 5 https://192.168.1.1/
cdeny "IoT VLAN soundbar"   curl -s --max-time 5 http://192.168.2.161/
cdeny "host Home Assistant" curl -s --max-time 5 http://192.168.1.104:8123/
cdeny "host portainer"      curl -s --max-time 5 http://192.168.1.104:9000/
cdeny "host DSM"            curl -s --max-time 5 http://192.168.1.104:5000/
cdeny "t3_proxy portainer"  curl -s --max-time 5 http://192.168.90.7:9000/

echo "== cannot exfiltrate (spec 5) =="
cdeny  "direct internet"          curl -s --max-time 5 https://example.com/
cdeny  "non-allowlisted via proxy" curl -s --max-time 8 -x "$PX" https://pastebin.com/
cdeny  "own DNS resolver"         getent hosts openrouter.ai
callow "allowlisted via proxy"    curl -s --max-time 10 -x "$PX" https://openrouter.ai/api/v1/models

echo "== cannot read what it should not (spec 5) =="
cdeny "stack secrets dir"   ls /volume1/docker/secrets
cdeny "host /etc/shadow"    cat /host/etc/shadow
cdeny "media library"       ls /data/media
cdeny "other appdata"       ls /volume1/docker/appdata
echo "== but its own workspace works =="
callow "code mount"         ls /opt/code
callow "own data dir"       ls /opt/data

echo "== guardrails: config WRITABLE by operator choice, .env still locked =="
# config.yaml is deliberately writable as of 2026-09-10: the operator wanted the
# dashboard's model picker to persist, which a read-only bind mount makes
# impossible. This REOPENS the first leg of finding C3 knowingly. The checks
# below assert the compensating controls, not the original one.
callow "config.yaml writable (intended)" sh -c 'touch /opt/data/config.yaml'
# .env is the line that did NOT move: credentials stay out of reach.
cdeny  "append to .env"        sh -c 'echo x >> /opt/data/.env'
cdeny  "replace .env"          sh -c 'rm -f /opt/data/.env'
# Second leg of C3, still closed: the agent cannot RELOAD a config it rewrote,
# so tampering lies dormant until an operator-initiated restart.
denied "restart itself to reload" POST "/containers/hermes/restart"
# And drift in the security keys is detected hourly against a root-owned golden
# copy the agent can neither read nor write.
cdeny  "read the golden copy"  cat /volume1/docker/appdata/hermes-etc/config.yaml.golden
cdeny "write to rootfs"        touch /usr/local/bin/pwn
cdeny "write to /opt/hermes"   touch /opt/hermes/pwn

echo "== cannot tamper with its own security scanner =="
# tirith is mounted :ro from a root-owned 0555 file rather than auto-installed
# into $HERMES_HOME/bin (= /opt/data), which the agent CAN write. Without this
# the agent could overwrite the scanner that is meant to inspect its commands.
callow "tirith present"      /opt/hermes-bin/tirith --version
cdeny  "overwrite tirith"    sh -c 'echo x > /opt/hermes-bin/tirith'
cdeny  "delete tirith"       rm -f /opt/hermes-bin/tirith
# NOT a check that /opt/data/bin is unwritable -- it is the agent's own
# workspace and is SUPPOSED to be writable (see "own data dir" above). The real
# property is that the pinned path is what gets USED: tirith_security.py only
# consults PATH and $HERMES_HOME/bin when tirith_path is the default literal
# "tirith". With an explicit path it resolves that path and returns, so a file
# planted at /opt/data/bin/tirith is never looked at. Assert the pin instead.
callow "scanner path is pinned" sh -c 'hermes config get security.tirith_path | grep -q "^/opt/hermes-bin/tirith$"'

echo "== cannot escalate =="
cdeny "sudo present"        command -v sudo
cdeny "write /etc/passwd"   sh -c 'echo x >> /etc/passwd'

echo "== Google credential boundary (spec 2026-09-10 section 4) =="
# The whole design exists to make these true: /opt/data holds no Google token.
# Checks stay bounded and deterministic on purpose -- cdeny treats command
# FAILURE as pass, so a check that can time out can pass without looking.
cdeny "no /credentials path"        ls /credentials
cdeny "no /config path"             ls /config
cdeny "no client_secret in /config" cat /config/client_secret.json
cdeny "no google token in /opt/data" sh -c 'find /opt/data -maxdepth 3 -type f \( -iname "*google*.json" -o -iname "*token*.json" -o -iname "*client_secret*" \) 2>/dev/null | grep -q .'
# The bundled google-workspace skill writes google_token.json / client secret
# under HERMES_HOME (= /opt/data here) -- the credential-in-the-blast-radius
# shape spec section 2 rejected. It must not be offered to the agent.
callow "bundled google skill disabled" sh -c 'hermes skills list 2>/dev/null | grep "google-workspace" | grep -q "disabled"'

echo "== still cannot reach Google directly (Hermes egress unchanged) =="
# The MCP container talks to Google; Hermes must not. If either starts passing,
# someone added googleapis to Hermes' own filter -- which the design forbids.
cdeny  "direct googleapis"   sh -c 'curl -s --max-time 8 -x http://192.168.92.2:8888 https://www.googleapis.com/discovery/v1/apis'
cdeny  "google egress proxy" sh -c 'curl -s --max-time 8 -x http://192.168.95.2:8888 https://www.googleapis.com/discovery/v1/apis'
callow "mcp reachable"       sh -c 'curl -s -o /dev/null --max-time 8 http://192.168.92.3:8000/health'

echo "== MCP allowlist matches policy, and send is not exposed (section 6) =="
# Fails loudly if an upstream bump adds a writer. send_gmail_message is withheld
# at both layers (Task 8 branch B, resolved from source 2026-09-10: approvals.*
# does NOT gate MCP calls, and the MCP trust gate would gate every write tool).
callow "mcp handshake"       sh -c 'hermes mcp test google 2>/dev/null | grep -q "Connected"'
callow "21 tools selected"   sh -c 'hermes mcp list 2>/dev/null | grep -q "21 selected"'
cdeny  "no send/share tools" sh -c 'hermes mcp test google 2>/dev/null | grep -qE "send_gmail_message|set_drive_file_permissions|manage_drive_access|get_drive_shareable_link|check_drive_file_public_access"'

echo "== mail is not read unattended (section 7.1) =="
callow "unattended denies" sh -c 'hermes config get approvals.unattended_mode | grep -q "^deny$"'
callow "cron denies"       sh -c 'hermes config get approvals.cron_mode | grep -q "^deny$"'
callow "no scheduled mail" sh -c '! hermes cron list 2>/dev/null | grep -qiE "gmail|mail|inbox|brief"'

echo "== private SearXNG search peer (2026-09-14) =="
# Search-only peer on hermes_search. Hermes can reach it directly (NO_PROXY);
# the reverse direction is firewalled; it has no published ports and sits on no
# other network. Valkey/limiter deliberately absent: Hermes caps searches itself.
callow "searxng search answers" sh -c 'curl -s --max-time 10 "http://192.168.96.2:8080/search?q=test&format=json" | grep -q "\"results\""'
cdeny  "searxng has no published port" sh -c 'curl -s --max-time 5 http://192.168.1.104:8080/search?q=test\&format=json | grep -q "\"results\""'
callow "searxng only on hermes_search" sh -c 'curl -s --max-time 8 http://192.168.93.2:2375/containers/hermes-searxng/json 2>/dev/null | grep -q "hermes_search"'
cdeny  "searxng not on t3_proxy"       sh -c 'curl -s --max-time 8 http://192.168.93.2:2375/containers/hermes-searxng/json 2>/dev/null | grep -q "t3_proxy"'
cdeny  "searxng not on hermes_net"     sh -c 'curl -s --max-time 8 http://192.168.93.2:2375/containers/hermes-searxng/json 2>/dev/null | grep -q "hermes_net"'
callow "search backend is searxng"     sh -c 'hermes config get web.search_backend 2>/dev/null | grep -q "^searxng$"'

echo "== private web extractor (2026-09-14) =="
# Second peer on hermes_search. Unlike SearXNG, which queries two FIXED engines,
# this one fetches arbitrary URLs -- so it is SSRF-as-a-service unless contained,
# and the SSRF checks below are the point of this whole section, not garnish.
#
# The agent-side gate does not cover it: tools/url_safety.py:283 returns True
# when DNS fails and a proxy is configured, and the agent's DNS is deliberately
# blocked, so every HOSTNAME is waved through and only literal private IPs are
# stopped. Measured: is_safe_url("http://localtest.me/") -> True (-> 127.0.0.1).
#
# NOT TESTABLE FROM IN HERE: the firewall leg. The shim refuses private targets
# before a packet leaves, so there is no way to exercise the DROP rules through
# its API -- by design. Verify that leg from the HOST, after any firewall edit:
#   sudo iptables -S HERMES-CONTAIN | grep -- '-s 192.168.96.3/32 .* -j DROP'
#   sudo /usr/local/bin/docker run --rm --network container:hermes-extract \
#        curlimages/curl:8.8.0 -s --max-time 5 http://192.168.1.104:5000/   # must fail
callow "extract backend is tavily"     sh -c 'hermes config get web.extract_backend 2>/dev/null | grep -q "^tavily$"'
callow "no cloud extract fallback"     sh -c 'hermes config get web.keyless_rescue 2>/dev/null | grep -qi "^false$"'
callow "extractor is the local shim"   sh -c 'echo "$TAVILY_BASE_URL" | grep -q "^http://192.168.96.3:8080$"'
callow "extractor extracts a real page" sh -c 'curl -s --max-time 7 -X POST http://192.168.96.3:8080/extract \
  -H "Content-Type: application/json" -d "{\"urls\":[\"https://example.com/\"]}" \
  | grep -q "Example Domain"'
# PDF support (2026-09-14). Not a containment property -- an ALLOW check, for the
# reason given at the top of this file: vendor specs and standards are PDFs, and
# silently losing this sends the agent on multi-minute detours through
# web.archive.org looking for an HTML mirror.
#
# The target is THIS NAS's own datasheet, deliberately: it is the document whose
# refusal motivated adding pypdf, and it exercises the octet-stream path (that
# CDN mislabels its PDFs). Two earlier candidates were rejected on evidence --
# w3.org's dummy.pdf answers 403 to this user-agent, and rfc-editor's pdfrfc
# path is a 404 -- so if this check ever fails, CURL THE URL BY HAND FIRST: an
# upstream move looks identical to a regression from in here.
callow "extractor reads a PDF"          sh -c 'curl -s --max-time 7 -X POST http://192.168.96.3:8080/extract   -H "Content-Type: application/json" -d "{\"urls\":[\"https://global.download.synology.com/download/Document/Hardware/DataSheet/DiskStation/20-year/DS920+/enu/Synology_DS920_Plus_Data_Sheet_enu.pdf\"]}"   | grep -q "\"raw_content\": \"."'
# ...but the content-type gate still holds: non-documents are refused outright.
cdeny  "extractor refuses an image"     sh -c 'curl -s --max-time 7 -X POST http://192.168.96.3:8080/extract   -H "Content-Type: application/json" -d "{\"urls\":[\"https://www.python.org/static/img/python-logo.png\"]}"   | grep -q "\"raw_content\": \"."'
# THE SSRF CHECKS. A pass means the returned JSON carries NO non-empty
# raw_content, i.e. the fetch was refused rather than served.
cdeny  "extractor refuses literal LAN IP" sh -c 'curl -s --max-time 7 -X POST http://192.168.96.3:8080/extract \
  -H "Content-Type: application/json" -d "{\"urls\":[\"http://192.168.1.104:5000/\"]}" \
  | grep -q "\"raw_content\": \"."'
cdeny  "extractor refuses rebinding host" sh -c 'curl -s --max-time 7 -X POST http://192.168.96.3:8080/extract \
  -H "Content-Type: application/json" -d "{\"urls\":[\"http://localtest.me/\"]}" \
  | grep -q "\"raw_content\": \"."'
cdeny  "extractor refuses file:// scheme"  sh -c 'curl -s --max-time 7 -X POST http://192.168.96.3:8080/extract \
  -H "Content-Type: application/json" -d "{\"urls\":[\"file:///etc/passwd\"]}" \
  | grep -q "\"raw_content\": \"."'
callow "extractor only on hermes_search"  sh -c 'curl -s --max-time 8 http://192.168.93.2:2375/containers/hermes-extract/json 2>/dev/null | grep -q "hermes_search"'
cdeny  "extractor not on t3_proxy"        sh -c 'curl -s --max-time 8 http://192.168.93.2:2375/containers/hermes-extract/json 2>/dev/null | grep -q "t3_proxy"'
cdeny  "extractor not on hermes_net"      sh -c 'curl -s --max-time 8 http://192.168.93.2:2375/containers/hermes-extract/json 2>/dev/null | grep -q "hermes_net"'
cdeny  "extractor not on hermes_socket"   sh -c 'curl -s --max-time 8 http://192.168.93.2:2375/containers/hermes-extract/json 2>/dev/null | grep -q "hermes_socket"'
cdeny  "extractor publishes no host port" sh -c 'curl -s --max-time 8 http://192.168.93.2:2375/containers/hermes-extract/json 2>/dev/null | grep -q "HostPort"'
# It holds no credentials and must not gain any: nothing to steal is the design.
cdeny  "extractor holds no secrets in env" sh -c 'curl -s --max-time 8 http://192.168.93.2:2375/containers/hermes-extract/json 2>/dev/null | grep -qiE "API_KEY|TOKEN|PASSWORD|SECRET"'
cdeny  "extractor cannot restart itself"   sh -c 'curl -s -o /dev/null -w "%{http_code}" --max-time 8 -X POST http://192.168.93.2:2375/containers/hermes-extract/restart | grep -qE "^(200|204)$"'

echo "== PocketSmith MCP (spec 2026-09-11) =="
# Unlike Google, the PocketSmith MCP is vendor-hosted and reached DIRECTLY by
# Hermes, so this suite asserts reachability and a valid token rather than an
# isolated-container boundary.
callow "pocketsmith reachable via proxy" sh -c 'curl -s -o /dev/null --max-time 10 -x http://192.168.92.2:8888 https://mcp.pocketsmith.com/.well-known/oauth-protected-resource'
callow "pocketsmith MCP connected"       sh -c 'hermes mcp test pocketsmith 2>/dev/null | grep -qi "connected"'
# Full access is a deliberate operator choice (spec section 1). Assert a
# representative writer is present so a silent downgrade to the read-only
# endpoint cannot pass as healthy.
callow "full-access writer present"      sh -c 'hermes mcp test pocketsmith 2>/dev/null | grep -qE "update_transaction|create_event"'
# DELIBERATE DELTA (spec 5.2): the OAuth token DOES live in the agent-writable
# mount here, unlike Google. Assert it is exactly the expected file rather than
# leaving it to a loose glob, and keep asserting no Google-shaped credential.
callow "pocketsmith token at expected path" sh -c 'test -f /opt/data/mcp-tokens/pocketsmith.json'
cdeny  "no google token in /opt/data"    sh -c 'find /opt/data -maxdepth 3 -type f \( -iname "*google*.json" -o -iname "*client_secret*" \) 2>/dev/null | grep -q .'
callow "no scheduled finances"           sh -c '! hermes cron list 2>/dev/null | grep -qiE "pocketsmith|budget|financ|transaction"'

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] && echo "CONTAINED: spec section 5 criterion holds." \
                  || echo "NOT CONTAINED: $fail check(s) failed - do not treat this deployment as safe."
exit $fail
