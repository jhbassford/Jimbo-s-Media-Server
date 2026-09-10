# Google Workspace MCP image — pin and capability record

Task 3 of `docs/superpowers/plans/2026-09-10-hermes-google-workspace.md`.
Everything here was read off the live image on the NAS, not from documentation.

## Pin

```
ghcr.io/taylorwilsdon/google_workspace_mcp@sha256:0ce26298d707ee1e213ca3c51ef814287b8d8c9c2a0abd9494f95f2adc07bc1d
```

Tag `1.26.0`, linux/amd64, pulled 2026-09-10. **A published image exists**, so the
plan's build-from-source fallback was not needed. Never substitute the tag.

Runtime identity: `uid=1000(app) gid=1000(app)`, `HOME=/home/app`.

## Findings that change the plan

**1. The entrypoint is `/bin/sh -c`, and CMD is a shell string.**

```
entrypoint=[/bin/sh -c]
cmd=[uv run main.py --transport streamable-http ${TOOL_TIER:+--tool-tier "$TOOL_TIER"} ${TOOLS:+--tools $TOOLS}]
```

A compose `command:` written as a YAML **list** would be passed as
`sh -c "<first element>" <rest…>` — only the first element runs as the script and
every flag after it is silently discarded. The plan's Task 4 block did exactly
that. Configure via **environment variables** instead; the image reads them all.

**2. `--permissions SERVICE:LEVEL` exists and is a better fit than `--tools`.**

> Gmail levels: readonly, organize, drafts, send, full (cumulative).
> Other services: readonly, full.
> Mutually exclusive with `--read-only` and `--tools`.

It drives **both** tool registration and the OAuth scopes requested (`--read-only`
is documented as "requests only read-only scopes and disables tools requiring
write permissions"). That collapses spec §5's Layer 0 and Layer 1 into one
consistent switch — better than the plan assumed. `--disabled-tools` still
"composes with every other filtering option", so it remains available as the
second lock.

Chosen: `WORKSPACE_MCP_PERMISSIONS=gmail:send calendar:full drive:readonly docs:readonly`

Gmail levels being **cumulative** means `gmail:send` also grants `organize`
(label and filter mutation), which spec §1 excludes. Those tools are therefore
subtracted explicitly below.

**3. `WORKSPACE_MCP_HOST` must be set to `0.0.0.0` or the server is unreachable.**

`main.py:resolve_bind_host_for_transport` binds **`127.0.0.1`** when transport is
`streamable-http` and OAuth 2.1 is disabled. Hermes would not have been able to
reach it. Confirmed live: a default run logs
`Uvicorn running on http://127.0.0.1:8000`.

**4. SECURITY — the MCP endpoint has no authentication of its own.**

Setting `WORKSPACE_MCP_HOST` triggers this startup notice, quoted from source:

> Legacy streamable-http mode has no MCP-level auth provider and is bound to
> {host} because WORKSPACE_MCP_HOST was explicitly set. Use
> `MCP_ENABLE_OAUTH21=true` for remotely reachable HTTP deployments.

So **anything that can reach `192.168.92.3:8000/mcp` can use the Google tools
with no credential.** Accepted, with compensating controls that must hold:

- `hermes_net` has exactly three members — Hermes, the agent's egress proxy, and
  this container. Only Hermes ever initiates MCP calls.
- **No host port is published, ever.** This is now load-bearing, not hygiene.
- The threat model already assumes Hermes is hijacked, and a hijacked Hermes is
  *supposed* to be able to call this server. The boundary is the tool allowlist
  and the OAuth scopes, not endpoint authentication.

`MCP_ENABLE_OAUTH21=true` was rejected: it reintroduces the `/oauth2/*` and
`/.well-known/*` surface spec §8 deliberately avoids, and would require Hermes to
run its own OAuth dance against a server it reaches over a two-member bridge.

**5. `--single-user` mode exists and matches this deployment** — "bypass session
mapping and use any credentials from the credentials directory". Use it.

**6. Shared `RLIMIT_NPROC` ceiling with Hermes.**

This image runs as **uid 1000**, the same real UID as Hermes. The parent design
(`compose/hermes.yml`, deviation 2) notes RLIMIT_NPROC counts per real UID
**system-wide**, and stated the 1024 ceiling was exclusive to Hermes "in case that
ever changes". It has now changed.

Running as a foreign UID was tested and **fails** (`--user 1055:1055` →
`APP-FAILED-AS-FOREIGN-UID`; `HOME` resolves to `/` and `uv` cannot initialise).
Fixing that means the same `/etc/passwd` remap trick Hermes needed — real
complexity for a resource-contention issue, not a containment one.

Ruling: keep uid 1000, size this container's `nproc` low (**256**) so it cannot
meaningfully erode Hermes' 1024 headroom, and record the interaction here.
Follow-up option if it ever bites: remap via a `:ro` passwd mount as Hermes does.

**7. Useful extras:** a `GET /health` endpoint returning 200 (used by Task 4's
reachability check), and `GOOGLE_MCP_CREDENTIALS_DIR` for the credential path.

## Tool inventory (read from the image's own source)

Public tools only; `_`-prefixed helpers omitted.

**Gmail** — `batch_modify_gmail_message_labels`, `draft_gmail_message`,
`get_gmail_attachment_content`, `get_gmail_message_content`,
`get_gmail_messages_content_batch`, `get_gmail_thread_content`,
`get_gmail_threads_content_batch`, `list_gmail_filters`, `list_gmail_labels`,
`manage_gmail_filter`, `manage_gmail_label`, `modify_gmail_message_labels`,
`search_gmail_messages`, `send_gmail_message`

**Calendar** — `create_calendar`, `get_events`, `list_calendars`, `manage_event`,
`manage_focus_time`, `manage_out_of_office`, `query_freebusy`

**Drive** — `check_drive_file_public_access`, `copy_drive_file`,
`create_drive_file`, `create_drive_folder`, `get_drive_file_content`,
`get_drive_file_download_url`, `get_drive_file_permissions`,
`get_drive_shareable_link`, `import_to_google_doc`, `import_to_google_sheets`,
`import_to_google_slides`, `list_drive_items`, `manage_drive_access`,
`resolve_drive_item`, `resolve_folder_id`, `search_drive_files`,
`set_drive_file_permissions`, `update_drive_file`

**Docs** — `batch_update_doc`, `create_doc`, `create_table_with_data`,
`debug_docs_runtime_info`, `debug_table_structure`, `export_doc_to_pdf`,
`find_and_replace_doc`, `get_doc_as_markdown`, `get_doc_content`,
`insert_doc_elements`, `insert_doc_image`, `inspect_doc_structure`,
`list_docs_in_folder`, `manage_doc_tab`, `modify_doc_text`, `search_docs`,
`update_doc_headers_footers`, `update_paragraph_style`

## Policy mapping (spec §1)

**Keep** — Gmail: `search_gmail_messages`, `get_gmail_message_content`,
`get_gmail_messages_content_batch`, `get_gmail_thread_content`,
`get_gmail_threads_content_batch`, `get_gmail_attachment_content`,
`list_gmail_labels`, `list_gmail_filters`, `draft_gmail_message`,
`send_gmail_message` (gated per §6). Calendar: `get_events`, `list_calendars`,
`manage_event`, `query_freebusy`. Drive: `search_drive_files`,
`list_drive_items`, `get_drive_file_content`, `get_drive_file_permissions`,
`resolve_drive_item`, `resolve_folder_id`. Docs: `get_doc_content`,
`get_doc_as_markdown`, `search_docs`, `list_docs_in_folder`,
`inspect_doc_structure`, `export_doc_to_pdf`.

**`WORKSPACE_MCP_DISABLED_TOOLS`** — the explicit second lock. `drive:readonly`
and `docs:readonly` should already withhold every Drive/Docs writer; these are
named anyway so that a permission-model change upstream cannot silently
reintroduce them, and so Task 9 has concrete names to assert against.

```
batch_modify_gmail_message_labels,modify_gmail_message_labels,manage_gmail_label,manage_gmail_filter,
create_calendar,manage_focus_time,manage_out_of_office,
set_drive_file_permissions,manage_drive_access,get_drive_shareable_link,check_drive_file_public_access,
get_drive_file_download_url,create_drive_file,create_drive_folder,copy_drive_file,update_drive_file,
import_to_google_doc,import_to_google_sheets,import_to_google_slides,
create_doc,batch_update_doc,modify_doc_text,find_and_replace_doc,insert_doc_elements,insert_doc_image,
create_table_with_data,manage_doc_tab,update_doc_headers_footers,update_paragraph_style,
debug_docs_runtime_info,debug_table_structure
```

The four that matter most are `set_drive_file_permissions`, `manage_drive_access`,
`get_drive_shareable_link` and `check_drive_file_public_access` — together they
are the public-link exfiltration path spec §2 says must be **absent**, not merely
blocked, and they are why "Drive read-only" is enforced at two layers here.

## Send-gate spike (Task 8)

Result: PENDING.
