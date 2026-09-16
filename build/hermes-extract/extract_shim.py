#!/usr/bin/env python3
"""Private readability extractor for Hermes — Tavily-shaped, trafilatura-backed.

WHY THIS EXISTS
Hermes' `web_extract` had no backend and fell through to the keyless
Firecrawl -> Exa ring, every call of which died as `403 Filtered` / curl exit 56
at the egress allowlist. This service is that backend, self-hosted.

WHY IT SPEAKS TAVILY'S API AND NOT FIRECRAWL'S
`web.extract_backend` accepts firecrawl, tavily, keenable, exa or parallel. Two
of those take a self-hosted base URL, and only ONE of them works in this
container:

  * `firecrawl` honours FIRECRAWL_API_URL, but the provider lazy-imports
    firecrawl-py==4.17.0 (tools/lazy_deps.py:50), which is NOT in the hermes
    image and CANNOT be installed there: /opt/hermes/.venv is read-only
    (`touch` -> EROFS, measured 2026-09-14) because the container runs
    read_only: true, and the only writable import path would be /opt/data --
    the agent's own mount. Putting an agent-writable directory on the agent's
    import path is strictly worse than the /opt/data/.local/bin PATH shadowing
    that was already removed from compose/hermes.yml.
  * `tavily` (plugins/web/tavily/provider.py) honours TAVILY_BASE_URL, posts
    with plain httpx -- a core dep that is already installed -- and needs
    nothing else.

So the Firecrawl API shape is off the table in this deployment regardless of
which server implements it. Tavily's is trivial by comparison: ONE endpoint.

THE CONTRACT WE MUST SATISFY (read off the pinned image, not a doc)
  POST {TAVILY_BASE_URL}/extract
       body    {"urls": [...], "include_images": false}
       headers Authorization: Bearer <TAVILY_API_KEY>, X-Client-Name: hermes-agent
  200  {"results":        [{"url","title","raw_content"}],
        "failed_results": [{"url","error"}]}

`_normalize_tavily_documents` reads `raw_content` first and falls back to
`content`; `failed_results[].error` becomes the per-URL error the model sees.
Non-2xx raises ValueError with the BODY attached, which surfaces to the model
verbatim -- so per-URL problems must come back as 200 + failed_results, and a
non-2xx is reserved for whole-call failures. The provider's httpx timeout is 60s
for the WHOLE BATCH, not per URL, hence the concurrency and the wall-clock cap.

SSRF: THE POINT OF THE WHOLE DESIGN
SearXNG queries two fixed engines. This service fetches whatever URL the agent
hands it, which makes it SSRF-as-a-service for a prompt-injected Hermes unless
it is contained. The agent-side gate does NOT contain it -- measured 2026-09-14
inside the hermes container:

    is_safe_url("http://192.168.1.104:5000/") -> False   (literal IP)
    is_safe_url("http://localtest.me/")       -> True    (resolves to 127.0.0.1)

tools/url_safety.py:283 returns True when DNS fails AND a proxy is configured,
delegating resolution to the proxy. Hermes' DNS is deliberately blocked, so that
branch is ALWAYS taken and every hostname is waved through. Only literal private
IPs are stopped.

Therefore, two layers, and this file is the WEAKER one:
  * POLICY (here): resolve every hop, reject unless EVERY answer is a public
    address, then connect to the vetted IP with Host + TLS SNI set to the
    original name so there is no rebinding window between check and fetch.
  * ENFORCEMENT (/volume1/docker/scripts/hermes-firewall.sh): DROP from this
    container's IP to all of RFC1918, loopback, link-local, CGNAT and the
    reserved ranges. A bug in this file therefore costs a timeout, not a breach.

WHAT IT READS
HTML via trafilatura (markdown out, comment threads stripped) and PDF via pypdf.
PDFs are here because vendor datasheets, specs and standards are PDFs: without
them the agent burned minutes per question hunting web.archive.org for an HTML
mirror of a Synology spec sheet. pypdf is plain text extraction -- no layout
reconstruction and no OCR -- so a scanned-image PDF returns nothing, and that is
reported as such rather than as an empty success. Everything else (images,
archives, video) is refused by content-type.

This process holds NO credentials of any kind. That is deliberate: it parses
hostile HTML and hostile PDFs, both with C-backed parsers, so it is assumed
exploitable, and there is nothing here to steal.
"""

import ipaddress
import json
import logging
import os
import socket
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from urllib.parse import unquote, urljoin, urlsplit, urlunsplit

import httpx
import trafilatura
from pypdf import PdfReader

try:  # top-level export in trafilatura 2.x; submodule in 1.x
    from trafilatura import extract_metadata
except ImportError:  # pragma: no cover
    from trafilatura.metadata import extract_metadata

PORT = int(os.environ.get("EXTRACT_PORT", "8080"))
MAX_URLS = int(os.environ.get("EXTRACT_MAX_URLS", "10"))
MAX_BYTES = int(os.environ.get("EXTRACT_MAX_BYTES", str(4 * 1024 * 1024)))
# PDFs get a bigger byte cap than HTML because they legitimately are bigger --
# vendor datasheets run 1-3 MB and a truncated PDF does not parse at all, it
# just fails. Separate knob so raising it does not also hand lxml a 12 MB
# document, which is the more dangerous of the two parsers to overfeed.
MAX_PDF_BYTES = int(os.environ.get("EXTRACT_MAX_PDF_BYTES", str(12 * 1024 * 1024)))
# Page ceiling, because text extraction is CPU-bound and this is a 4-core J4125
# shared with Plex transcodes. A 500-page manual is not what web_extract is for.
MAX_PDF_PAGES = int(os.environ.get("EXTRACT_MAX_PDF_PAGES", "50"))
PER_URL_TIMEOUT = float(os.environ.get("EXTRACT_TIMEOUT", "20"))
# Hermes' own httpx timeout is 60s for the whole batch. Stop well short of it so
# the model gets our structured failed_results instead of an opaque ReadTimeout.
BATCH_DEADLINE = float(os.environ.get("EXTRACT_BATCH_DEADLINE", "45"))
MAX_REDIRECTS = int(os.environ.get("EXTRACT_MAX_REDIRECTS", "3"))
CONCURRENCY = int(os.environ.get("EXTRACT_CONCURRENCY", "4"))
USER_AGENT = os.environ.get(
    "EXTRACT_USER_AGENT",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
)

_SCHEMES = ("http", "https")
_HTML_HINTS = ("text/html", "application/xhtml", "text/plain", "application/xml", "text/xml")
# application/octet-stream is accepted because plenty of servers hand out PDFs
# under it (and Synology's own datasheet CDN is one of them). It is NOT a
# general "fetch any binary" opening: the body is sniffed for the %PDF- magic
# below and anything else is refused, so the exposure is a capped download that
# gets thrown away.
_PDF_HINTS = ("application/pdf", "application/x-pdf", "application/octet-stream")
_PDF_MAGIC = b"%PDF-"

logging.basicConfig(
    level=logging.INFO, stream=sys.stdout, format="%(asctime)s %(levelname)s %(message)s"
)
log = logging.getLogger("hermes-extract")


class UnsafeTarget(Exception):
    """A URL that must never be fetched. The message reaches the model."""


def _addr_is_public(ip):
    """True only for globally routable unicast.

    ``is_global`` already excludes RFC1918, loopback, link-local, 0.0.0.0/8,
    240.0.0.0/4 AND the 100.64.0.0/10 CGNAT range (which matters here: this
    house is behind CGNAT, so a neighbour's address is not "the internet").
    The multicast/reserved checks are belt-and-braces against ``is_global``
    semantics shifting between Python releases.
    """
    return ip.is_global and not ip.is_multicast and not ip.is_reserved


def _resolve_public(host, port):
    """Every A/AAAA answer for *host*, or UnsafeTarget if ANY of them is not public.

    Fails on ANY bad answer rather than filtering them out: a host that returns
    one public and one private address is the textbook DNS-rebinding shape, and
    there is no legitimate page behind it.
    """
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror as exc:
        raise UnsafeTarget(f"DNS resolution failed for {host}: {exc}") from None
    addrs = []
    for *_, sockaddr in infos:
        ip = ipaddress.ip_address(sockaddr[0])
        if not _addr_is_public(ip):
            raise UnsafeTarget(
                f"Blocked: {host} resolves to the non-public address {ip}. "
                "This extractor may only reach the public internet."
            )
        addrs.append(ip)
    if not addrs:
        raise UnsafeTarget(f"Blocked: {host} did not resolve to any address")
    return addrs


def _pinned_request_parts(url):
    """(pinned_url, host_header, sni_host) with the connection nailed to a vetted IP.

    Resolving and then handing httpx the HOSTNAME would re-resolve and reopen the
    rebinding window. Connecting to the literal IP while keeping Host and TLS SNI
    on the real name closes it: certificate verification still runs against the
    name, because httpx passes the ``sni_hostname`` extension through to the TLS
    handshake's server_hostname.
    """
    parts = urlsplit(url)
    if parts.scheme not in _SCHEMES:
        raise UnsafeTarget(f"Blocked: unsupported URL scheme '{parts.scheme or ''}'")
    host = parts.hostname
    if not host:
        raise UnsafeTarget("Blocked: URL has no host")
    port = parts.port or (443 if parts.scheme == "https" else 80)
    ip = _resolve_public(host, port)[0]
    literal = f"[{ip}]" if ip.version == 6 else str(ip)
    # Strip any userinfo before it reaches the Host header.
    authority = parts.netloc.rsplit("@", 1)[-1]
    pinned = urlunsplit((parts.scheme, f"{literal}:{port}", parts.path or "/", parts.query, ""))
    return pinned, authority, host


def _fetch(client, url, deadline):
    """Fetch *url*, following redirects by hand so every hop is re-vetted.

    httpx's own follow_redirects would resolve and connect to the redirect target
    without going back through _resolve_public -- an open redirect on a public
    site would then be a free pass into 192.168/16.
    """
    for _hop in range(MAX_REDIRECTS + 1):
        if time.monotonic() > deadline:
            raise UnsafeTarget("Batch deadline exceeded before this URL completed")
        pinned, authority, sni = _pinned_request_parts(url)
        headers = {
            "Host": authority,
            "User-Agent": USER_AGENT,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en;q=0.9",
        }
        with client.stream(
            "GET", pinned, headers=headers, extensions={"sni_hostname": sni}
        ) as response:
            if response.is_redirect:
                location = response.headers.get("location", "")
                if not location:
                    raise UnsafeTarget(f"HTTP {response.status_code} redirect with no Location")
                url = urljoin(url, location)
                continue
            if response.status_code >= 400:
                raise UnsafeTarget(f"HTTP {response.status_code} from {url}")
            ctype = response.headers.get("content-type", "").lower()
            is_pdf = any(h in ctype for h in _PDF_HINTS)
            if ctype and not is_pdf and not any(h in ctype for h in _HTML_HINTS):
                raise UnsafeTarget(f"Refusing non-document content-type '{ctype.split(';')[0]}'")
            # PDFs get the larger cap; HTML keeps the tighter one.
            cap = MAX_PDF_BYTES if is_pdf else MAX_BYTES
            body, truncated = bytearray(), False
            for chunk in response.iter_bytes():
                body += chunk
                if len(body) > cap:
                    log.info("truncating %s at %d bytes", url, cap)
                    truncated = True
                    break
            encoding = response.charset_encoding or "utf-8"
        # Bytes, not text: the PDF path needs the raw stream. Decoding is the
        # HTML renderer's job now.
        return url, bytes(body), encoding, ctype, truncated
    raise UnsafeTarget(f"Too many redirects (>{MAX_REDIRECTS})")


def _pdf_fallback_title(url):
    """A PDF with no /Title metadata still deserves a label: use its filename."""
    name = unquote(urlsplit(url).path.rsplit("/", 1)[-1])
    return name or "PDF document"


def _render_pdf(body, url, truncated):
    """(title, text) from a PDF.

    Vendor specs, datasheets and standards are PDFs, and refusing them sent the
    agent on multi-minute detours through web.archive.org looking for an HTML
    mirror. pypdf is pure-python text extraction: no layout reconstruction, no
    OCR. A scanned-image PDF therefore yields nothing, which is reported as
    such rather than as an empty success.
    """
    if truncated:
        # Worth its own message: a truncated PDF does not parse partially, it
        # just fails, and "invalid PDF" would send someone debugging the wrong end.
        raise UnsafeTarget(
            f"PDF exceeded the {MAX_PDF_BYTES // (1024 * 1024)} MB fetch cap and was truncated, "
            "so it cannot be parsed"
        )
    try:
        reader = PdfReader(BytesIO(body), strict=False)
        if reader.is_encrypted:
            # An empty user password is the common "restricted, not secret" case.
            # Anything else needs `cryptography`, which is deliberately not installed.
            try:
                if not reader.decrypt(""):
                    raise UnsafeTarget("PDF is password-protected")
            except UnsafeTarget:
                raise
            except Exception:  # noqa: BLE001 — unsupported cipher, same outcome
                raise UnsafeTarget("PDF uses an unsupported encryption scheme") from None
        total = len(reader.pages)
        pages = [(p.extract_text() or "") for p in reader.pages[:MAX_PDF_PAGES]]
    except UnsafeTarget:
        raise
    except Exception as exc:  # noqa: BLE001 — malformed PDFs are routine
        raise UnsafeTarget(f"Could not parse PDF: {type(exc).__name__}: {exc}") from None

    text = "\n\n".join(p for p in pages if p.strip())
    if text and total > MAX_PDF_PAGES:
        text += f"\n\n[truncated: read {MAX_PDF_PAGES} of {total} pages]"
    title = ""
    try:
        title = (reader.metadata.title or "") if reader.metadata else ""
    except Exception as exc:  # noqa: BLE001 — a missing title is not a failure
        log.debug("PDF metadata read failed for %s: %s", url, exc)
    return (title.strip() or _pdf_fallback_title(url)), text


def _render_html(html, url):
    """(title, markdown). Falls back to plain text if this trafilatura lacks markdown."""
    kwargs = dict(
        url=url,
        include_comments=False,  # comment threads are noise AND injection surface
        include_tables=True,
        include_links=True,
        favor_recall=True,
    )
    try:
        text = trafilatura.extract(html, output_format="markdown", **kwargs)
    except (TypeError, ValueError):  # markdown output landed in trafilatura 1.9
        text = trafilatura.extract(html, output_format="txt", **kwargs)
    title = ""
    try:
        meta = extract_metadata(html, default_url=url)
        title = (getattr(meta, "title", "") or "") if meta else ""
    except Exception as exc:  # noqa: BLE001 — a missing title is not a failure
        log.debug("metadata extraction failed for %s: %s", url, exc)
    return title, text or ""


def _extract_one(client, url, deadline):
    """Never raises. Returns ("ok", doc) or ("failed", {url, error})."""
    try:
        final_url, body, encoding, ctype, truncated = _fetch(client, url, deadline)
        # Sniff the magic bytes rather than trusting Content-Type: servers mislabel
        # PDFs as octet-stream, and a page that merely CLAIMS to be a PDF must not
        # be handed to pypdf.
        if body[:5] == _PDF_MAGIC:
            title, text = _render_pdf(body, final_url, truncated)
            empty = "No extractable text in this PDF (it is most likely a scanned image; there is no OCR here)"
        elif any(h in ctype for h in _PDF_HINTS) and "html" not in ctype:
            raise UnsafeTarget(f"Content-Type said '{ctype.split(';')[0]}' but the body is not a PDF")
        else:
            title, text = _render_html(body.decode(encoding, errors="replace"), final_url)
            empty = "No extractable article content on this page"
        if not text.strip():
            return "failed", {"url": final_url, "error": empty}
        log.info("extracted %d chars from %s", len(text), final_url)
        return "ok", {"url": final_url, "title": title, "raw_content": text, "content": text}
    except UnsafeTarget as exc:
        log.info("refused %s: %s", url, exc)
        return "failed", {"url": url, "error": str(exc)}
    except Exception as exc:  # noqa: BLE001 — a bad page must not kill the batch
        log.warning("failed %s: %s: %s", url, type(exc).__name__, exc)
        return "failed", {"url": url, "error": f"{type(exc).__name__}: {exc}"}


def extract_batch(urls):
    deadline = time.monotonic() + BATCH_DEADLINE
    results, failed = [], []
    limits = httpx.Limits(max_connections=CONCURRENCY, max_keepalive_connections=0)
    # trust_env=False: this container is deliberately NOT behind the egress
    # allowlist proxy (it must reach arbitrary public hosts), and an inherited
    # *_proxy variable would silently route every fetch somewhere unintended.
    with httpx.Client(
        timeout=PER_URL_TIMEOUT, limits=limits, trust_env=False, follow_redirects=False
    ) as client:
        with ThreadPoolExecutor(max_workers=CONCURRENCY) as pool:
            for status, payload in pool.map(lambda u: _extract_one(client, u, deadline), urls):
                (results if status == "ok" else failed).append(payload)
    return {"results": results, "failed_results": failed}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "hermes-extract"
    sys_version = ""

    def log_message(self, fmt, *args):  # route access logs through our logger
        log.info("%s %s", self.address_string(), fmt % args)

    def _send(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?")[0] == "/healthz":
            return self._send(200, {"status": "ok"})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.split("?")[0] != "/extract":
            return self._send(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length) or b"{}")
            urls = payload.get("urls")
            if isinstance(urls, str):
                urls = [urls]
            urls = [u for u in (urls or []) if isinstance(u, str) and u.strip()]
        except (ValueError, TypeError) as exc:
            # Whole-call failure -> non-2xx, which the provider turns into a
            # ValueError carrying this body. Per-URL problems never come here.
            return self._send(400, {"error": f"Malformed request body: {exc}"})
        if not urls:
            return self._send(400, {"error": "No usable URLs in request"})
        if len(urls) > MAX_URLS:
            urls = urls[:MAX_URLS]
        self._send(200, extract_batch(urls))


def main():
    log.info(
        "hermes-extract on :%d (max_urls=%d max_bytes=%d pdf_max_bytes=%d pdf_max_pages=%d "
        "per_url_timeout=%.0fs batch_deadline=%.0fs)",
        PORT, MAX_URLS, MAX_BYTES, MAX_PDF_BYTES, MAX_PDF_PAGES, PER_URL_TIMEOUT, BATCH_DEADLINE,
    )
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
