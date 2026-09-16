#!/bin/sh
# =============================================================================
# ha-install-midea-ac-lan - (re)install the Midea AC LAN HA custom integration
# =============================================================================
# HOST PATH: /volume1/docker/scripts/ha-install-midea-ac-lan.sh  (root:root 0750)
# SOURCE OF TRUTH: appdata-templates/scripts/ in git.
#
#   sudo /volume1/docker/scripts/ha-install-midea-ac-lan.sh
#   sudo /volume1/docker/scripts/ha-install-midea-ac-lan.sh --no-restart
#
# WHY THIS EXISTS
# Home Assistant runs here as a container (compose/udms/homeassistant.yml,
# network_mode: host) with its config on the NAS at
# /volume1/docker/appdata/homeassistant. custom_components/ is not in the image
# and is not synced by push.sh (that tars only docker-compose.yml + compose/),
# and this box has no backup solution. So the integration survives a container
# recreate, but not the loss of appdata/ -- a restore from any backup predating
# 2026-09-16, or a migration to new hardware, comes back without it. This script
# is the reproducible, checksum-verified restore path. It is idempotent.
#
# WHY THIS FORK (do not "fix" this pin)
# The integration most guides link to, georgezhao2010/midea_ac_lan, is
# abandoned: last commit 2024-01-11, last release v0.3.22 (2023-10-16). The live
# fork is wuwentao/midea_ac_lan, which is what HACS ships as "Midea AC LAN" and
# the one whose release cadence tracks HA. Do not pull a georgezhao2010 release
# over this.
#
# PIN POLICY
# VERSION and SHA256 move together. The SHA256 is the digest GitHub *itself*
# publishes for the release asset (the `digest` field of the releases API), not
# a hash of whatever happened to download here. To bump:
#   curl -s https://api.github.com/repos/wuwentao/midea_ac_lan/releases/latest
# confirm the asset's `digest`, and check the `homeassistant` minimum in that
# tag's hacs.json against the running HA before raising VERSION.
#
# WHAT THIS SCRIPT CANNOT DO
# The Midea cloud login that retrieves the appliance Token/Key is an operator
# step in the HA UI (Settings -> Devices & Services -> Add Integration ->
# Midea AC LAN), because it needs the operator's Midea account credentials.
# Background and the VLAN/account gotchas are in appdata-templates/README.md.
set -eu

VERSION=v2026.9.1
SHA256=a39d7f6fe2fd9bedccb3f98fe242473739d9159c05f7038d9426695bc2518d3b

HA_CFG=/volume1/docker/appdata/homeassistant
DEST="$HA_CFG/custom_components/midea_ac_lan"
URL="https://github.com/wuwentao/midea_ac_lan/releases/download/$VERSION/midea_ac_lan.zip"
DOCKER=/usr/local/bin/docker

[ "$(id -u)" = "0" ] || { echo "must run as root (sudo)"; exit 1; }

RESTART=yes
case "${1:-}" in
	--no-restart) RESTART=no ;;
	"") ;;
	*) echo "usage: $0 [--no-restart]"; exit 1 ;;
esac

# This NAS ships 7z but NOT unzip (verified 2026-09-16: `command -v unzip` is
# empty). Do not rewrite this to use unzip.
for t in /usr/bin/curl /usr/bin/7z /usr/bin/sha256sum; do
	[ -x "$t" ] || { echo "ERROR: $t is missing"; exit 1; }
done

TMP=$(mktemp -d /tmp/midea_ac_lan.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

echo "==> fetching $VERSION"
/usr/bin/curl -fsSL -o "$TMP/midea_ac_lan.zip" "$URL"

echo "==> verifying checksum"
echo "$SHA256  $TMP/midea_ac_lan.zip" | /usr/bin/sha256sum -c - >/dev/null \
	|| { echo "ERROR: checksum mismatch -- refusing to install"; exit 1; }

echo "==> extracting"
/usr/bin/7z x -y -o"$TMP/x" "$TMP/midea_ac_lan.zip" >/dev/null
[ -f "$TMP/x/manifest.json" ] \
	|| { echo "ERROR: archive has no manifest.json at its root"; exit 1; }

# The zip holds the CONTENTS of custom_components/midea_ac_lan, not the parent
# directories, so it must be extracted into a directory literally named
# midea_ac_lan. Extracting one level up (into custom_components/) scatters
# HA's core filenames across the components root.
GOT=$(/bin/sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
	"$TMP/x/manifest.json" | head -1)
echo "    manifest version: $GOT"

if [ -d "$DEST" ]; then
	# The backup MUST NOT live under custom_components/. HA scans every
	# non-dot entry there and resolves each one's manifest `domain` -- so a
	# sibling backup resolves to the SAME domain as the live install and gets
	# discovered as a second copy of `midea_ac_lan`. It does not error; it
	# silently dedupes, and which copy wins depends on readdir order. So the
	# backup goes to a sibling of custom_components/, which HA never scans.
	BAK_ROOT="$HA_CFG/custom_components.bak"
	BAK="$BAK_ROOT/midea_ac_lan-$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$BAK_ROOT"
	echo "==> backing up existing install to $BAK"
	mv "$DEST" "$BAK"
fi

echo "==> installing to $DEST"
mkdir -p "$DEST"
cp -a "$TMP/x/." "$DEST/"
chown -R root:root "$DEST"
# a+rX, not a+r: directories need the execute bit to be traversable, and no
# data file here should ever be executable.
chmod -R a+rX "$DEST"
echo "    $(ls -1 "$DEST" | wc -l) entries"

if [ "$RESTART" = "yes" ]; then
	echo "==> restarting homeassistant"
	$DOCKER restart homeassistant >/dev/null
	sleep 50
	echo "==> verifying HA loaded it"
	if $DOCKER logs --tail 400 homeassistant 2>&1 \
			| grep -q "custom integration midea_ac_lan"; then
		echo "    ok: HA reports the custom integration"
	else
		echo "    WARNING: no 'custom integration midea_ac_lan' line in the tail."
		echo "    Inspect: $DOCKER logs --tail 200 homeassistant | grep -i midea"
	fi
fi
echo "done."
