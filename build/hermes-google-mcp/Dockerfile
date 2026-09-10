# Derived from the pinned upstream image, adding ONE thing: PySocks.
#
# WHY: httplib2 (which google-api-python-client uses for every Google API call)
# has NO proxy support unless PySocks is importable -- `httplib2.socks` is None
# in the upstream image. Without it httplib2 silently ignores HTTPS_PROXY,
# attempts a DIRECT connection, needs DNS, and fails with
# "Unable to find the server at www.googleapis.com" -- because external DNS is
# blocked for this container by design.
#
# Measured on the upstream image: the OAuth token exchange (requests/oauthlib)
# SUCCEEDS through the proxy, then the userinfo fetch (httplib2) fails on DNS.
# Every Google API tool call would have failed the same way.
#
# The alternatives were all worse: allowing DNS + direct egress would make the
# domain allowlist unenforceable for the one container holding a send-capable
# Gmail token, and pinning Google's IP ranges in iptables is not maintainable.
# Adding the missing dependency preserves the boundary instead of trading it away.
#
# The venv is uv-managed and ships NO pip, so uv is used to install into it.
FROM ghcr.io/taylorwilsdon/google_workspace_mcp@sha256:0ce26298d707ee1e213ca3c51ef814287b8d8c9c2a0abd9494f95f2adc07bc1d
USER root
RUN uv pip install --python /app/.venv/bin/python --no-cache "PySocks==1.7.1" \
 && /app/.venv/bin/python -c "import httplib2; assert httplib2.socks is not None, 'PySocks still not wired into httplib2'; print('httplib2 proxy support OK')"
USER app
