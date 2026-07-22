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
