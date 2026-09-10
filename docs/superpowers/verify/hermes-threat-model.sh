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

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] && echo "CONTAINED: spec section 5 criterion holds." \
                  || echo "NOT CONTAINED: $fail check(s) failed - do not treat this deployment as safe."
exit $fail
