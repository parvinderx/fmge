# Supabase Cloud Sync (No Auth) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Back up `tracker.html`'s state to a Supabase table (single row, no auth, no login UI) so the single user's tracker syncs across their own devices on top of the existing localStorage/file-sync persistence.

**Architecture:** A single-row Postgres table (`fmge_tracker_state`) with RLS enabled but fully permissive for the `anon` role. `tracker.html` loads the Supabase JS client from a CDN, pulls the row on startup (using it only if newer than the local copy), and pushes an upsert after every debounced local save. All Supabase calls are best-effort and never block local saving.

**Tech Stack:** Vanilla JS (no build step), `@supabase/supabase-js` v2 via CDN, Supabase Postgres + PostgREST + RLS.

## Global Constraints

- This is a single static HTML file with **no build tooling and no test runner** (no `package.json`, no Jest/pytest). "Tests" in this plan are manual verification steps: browser devtools, the Supabase SQL editor/dashboard, and `curl` against the PostgREST API. There is no automated red/green cycle to run — read each verification step's expected output and confirm it by hand.
- Follow the existing code style in `tracker.html`: `var` declarations, function statements (not arrow functions), double-quoted strings, 2-space indentation, `"use strict"` IIFE already wrapping the script.
- `SUPABASE_URL` and `SUPABASE_ANON_KEY` default to empty strings in the committed file — the user fills them in locally after creating their Supabase project. Cloud sync must no-op cleanly (status: "Cloud sync: not configured") when either is blank.
- No Supabase Auth, no login UI, no per-user data separation — single fixed row, `id = 'default'`.
- Every Supabase call is wrapped in try/catch; failures fall back silently to local-only save and update the status text — they must never throw past the calling function or break `renderAll()`.

---

### Task 1: Replace `supabase-schema.sql` with the no-auth schema

**Files:**
- Modify: `supabase-schema.sql` (full replacement)

**Interfaces:**
- Produces: a `public.fmge_tracker_state` table with columns `id text primary key`, `payload jsonb not null`, `updated_at timestamptz not null default now()`, reachable by the `anon` role for select/insert/update. This is the table Task 4 and Task 5's JS code will read from and write to, using the fixed row id `'default'`.

- [ ] **Step 1: Replace the schema file**

Replace the entire contents of `supabase-schema.sql` with:

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

- [ ] **Step 2: Run it against the Supabase project**

In the Supabase dashboard, open **SQL Editor**, paste the file's contents, and run it.
Expected: "Success. No rows returned" and a new `fmge_tracker_state` table visible under **Table Editor**.

- [ ] **Step 3: Verify the anon policies actually work over the REST API**

From a terminal, with `<PROJECT_URL>` and `<ANON_KEY>` from Project Settings → API:

```bash
curl -s "<PROJECT_URL>/rest/v1/fmge_tracker_state" \
  -H "apikey: <ANON_KEY>" \
  -H "Authorization: Bearer <ANON_KEY>"
```

Expected: `[]` (empty array, HTTP 200) — proves the anon role can `select` even though the table is empty. Then:

```bash
curl -s -X POST "<PROJECT_URL>/rest/v1/fmge_tracker_state" \
  -H "apikey: <ANON_KEY>" \
  -H "Authorization: Bearer <ANON_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"id":"smoke-test","payload":{"milestones":[]},"updated_at":"2026-01-01T00:00:00Z"}'
```

Expected: HTTP 201 with the inserted row echoed back. Then clean up the smoke-test row:

```bash
curl -s -X DELETE "<PROJECT_URL>/rest/v1/fmge_tracker_state?id=eq.smoke-test" \
  -H "apikey: <ANON_KEY>" \
  -H "Authorization: Bearer <ANON_KEY>"
```

Expected: HTTP 204.

- [ ] **Step 4: Commit**

```bash
git add supabase-schema.sql
git commit -m "Replace per-user Supabase schema with single-row, no-auth schema"
```

---

### Task 2: Load the Supabase JS client and add config constants

**Files:**
- Modify: `tracker.html:355` (script tag insertion, before the main `<script>` block)
- Modify: `tracker.html:361` (constants block)

**Interfaces:**
- Produces: global `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SYNC_ROW_ID` constants and the `supabase` global (from the CDN UMD bundle, exposing `supabase.createClient`) that Task 4 consumes.

- [ ] **Step 1: Add the CDN script tag**

In `tracker.html`, immediately before the existing `<script>` tag at line 355 (`<script>` followed by `(function(){`), add:

```html
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
```

- [ ] **Step 2: Add config constants**

Find this block (`tracker.html:359-364`):

```javascript
var STORAGE_KEY = "fmge_tracker_v1";
var FILE_SYNC_KEY = "fmge_tracker_file_sync_v1";
var DATA_FILE_NAME = "fmge-tracker-data.json";
var EXAM_DATE = "2027-01-09";
var TL_START = "2026-07-22";
var TL_END = "2027-01-09";
```

Replace it with:

```javascript
var STORAGE_KEY = "fmge_tracker_v1";
var FILE_SYNC_KEY = "fmge_tracker_file_sync_v1";
var DATA_FILE_NAME = "fmge-tracker-data.json";
var SUPABASE_URL = "";
var SUPABASE_ANON_KEY = "";
var SYNC_ROW_ID = "default";
var EXAM_DATE = "2027-01-09";
var TL_START = "2026-07-22";
var TL_END = "2027-01-09";
```

(Leave `SUPABASE_URL`/`SUPABASE_ANON_KEY` blank here — fill them in locally after Task 1's setup, never commit real keys since this obscurity-based design still shouldn't be handed out over more channels than necessary. Note the values are visible in the deployed page source either way, per the design spec.)

- [ ] **Step 3: Verify the CDN script loads and constants exist**

Open `tracker.html` directly in a browser (double-click, or serve it locally), open devtools console, and run:

```js
typeof window.supabase.createClient
```

Expected: `"function"`. Also confirm no red errors appeared in the console during page load.

- [ ] **Step 4: Commit**

```bash
git add tracker.html
git commit -m "Load supabase-js client and add cloud sync config constants"
```

---

### Task 3: Add the cloud sync status line to the Data & Backup sheet

**Files:**
- Modify: `tracker.html:343` (Data & Backup overlay markup)

**Interfaces:**
- Produces: a `#cloudSyncStatus` element in the DOM that Task 4/5's `updateCloudSyncStatus(message, ok)` function (defined in Task 4) will write to.

- [ ] **Step 1: Add the status paragraph**

Find this line (`tracker.html:343`):

```html
    <p class="sync-status" id="fileSyncStatus">JSON file sync: not linked</p>
```

Replace it with:

```html
    <p class="sync-status" id="fileSyncStatus">JSON file sync: not linked</p>
    <p class="sync-status" id="cloudSyncStatus">Cloud sync: not configured</p>
```

- [ ] **Step 2: Verify it renders**

Open `tracker.html` in a browser, tap the ⚙ Data button in the header, and confirm the "Data & Backup" sheet now shows a line reading "Cloud sync: not configured" directly under the "JSON file sync" line.

- [ ] **Step 3: Commit**

```bash
git add tracker.html
git commit -m "Add cloud sync status line to Data & Backup sheet"
```

---

### Task 4: Implement the Supabase client, `loadFromSupabaseIfNewer()`, and wire it into startup

**Files:**
- Modify: `tracker.html:516` (insert new functions after `loadFromLinkedJsonIfAvailable`)
- Modify: `tracker.html:1179-1185` (init sequence)

**Interfaces:**
- Consumes: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SYNC_ROW_ID` (Task 2), `#cloudSyncStatus` element (Task 3), the module-level `data` variable (defined at `tracker.html:518` as `var data = loadData();`).
- Produces: `getSupabaseClient()` → `SupabaseClient|null`, `updateCloudSyncStatus(message, ok)` → `void`, `loadFromSupabaseIfNewer()` → `Promise<object|null>` (resolves to a parsed tracker payload if the remote row is newer than local, else `null`). Task 5 consumes `getSupabaseClient()` and `updateCloudSyncStatus`.

- [ ] **Step 1: Add the client helper and load function**

Find the end of `loadFromLinkedJsonIfAvailable` (`tracker.html:504-516`):

```javascript
async function loadFromLinkedJsonIfAvailable(){
  try{
    var handle = await getStoredDirectoryHandle();
    if(!handle) return null;
    var parsed = await readDataFromDirectoryHandle(handle);
    if(parsed && Array.isArray(parsed.milestones)){
      fileSync.handle = handle;
      fileSync.ready = true;
      return parsed;
    }
  }catch(e){}
  return null;
}
```

Immediately after its closing brace (still before `var data = loadData();`), add:

```javascript
function updateCloudSyncStatus(message, ok){
  var status = document.getElementById("cloudSyncStatus");
  if(!status) return;
  status.textContent = message;
  status.style.color = ok ? "var(--success)" : "var(--muted)";
}

var cloudSync = { client: null };
function getSupabaseClient(){
  if(!SUPABASE_URL || !SUPABASE_ANON_KEY) return null;
  if(!cloudSync.client){
    cloudSync.client = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  }
  return cloudSync.client;
}

async function loadFromSupabaseIfNewer(){
  var client = getSupabaseClient();
  if(!client){
    updateCloudSyncStatus("Cloud sync: not configured", false);
    return null;
  }
  try{
    var result = await client.from("fmge_tracker_state").select("payload, updated_at").eq("id", SYNC_ROW_ID).maybeSingle();
    if(result.error) throw result.error;
    updateCloudSyncStatus("Cloud sync: saved", true);
    var row = result.data;
    if(!row || !row.payload || !Array.isArray(row.payload.milestones)) return null;
    var localSaved = data.lastSaved ? new Date(data.lastSaved).getTime() : 0;
    var remoteSaved = row.updated_at ? new Date(row.updated_at).getTime() : 0;
    if(remoteSaved > localSaved) return row.payload;
    return null;
  }catch(e){
    updateCloudSyncStatus("Cloud sync: offline — saved locally only", false);
    return null;
  }
}
```

- [ ] **Step 2: Wire it into the init sequence**

Find this block (`tracker.html:1179-1185`):

```javascript
void refreshFileSyncStatus();
loadFromLinkedJsonIfAvailable().then(function(parsed){
  if(parsed){
    data = parsed;
    renderAll();
  }
});
```

Replace it with:

```javascript
void refreshFileSyncStatus();
loadFromLinkedJsonIfAvailable().then(function(parsed){
  if(parsed){
    data = parsed;
    renderAll();
  }
});
loadFromSupabaseIfNewer().then(function(payload){
  if(payload){
    data = payload;
    renderAll();
  }
});
```

- [ ] **Step 3: Verify against a real Supabase project**

Fill in `SUPABASE_URL` and `SUPABASE_ANON_KEY` locally (do not commit real values yet). In the Supabase SQL editor, seed a row with a timestamp far in the future so it's guaranteed newer than any local save:

```sql
insert into public.fmge_tracker_state (id, payload, updated_at)
values ('default', '{"milestones":[{"id":1,"phase":1,"task":"CLOUD SYNC TEST","marks":0,"plannedStart":"2026-07-22","plannedEnd":"2026-07-22","status":"Not started","actualStart":"","actualEnd":"","notes":""}],"mocks":[],"studyLogs":[],"lastSaved":null}'::jsonb, '2099-01-01T00:00:00Z')
on conflict (id) do update set payload = excluded.payload, updated_at = excluded.updated_at;
```

Reload `tracker.html` in the browser. Expected: the Milestones tab now shows a single milestone titled "CLOUD SYNC TEST", and the Data & Backup sheet shows "Cloud sync: saved". Then revert the seeded row so Task 5's test starts clean:

```sql
delete from public.fmge_tracker_state where id = 'default';
```

Also verify the not-configured and offline paths: temporarily blank `SUPABASE_URL` and reload — expect "Cloud sync: not configured" and the rest of the app working normally; then restore the real URL but set `SUPABASE_ANON_KEY` to an obviously wrong string and reload — expect "Cloud sync: offline — saved locally only" and the app still working normally.

- [ ] **Step 4: Commit**

```bash
git add tracker.html
git commit -m "Load newer tracker state from Supabase on startup"
```

---

### Task 5: Push local saves to Supabase

**Files:**
- Modify: `tracker.html:531-544` (`saveData`)

**Interfaces:**
- Consumes: `getSupabaseClient()`, `updateCloudSyncStatus()` (Task 4), `SYNC_ROW_ID` (Task 2), the module-level `data` variable.
- Produces: `pushToSupabase()` → `Promise<void>` (best-effort upsert, never throws), called from `saveData()`.

- [ ] **Step 1: Add `pushToSupabase()` and call it from `saveData()`**

Find `saveData` (`tracker.html:531-544`):

```javascript
var saveTimer = null;
async function saveData(){
  data.lastSaved = new Date().toISOString();
  try{ localStorage.setItem(STORAGE_KEY, JSON.stringify(data)); }catch(e){}
  if(fileSync.handle){
    try{ await writeDataToDirectoryHandle(fileSync.handle, data); }
    catch(e){
      fileSync.handle = null;
      fileSync.ready = false;
      updateFileSyncStatus('JSON file sync: link lost, localStorage still saving', false);
    }
  }
  flashSaved();
}
```

Replace it with:

```javascript
var saveTimer = null;
async function pushToSupabase(){
  var client = getSupabaseClient();
  if(!client){
    updateCloudSyncStatus("Cloud sync: not configured", false);
    return;
  }
  try{
    var result = await client.from("fmge_tracker_state").upsert({id: SYNC_ROW_ID, payload: data, updated_at: data.lastSaved});
    if(result.error) throw result.error;
    updateCloudSyncStatus("Cloud sync: saved", true);
  }catch(e){
    updateCloudSyncStatus("Cloud sync: offline — saved locally only", false);
  }
}
async function saveData(){
  data.lastSaved = new Date().toISOString();
  try{ localStorage.setItem(STORAGE_KEY, JSON.stringify(data)); }catch(e){}
  if(fileSync.handle){
    try{ await writeDataToDirectoryHandle(fileSync.handle, data); }
    catch(e){
      fileSync.handle = null;
      fileSync.ready = false;
      updateFileSyncStatus('JSON file sync: link lost, localStorage still saving', false);
    }
  }
  void pushToSupabase();
  flashSaved();
}
```

- [ ] **Step 2: Verify a local edit reaches Supabase**

With real `SUPABASE_URL`/`SUPABASE_ANON_KEY` set and the table empty (per Task 4 Step 3's cleanup), open `tracker.html`, go to Milestones, and change any milestone's status (e.g. to "In progress"). Wait about a second for the 400ms debounce, then in the Supabase Table Editor refresh `fmge_tracker_state`.

Expected: one row with `id = 'default'`, `payload` containing the milestone with its new status, and `updated_at` matching the "Last saved" time shown in the Data & Backup sheet. The on-page status should read "Cloud sync: saved".

- [ ] **Step 3: Verify the offline fallback still saves locally**

Temporarily set `SUPABASE_ANON_KEY` to an invalid string, reload, and change another milestone's status. Expected: the change persists (visible after a page reload with the correct key restored later), "Saved" dot still flashes, and the cloud status reads "Cloud sync: offline — saved locally only" — confirming a broken cloud link never blocks local saving.

- [ ] **Step 4: Commit**

```bash
git add tracker.html
git commit -m "Push local tracker saves to Supabase as a best-effort background sync"
```
