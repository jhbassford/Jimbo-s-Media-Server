#!/bin/sh
# =============================================================================
# hermes-guardrail-check - detect tampering with the agent's own guardrails
# =============================================================================
# HOST PATH: /volume1/docker/scripts/hermes-guardrail-check.sh  (root:root 0750)
# SOURCE OF TRUTH: appdata-templates/scripts/ in git.
# Run hourly by hermes-firewall.service (second ExecStart), so it shares the
# firewall's schedule and journal.
#
# WHY
# config.yaml was moved OUT of a read-only bind mount and into the agent's
# writable /opt/data, at the operator's request, so the dashboard's model picker
# can persist. That reopens the first leg of review finding C3: a prompt-injected
# agent can rewrite its own containment settings.
#
# It cannot ACTIVATE them itself -- `hermes` is excluded from the socket proxy's
# restart allowlist -- so a tampered value lies dormant until the next
# operator-initiated restart. This check is what makes that window observable
# instead of silent.
#
# WHAT IT DOES NOT DO
# It does not revert. Reverting would undo legitimate UI changes and defeat the
# reason config.yaml was made writable. It compares the SECURITY keys -- and, as
# of 2026-09-10, the mcp_servers.* tool allowlist (spec section 5) -- against a
# root-owned golden copy the agent cannot read or write, and shouts. Model,
# personality and cosmetic changes are ignored by design.
#
# ACCEPTING A LEGITIMATE CHANGE
#   sudo /volume1/docker/scripts/hermes-guardrail-check.sh --accept
# ...after you have reviewed the diff and are sure YOU made it.
set -u

LIVE=/volume1/docker/appdata/hermes/config.yaml
GOLDEN=/volume1/docker/appdata/hermes-etc/config.yaml.golden
TAG=hermes-guardrail

log() {
	echo "$(/usr/bin/date '+%Y-%m-%d %H:%M:%S') [$TAG] $*"
	/usr/bin/logger -t "$TAG" -- "$*" 2>/dev/null || true
}

[ "$(id -u)" = "0" ] || { log "ABORT: must run as root"; exit 1; }
[ -r "$LIVE" ]   || { log "ABORT: live config not readable at $LIVE"; exit 1; }
[ -r "$GOLDEN" ] || { log "ABORT: golden copy missing at $GOLDEN - run --accept to create it"; exit 1; }

# Extract only the guardrail-bearing top-level sections, normalised: comments,
# blank lines and trailing whitespace stripped, so reformatting or re-commenting
# a file is not reported as tampering.
#
# Deliberately pure awk, NO python/yaml. The first version of this script parsed
# with PyYAML -- and the NAS's system python3 has no yaml module, so BOTH
# extractions returned the same ModuleNotFoundError text, compared equal, and the
# check reported "guardrails unchanged". A monitor that fails open is worse than
# no monitor, because it is believed. This version has no dependencies beyond awk.
extract() {
	/usr/bin/awk '
		# A new top-level key (column 0, ends in ":") switches section tracking.
		/^[A-Za-z_][A-Za-z0-9_]*:/ {
			insec = ($0 ~ /^(approvals|security|skills|tool_loop_guardrails|terminal|dashboard|mcp_servers):/)
		}
		insec {
			line = $0
			sub(/[ 	]*#.*$/, "", line)      # strip comments
			sub(/[ 	]+$/, "", line)         # strip trailing whitespace
			if (line != "") print line
		}
	' "$1" | /usr/bin/sed 's/password_hash:.*/password_hash: <redacted>/'
}

if [ "${1:-}" = "--accept" ]; then
	cp -a "$LIVE" "$GOLDEN"
	chown root:root "$GOLDEN"; chmod 0400 "$GOLDEN"
	log "baseline ACCEPTED - current guardrails are now the golden copy"
	exit 0
fi

LIVE_G=$(extract "$LIVE")
GOLD_G=$(extract "$GOLDEN")

# Fail CLOSED: an empty extraction means the file was truncated, renamed, or the
# section headers were removed outright - all of which are tampering, and none of
# which should be reported as "unchanged".
if [ -z "$LIVE_G" ] || [ -z "$GOLD_G" ]; then
	log "ALERT: guardrail extraction produced NOTHING (live=${#LIVE_G} bytes, golden=${#GOLD_G} bytes)."
	log "ALERT: the config may be truncated or its security sections removed. Treat as tampering."
	exit 2
fi

if [ "$LIVE_G" = "$GOLD_G" ]; then
	log "guardrails unchanged"
	exit 0
fi

log "ALERT: GUARDRAIL DRIFT DETECTED in $LIVE"
log "ALERT: security-relevant config differs from the golden copy."
log "ALERT: if you did not change this yourself, treat the agent as compromised."
log "ALERT: a rewritten config does NOT take effect until hermes is restarted,"
log "ALERT: so you still have time. Review, then either restore or accept:"
log "ALERT:   diff <(sudo cat $GOLDEN) <(sudo cat $LIVE)"
log "ALERT:   sudo cp -a $GOLDEN $LIVE && sudo chown 1000:10 $LIVE   # restore"
log "ALERT:   sudo $0 --accept                                        # accept"
printf '%s\n' "--- golden ---" "$GOLD_G" "--- live ---" "$LIVE_G"
exit 2
