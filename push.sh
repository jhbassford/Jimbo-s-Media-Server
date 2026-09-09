#!/bin/bash
# Push local changes to NAS
set -e

echo "Pushing to NAS..."
# --exclude='*.bak-*': compose/udms/ accumulates NAS-side backup artifacts
# (e.g. *.bak-20260908). They are gitignored, but this tar reads the WORKING
# TREE, not git, so without the exclude they are re-pushed to the NAS on every
# deploy — stale copies of live service definitions sitting next to the real
# ones. Note: push.sh syncs ONLY docker-compose.yml and compose/; anything in
# appdata-templates/ must be delivered to the NAS separately (see its README).
tar czf - --exclude='*.bak-*' docker-compose.yml compose/ | ssh nas "tar xzf - -C /volume1/docker/"
echo "Done. Files updated on NAS."
