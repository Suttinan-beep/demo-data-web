create extension if not exists pgcrypto;

alter table public."UserIDdemoDATA"
  add column if not exists password_hash text;

update public."UserIDdemoDATA"
set password_hash = crypt("Password", gen_salt('bf'))
where "Password" is not null
  and coalesce(password_hash, '') = '';

alter table public."UserIDdemoDATA" enable row level security;
alter table public."UserMenuPIN" enable row level security;

drop policy if exists "allow anon select all users" on public."UserIDdemoDATA";
drop policy if exists "allow login read users" on public."UserIDdemoDATA";
drop policy if exists "login_read" on public."UserIDdemoDATA";
drop policy if exists "allow anon select all menu pin" on public."UserMenuPIN";
drop policy if exists "login_read_menu_pin" on public."UserMenuPIN";

create or replace function public.verify_user_login(
  p_user_id text,
  p_password text
)
returns table (
  user_id text,
  nickname text,
  department text
)
language sql
security definer
set search_path = public
as $$
  select
    u.user_id,
    u."NicKname" as nickname,
    u."Department" as department
  from public."UserIDdemoDATA" as u
  where lower(u.user_id) = lower(trim(p_user_id))
    and u.password_hash = crypt(p_password, u.password_hash)
  limit 1;
$$;

create or replace function public.verify_menu_pin(
  p_user_id text,
  p_menu_code text,
  p_pin text
)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public."UserMenuPIN" as p
    where lower(p.user_id) = lower(trim(p_user_id))
      and upper(p.menu_code) = upper(trim(p_menu_code))
      and p.is_active = true
      and p.pin_hash = crypt(p_pin, p.pin_hash)
  );
$$;

revoke all on table public."UserIDdemoDATA" from anon, authenticated;
revoke all on table public."UserMenuPIN" from anon, authenticated;

grant execute on function public.verify_user_login(text, text) to anon, authenticated;
grant execute on function public.verify_menu_pin(text, text, text) to anon, authenticated;

comment on function public.verify_user_login(text, text) is
'Checks user_id + password hash server-side and returns a safe profile payload.';

comment on function public.verify_menu_pin(text, text, text) is
'Checks menu PIN server-side so pin_hash never leaves the database.';
