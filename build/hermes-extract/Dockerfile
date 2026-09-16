FROM python:3.12-slim

# Built 2026-09-14 from python:3.12-slim (trafilatura 2.2.0 / httpx 0.28.1 /
# pypdf 6.18.1, which resolve lxml 6.1.3).
# Versions are pinned exactly, and the pins were READ BACK from a real build on
# this NAS rather than guessed -- see appdata-templates/README.md for the
# discover-then-pin procedure. Re-read them on any rebuild.
#
# Three runtime deps. trafilatura pulls lxml (the actual HTML parser) plus
# courlan/htmldate/justext; httpx is the fetcher; pypdf reads PDFs, because
# vendor datasheets and standards are PDFs and refusing them sent the agent on
# multi-minute detours through web.archive.org hunting for an HTML mirror.
# pypdf is pure python and pulls NOTHING -- in particular not `cryptography`,
# so AES-encrypted PDFs are refused rather than silently adding a large C
# dependency to a container whose whole job is parsing hostile input.
# Deliberately NO fastapi / starlette / pydantic: the API surface is one POST
# endpoint and http.server covers it.
RUN pip install --no-cache-dir \
      "trafilatura==2.2.0" \
      "httpx==0.28.1" \
      "pypdf==6.18.1" \
 && useradd -u 1101 -U -m -s /usr/sbin/nologin extract

COPY extract_shim.py /app/extract_shim.py

# HOME + TMPDIR land on the tmpfs: the rootfs is read_only in compose, and
# trafilatura's dependencies (htmldate, dateparser) want a writable HOME.
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 HOME=/tmp TMPDIR=/tmp
USER 1101:1101
WORKDIR /app
ENTRYPOINT ["python", "/app/extract_shim.py"]
