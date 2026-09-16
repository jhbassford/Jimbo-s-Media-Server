"""Minimal read-only Google Health MCP server.

Holds a health-only OAuth token (scopes: googlehealth.nutrition.readonly +
googlehealth.activity_and_fitness.readonly) in its own credential volume and
exposes a handful of read tools to Hermes over streamable-HTTP.

WHY THIS IS ITS OWN CONTAINER (not folded into hermes-google-mcp):
  1. The Google Health API refuses any OAuth token that also carries
     Gmail/Calendar/Drive scopes (measured: 403 DISALLOWED_OAUTH_SCOPES), so the
     health grant cannot share the Workspace token.
  2. taylorwilsdon/google_workspace_mcp has no health tools and no config to add
     them; bolting them on means forking a pinned image.
  3. The Workspace container holds a send-capable Gmail token; a read-only health
     grant does not belong in that blast radius.
"""

import datetime as _dt
import os
import threading

import requests
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from mcp.server.fastmcp import FastMCP

TOKEN_PATH = os.environ.get("HEALTH_TOKEN_PATH", "/credentials/token.json")
BASE = "https://health.googleapis.com/v4"
SCOPES = [
    "https://www.googleapis.com/auth/googlehealth.nutrition.readonly",
    "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
]

mcp = FastMCP(
    "google-health",
    instructions=(
        "Read-only access to the operator's Google Health data (Fitbit/Pixel "
        "device metrics plus third-party apps that write to Health Connect, "
        "including MacroFactor nutrition and workouts). All data is the "
        "operator's own."
    ),
    host="0.0.0.0",
    port=int(os.environ.get("HEALTH_MCP_PORT", "8000")),
    stateless_http=True,
)

_lock = threading.Lock()
_creds = None


def _token():
    global _creds
    with _lock:
        if _creds is None:
            _creds = Credentials.from_authorized_user_file(TOKEN_PATH, SCOPES)
        if not _creds.valid:
            _creds.refresh(Request())
            try:
                with open(TOKEN_PATH, "w", encoding="utf-8") as f:
                    f.write(_creds.to_json())
            except OSError:
                pass
        return _creds.token


def _get(path, params=None):
    r = requests.get(
        BASE + path,
        params=params,
        headers={"Authorization": "Bearer " + _token(), "Accept": "application/json"},
        timeout=30,
    )
    if r.status_code >= 400:
        raise RuntimeError("health API %s %s: %s" % (r.status_code, path, r.text[:500]))
    return r.json()


def _list(datatype, inner, start, end, max_items, max_pages=40):
    """Page a data type newest-first, filtered to [start, end] (YYYY-MM-DD)."""
    params = {"page_size": "100" if datatype == "nutrition-log" else "25"}
    params["filter"] = '%s.interval.civil_start_time >= "%sT00:00:00"' % (inner, start)
    out, page_token, pages, use_filter = [], None, 0, True
    while True:
        p = dict(params)
        if page_token:
            p["pageToken"] = page_token
        try:
            body = _get("/users/me/dataTypes/%s/dataPoints" % datatype, p)
        except RuntimeError:
            if use_filter:
                use_filter = False
                params.pop("filter", None)
                out, page_token, pages = [], None, 0
                continue
            raise
        pts = body.get("dataPoints", [])
        out.extend(pts)
        page_token = body.get("nextPageToken")
        pages += 1
        if len(out) >= max_items:
            return out[:max_items]
        oldest = _civil(pts[-1].get(inner, {}).get("interval", {}) if pts else {})
        if oldest and oldest[:10] < start:
            break
        if not page_token or pages >= max_pages:
            break
    return [p for p in out if _in_range(_civil(p.get(inner, {}).get("interval", {})), start, end)][:max_items]


def _civil(iv):
    if not isinstance(iv, dict):
        return ""
    c = iv.get("civilStartTime")
    if isinstance(c, dict):
        d = c.get("date", {})
        t = c.get("time", {})
        return "%04d-%02d-%02dT%02d:%02d:%02d" % (
            d.get("year", 0), d.get("month", 0), d.get("day", 0),
            t.get("hours", 0), t.get("minutes", 0), t.get("seconds", 0))
    return (iv.get("startTime") or "")[:19]


def _in_range(ts, start, end):
    return bool(ts) and start <= ts[:10] <= end


def _src(dp):
    ds = dp.get("dataSource", {}) or {}
    app = ds.get("application", {}) or {}
    dev = ds.get("device", {}) or {}
    return {
        "platform": ds.get("platform"),
        "package": app.get("packageName"),
        "device": dev.get("displayName"),
    }


def _nutrient(n, name):
    for x in (n.get("nutrients") or []):
        if x.get("nutrient") == name:
            q = x.get("quantity") or {}
            return q.get("grams")
    return None


def _defaults(start, end):
    end = end or _dt.date.today().isoformat()
    if not start:
        start = (_dt.date.fromisoformat(end) - _dt.timedelta(days=7)).isoformat()
    return start, end


@mcp.tool()
def whoami() -> dict:
    """Return the Google/Fitbit identity this server is authorised as."""
    return {"identity": _get("/users/me/identity")}


@mcp.tool()
def list_nutrition_entries(start_date: str = "", end_date: str = "", max_items: int = 300) -> dict:
    """List logged food entries (time, food, calories, macros, source app).

    Dates are YYYY-MM-DD; omit for the last 7 days. MacroFactor entries have
    source.package == 'com.sbs.diet'.
    """
    start, end = _defaults(start_date, end_date)
    pts = _list("nutrition-log", "nutritionLog", start, end, max_items)
    items = []
    for p in pts:
        n = p.get("nutritionLog", {}) or {}
        items.append({
            "time": _civil(n.get("interval", {})),
            "food": n.get("foodDisplayName"),
            "meal": n.get("mealType"),
            "kcal": (n.get("energy") or {}).get("kcal"),
            "protein_g": _nutrient(n, "PROTEIN"),
            "carb_g": (n.get("totalCarbohydrate") or {}).get("grams"),
            "fat_g": (n.get("totalFat") or {}).get("grams"),
            "source": _src(p),
        })
    return {"start": start, "end": end, "count": len(items), "entries": items}


@mcp.tool()
def nutrition_daily_totals(start_date: str = "", end_date: str = "") -> dict:
    """Sum calories and macros per day for a date range (YYYY-MM-DD, last 7 days default)."""
    start, end = _defaults(start_date, end_date)
    pts = _list("nutrition-log", "nutritionLog", start, end, 5000, max_pages=80)
    days = {}
    for p in pts:
        n = p.get("nutritionLog", {}) or {}
        day = _civil(n.get("interval", {}))[:10]
        if not day:
            continue
        d = days.setdefault(day, {"date": day, "items": 0, "kcal": 0.0, "protein_g": 0.0,
                                  "carb_g": 0.0, "fat_g": 0.0})
        d["items"] += 1
        d["kcal"] += (n.get("energy") or {}).get("kcal") or 0.0
        d["protein_g"] += _nutrient(n, "PROTEIN") or 0.0
        d["carb_g"] += (n.get("totalCarbohydrate") or {}).get("grams") or 0.0
        d["fat_g"] += (n.get("totalFat") or {}).get("grams") or 0.0
    rows = []
    for d in sorted(days.values(), key=lambda x: x["date"]):
        for k in ("kcal", "protein_g", "carb_g", "fat_g"):
            d[k] = round(d[k], 1)
        rows.append(d)
    return {"start": start, "end": end, "days": rows}


@mcp.tool()
def list_workouts(start_date: str = "", end_date: str = "", max_items: int = 200) -> dict:
    """List workout/exercise sessions (time, type, duration, source).

    MacroFactor Workout sessions have source.package == 'com.sbs.train' but carry
    no per-exercise detail; Pixel Watch sessions have source.platform == 'FITBIT'
    and include metrics. Dates YYYY-MM-DD; omit for the last 30 days.
    """
    end = end_date or _dt.date.today().isoformat()
    start = start_date or (_dt.date.fromisoformat(end) - _dt.timedelta(days=30)).isoformat()
    pts = _list("exercise", "exercise", start, end, max_items)
    items = []
    for p in pts:
        e = p.get("exercise", {}) or {}
        iv = e.get("interval", {}) or {}
        items.append({
            "start": (iv.get("startTime") or "")[:19],
            "end": (iv.get("endTime") or "")[:19],
            "type": e.get("exerciseType"),
            "name": e.get("displayName"),
            "active_duration": e.get("activeDuration"),
            "metrics": e.get("metricsSummary") or {},
            "source": _src(p),
        })
    return {"start": start, "end": end, "count": len(items), "workouts": items}


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
