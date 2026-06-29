-- Restore app_user_sessions table and update login RPCs to create sessions.
create extension if not exists pgcrypto;

-- Create app_user_sessions table
create table if not exists public.app_user_sessions (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id text not null,
  token_hash text not null unique,
  created_at timestamp without time zone not null default timezone('Asia/Bangkok', now()),
  last_used_at timestamp without time zone default timezone('Asia/Bangkok', now()),
  expires_at timestamp without time zone not null,
  max_expires_at timestamp without time zone,
  revoked_at timestamp without time zone
);

-- Store session timestamps as Thailand local time for easier reading in Supabase table views.
do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'app_user_sessions'
      and column_name = 'created_at'
      and data_type = 'timestamp with time zone'
  ) then
    alter table public.app_user_sessions
      alter column created_at type timestamp without time zone using timezone('Asia/Bangkok', created_at),
      alter column last_used_at type timestamp without time zone using timezone('Asia/Bangkok', last_used_at),
      alter column expires_at type timestamp without time zone using timezone('Asia/Bangkok', expires_at),
      alter column revoked_at type timestamp without time zone using timezone('Asia/Bangkok', revoked_at);
  end if;
end;
$$;

alter table public.app_user_sessions
  add column if not exists max_expires_at timestamp without time zone,
  alter column created_at set default timezone('Asia/Bangkok', now()),
  alter column last_used_at set default timezone('Asia/Bangkok', now());

update public.app_user_sessions
set max_expires_at = coalesce(max_expires_at, created_at + interval '12 hours')
where max_expires_at is null;

-- Create index for faster lookups
create index if not exists idx_app_user_sessions_user_id on public.app_user_sessions(user_id);
create index if not exists idx_app_user_sessions_token_hash on public.app_user_sessions(token_hash);
create index if not exists idx_app_user_sessions_expires_at on public.app_user_sessions(expires_at);

-- Menu permission tables. Keep these separate from PINs so access rules can grow cleanly.
create table if not exists public.app_roles (
  role_code text primary key,
  role_name text not null,
  is_active boolean not null default true,
  created_at timestamp without time zone not null default timezone('Asia/Bangkok', now())
);

create table if not exists public.app_user_roles (
  user_id text not null,
  role_code text not null references public.app_roles(role_code) on delete cascade,
  is_active boolean not null default true,
  created_at timestamp without time zone not null default timezone('Asia/Bangkok', now()),
  primary key (user_id, role_code)
);

create table if not exists public.app_menus (
  menu_code text primary key,
  menu_name text not null,
  menu_path text,
  display_order integer not null default 100,
  requires_pin boolean not null default false,
  is_active boolean not null default true,
  created_at timestamp without time zone not null default timezone('Asia/Bangkok', now())
);

create table if not exists public.app_role_menu_permissions (
  role_code text not null references public.app_roles(role_code) on delete cascade,
  menu_code text not null references public.app_menus(menu_code) on delete cascade,
  can_access boolean not null default true,
  created_at timestamp without time zone not null default timezone('Asia/Bangkok', now()),
  primary key (role_code, menu_code)
);

create table if not exists public.app_user_menu_permissions (
  user_id text not null,
  menu_code text not null references public.app_menus(menu_code) on delete cascade,
  permission_effect text not null default 'ALLOW' check (permission_effect in ('ALLOW', 'DENY')),
  created_at timestamp without time zone not null default timezone('Asia/Bangkok', now()),
  primary key (user_id, menu_code)
);

create index if not exists idx_app_user_roles_user_id on public.app_user_roles(user_id);
create index if not exists idx_app_role_menu_permissions_role_code on public.app_role_menu_permissions(role_code);
create index if not exists idx_app_user_menu_permissions_user_id on public.app_user_menu_permissions(user_id);

insert into public.app_roles (role_code, role_name)
values
  ('STAFF', 'Staff'),
  ('MANAGER', 'Manager'),
  ('HR', 'HR'),
  ('ADMIN', 'Admin')
on conflict (role_code) do nothing;

insert into public.app_menus (menu_code, menu_name, menu_path, display_order, requires_pin)
values
  ('CUSTOMER_SEARCH', 'Customer Search', 'home.html', 10, false),
  ('WEBPORTAL', 'Web Portal', 'webportal.html', 20, true),
  ('CLEARPORT', 'Update Clearport', 'clearport.html', 30, true),
  ('ATTENDANCE', 'Attendance System', 'Attendance.html', 40, false)
on conflict (menu_code) do update
set
  menu_name = excluded.menu_name,
  menu_path = excluded.menu_path,
  display_order = excluded.display_order,
  requires_pin = excluded.requires_pin;

insert into public.app_role_menu_permissions (role_code, menu_code, can_access)
values
  ('ADMIN', 'CUSTOMER_SEARCH', true),
  ('ADMIN', 'WEBPORTAL', true),
  ('ADMIN', 'CLEARPORT', true),
  ('ADMIN', 'ATTENDANCE', true)
on conflict (role_code, menu_code) do update
set can_access = excluded.can_access;

-- Enable RLS
alter table public.app_user_sessions enable row level security;
alter table public.app_roles enable row level security;
alter table public.app_user_roles enable row level security;
alter table public.app_menus enable row level security;
alter table public.app_role_menu_permissions enable row level security;
alter table public.app_user_menu_permissions enable row level security;

-- Drop old policies if they exist
drop policy if exists "allow_select_own_sessions" on public.app_user_sessions;
drop policy if exists "allow_insert_own_sessions" on public.app_user_sessions;
drop policy if exists "allow_select_sessions" on public.app_user_sessions;
drop policy if exists "allow_insert_sessions" on public.app_user_sessions;

-- Create simple RLS policies for anon users
create policy "allow_insert_sessions"
  on public.app_user_sessions for insert
  with check (true);

create policy "allow_select_sessions"
  on public.app_user_sessions for select
  using (true);

-- Grant permissions
revoke all on table public.app_user_sessions from anon, authenticated;
grant select, insert on table public.app_user_sessions to anon, authenticated;

-- Drop old functions first
drop function if exists public.verify_user_login(text,text) cascade;
drop function if exists public.verify_menu_pin_for_session(text,text,text) cascade;
drop function if exists public.get_allowed_menus_for_session(text) cascade;
drop function if exists public.check_menu_access_for_session(text,text) cascade;

-- Update verify_user_login RPC to generate session token
create or replace function public.verify_user_login(
  p_user_id text,
  p_password text
)
returns table (
  user_id text,
  name text,
  nickname text,
  department text,
  session_token text,
  expires_at timestamp without time zone,
  max_expires_at timestamp without time zone
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id text;
  v_name text;
  v_nickname text;
  v_department text;
  v_password_hash text;
  v_token text;
  v_token_hash text;
  v_expires_at timestamp without time zone;
  v_max_expires_at timestamp without time zone;
begin
  -- Verify user credentials
  select u.user_id, u."Name", u."NicKname", u."Department", u.password_hash
  into v_user_id, v_name, v_nickname, v_department, v_password_hash
  from public."UserIDdemoDATA" as u
  where lower(u.user_id) = lower(trim(p_user_id))
  limit 1;

  if v_user_id is null then
    return;
  end if;

  -- Check password against the bcrypt hash created by supabase-security-migration.sql.
  if v_password_hash is null or v_password_hash != extensions.crypt(trim(p_password), v_password_hash) then
    return;
  end if;

  -- Generate session token (32 bytes = 64 hex chars)
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_token_hash := v_token;
  
  -- Idle timeout is 15 minutes. Active sessions can be refreshed up to 12 hours.
  v_expires_at := timezone('Asia/Bangkok', now()) + interval '15 minutes';
  v_max_expires_at := timezone('Asia/Bangkok', now()) + interval '12 hours';

  -- Store session in database
  insert into public.app_user_sessions (user_id, token_hash, expires_at, max_expires_at)
  values (v_user_id, v_token_hash, v_expires_at, v_max_expires_at)
  on conflict (token_hash) do nothing;

  -- Return user data with session token
  return query
  select
    v_user_id,
    v_name,
    v_nickname,
    v_department,
    v_token,
    v_expires_at,
    v_max_expires_at;
end;
$$;

create or replace function public.touch_app_user_session(
  p_session_token text
)
returns table (
  user_id text,
  expires_at timestamp without time zone,
  max_expires_at timestamp without time zone
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamp without time zone;
begin
  v_now := timezone('Asia/Bangkok', now());

  update public.app_user_sessions as s
  set
    last_used_at = v_now,
    expires_at = least(v_now + interval '15 minutes', coalesce(s.max_expires_at, s.created_at + interval '12 hours'))
  where s.token_hash = p_session_token
    and s.revoked_at is null
    and s.expires_at > v_now
    and coalesce(s.max_expires_at, s.created_at + interval '12 hours') > v_now
  returning s.user_id, s.expires_at, coalesce(s.max_expires_at, s.created_at + interval '12 hours')
  into user_id, expires_at, max_expires_at;

  if user_id is null then
    return;
  end if;

  return next;
end;
$$;

-- Update verify_menu_pin_for_session RPC to check session validity
create or replace function public.verify_menu_pin_for_session(
  p_session_token text,
  p_menu_code text,
  p_pin text
)
returns table (
  is_valid boolean,
  user_id text,
  menu_code text
)
language sql
security definer
set search_path = public
as $$
  with session_check as (
    select
      s.user_id,
      s.expires_at
    from public.app_user_sessions as s
    where s.token_hash = p_session_token  -- Direct plaintext comparison
      and s.revoked_at is null
      and s.expires_at > timezone('Asia/Bangkok', now())
    limit 1
  )
  select
    (exists(
      select 1
      from public."UserMenuPIN" as mp
      where lower(mp.user_id) = lower((select user_id from session_check limit 1))
        and upper(mp.menu_code) = upper(trim(p_menu_code))
        and mp.is_active = true
        and (
          mp.pin_hash = trim(p_pin)
          or (
            mp.pin_hash like '$2%'
            and mp.pin_hash = extensions.crypt(trim(p_pin), mp.pin_hash)
          )
        )
    ))::boolean,
    (select user_id from session_check limit 1),
    upper(trim(p_menu_code));
$$;

-- Return active menu permissions for the current valid app session.
create or replace function public.get_allowed_menus_for_session(
  p_session_token text
)
returns table (
  menu_code text
)
language sql
security definer
set search_path = public
as $$
  with session_check as (
    select s.user_id
    from public.app_user_sessions as s
    where s.token_hash = p_session_token
      and s.revoked_at is null
      and s.expires_at > timezone('Asia/Bangkok', now())
    limit 1
  )
  select menu_code
  from (
    select distinct rpm.menu_code
    from public.app_user_roles as ur
    join public.app_roles as r
      on r.role_code = ur.role_code
      and r.is_active = true
    join public.app_role_menu_permissions as rpm
      on rpm.role_code = ur.role_code
      and rpm.can_access = true
    join public.app_menus as m
      on m.menu_code = rpm.menu_code
      and m.is_active = true
    where lower(ur.user_id) = lower((select user_id from session_check limit 1))
      and ur.is_active = true

    union

    select up.menu_code
    from public.app_user_menu_permissions as up
    join public.app_menus as m
      on m.menu_code = up.menu_code
      and m.is_active = true
    where lower(up.user_id) = lower((select user_id from session_check limit 1))
      and up.permission_effect = 'ALLOW'
  ) as allowed
  where not exists (
    select 1
    from public.app_user_menu_permissions as denied
    where lower(denied.user_id) = lower((select user_id from session_check limit 1))
      and denied.menu_code = allowed.menu_code
      and denied.permission_effect = 'DENY'
  )
  order by menu_code;
$$;

-- Check whether a valid app session can access one specific menu.
create or replace function public.check_menu_access_for_session(
  p_session_token text,
  p_menu_code text
)
returns table (
  has_access boolean,
  user_id text,
  menu_code text
)
language sql
security definer
set search_path = public
as $$
  with session_check as (
    select s.user_id
    from public.app_user_sessions as s
    where s.token_hash = p_session_token
      and s.revoked_at is null
      and s.expires_at > timezone('Asia/Bangkok', now())
    limit 1
  )
  select
    exists(
      select 1
      from (
        select distinct rpm.menu_code
        from public.app_user_roles as ur
        join public.app_roles as r
          on r.role_code = ur.role_code
          and r.is_active = true
        join public.app_role_menu_permissions as rpm
          on rpm.role_code = ur.role_code
          and rpm.can_access = true
        join public.app_menus as m
          on m.menu_code = rpm.menu_code
          and m.is_active = true
        where lower(ur.user_id) = lower((select user_id from session_check limit 1))
          and ur.is_active = true

        union

        select up.menu_code
        from public.app_user_menu_permissions as up
        join public.app_menus as m
          on m.menu_code = up.menu_code
          and m.is_active = true
        where lower(up.user_id) = lower((select user_id from session_check limit 1))
          and up.permission_effect = 'ALLOW'
      ) as allowed
      where allowed.menu_code = upper(trim(p_menu_code))
        and not exists (
          select 1
          from public.app_user_menu_permissions as denied
          where lower(denied.user_id) = lower((select user_id from session_check limit 1))
            and denied.menu_code = allowed.menu_code
            and denied.permission_effect = 'DENY'
        )
    )::boolean as has_access,
    (select user_id from session_check limit 1) as user_id,
    upper(trim(p_menu_code)) as menu_code;
$$;

comment on function public.verify_user_login(text, text) is
'Authenticates user and creates a session token with 15-minute expiration.';

comment on function public.verify_menu_pin_for_session(text, text, text) is
'Verifies session is valid, then checks menu PIN for that user.';

comment on function public.get_allowed_menus_for_session(text) is
'Returns active menu codes available to the user for a valid app session.';

comment on function public.check_menu_access_for_session(text, text) is
'Checks whether a valid app session has access to a specific menu code.';

grant execute on function public.verify_user_login(text, text) to anon, authenticated;
grant execute on function public.touch_app_user_session(text) to anon, authenticated;
grant execute on function public.verify_menu_pin_for_session(text, text, text) to anon, authenticated;
grant execute on function public.get_allowed_menus_for_session(text) to anon, authenticated;
grant execute on function public.check_menu_access_for_session(text, text) to anon, authenticated;
