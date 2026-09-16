#!/usr/bin/env python3
"""Daily 'Beat the Day' message -- LIVE read from PocketSmith.

Operator-authorized exemption, 2026-09-11. See ENVIRONMENT.md §3.

READ-ONLY BY CONSTRUCTION. The only PocketSmith MCP tool this script can call is
`list_transactions`, hardcoded in TOOL below and checked against ALLOWED_TOOLS.
No tool name, endpoint or MCP argument is taken from the environment, a file or
the network. It must never call a mutating tool (create_*, update_*, delete_*,
assign_*).

TOKEN HANDLING. The MCP access token expires hourly and no agent runs at fire
time, so this script refreshes it via the stored refresh token (public PKCE
client, no secret) and writes the rotated token back to Hermes' cache. Without
this the job would fail at 07:00 on its first run.

HONEST CAVEAT -- this is honor-system, not a capability boundary. The stored
token is full-access (66 tools, writes and deletes included); the script file
itself lives in /opt/data, the agent's own writable mount. Nothing but this code
and the sentence in ENVIRONMENT.md stops a rewrite. Recorded as such on purpose.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, timedelta

BASE = "/opt/data/pocketsmith-daily"
sys.path.insert(0, BASE)

import psclient  # noqa: E402
from pull_transactions import parse_page  # noqa: E402

TOKEN_PATH = "/opt/data/mcp-tokens/pocketsmith.json"
CLIENT_PATH = "/opt/data/mcp-tokens/pocketsmith.client.json"
TOKEN_URL = "https://mcp.pocketsmith.com/oauth/token"
USER_AGENT = "Hermes-Agent/0.21.1"

# The one and only tool this script may invoke. Hardcoded; never parameterised.
TOOL = "list_transactions"
ALLOWED_TOOLS = ("list_transactions",)

USER_ID = 324826          # hardcoded so no get_current_user call is needed
LOOKBACK_DAYS = 90

CFG_PATH = BASE + "/config.json"
AUDIT_PATH = BASE + "/audit.log"

ICONS = {
    "Eating Out": "\U0001f37d", "Alcohol & Bars": "\U0001f37a",
    "Entertainment": "\U0001f3ac", "Recreation": "\U0001f579",
    "Hobbies": "\U0001f3a8", "Shopping": "\U0001f6cd", "Clothing": "\U0001f455",
    "Electronics": "\U0001f50c", "Gifts": "\U0001f381", "Media": "\U0001f4bf",
    "Personal Care": "\U0001f9f4", "Cash Withdrawal": "\U0001f4b5",
    "Online Services": "\u2601\ufe0f", "Dues and Subscriptions": "\U0001f501",
    "Computing": "\U0001f4bb", "Travel": "\U0001f687", "Groceries": "\U0001f6d2",
}


def money(x):
    return "$%s" % format(round(x, 2), ",.2f")


def refresh_if_needed():
    """Return a valid access token, refreshing it in place when near expiry."""
    with open(TOKEN_PATH) as fh:
        blob = json.load(fh)
    if float(blob.get("expires_at") or 0) > time.time() + 120:
        return blob["access_token"]

    with open(CLIENT_PATH) as fh:
        client_id = json.load(fh)["client_id"]
    body = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": blob["refresh_token"],
        "client_id": client_id,
    }).encode()
    req = urllib.request.Request(
        TOKEN_URL, data=body, method="POST",
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        })
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            new = json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        raise SystemExit("token refresh failed: HTTP %s: %s"
                         % (exc.code, exc.read().decode("utf-8", "replace")[:500]))
    if not new.get("access_token"):
        raise SystemExit("token refresh returned no access_token")

    blob["access_token"] = new["access_token"]
    if new.get("refresh_token"):
        blob["refresh_token"] = new["refresh_token"]
    blob["token_type"] = new.get("token_type", blob.get("token_type"))
    blob["expires_in"] = new.get("expires_in")
    blob["expires_at"] = time.time() + float(new.get("expires_in") or 3600)
    tmp = TOKEN_PATH + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(blob, fh)
    os.replace(tmp, TOKEN_PATH)
    os.chmod(TOKEN_PATH, 0o600)
    return blob["access_token"]


def fetch_day(iso):
    """The single hardcoded PocketSmith call: list_transactions for one day."""
    assert TOOL in ALLOWED_TOOLS
    text = psclient.call_tool(TOOL, {
        "user_id": USER_ID,
        "start_date": iso,
        "end_date": iso,
        "per_page": 100,
        "page": 1,
    })
    page, pages, total, items = parse_page(text)
    if items is None:
        raise SystemExit("could not parse list_transactions response: %s"
                         % text[:300])
    if pages and pages > 1:
        raise SystemExit("list_transactions returned %d pages for one day; "
                         "refusing to report a truncated total" % pages)
    return items, (total if total is not None else len(items))


def sum_discretionary(rows):
    cfg = json.load(open(CFG_PATH))
    include = set(cfg["profiles"][cfg["active_profile"]]["include"])
    exclude = set(cfg["exclude_categories"])
    total = 0.0
    n = 0
    cats = {}
    for t in rows:
        cat = t.get("category") or {}
        title = cat.get("title")
        if (bool(cat.get("is_transfer")) or bool(t.get("is_transfer"))
                or (title or "") in exclude or title not in include):
            continue
        amt = t.get("amount_in_base_currency")
        if amt is None:
            amt = t.get("amount") or 0.0
        if t.get("type") == "debit":
            total += abs(amt)
            n += 1
        else:
            total -= abs(amt)
        cats[title] = cats.get(title, 0.0) + (abs(amt) if t.get("type") == "debit"
                                              else -abs(amt))
    return max(total, 0.0), n, cats


def build_message(target_iso, total, n, cats):
    nice = "%s %s" % (date.fromisoformat(target_iso).strftime("%a"),
                      date.fromisoformat(target_iso).strftime("%-d %b %Y"))
    if total <= 0:
        return ("\U0001f3c6 *Beat the Day* -- %s\n\n"
                "You spent *%s* on discretionary stuff that day. It's basically "
                "a free win -- just don't spend anything today. \U0001fae1"
                % (nice, money(0.0)))
    lines = ["\u2615 *Beat the Day*", ""]
    lines.append("On this day %d days ago -- *%s* -- your discretionary spend "
                 "was *%s* (%d transaction%s)."
                 % (LOOKBACK_DAYS, nice, money(total), n, "" if n == 1 else "s"))
    lines.append("")
    lines.append("\U0001f3af *Today's target: beat %s*" % money(total))
    lines.append("")
    top = sorted([(c, a) for c, a in cats.items() if a > 0], key=lambda kv: -kv[1])[:4]
    if top:
        lines.append("What that day looked like:")
        width = max(len(c) for c, _ in top)
        for cat, amt in top:
            lines.append("  %s %s  %s" % (ICONS.get(cat, "\u2022"),
                                          cat.ljust(width), money(amt)))
    return "\n".join(lines)


def write_audit(target_iso, rows_returned, included, total):
    line = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "job": "dba824ba9601",
        "tool": TOOL,
        "date_range": "%s..%s" % (target_iso, target_iso),
        "rows_returned": rows_returned,
        "rows_included": included,
        "total": round(total, 2),
    }
    with open(AUDIT_PATH, "a") as fh:
        fh.write(json.dumps(line, sort_keys=True) + "\n")


def main():
    refresh_if_needed()
    target = date.today() - timedelta(days=LOOKBACK_DAYS)
    iso = target.isoformat()
    rows, rows_returned = fetch_day(iso)
    total, n, cats = sum_discretionary(rows)
    write_audit(iso, rows_returned, n, total)
    print(build_message(iso, total, n, cats))


if __name__ == "__main__":
    main()
