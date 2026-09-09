#!/bin/sh
# =============================================================================
# Hermes containment - THE egress-enforcement boundary.
# =============================================================================
# HOST PATH: /volume1/docker/scripts/hermes-firewall.sh   (root:root 0750)
# SOURCE OF TRUTH: this file, in git (appdata-templates/scripts/).
#
# WHY THIS FILE IS VERSION-CONTROLLED
# Everything else on this branch fails CLOSED: a missing config file, a bad
# mount, a wrong uid - the container crash-loops and you notice. This script
# fails OPEN. If it is absent, or silently stops being applied, the result is a
# fully functional, wholly uncontained agent with an internet-reachable
# dashboard and no error anywhere. /volume1/docker/scripts/ is outside the
# push.sh-synced tree, so a NAS rebuild that restores compose/ restores
# everything EXCEPT this. That is why it lives in git and why
# appdata-templates/README.md records where it goes.
#
# The Tinyproxy egress allowlist (compose/hermes-egress-proxy.yml) is opt-in:
# HTTP_PROXY/HTTPS_PROXY are advisory, and any library that ignores them walks
# straight past it. This script is what makes the proxy inescapable.
#
# Keyed on the container's IPs, NOT on a bridge interface: hermes shares
# t3_proxy with every other proxied service, so an interface-based rule would
# take the whole stack down.
#
# =============================================================================
# HOST QUIRKS ESTABLISHED ON THIS NAS (DSM 4.4.302, iptables v1.8.3 legacy)
# =============================================================================
# 1. FORWARD does not jump to DOCKER-USER directly. The real path is
#    FORWARD -> FORWARD_FIREWALL -> DEFAULT_FORWARD -> DOCKER-USER. Synology
#    inserts its own chains. Jumping from DOCKER-USER still works, but do not
#    assume the stock Docker layout when debugging.
# 2. /usr/bin/iptables is a Synology SHELL WRAPPER around
#    /usr/bin/xtables-legacy-multi that retries on EAGAIN.
# 3. THE BUILT-IN CHAINS CANNOT BE ADDRESSED BY NAME on this host. Verified:
#      iptables -S INPUT    -> "No chain/target/match by that name."
#      iptables -S OUTPUT   -> "No chain/target/match by that name."
#      iptables -S FORWARD  -> prints DEFAULT_FORWARD's rules (!)
#      iptables -S DOCKER-USER / INPUT_FIREWALL / DEFAULT_FORWARD -> fine
#    ...while "iptables-save" shows INPUT, OUTPUT and FORWARD perfectly well.
#    Custom chains are addressable; built-ins are not. So "-I INPUT 1 -j ..."
#    is NOT assumed to work here. The script TRIES it, verifies the result with
#    iptables-save (which is authoritative), and falls back to INPUT_FIREWALL -
#    the single custom chain that INPUT unconditionally jumps to:
#      -A INPUT -j INPUT_FIREWALL
#    Verify listings with "iptables-save", never with "iptables -L INPUT".
#
# =============================================================================
# WHY AN INPUT COMPANION IS REQUIRED (review finding I1)
# =============================================================================
# DOCKER-USER is reached only from the FORWARD path. Container-to-HOST traffic
# is INPUT, and never traverses DOCKER-USER at all. Without the INPUT-side
# rules below, a hijacked agent still reaches, on 192.168.1.104 and on every
# docker bridge gateway address (192.168.90.1, 192.168.92.1, 192.168.93.1,
# 172.17.0.1, ...) which are also the host:
#   :8123  Home Assistant  (network_mode: host - full IoT control, and the
#                           UniFi rule in Task 8 cannot see this either,
#                           because no packet ever reaches VLAN 20)
#   :9000  Portainer       (backed by the PERMISSIVE socket proxy - container
#                           create == root on the NAS)
#   :32400 Plex
#   :5000/:5001 DSM
#   :22    sshd
# A LAN-address rule is not enough on its own: every bridge gateway is the same
# host. This chain drops ALL host-bound traffic from the agent's IPs, so the
# address it picks does not matter.
#
# DNS IS NOT AFFECTED. Docker's embedded resolver at 127.0.0.11 lives inside
# the container's own network namespace; the container's queries never leave it
# as packets from a hermes IP. dockerd forwards them upstream from the HOST's
# namespace with the host's own source address, so they never match any rule
# here. Confirm after applying with:
#   docker run --rm --network container:hermes curlimages/curl:8.8.0 \
#     sh -c 'nslookup openrouter.ai || echo DNS-BROKEN'
#
# =============================================================================
# IDEMPOTENCY (review finding I2)
# =============================================================================
# The earlier version's cleanup loop
#   while iptables -D DOCKER-USER -m comment --comment "hermes-containment"
# was a NO-OP: iptables -D needs a full rule spec or a rule number, and a bare
# --comment match is neither. It deleted nothing, so every re-run appended
# another generation of rules and the listing became unauditable.
#
# This version owns a dedicated chain. -N creates it (ignore "exists"), -F
# empties it, then it is refilled. Flush-and-refill is genuinely idempotent,
# the jumps are deleted by FULL rule spec ("-D DOCKER-USER -j HERMES-CONTAIN",
# which really does delete) and re-inserted at position 1, and the entire
# policy is auditable with one command:
#   sudo iptables -S HERMES-CONTAIN
#
# =============================================================================
# PERSISTENCE (review finding I2c)
# =============================================================================
# DSM does not persist iptables rules, AND a Docker package restart or a
# "docker compose down/up" rebuilds the Docker chains WITHOUT a reboot. A
# boot-only task therefore silently drops containment while Hermes keeps
# running. Two DSM Task Scheduler entries are required, both as root:
#   1. Triggered task, event Boot-up
#   2. Scheduled task, daily, "repeat every 1 hour"
# The re-apply is cheap and loud: if the rules were found missing it logs
# CONTAINMENT WAS MISSING to stdout (captured in the task's own output) and to
# syslog via logger, so a gap leaves evidence instead of passing silently.
# =============================================================================

set -u

IPT=/usr/bin/iptables
CHAIN=HERMES-CONTAIN
TAG=hermes-firewall

# Hermes' static IPs, one per attached network. Must match compose/hermes.yml.
#   192.168.90.10  t3_proxy      (ingress from Traefik)
#   192.168.92.10  hermes_net    (egress via the Tinyproxy allowlist)
#   192.168.93.10  hermes_socket (restricted docker socket proxy)
HERMES_IPS="192.168.90.10 192.168.92.10 192.168.93.10"

# The only destinations the agent may initiate to.
EGRESS_PROXY=192.168.92.2      # Tinyproxy - its one way out
SOCKET_PROXY=192.168.93.2      # restricted docker socket proxy (read + scoped restart)
TRAEFIK=192.168.90.254         # t3_proxy ingress peer

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') [$TAG] $*"
	logger -t "$TAG" -- "$*" 2>/dev/null || true
}

die() { log "ABORT: $*"; exit 1; }

[ "$(id -u)" = "0" ] || die "must run as root"
[ -x "$IPT" ] || die "no iptables at $IPT"

# --- Was containment actually in place before this run? ----------------------
# Reported loudly, because the whole point of the hourly re-apply is to make a
# silent loss of containment noisy.
was_present=1
$IPT -S "$CHAIN"                >/dev/null 2>&1 || was_present=0
$IPT -C DOCKER-USER -j "$CHAIN" >/dev/null 2>&1 || was_present=0
# iptables-save is authoritative here; see host quirk 3.
iptables-save -t filter 2>/dev/null | grep -qE "^-A (INPUT|INPUT_FIREWALL) -j $CHAIN\$" || was_present=0

# --- Build the policy chain --------------------------------------------------
$IPT -N "$CHAIN" 2>/dev/null   # already exists on a re-run; not an error
$IPT -F "$CHAIN" || die "cannot flush $CHAIN"

# Replies to connections the agent did not initiate (notably Traefik -> hermes
# ingress) must survive, or the dashboard breaks.
$IPT -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN \
	|| die "cannot add conntrack RETURN"

for ip in $HERMES_IPS; do
	# Permitted, and nothing else: its own egress proxy, the restricted socket
	# proxy, and Traefik.
	#
	# NOTE - this deliberately allows only 192.168.90.254 on t3_proxy, not the
	# whole 192.168.90.0/24 the plan originally specified. That /24 also holds
	# Portainer, an unauthenticated Dozzle and every *arr API, all reachable
	# without passing Traefik's basic-auth middleware (review finding C1;
	# Docker bridges are bidirectional). This is a PARTIAL, firewall-only
	# mitigation and is NOT a substitute for moving Hermes off the shared
	# t3_proxy network, which remains the real fix and is the operator's call
	# because it means restarting Traefik.
	for dst in "$EGRESS_PROXY" "$SOCKET_PROXY" "$TRAEFIK"; do
		$IPT -A "$CHAIN" -s "$ip" -d "$dst" -j RETURN \
			|| die "cannot add RETURN $ip -> $dst"
	done

	# Everything else: the internet, the LAN, the IoT VLAN, the router, the
	# rest of t3_proxy, and - via the INPUT hook below - the host itself on
	# every one of its addresses.
	# Rate-limited logging first, so an attempt leaves evidence. Best effort:
	# if this kernel has no LOG target, containment still applies.
	$IPT -A "$CHAIN" -s "$ip" -m limit --limit 6/min --limit-burst 10 \
		-j LOG --log-prefix "hermes-drop: " --log-level 4 2>/dev/null \
		|| log "note: LOG target unavailable, dropping without logging"
	$IPT -A "$CHAIN" -s "$ip" -j DROP || die "cannot add DROP for $ip"
done

# --- Hook 1: container -> anywhere-but-the-host (FORWARD path) ---------------
# Deleting by FULL rule spec genuinely deletes (unlike the old comment-only
# loop), so this is safe to run repeatedly and always lands at position 1.
while $IPT -D DOCKER-USER -j "$CHAIN" 2>/dev/null; do :; done
$IPT -I DOCKER-USER 1 -j "$CHAIN" || die "cannot hook DOCKER-USER"

# --- Hook 2: container -> the HOST itself (INPUT path) -----------------------
# Try the built-in INPUT chain first, then verify with iptables-save, because
# on this host iptables can fail to address built-ins by name (quirk 3) and
# some failure modes are quiet.
host_hook=""
while $IPT -D INPUT -j "$CHAIN" 2>/dev/null; do :; done
if $IPT -I INPUT 1 -j "$CHAIN" 2>/dev/null &&
	iptables-save -t filter 2>/dev/null | grep -qE "^-A INPUT -j $CHAIN\$"; then
	host_hook=INPUT
else
	# Fallback: INPUT_FIREWALL is a custom chain (therefore addressable) and is
	# the only rule in INPUT: "-A INPUT -j INPUT_FIREWALL". Inserting at
	# position 1 places us ahead of its "-i lo -j ACCEPT" and its
	# RELATED,ESTABLISHED accept; our own chain starts with a conntrack RETURN,
	# so established flows are still honoured.
	# CAVEAT: DSM rebuilds INPUT_FIREWALL whenever the Synology firewall
	# configuration changes. That is precisely what the hourly re-apply covers.
	while $IPT -D INPUT_FIREWALL -j "$CHAIN" 2>/dev/null; do :; done
	$IPT -I INPUT_FIREWALL 1 -j "$CHAIN" || die "cannot hook INPUT or INPUT_FIREWALL"
	iptables-save -t filter 2>/dev/null | grep -qE "^-A INPUT_FIREWALL -j $CHAIN\$" \
		|| die "INPUT_FIREWALL hook did not take"
	host_hook=INPUT_FIREWALL
fi

# --- Report ------------------------------------------------------------------
if [ "$was_present" = "0" ]; then
	log "CONTAINMENT WAS MISSING - rules were not in place before this run."
	log "CONTAINMENT WAS MISSING - if the agent was running, it was uncontained."
	log "CONTAINMENT WAS MISSING - check for a docker restart or a compose down/up."
fi
log "applied: $(iptables-save -t filter | grep -c "^-A $CHAIN ") rules in $CHAIN; hooks: DOCKER-USER + $host_hook"
log "audit with: iptables -S $CHAIN   (do NOT use iptables -L INPUT on this host)"
exit 0
