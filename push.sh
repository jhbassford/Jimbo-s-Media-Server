#!/bin/bash
# Push local changes to NAS
set -e

echo "Pushing to NAS..."
tar czf - docker-compose.yml compose/ | ssh nas "tar xzf - -C /volume1/docker/"
echo "Done. Files updated on NAS."
