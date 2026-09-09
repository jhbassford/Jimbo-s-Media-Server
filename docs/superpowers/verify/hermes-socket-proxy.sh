#!/bin/bash
# Asserts the restricted proxy allows exactly read + restart, and nothing else.
#
# Reaches TWO proxies from a single container:
#   - RESTRICTED (hermes-socket-proxy) at 192.168.93.2:2375 — the proxy under
#     test. Started with -allowfrom=192.168.93.0/24, so it must be reached
#     from a source address inside that CIDR or "allow" checks get misleading
#     403s on source IP, not on the path/method regex being tested.
#   - PERMISSIVE (existing tecnativa socket-proxy) at 127.0.0.1:2375 — used
#     ONLY to create/start/stop/delete a disposable "canary" container.
#     NEVER used to exercise the restricted proxy's allow/deny surface, and
#     NEVER used against plex or any other in-use container.
#
# Why --network host: the permissive proxy is published as
# "127.0.0.1:2375:2375" — bound to the host's loopback interface only.
# Verified empirically (2026-09-09): a container attached directly to the
# hermes_socket bridge cannot reach it via the bridge gateway IP
# (192.168.93.1) — curl returns 000 (connection refused), because a port
# bound to 127.0.0.1 is not reachable from traffic arriving on a different
# host interface. A container run with --network host shares the host's own
# network namespace: it reaches 127.0.0.1:2375 directly (host loopback), and
# it reaches 192.168.93.2:2375 by routing out the hermes_socket bridge
# interface with source address 192.168.93.1 (the bridge's own host-side
# address) — which IS inside -allowfrom=192.168.93.0/24, so the restricted
# proxy does not reject it on source IP. Both were confirmed with curl
# returning 200 in this mode before this script was written.
#
# Run with:
#   docker run --rm --network host -v <this file>:/t.sh:ro curlimages/curl:8.8.0 sh /t.sh
set -u
RESTRICTED=http://192.168.93.2:2375
PERMISSIVE=http://127.0.0.1:2375
CANARY=hermes-restart-canary
fail=0

# ALLOW check: exact expected status code against the RESTRICTED proxy.
chk() { # name expected_code method url
  code=$(curl -s --path-as-is -o /dev/null -w '%{http_code}' -X "$3" "$RESTRICTED$4")
  if [ "$code" = "$2" ]; then echo "PASS $1 ($code)"; else echo "FAIL $1: got $code want $2"; fail=1; fi
}

# DENY check: any of a comma-separated set of acceptable "denied" codes
# against the RESTRICTED proxy. 403 = path-matching rejection on a
# configured method; 405 = the method itself has no -allow flag at all
# (e.g. DELETE, which is not configured). Both are conclusive denials.
chkdeny() { # name method url accepted_codes_csv
  code=$(curl -s --path-as-is -o /dev/null -w '%{http_code}' -X "$2" "$RESTRICTED$3")
  ok=0
  old_ifs=$IFS
  IFS=,
  for want in $4; do
    [ "$code" = "$want" ] && ok=1
  done
  IFS=$old_ifs
  if [ "$ok" = 1 ]; then echo "PASS $1 ($code)"; else echo "FAIL $1: got $code want one of [$4]"; fail=1; fi
}

cleanup() {
  curl -s -o /dev/null -X POST "$PERMISSIVE/containers/$CANARY/stop" >/dev/null 2>&1
  curl -s -o /dev/null -X DELETE "$PERMISSIVE/containers/$CANARY?force=1" >/dev/null 2>&1
}
trap cleanup EXIT

# --- Set up a disposable canary via the PERMISSIVE proxy only. ---
# This is the ONLY container ever created/started/stopped/deleted by this
# script; restart and stats below are proven against IT, never against plex.
curl -s -o /dev/null -X POST "$PERMISSIVE/images/create?fromImage=alpine&tag=latest"
create_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$PERMISSIVE/containers/create?name=$CANARY" \
  -H 'Content-Type: application/json' -d '{"Image":"alpine","Cmd":["sleep","300"]}')
if [ "$create_code" = "409" ]; then
  # Leftover from a previous aborted run — clear it and retry once.
  curl -s -o /dev/null -X POST "$PERMISSIVE/containers/$CANARY/stop"
  curl -s -o /dev/null -X DELETE "$PERMISSIVE/containers/$CANARY?force=1"
  create_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$PERMISSIVE/containers/create?name=$CANARY" \
    -H 'Content-Type: application/json' -d '{"Image":"alpine","Cmd":["sleep","300"]}')
fi
if [ "$create_code" != "201" ]; then
  echo "FAIL canary create: got $create_code want 201"; fail=1
fi
start_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$PERMISSIVE/containers/$CANARY/start")
if [ "$start_code" != "204" ]; then
  echo "FAIL canary start: got $start_code want 204"; fail=1
fi

# --- Read surface ---
chk "GET /version"              200 GET    /version
chk "GET /info"                 200 GET    /info
chk "GET /containers/json"      200 GET    "/containers/json?all=1"
chk "GET plex inspect"          200 GET    /containers/plex/json
chk "GET plex logs"             200 GET    "/containers/plex/logs?stdout=1&tail=1"

# --- The one mutation this proxy exists to grant — proven for real, against
#     the disposable canary, including the "?t=5" query allowance (Finding 4).
#     Never exercised against plex or any other in-use container.
#
#     The restart allowlist is a NAME alternation, not a wildcard, so the canary
#     name must appear in it or this check cannot pass. Two ways to satisfy that
#     were available: rename the canary to one of the production names, or list
#     the canary name in the regex. The first is impossible without restarting a
#     live service on every verification run (plex/pihole/an *arr — this is the
#     household's media and DNS box), so the second was chosen: the compose file
#     lists `hermes-restart-canary` explicitly, with a comment saying why. It
#     grants nothing to a hijacked agent — the proxy cannot create containers and
#     cannot rename them, so outside a verification run that name is a 404. ---
chk "POST canary restart"       204 POST   "/containers/$CANARY/restart?t=5"
chk "GET canary stats"          200 GET    "/containers/$CANARY/stats?stream=false"

# --- Deny surface ---
chkdeny "DENY container create"                POST   "/containers/create?name=pwn"                  403
chkdeny "DENY container delete"                DELETE "/containers/plex"                              403,405
chkdeny "DENY exec create"                     POST   "/containers/plex/exec"                         403
chkdeny "DENY images list"                     GET    "/images/json"                                  403
chkdeny "DENY volumes list"                    GET    "/volumes"                                      403
chkdeny "DENY networks list"                   GET    "/networks"                                     403
chkdeny "DENY container stop"                  POST   "/containers/plex/stop"                         403
chkdeny "DENY build"                           POST   "/build"                                        403
chkdeny "DENY logs path traversal (to images)" GET    "/containers/plex/logs/../../images/json"        403
chkdeny "DENY logs path traversal (to json)"   GET    "/containers/plex/logs/../json"                  403

# --- Restart is SCOPED, not universal. The allowlist is an explicit alternation
#     of the media-stack containers the ops role manages; everything that is
#     containment infrastructure or household infrastructure is excluded. These
#     checks prove the exclusions are real, not just intended. Restarting any of
#     these would be a containment escape or a household outage:
#       hermes              -> reload guardrails the agent had just rewritten
#       hermes-egress-proxy -> its own egress allowlist
#       hermes-socket-proxy -> this proxy
#       pihole              -> DNS for the whole house
#       traefik             -> all ingress
#       cloudflared         -> all remote access
#       socket-proxy        -> the PERMISSIVE proxy (container create == root)
#       watchtower/portainer/dozzle
#     A DENY here is proven by the status code alone: the request never reaches
#     the Docker socket, so nothing is actually restarted by running this. ---
chkdeny "DENY restart hermes (self)"           POST   "/containers/hermes/restart"                     403
chkdeny "DENY restart pihole (household DNS)"  POST   "/containers/pihole/restart"                     403
chkdeny "DENY restart traefik (all ingress)"   POST   "/containers/traefik/restart"                    403
chkdeny "DENY restart cloudflared (tunnel)"    POST   "/containers/cloudflared/restart"                403
chkdeny "DENY restart hermes-egress-proxy"     POST   "/containers/hermes-egress-proxy/restart"        403
chkdeny "DENY restart hermes-socket-proxy"     POST   "/containers/hermes-socket-proxy/restart"        403
chkdeny "DENY restart socket-proxy (permissive)" POST "/containers/socket-proxy/restart"               403
chkdeny "DENY restart watchtower"              POST   "/containers/watchtower/restart"                 403
chkdeny "DENY restart portainer"               POST   "/containers/portainer/restart"                  403
chkdeny "DENY restart dozzle"                  POST   "/containers/dozzle/restart"                     403
# A prefix of an allowlisted name must not match either — the alternation is
# anchored, so "plex-evil" and a bare "plex/restart/../hermes/restart" both fail.
chkdeny "DENY restart non-allowlisted name"    POST   "/containers/plex-evil/restart"                  403
chkdeny "DENY restart traversal to hermes"     POST   "/containers/plex/restart/../hermes/restart"     403

exit $fail
