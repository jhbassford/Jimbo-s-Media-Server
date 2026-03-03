#!/bin/bash
# Pull latest files from NAS
set -e

echo "Pulling from NAS..."
ssh nas "cd /volume1/docker && tar czf - docker-compose.yml compose/" | tar xzf - --overwrite
echo "Done. Local files updated from NAS."
