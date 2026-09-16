# Hermes Health Data — Google Health API Feasibility Spike

Date: 2026-09-10
Status: Ready to run
Supersedes nothing. Extends `2026-09-10-hermes-google-workspace-design.md`.

## 1. The one question

Does MacroFactor's nutrition and workout data — written to **Health Connect**
on the Pixel — reach Google's **cloud** datastore and become readable through
the **Google Health API**? Or does it stay on-device, in which case the answer
is the Tasker/Health Connect path instead?

This spike answers it empirically in one sitting. It builds nothing and touches
no running service.

## 2. What the documentation actually says

Earlier reading of the data-type pages suggested Health Connect was *not* a
source. The **Endpoints** page contradicts that, and this is the reason the
spike is worth running:

- `dataSourceFamily = users/me/dataSourceFamilies/all-sources` (the **default**)
  "Returns data points reconciled across all registered first-party (1P) and
  third-party (3P) data sources. **Third-party app data will be returned with
  this option**."
- `dataSourceFamily = users/me/dataSourceFamilies/google-sources` "includes
  physical tracker device records, **data from Health Connect**, and any manual
  entries logged through first-party apps (such as the Fitbit app or Google Fit)."

Against that:

- Data-availability text says updates appear only after "you sync your activity
  tracker or manually enter new data into the Fitbit mobile or web app".
- Every data type's "compatible devices" list is Fitbit hardware + Pixel Watch.

So the docs name both Health Connect and third-party app data **and** describe a
device-first sync. They do not agree, which means the only answer is a
measurement. That is this spike.

## 3. Capability surface being probed

Scope prefix is `https://www.googleapis.com/auth/googlehealth` + the suffix.

| Need | data type (path) | filter name | operations | scope |
|---|---|---|---|---|
| Nutrition | `nutrition-log` | `nutrition_log` | list, get, reconcile, rollUp, dailyRollUp | `.nutrition.readonly` |
| Workouts | `exercise` | `exercise` | list, get, reconcile | `.activity_and_fitness.readonly` |
| Who am I | `identity` | — | get | `googlehealth.profile.readonly`? (see note) |

Notes:
- Data type is **kebab-case in the URL, snake_case in `filter`**.
- `exercise` and `sleep` list page size is capped at **25**; everything else 10,000.
- `dataSourceFamily` is a **query param** for `reconcile`, a **body field** for
  `rollUp`/`dailyRollUp`. `list` may not honour it — if not, use `reconcile`.
- `getIdentity` may work under the two scopes above; if it 403s, that is not a
  failure of the spike, just skip it.

## 4. Ground truth to capture first (on the phone)

Without this there is nothing to compare the API response against.

1. **MacroFactor** — pick and record one recent, unambiguous day: total
   calories + macros (e.g. P/C/F), and one workout (date, type, start time,
   duration).
2. **Health Connect** — Settings → App permissions → MacroFactor. Record which
   data types MacroFactor is permitted to read/write. Confirm Nutrition and
   Exercise are among them.
3. **MacroFactor package name** — get it from the Play Store URL
   (`...?id=<package>`). This is the string to hunt for in
   `dataSource.application.packageName`; it is the smoking gun.
4. **Health Connect sync** — confirm Health Connect is signed in / syncing to
   the Google account. If the first probe is empty, this is the first thing to
   re-check.

## 5. Constraints

- Reuse GCP project **`hermes-nas`** and the existing **Web application** OAuth
  client (redirect `https://gws.bassford.net/oauth2callback`).
- **Do not touch** `/volume1/docker/appdata/hermes-google/credentials`. The
  probe token is separate, ephemeral, and never copied there.
- **No changes** to Hermes, the MCP containers, the egress filters, or the
  firewall. The probe runs from a normal shell (workstation or `ssh nas` host
  shell), which is not behind the Hermes tinyproxy.
- **Do not** run `start_google_auth` inside the MCP container for the token:
  per `docs/superpowers/verify/google-mcp-image.md` it requests the server's
  configured scopes, and an ad-hoc import requests ~40 including Drive-write.
  Use the playground with the exact scopes below.
- Restricted-scope go/no-go mirrors Workspace Task 1: if Google will not let an
  **unverified production** app add these scopes, stop and record it.

---

## Task 1 — Enable the API and add the scopes (go/no-go)

Operator action in the browser.

- [ ] **Step 1: Enable the API**

`console.cloud.google.com` → project `hermes-nas` → **APIs & Services → Library**
→ search **Google Health API** → **Enable**.

- [ ] **Step 2: Add the two read scopes to the consent screen**

**APIs & Services → OAuth consent screen → Data access → Add or remove scopes.**
Add exactly:

```
https://www.googleapis.com/auth/googlehealth.nutrition.readonly
https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly
```

- [ ] **Step 3: STOP CONDITION**

If Google refuses to save/add restricted health scopes to this app, or forces a
verification submission, **stop**. Record the outcome; the Google Health API
path is closed and the design becomes the Tasker path.

Record: publishing status before/after, whether the scopes saved, any warning
text verbatim.

---

## Task 2 — Obtain a probe token without disturbing the bridge

- [ ] **Step 1: Allow the playground redirect on the existing client**

**Credentials → (the Web application client) → Authorized redirect URIs → Add:**

```
https://developers.google.com/oauthplayground
```

This is non-disruptive: it does not invalidate the existing token and does not
affect `gws.bassford.net` consent.

- [ ] **Step 2: Configure the playground with your own credentials**

Open `https://developers.google.com/oauthplayground` → gear icon (top right) →
tick **Use your own OAuth credentials** → paste the client **ID** and **secret**.

- [ ] **Step 3: Authorise the two scopes**

In **Step 1**, expand *Input your own scopes* and enter, space-separated:

```
https://www.googleapis.com/auth/googlehealth.nutrition.readonly
https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly
```

Click **Authorize APIs**, choose the MacroFactor-bearing account
(`jhbassford@gmail.com`), accept the **unverified app** warning.

- [ ] **Step 4: Exchange for a token**

**Step 2** → **Exchange authorization code for tokens**. Copy the **Access
token**. Keep the tab open; it is good for ~1 hour.

Fallback if the playground is blocked: create a throwaway **Desktop**-type
client in the same project with a loopback redirect and do the code exchange
locally. Do not reuse the production Web client's real redirect.

---

## Task 3 — Hit the API

Run from any normal shell with `curl`. Substitute `$TOKEN` and a real date
range that brackets the ground-truth entries. `python3 -m json.tool` is present
on the NAS host; `jq` is not on the host path (it lives inside Hermes).

- [ ] **Step 1: Identity and devices (context)**

```bash
TOKEN='<paste>'
H='-H Authorization:Bearer\ '"$TOKEN"' -H Accept:application/json'

curl -s $H https://health.googleapis.com/v4/users/me/identity          | python3 -m json.tool
curl -s $H https://health.googleapis.com/v4/users/me/pairedDevices     | python3 -m json.tool
```

- [ ] **Step 2: Raw nutrition records — inspect `dataSource` on every record**

```bash
curl -s $H "https://health.googleapis.com/v4/users/me/dataTypes/nutrition-log/dataPoints?page_size=25&filter=nutrition_log.interval.civil_start_time%20%3E%3D%20%222026-09-01T00:00:00%22" \
  | python3 -m json.tool
```

- [ ] **Step 3: Raw workout sessions**

```bash
curl -s $H "https://health.googleapis.com/v4/users/me/dataTypes/exercise/dataPoints?page_size=25&filter=exercise.interval.civil_start_time%20%3E%3D%20%222026-09-01T00:00:00%22" \
  | python3 -m json.tool
```

- [ ] **Step 4: Reconciled, third-party + Health Connect included**

```bash
curl -s $H "https://health.googleapis.com/v4/users/me/dataTypes/nutrition-log/dataPoints:reconcile?dataSourceFamily=users/me/dataSourceFamilies/all-sources&filter=nutrition_log.interval.civil_start_time%20%3E%3D%20%222026-09-01T00:00:00%22" \
  | python3 -m json.tool
curl -s $H "https://health.googleapis.com/v4/users/me/dataTypes/exercise/dataPoints:reconcile?dataSourceFamily=users/me/dataSourceFamilies/all-sources" \
  | python3 -m json.tool
```

- [ ] **Step 5: Save the raw output**

Write each response (redact the token only; no other secrets) to
`docs/superpowers/verify/health-api-probe/` as JSON.

---

## Task 4 — Interpret (binary)

**PASS — the cloud has MacroFactor data:**
- a `nutrition-log` record whose `energy`/macros match a known MacroFactor day,
  **or** any record whose `dataSource.application.packageName` equals
  MacroFactor's package; **or**
- an `exercise` session matching a known workout.
- Also record **which `dataSourceFamily` surfaced it** (`all-sources` vs
  `google-sources`) — that fixes the query the integration must use.

**FAIL — it does not:**
- `nutrition-log`/`exercise` come back empty or contain only manual/device
  entries, no MacroFactor package appears anywhere, and `reconcile`
  `all-sources` shows nothing third-party.

Before declaring FAIL, do the contingency once: confirm Health Connect sync is
on and the Fitbit app is installed/linked to the same account, wait for a sync,
and re-probe. If still empty, MacroFactor data does not reach the Google cloud,
and the Tasker path is the answer.

---

## Task 5 — Record

Create `docs/superpowers/verify/google-health-api-probe.md`:

```
# Google Health API — MacroFactor reachability probe
Recorded: <DATE>
Project: hermes-nas   Client: Web application   Scopes saved: yes/no
Scopes granted: <list>
getIdentity: <id or error>
pairedDevices: <devices or none>
nutrition-log records: <n>   MacroFactor package seen: yes/no
exercise sessions: <n>       matched known workout: yes/no
Verdict: PASS | FAIL
Query that worked (if PASS): dataType=<...> dataSourceFamily=<...>
```

---

## 6. What PASS implies (next project, NOT this spike)

- A `hermes-health-mcp` container in the house pattern: own credential volume,
  non-root, `read_only`, digest-pinned, no watchtower, no published ports.
- Add `health.googleapis.com` to the **exact-hostname** egress filter (the
  existing filter has no wildcard, so it must be named explicitly). Do not
  widen Hermes' own filter.
- Token in the health MCP's volume, never in `/opt/data`. Read scopes only —
  no `nutrition.writeonly`, no `activity_and_fitness.writeonly`.
- Webhooks are tempting for freshness, but a webhook that pulls health data on
  a timer is still unattended ingestion; keep it pull-on-ask until the operator
  decides otherwise.

## 7. What FAIL implies

- Tasker profile + `RafhaanShah/TaskerHealthConnect` plugin → append-only
  ingest container behind Cloudflare Access → read-only dir Hermes reads.
  Spec separately.

## 8. Out of scope

- Building either integration.
- Any change to the running Hermes / Google containers.
- Fitbit hardware (assume none).
