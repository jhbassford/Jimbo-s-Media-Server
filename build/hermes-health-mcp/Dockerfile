FROM python:3.11-slim

# Pinned to the exact versions already proven inside the Google Workspace MCP
# image (probed live 2026-09): mcp 1.28.1, google-auth 2.49.2, requests 2.33.1.
RUN pip install --no-cache-dir \
      "mcp==1.28.1" \
      "google-auth==2.49.2" \
      "requests==2.33.1" \
 && useradd -u 1100 -U -m -s /usr/sbin/nologin health

COPY health_mcp.py /app/health_mcp.py

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
USER 1100:1100
WORKDIR /app
ENTRYPOINT ["python", "/app/health_mcp.py"]
