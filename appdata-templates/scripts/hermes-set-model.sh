#!/bin/sh
# =============================================================================
# hermes-set-model - change the agent's default model
# =============================================================================
# HOST PATH: /volume1/docker/scripts/hermes-set-model.sh   (root:root 0750)
# SOURCE OF TRUTH: appdata-templates/scripts/ in git.
#
#   sudo /volume1/docker/scripts/hermes-set-model.sh deepseek/deepseek-v4.1-flash
#
# WHY THIS EXISTS
# The dashboard's model picker CANNOT persist a change. config.yaml is bind
# mounted read-only at /opt/data/config.yaml, so Hermes' atomic write fails:
#   os.replace -> Errno 16 (Device or resource busy, cannot replace a bind mount)
#   copyfile   -> Errno 30 (Read-only file system)
# That is deliberate, not a bug. config.yaml holds every containment guardrail
# (approvals.*, security.*, skills.*, tool_loop_guardrails.*). If the agent
# could rewrite it, those guardrails would be advisory rather than enforced --
# review finding C3. The cost is that legitimate config changes are an operator
# action on the host. This script is that action, made cheap.
#
# Note the second leg of C3 is independently closed: `hermes` is excluded from
# the socket proxy's restart allowlist, so even a rewritten config could not be
# reloaded by the agent itself.
#
# Model changes are NOT free-form: the model is validated against OpenRouter's
# live catalogue first, because a typo here fails at runtime with a confusing
# provider error rather than at config time.
set -eu

CFG=/volume1/docker/appdata/hermes-etc/config.yaml
DOCKER=/usr/local/bin/docker
PROXY=192.168.92.2:8888

[ "$(id -u)" = "0" ] || { echo "must run as root (sudo)"; exit 1; }
[ $# -eq 1 ] || { echo "usage: $0 <model-id>   e.g. deepseek/deepseek-v4.1-flash"; exit 1; }
MODEL=$1

echo "==> validating '$MODEL' against OpenRouter's live catalogue"
# Queried through the agent's own egress proxy, so this also proves the model is
# reachable by the path the agent will actually use.
if ! $DOCKER run --rm --network hermes_net curlimages/curl:8.8.0 \
        -s --max-time 30 -x "$PROXY" https://openrouter.ai/api/v1/models 2>/dev/null \
     | grep -q "\"id\":\"$MODEL\""; then
	echo "ERROR: '$MODEL' is not in OpenRouter's catalogue (or the egress proxy is down)."
	echo "       List candidates with:"
	echo "         $DOCKER run --rm --network hermes_net curlimages/curl:8.8.0 \\"
	echo "           -s -x $PROXY https://openrouter.ai/api/v1/models | grep -o '\"id\":\"[^\"]*\"'"
	exit 1
fi
echo "    ok, model exists"

# A model being IN the catalogue does not mean your account may use it: an
# endpoint can be filtered out by OpenRouter privacy settings (e.g. "paid model
# training violation"), which returns a 404 at call time, not at config time.
# Warn rather than block -- availability can differ per endpoint.
echo "==> checking your account can actually reach it"
KEY=$(grep -m1 '^OPENROUTER_API_KEY=' /volume1/docker/appdata/hermes-etc/hermes.env | cut -d= -f2- || true)
if [ -n "${KEY:-}" ]; then
	RESP=$($DOCKER run --rm --network hermes_net curlimages/curl:8.8.0 \
		-s --max-time 40 -x "$PROXY" https://openrouter.ai/api/v1/chat/completions \
		-H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
		-d "{\"model\":\"$MODEL\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" 2>/dev/null || true)
	case "$RESP" in
		*'"error"'*) echo "    WARNING: a test call was refused:"; echo "$RESP" | head -c 400; echo;
		             echo "    Continuing anyway - fix at https://openrouter.ai/settings/privacy if this is a policy block." ;;
		*)           echo "    ok, test call succeeded" ;;
	esac
else
	echo "    (no API key found; skipping the live call)"
fi

echo "==> backing up and updating config.yaml"
cp -a "$CFG" "$CFG.bak-$(date +%Y%m%d-%H%M%S)"
python3 - "$CFG" "$MODEL" <<'PY'
import re, sys
cfg, model = sys.argv[1], sys.argv[2]
s = open(cfg).read()
new, n = re.subn(r'(?m)^(  default: ").*(")$', lambda m: m.group(1) + model + m.group(2), s, count=1)
if n != 1:
    sys.exit("ERROR: could not find the model.default line in config.yaml; not writing")
open(cfg, 'w').write(new)
print("    set model.default =", model)
PY
chown root:root "$CFG"; chmod 0644 "$CFG"

echo "==> restarting hermes"
$DOCKER restart hermes >/dev/null
sleep 20

echo "==> verifying"
GOT=$($DOCKER exec -u 1000:10 hermes hermes config get model.default 2>/dev/null | tail -1 | tr -d '\r')
echo "    model.default is now: $GOT"
[ "$GOT" = "$MODEL" ] || { echo "ERROR: config did not take effect"; exit 1; }
echo "done."
