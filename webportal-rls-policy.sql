-- Allow the app's anon client to read and manage WebPortal records.
-- Run this in Supabase SQL Editor.

alter table public.webportal enable row level security;

drop policy if exists "allow_webportal_select" on public.webportal;
drop policy if exists "allow_webportal_insert" on public.webportal;
drop policy if exists "allow_webportal_update" on public.webportal;

create policy "allow_webportal_select"
  on public.webportal for select
  to anon, authenticated
  using (true);

create policy "allow_webportal_insert"
  on public.webportal for insert
  to anon, authenticated
  with check (
    coalesce(trim(department), '') <> ''
    and coalesce(trim(link_name), '') <> ''
    and coalesce(trim(url), '') <> ''
    and coalesce(trim(created_by), '') <> ''
  );

create policy "allow_webportal_update"
  on public.webportal for update
  to anon, authenticated
  using (true)
  with check (
    coalesce(trim(department), '') <> ''
    and coalesce(trim(link_name), '') <> ''
    and coalesce(trim(url), '') <> ''
  );

grant select, insert, update on table public.webportal to anon, authenticated;
