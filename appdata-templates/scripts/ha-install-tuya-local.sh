#!/bin/sh
# =============================================================================
# ha-install-tuya-local - (re)install the "Tuya Local" HA custom integration
# =============================================================================
# HOST PATH: /volume1/docker/scripts/ha-install-tuya-local.sh  (root:root 0750)
# SOURCE OF TRUTH: appdata-templates/scripts/ in git.
#
#   sudo /volume1/docker/scripts/ha-install-tuya-local.sh
#   sudo /volume1/docker/scripts/ha-install-tuya-local.sh --no-restart
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
# WHY MANUAL INSTALL, NOT HACS
# HACS is not installed on this box and activating it needs a one-time
# interactive GitHub device-code authorisation that cannot be scripted. A manual
# install of the component tree needs no auth at all.
#
# WHY THIS REPO
# make-all/tuya-local is the integration HACS ships under the "Tuya Local" name.
# It is actively maintained and its VERSION tracks HA's calendar versioning. The
# brief's fallback, rospogrigio/localtuya, is for when no bundled device profile
# matches a fan and data points must be mapped by hand -- it is NOT installed
# here, and this script does not install it.
#
# PIN POLICY
# This integration publishes NO release assets: its GitHub releases are tags
# only (the releases API's `assets` is empty) and HACS fetches the source archive
# at the tag. So, unlike the Midea script, there is no digest GitHub will confirm
# for us. We pin three things that must move together:
#   - COMMIT   the immutable commit the tag points at (~ the content)
#   - VERSION  the manifest version, checked after extraction
#   - SHA256   the sha256 of codeload's tarball for that commit, recorded here
# To bump:
#   curl -s https://api.github.com/repos/make-all/tuya-local/releases/latest
#   curl -s https://api.github.com/repos/make-all/tuya-local/git/tags/<tag-sha>
#   # take object.sha (the commit), then:
#   curl -sL https://codeload.github.com/make-all/tuya-local/tar.gz/<commit> | sha256sum
# GitHub can in principle change its source-archive format, which would change
# the hash without the code changing; the manifest VERSION check is the second
# pin that catches a bumped-but-unverified archive.
#
# WHAT THIS SCRIPT CANNOT DO
# Adding the fans needs the operator's Smart Life / Tuya Smart account -- the
# cloud-assisted config flow fetches each device's local key. That stays a UI
# step (Settings -> Devices & Services -> Add Integration -> Tuya Local). The
# pairing/one-local-connection/key-rotation gotchas live in
# appdata-templates/README.md. This script only puts the code in place.
set -eu

VERSION=2026.9.1
COMMIT=4551357adb34b6cf3073af8deada6a9bf13c94f0
SHA256=4395829bbdf32eb004a1aec991d4362d4cc461816aa82d46b0ceb09acd77dafc

HA_CFG=/volume1/docker/appdata/homeassistant
DEST="$HA_CFG/custom_components/tuya_local"
URL="https://codeload.github.com/make-all/tuya-local/tar.gz/$COMMIT"
DOCKER=/usr/local/bin/docker

[ "$(id -u)" = "0" ] || { echo "must run as root (sudo)"; exit 1; }

RESTART=yes
case "${1:-}" in
	--no-restart) RESTART=no ;;
	"") ;;
	*) echo "usage: $0 [--no-restart]"; exit 1 ;;
esac

# This NAS ships GNU tar 1.34 and sha256sum (verified 2026-09-16). It does NOT
# ship git or unzip. Do not rewrite this to use either.
for t in /usr/bin/curl /usr/bin/tar /usr/bin/sha256sum /bin/sed; do
	[ -x "$t" ] || { echo "ERROR: $t is missing"; exit 1; }
done

TMP=$(mktemp -d /tmp/tuya_local.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

echo "==> fetching $VERSION ($COMMIT)"
/usr/bin/curl -fsSL -o "$TMP/tuya_local.tar.gz" "$URL"

echo "==> verifying checksum"
echo "$SHA256  $TMP/tuya_local.tar.gz" | /usr/bin/sha256sum -c - >/dev/null \
	|| { echo "ERROR: checksum mismatch -- refusing to install"; exit 1; }

# codeload serves the WHOLE repository, laid out as
# tuya-local-<commit>/custom_components/tuya_local/. Strip the top directory and
# extract only the component, so nothing else (tests, .github, docs) lands in
# the HA config and so HA's core filenames are never scattered.
echo "==> extracting"
/usr/bin/tar -xzf "$TMP/tuya_local.tar.gz" -C "$TMP" --strip-components=1 \
	"tuya-local-$COMMIT/custom_components/tuya_local"
SRC="$TMP/custom_components/tuya_local"
[ -f "$SRC/manifest.json" ] \
	|| { echo "ERROR: extracted tree has no manifest.json"; exit 1; }

GOT=$(/bin/sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
	"$SRC/manifest.json" | head -1)
echo "    manifest version: $GOT"
[ "$GOT" = "$VERSION" ] \
	|| { echo "ERROR: manifest version $GOT != pinned $VERSION"; exit 1; }

if [ -d "$DEST" ]; then
	# The backup MUST NOT live under custom_components/. HA scans every
	# non-dot entry there and resolves each one's manifest `domain` -- so a
	# sibling backup resolves to the SAME domain as the live install and gets
	# discovered as a second copy of `tuya_local`. It does not error; it
	# silently dedupes, and which copy wins depends on readdir order. So the
	# backup goes to a sibling of custom_components/, which HA never scans.
	BAK_ROOT="$HA_CFG/custom_components.bak"
	BAK="$BAK_ROOT/tuya_local-$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$BAK_ROOT"
	echo "==> backing up existing install to $BAK"
	mv "$DEST" "$BAK"
fi

echo "==> installing to $DEST"
mkdir -p "$DEST"
cp -a "$SRC/." "$DEST/"
chown -R root:root "$DEST"
# a+rX, not a+r: directories need the execute bit to be traversable, and no
# data file here should ever be executable.
chmod -R a+rX "$DEST"
echo "    $(ls -1 "$DEST" | wc -l) entries"

if [ "$RESTART" = "yes" ]; then
	echo "==> restarting homeassistant"
	$DOCKER restart homeassistant >/dev/null
	# HA does NOT pip-install a custom integration's requirements merely because
	# it was discovered at startup -- it does so when the config flow is loaded,
	# i.e. when the operator opens Add Integration -> Tuya Local
	# (config_entries.py::_load_integration). So at this point tinytuya is
	# expected to be absent and that is not a failure; this only confirms
	# discovery. Verified 2026-09-16.
	sleep 30
	echo "==> verifying HA loaded it"
	if $DOCKER logs --tail 500 homeassistant 2>&1 \
			| grep -q "custom integration tuya_local"; then
		echo "    ok: HA reports the custom integration"
	else
		echo "    WARNING: no 'custom integration tuya_local' line in the tail."
		echo "    Inspect: $DOCKER logs --tail 200 homeassistant | grep -i tuya"
	fi
fi
echo "done."
