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
  alter column created_at set default timezone('Asia/Bangkok', now()),
  alter column last_used_at set default timezone('Asia/Bangkok', now());

-- Create index for faster lookups
create index if not exists idx_app_user_sessions_user_id on public.app_user_sessions(user_id);
create index if not exists idx_app_user_sessions_token_hash on public.app_user_sessions(token_hash);
create index if not exists idx_app_user_sessions_expires_at on public.app_user_sessions(expires_at);

-- Enable RLS
alter table public.app_user_sessions enable row level security;

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

-- Update verify_user_login RPC to generate session token
create or replace function public.verify_user_login(
  p_user_id text,
  p_password text
)
returns table (
  user_id text,
  nickname text,
  department text,
  session_token text,
  expires_at timestamp without time zone
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id text;
  v_nickname text;
  v_department text;
  v_password_hash text;
  v_token text;
  v_token_hash text;
  v_expires_at timestamp without time zone;
begin
  -- Verify user credentials
  select u.user_id, u."NicKname", u."Department", u.password_hash
  into v_user_id, v_nickname, v_department, v_password_hash
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
  
  -- Set expiration to 24 hours from now
  v_expires_at := timezone('Asia/Bangkok', now()) + interval '24 hours';

  -- Store session in database
  insert into public.app_user_sessions (user_id, token_hash, expires_at)
  values (v_user_id, v_token_hash, v_expires_at)
  on conflict (token_hash) do nothing;

  -- Return user data with session token
  return query
  select
    v_user_id,
    v_nickname,
    v_department,
    v_token,
    v_expires_at;
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

comment on function public.verify_user_login(text, text) is
'Authenticates user and creates a session token with 24-hour expiration.';

comment on function public.verify_menu_pin_for_session(text, text, text) is
'Verifies session is valid, then checks menu PIN for that user.';

grant execute on function public.verify_user_login(text, text) to anon, authenticated;
grant execute on function public.verify_menu_pin_for_session(text, text, text) to anon, authenticated;
