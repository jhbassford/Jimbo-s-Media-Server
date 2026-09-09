#!/bin/bash
# Asserts the restricted proxy allows exactly read + restart.
# Run from a container ON the hermes_socket network — the proxy is started with
# -allowfrom=192.168.93.0/24, so a host-side test via a published port may be
# rejected on source IP and produce misleading 403s on the "allow" checks.
set -u
P=http://192.168.93.2:2375
fail=0
chk() { # name expected_code method url
  code=$(curl -s -o /dev/null -w '%{http_code}' -X "$3" "$P$4")
  if [ "$code" = "$2" ]; then echo "PASS $1 ($code)"; else echo "FAIL $1: got $code want $2"; fail=1; fi
}
chk "GET /version"              200 GET    /version
chk "GET /info"                 200 GET    /info
chk "GET /containers/json"      200 GET    "/containers/json?all=1"
chk "GET plex inspect"          200 GET    /containers/plex/json
chk "GET plex logs"             200 GET    "/containers/plex/logs?stdout=1&tail=1"
chk "DENY container create"     403 POST   "/containers/create?name=pwn"
chk "DENY container delete"     403 DELETE /containers/plex
chk "DENY exec create"          403 POST   /containers/plex/exec
chk "DENY images list"          403 GET    /images/json
chk "DENY volumes list"         403 GET    /volumes
chk "DENY networks list"        403 GET    /networks
chk "DENY container stop"       403 POST   /containers/plex/stop
chk "DENY build"                403 POST   /build
exit $fail
