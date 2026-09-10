#!/bin/sh
# =============================================================================
# Hermes containment verification (plan Task 4)
# =============================================================================
# Run from INSIDE the agent's own network namespace, which is the only vantage
# point that proves anything:
#   ssh nas 'cat > /tmp/hermes-containment.sh' < docs/superpowers/verify/hermes-containment.sh
#   ssh nas 'sudo /usr/local/bin/docker run --rm --network container:hermes \
#     -v /tmp/hermes-containment.sh:/t.sh:ro curlimages/curl:8.8.0 sh /t.sh'
#
# The hermes container must be RUNNING for --network container:hermes to work.
#
# WHY THE HOST CHECKS MATTER (review finding I1): DOCKER-USER is reached only
# from the FORWARD path. Container-to-HOST traffic goes via INPUT and never
# traverses DOCKER-USER at all. Before the INPUT_FIREWALL hook existed, every
# "host ..." check below passed straight through - including Home Assistant on
# :8123, which is full control of the IoT estate, and which Task 8's UniFi rule
# could never see because no packet ever reaches VLAN 20.
#
# Every bridge gateway (192.168.90.1, .92.1, .93.1, 172.17.0.1) IS the host, so
# a rule naming only 192.168.1.104 would not be enough. Both forms are tested.
set -u

command -v curl >/dev/null 2>&1 || { echo "ABORT: no curl in this image"; exit 2; }

fail=0
pass=0

chk() { # name expected(allow|deny) url
	if curl -s -o /dev/null --max-time 6 "$3" 2>/dev/null; then r=allow; else r=deny; fi
	if [ "$r" = "$2" ]; then
		echo "PASS  $1 ($r)"; pass=$((pass + 1))
	else
		echo "FAIL  $1: got $r, want $2"; fail=$((fail + 1))
	fi
}

chkproxy() { # name expected(allow|deny) url
	if curl -s -o /dev/null --max-time 10 -x 192.168.92.2:8888 "$3" 2>/dev/null; then r=allow; else r=deny; fi
	if [ "$r" = "$2" ]; then
		echo "PASS  $1 ($r)"; pass=$((pass + 1))
	else
		echo "FAIL  $1: got $r, want $2"; fail=$((fail + 1))
	fi
}

echo "== the proxy must be the ONLY way out =="
chk      "direct internet blocked"      deny  https://example.com/
chk      "direct openrouter blocked"    deny  https://openrouter.ai/
chkproxy "via proxy: openrouter"        allow https://openrouter.ai/api/v1/models
chkproxy "via proxy: non-allowlisted"   deny  https://pastebin.com/

echo "== cannot pivot to the LAN, the router, or the IoT VLAN =="
chk "router UI"                deny https://192.168.1.1/
chk "IoT VLAN gateway"         deny http://192.168.2.1/
chk "IoT VLAN host"            deny http://192.168.2.161/

echo "== cannot reach the HOST (the INPUT path DOCKER-USER cannot see) =="
chk "host Home Assistant"      deny http://192.168.1.104:8123/
chk "host portainer"           deny http://192.168.1.104:9000/
chk "host dozzle"              deny http://192.168.1.104:8082/
chk "host plex"                deny http://192.168.1.104:32400/web/
chk "host DSM"                 deny http://192.168.1.104:5000/
chk "bridge gw 192.168.92.1"   deny http://192.168.92.1:9000/
chk "bridge gw 192.168.90.1"   deny http://192.168.90.1:9000/
chk "bridge gw 172.17.0.1"     deny http://172.17.0.1:9000/

echo "== t3_proxy is unreachable BY CONSTRUCTION (finding C1 fixed) =="
# The agent is no longer a member of t3_proxy at all - it sits on hermes_ingress,
# a two-member network with only Traefik. These were previously enforced by a
# firewall RETURN-allowlist; they are now simply not routable.
chk "portainer via t3_proxy"   deny http://192.168.90.7:9000/
chk "dozzle via t3_proxy"      deny http://192.168.90.9:8080/
chk "radarr via t3_proxy"      deny http://192.168.90.3:7878/

echo "== but its own two proxies, and Traefik ingress, still work =="
chk "traefik on hermes_ingress" allow http://192.168.94.254:80/
chk "restricted socket proxy"  allow http://192.168.93.2:2375/version
chk "egress proxy reachable"   allow http://192.168.92.2:8888/

echo
echo "passed=$pass failed=$fail"
exit $fail
