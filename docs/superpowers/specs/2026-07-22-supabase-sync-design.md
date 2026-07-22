# FMGE Tracker — Supabase Cloud Sync (No Auth)

## Purpose

`tracker.html` currently persists data only via `localStorage` (per-browser) and an
optional File System Access API sync to a local JSON file (Chromium-only, local disk
only). Neither survives across devices or browsers. This adds Supabase as a cloud
backup layer so the single user's tracker state syncs across their own devices,
without any login screen or Supabase Auth involved.

## Scope

- Single user, single shared dataset. Not multi-tenant — there is no concept of
  separate visitors with separate data.
- No login UI, no Supabase Auth (not even anonymous auth).
- Protection model is **obscurity only**: the Supabase URL and anon key will be
  visible in the deployed page's source (GitHub Pages / Vercel are static hosts).
  Anyone who obtains them could read or overwrite the data. This is an accepted
  trade-off for a low-stakes personal study tracker, consistent with the existing
  file-sync feature's trust model.
- Cloud sync is a **backup layer**, not the primary store. `localStorage` remains
  the instant, always-available source of truth; Supabase sync happens in the
  background and must never block or break the app if it's unreachable.

## Architecture

### Database

A single table, replacing the current `supabase-schema.sql` (which assumed
`auth.users` and per-user RLS — not applicable here):

```sql
create table if not exists public.fmge_tracker_state (
  id text primary key,
  payload jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.fmge_tracker_state enable row level security;

create policy "Anyone with the anon key can read tracker state"
  on public.fmge_tracker_state
  for select
  to anon
  using (true);

create policy "Anyone with the anon key can insert tracker state"
  on public.fmge_tracker_state
  for insert
  to anon
  with check (true);

create policy "Anyone with the anon key can update tracker state"
  on public.fmge_tracker_state
  for update
  to anon
  using (true)
  with check (true);
```

Only one row will ever exist, keyed by a fixed id (e.g. `'default'`). RLS is kept
**on** with explicit permissive policies for the `anon` role, rather than disabling
RLS outright — this makes the open-access trade-off an explicit, visible choice in
the schema rather than an implicit default.

### Client wiring (`tracker.html`)

- Add the `@supabase/supabase-js` v2 CDN script tag.
- New constants near the existing `DATA_FILE_NAME` declaration:
  - `SUPABASE_URL` — filled in by the user after creating their project.
  - `SUPABASE_ANON_KEY` — filled in by the user after creating their project.
  - `SYNC_ROW_ID = 'default'`.
- **Load path**: alongside the existing `loadFromLinkedJsonIfAvailable()` call at
  startup, add `loadFromSupabaseIfNewer()`:
  - Fetch the row by `SYNC_ROW_ID`.
  - If the fetch succeeds and the remote `updated_at` is newer than the local
    `data.lastSaved`, replace the in-memory `data`, re-render the UI, and write the
    result to `localStorage`.
  - If the fetch fails (offline, misconfigured keys, table not yet created), do
    nothing — fall through to whatever `localStorage`/file-sync already loaded.
- **Save path**: extend `saveData()` (already debounced 400ms via `scheduleSave`).
  After the existing `localStorage.setItem` call, also upsert
  `{ id: SYNC_ROW_ID, payload: data, updated_at: <now> }` to Supabase.
  - On success: update a cloud-sync status indicator to "saved".
  - On failure: update the indicator to "offline — saved locally only" and do
    not throw; local save has already succeeded.
- **UI**: a small status line placed near the existing "Saved" dot / file-sync
  status text (same visual pattern already used for file-sync), showing one of:
  "Cloud sync: saved", "Cloud sync: offline — saved locally only", or
  "Cloud sync: not configured" (shown if the URL/key constants are left blank).

### Data flow summary

```
On load:  localStorage -> (maybe) local JSON file -> (maybe) Supabase if newer -> render
On edit:  render -> localStorage (always) -> Supabase upsert (best-effort, debounced)
```

### Error handling

- Every Supabase call is wrapped in try/catch. Network failure, missing
  config, or table-not-found never blocks the UI or breaks local saving.
- No retry queue: the next edit's debounce naturally retries the upsert.
- Conflict resolution is last-write-wins by `updated_at` timestamp comparison —
  sufficient for a single user working on one device at a time.

## Out of scope

- Any login/auth system, including Supabase anonymous auth.
- Multi-device concurrent-edit conflict resolution beyond last-write-wins.
- Server-side functions/triggers.
- Migrating away from the existing localStorage or file-sync features — both stay
  exactly as they are today.

## Setup steps (for the user, not part of the code change)

1. In the Supabase dashboard, run the SQL above against the project's SQL editor.
2. Copy the project URL and anon public key from Project Settings → API.
3. Paste them into the `SUPABASE_URL` / `SUPABASE_ANON_KEY` constants in
   `tracker.html`.
