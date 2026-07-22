create table if not exists public.fmge_tracker_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  payload jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.fmge_tracker_state enable row level security;

create policy "Users can read their own tracker state"
  on public.fmge_tracker_state
  for select
  using (auth.uid() = user_id);

create policy "Users can insert their own tracker state"
  on public.fmge_tracker_state
  for insert
  with check (auth.uid() = user_id);

create policy "Users can update their own tracker state"
  on public.fmge_tracker_state
  for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
