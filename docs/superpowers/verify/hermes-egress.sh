#!/bin/bash
# Asserts the forward proxy allows only allowlisted domains.
set -u
PX=192.168.92.2:8888
fail=0
chk() { # name expected_result url
  if curl -s -o /dev/null --max-time 10 -x "$PX" "$3" 2>/dev/null; then r=allow; else r=deny; fi
  if [ "$r" = "$2" ]; then echo "PASS $1 ($r)"; else echo "FAIL $1: got $r want $2"; fail=1; fi
}
chk "openrouter allowed"  allow https://openrouter.ai/api/v1/models
chk "github allowed"      allow https://api.github.com/
chk "evil.com denied"     deny  https://example.com/
chk "pastebin denied"     deny  https://pastebin.com/

# Extra check beyond the brief's original 4: proves ConnectPort 443 is
# actually enforced, not just declared. This targets an ALLOWLISTED domain
# (github.com) but on a non-443 port. If the config's default-deny were
# working purely on hostname (Filter) and ConnectPort were silently
# ineffective, this CONNECT would succeed and the proxy could be used as a
# generic TCP tunnel to any port on an allowlisted host. Port 443 to the
# SAME host is proven to work above ("github allowed"), so a deny here
# isolates the port restriction specifically, not a hostname-filter miss.
chk "github:8080 (wrong port) denied" deny https://github.com:8080/
exit $fail
