-- Attendance System database setup.
-- Run this file in Supabase SQL Editor.

create extension if not exists pgcrypto;

alter table public."UserIDdemoDATA"
  add column if not exists "Company" text,
  add column if not exists "Name" text;

update public."UserIDdemoDATA"
set "Company" = nullif(trim(split_part(user_id, '@', 2)), '')
where user_id like '%@%'
  and ("Company" is null or trim("Company") = '');

insert into storage.buckets (id, name, public)
values ('attendance-photos', 'attendance-photos', true)
on conflict (id) do update set public = true;

drop policy if exists "allow_attendance_photos_read" on storage.objects;
drop policy if exists "allow_attendance_photos_insert" on storage.objects;

create policy "allow_attendance_photos_read"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'attendance-photos');

create policy "allow_attendance_photos_insert"
  on storage.objects for insert
  to anon, authenticated
  with check (bucket_id = 'attendance-photos');

create table if not exists public.attendance_records (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id text not null,
  nickname text,
  department text,
  work_date date not null default (timezone('Asia/Bangkok', now()))::date,
  checkin_type text not null,
  checkin_at timestamp without time zone not null default timezone('Asia/Bangkok', now()),
  checkout_at timestamp without time zone,
  captured_at timestamp without time zone,
  capture_date text,
  capture_time text,
  latitude double precision,
  longitude double precision,
  address text,
  note text,
  photo_data_url text,
  checkout_note text,
  created_at timestamp without time zone not null default timezone('Asia/Bangkok', now()),
  updated_at timestamp without time zone not null default timezone('Asia/Bangkok', now())
);

alter table public.attendance_records
  add column if not exists checkout_captured_at timestamp without time zone,
  add column if not exists checkout_capture_date text,
  add column if not exists checkout_capture_time text,
  add column if not exists checkout_latitude double precision,
  add column if not exists checkout_longitude double precision,
  add column if not exists checkout_address text,
  add column if not exists checkout_photo_data_url text;

create index if not exists idx_attendance_records_user_date
  on public.attendance_records(user_id, work_date);

create unique index if not exists uq_attendance_records_user_date
  on public.attendance_records(user_id, work_date);

create index if not exists idx_attendance_records_checkout
  on public.attendance_records(user_id, checkout_at);

create table if not exists public.attendance_field_checkins (
  id uuid primary key default extensions.gen_random_uuid(),
  attendance_id uuid not null references public.attendance_records(id) on delete cascade,
  user_id text not null,
  sequence_no integer not null,
  location_name text not null,
  checked_at timestamp without time zone not null default timezone('Asia/Bangkok', now()),
  captured_at timestamp without time zone,
  capture_date text,
  capture_time text,
  latitude double precision not null,
  longitude double precision not null,
  accuracy_meters double precision,
  distance_km numeric(10, 3),
  address text,
  note text,
  photo_data_url text,
  created_at timestamp without time zone not null default timezone('Asia/Bangkok', now())
);

create unique index if not exists uq_attendance_field_checkins_sequence
  on public.attendance_field_checkins(attendance_id, sequence_no);

create index if not exists idx_attendance_field_checkins_user_checked
  on public.attendance_field_checkins(user_id, checked_at);

create table if not exists public.attendance_day_remarks (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id text not null,
  work_date date not null,
  remark_type text not null check (remark_type in ('absent', 'leave', 'personal_leave', 'sick_leave', 'annual_leave', 'normal_before_launch', 'holiday', 'forgot_checkin', 'other')),
  remark_note text,
  created_at timestamp without time zone not null default timezone('Asia/Bangkok', now()),
  updated_at timestamp without time zone not null default timezone('Asia/Bangkok', now()),
  unique (user_id, work_date)
);

alter table public.attendance_day_remarks
  drop constraint if exists attendance_day_remarks_remark_type_check;

alter table public.attendance_day_remarks
  add constraint attendance_day_remarks_remark_type_check
  check (remark_type in ('absent', 'leave', 'personal_leave', 'sick_leave', 'annual_leave', 'normal_before_launch', 'holiday', 'forgot_checkin', 'other'));

create index if not exists idx_attendance_day_remarks_user_date
  on public.attendance_day_remarks(user_id, work_date);

alter table public.attendance_records enable row level security;
alter table public.attendance_field_checkins enable row level security;
alter table public.attendance_day_remarks enable row level security;

drop policy if exists "allow_attendance_select" on public.attendance_records;
drop policy if exists "allow_attendance_field_checkins_select" on public.attendance_field_checkins;
drop policy if exists "allow_attendance_day_remarks_select" on public.attendance_day_remarks;

create policy "allow_attendance_select"
  on public.attendance_records for select
  to anon, authenticated
  using (true);

create policy "allow_attendance_field_checkins_select"
  on public.attendance_field_checkins for select
  to anon, authenticated
  using (true);

create policy "allow_attendance_day_remarks_select"
  on public.attendance_day_remarks for select
  to anon, authenticated
  using (true);

revoke all on table public.attendance_records from anon, authenticated;
grant select on table public.attendance_records to anon, authenticated;
revoke all on table public.attendance_field_checkins from anon, authenticated;
grant select on table public.attendance_field_checkins to anon, authenticated;
revoke all on table public.attendance_day_remarks from anon, authenticated;
grant select on table public.attendance_day_remarks to anon, authenticated;

create or replace function public.get_attendance_server_time()
returns table (
  server_time timestamp without time zone,
  server_time_iso text,
  work_date date
)
language sql
security definer
set search_path = public
as $$
  select
    timezone('Asia/Bangkok', now())::timestamp without time zone as server_time,
    to_char(timezone('Asia/Bangkok', now()), 'YYYY-MM-DD"T"HH24:MI:SS') || '+07:00' as server_time_iso,
    (timezone('Asia/Bangkok', now()))::date as work_date;
$$;

create or replace function public.record_attendance_checkin(
  p_session_token text,
  p_checkin_type text,
  p_captured_at timestamp without time zone default null,
  p_capture_date text default null,
  p_capture_time text default null,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_address text default null,
  p_note text default null,
  p_photo_data_url text default null
)
returns table (
  id uuid,
  user_id text,
  checkin_at timestamp without time zone,
  checkout_at timestamp without time zone
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id text;
  v_nickname text;
  v_department text;
  v_record_id uuid;
begin
  select s.user_id
  into v_user_id
  from public.app_user_sessions as s
  where s.token_hash = p_session_token
    and s.revoked_at is null
    and s.expires_at > timezone('Asia/Bangkok', now())
  limit 1;

  if v_user_id is null then
    raise exception 'Invalid or expired session';
  end if;

  if exists (
    select 1
    from public.attendance_records as ar
    where ar.user_id = v_user_id
      and ar.work_date = (timezone('Asia/Bangkok', now()))::date
  ) then
    raise exception 'Attendance for today has already been recorded';
  end if;

  select u."NicKname", u."Department"
  into v_nickname, v_department
  from public."UserIDdemoDATA" as u
  where lower(u.user_id) = lower(v_user_id)
  limit 1;

  insert into public.attendance_records (
    user_id,
    nickname,
    department,
    checkin_type,
    captured_at,
    capture_date,
    capture_time,
    latitude,
    longitude,
    address,
    note,
    photo_data_url
  )
  values (
    v_user_id,
    v_nickname,
    v_department,
    coalesce(nullif(trim(p_checkin_type), ''), 'Office'),
    timezone('Asia/Bangkok', now()),
    nullif(trim(p_capture_date), ''),
    nullif(trim(p_capture_time), ''),
    p_latitude,
    p_longitude,
    nullif(trim(p_address), ''),
    nullif(trim(p_note), ''),
    p_photo_data_url
  )
  returning attendance_records.id into v_record_id;

  return query
  select
    ar.id,
    ar.user_id,
    ar.checkin_at,
    ar.checkout_at
  from public.attendance_records as ar
  where ar.id = v_record_id;
end;
$$;

drop function if exists public.record_attendance_checkout(text, uuid, text);

create or replace function public.record_attendance_checkout(
  p_session_token text,
  p_attendance_id uuid default null,
  p_checkout_note text default null,
  p_checkout_captured_at timestamp without time zone default null,
  p_checkout_capture_date text default null,
  p_checkout_capture_time text default null,
  p_checkout_latitude double precision default null,
  p_checkout_longitude double precision default null,
  p_checkout_address text default null,
  p_checkout_photo_data_url text default null
)
returns table (
  id uuid,
  user_id text,
  checkin_at timestamp without time zone,
  checkout_at timestamp without time zone
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id text;
  v_record_id uuid;
begin
  select s.user_id
  into v_user_id
  from public.app_user_sessions as s
  where s.token_hash = p_session_token
    and s.revoked_at is null
    and s.expires_at > timezone('Asia/Bangkok', now())
  limit 1;

  if v_user_id is null then
    raise exception 'Invalid or expired session';
  end if;

  select ar.id
  into v_record_id
  from public.attendance_records as ar
  where ar.user_id = v_user_id
    and ar.checkout_at is null
    and (p_attendance_id is null or ar.id = p_attendance_id)
  order by ar.checkin_at desc
  limit 1;

  if v_record_id is null then
    raise exception 'No open attendance record found';
  end if;

  update public.attendance_records as ar
  set
    checkout_at = timezone('Asia/Bangkok', now()),
    checkout_note = nullif(trim(p_checkout_note), ''),
    checkout_captured_at = p_checkout_captured_at,
    checkout_capture_date = nullif(trim(p_checkout_capture_date), ''),
    checkout_capture_time = nullif(trim(p_checkout_capture_time), ''),
    checkout_latitude = p_checkout_latitude,
    checkout_longitude = p_checkout_longitude,
    checkout_address = nullif(trim(p_checkout_address), ''),
    checkout_photo_data_url = p_checkout_photo_data_url,
    updated_at = timezone('Asia/Bangkok', now())
  where ar.id = v_record_id;

  return query
  select
    ar.id,
    ar.user_id,
    ar.checkin_at,
    ar.checkout_at
  from public.attendance_records as ar
  where ar.id = v_record_id;
end;
$$;

create or replace function public.get_today_attendance_status(
  p_session_token text
)
returns table (
  id uuid,
  user_id text,
  checkin_type text,
  checkin_at timestamp without time zone,
  checkout_at timestamp without time zone,
  captured_at timestamp without time zone,
  capture_date text,
  capture_time text,
  latitude double precision,
  longitude double precision,
  address text,
  note text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id text;
begin
  select s.user_id
  into v_user_id
  from public.app_user_sessions as s
  where s.token_hash = p_session_token
    and s.revoked_at is null
    and s.expires_at > timezone('Asia/Bangkok', now())
  limit 1;

  if v_user_id is null then
    raise exception 'Invalid or expired session';
  end if;

  return query
  select
    ar.id,
    ar.user_id,
    ar.checkin_type,
    ar.checkin_at,
    ar.checkout_at,
    ar.captured_at,
    ar.capture_date,
    ar.capture_time,
    ar.latitude,
    ar.longitude,
    ar.address,
    ar.note
  from public.attendance_records as ar
  where ar.user_id = v_user_id
    and ar.work_date = (timezone('Asia/Bangkok', now()))::date
  order by
    case when ar.checkout_at is null then 0 else 1 end,
    ar.checkin_at desc
  limit 1;
end;
$$;

create or replace function public.record_attendance_field_checkin(
  p_session_token text,
  p_attendance_id uuid,
  p_captured_at timestamp without time zone default null,
  p_capture_date text default null,
  p_capture_time text default null,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_accuracy_meters double precision default null,
  p_distance_km numeric default null,
  p_address text default null,
  p_note text default null,
  p_photo_data_url text default null
)
returns table (
  id uuid,
  attendance_id uuid,
  user_id text,
  sequence_no integer,
  location_name text,
  checked_at timestamp without time zone,
  captured_at timestamp without time zone,
  latitude double precision,
  longitude double precision,
  accuracy_meters double precision,
  distance_km numeric,
  address text,
  note text,
  photo_data_url text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id text;
  v_attendance_id uuid;
  v_sequence_no integer;
  v_record_id uuid;
begin
  select s.user_id
  into v_user_id
  from public.app_user_sessions as s
  where s.token_hash = p_session_token
    and s.revoked_at is null
    and s.expires_at > timezone('Asia/Bangkok', now())
  limit 1;

  if v_user_id is null then
    raise exception 'Invalid or expired session';
  end if;

  select ar.id
  into v_attendance_id
  from public.attendance_records as ar
  where ar.id = p_attendance_id
    and ar.user_id = v_user_id
    and ar.checkout_at is null
    and ar.work_date = (timezone('Asia/Bangkok', now()))::date
  limit 1;

  if v_attendance_id is null then
    raise exception 'No open attendance record found for field check-in';
  end if;

  if p_latitude is null or p_longitude is null then
    raise exception 'Latitude and longitude are required';
  end if;

  select coalesce(max(afc.sequence_no), 0) + 1
  into v_sequence_no
  from public.attendance_field_checkins as afc
  where afc.attendance_id = v_attendance_id;

  insert into public.attendance_field_checkins (
    attendance_id,
    user_id,
    sequence_no,
    location_name,
    checked_at,
    captured_at,
    capture_date,
    capture_time,
    latitude,
    longitude,
    accuracy_meters,
    distance_km,
    address,
    note,
    photo_data_url
  )
  values (
    v_attendance_id,
    v_user_id,
    v_sequence_no,
    'จุดที่ ' || v_sequence_no,
    timezone('Asia/Bangkok', now()),
    p_captured_at,
    nullif(trim(p_capture_date), ''),
    nullif(trim(p_capture_time), ''),
    p_latitude,
    p_longitude,
    p_accuracy_meters,
    p_distance_km,
    nullif(trim(p_address), ''),
    nullif(trim(p_note), ''),
    p_photo_data_url
  )
  returning attendance_field_checkins.id into v_record_id;

  return query
  select
    afc.id,
    afc.attendance_id,
    afc.user_id,
    afc.sequence_no,
    afc.location_name,
    afc.checked_at,
    afc.captured_at,
    afc.latitude,
    afc.longitude,
    afc.accuracy_meters,
    afc.distance_km,
    afc.address,
    afc.note,
    afc.photo_data_url
  from public.attendance_field_checkins as afc
  where afc.id = v_record_id;
end;
$$;

create or replace function public.get_today_attendance_field_checkins(
  p_session_token text
)
returns table (
  id uuid,
  attendance_id uuid,
  user_id text,
  sequence_no integer,
  location_name text,
  checked_at timestamp without time zone,
  captured_at timestamp without time zone,
  latitude double precision,
  longitude double precision,
  accuracy_meters double precision,
  distance_km numeric,
  address text,
  note text,
  photo_data_url text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id text;
begin
  select s.user_id
  into v_user_id
  from public.app_user_sessions as s
  where s.token_hash = p_session_token
    and s.revoked_at is null
    and s.expires_at > timezone('Asia/Bangkok', now())
  limit 1;

  if v_user_id is null then
    raise exception 'Invalid or expired session';
  end if;

  return query
  select
    afc.id,
    afc.attendance_id,
    afc.user_id,
    afc.sequence_no,
    afc.location_name,
    afc.checked_at,
    afc.captured_at,
    afc.latitude,
    afc.longitude,
    afc.accuracy_meters,
    afc.distance_km,
    afc.address,
    afc.note,
    afc.photo_data_url
  from public.attendance_field_checkins as afc
  join public.attendance_records as ar
    on ar.id = afc.attendance_id
  where afc.user_id = v_user_id
    and ar.work_date = (timezone('Asia/Bangkok', now()))::date
  order by afc.sequence_no asc;
end;
$$;

drop function if exists public.save_my_attendance_day_remark(text, date, text, text);

create or replace function public.save_my_attendance_day_remark(
  p_session_token text,
  p_work_date date,
  p_remark_type text,
  p_remark_note text default null
)
returns table (
  id uuid,
  employee_id text,
  work_date date,
  remark_type text,
  remark_note text,
  updated_at timestamp without time zone
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id text;
  v_remark_type text;
begin
  select s.user_id
  into v_user_id
  from public.app_user_sessions as s
  where s.token_hash = p_session_token
    and s.revoked_at is null
    and s.expires_at > timezone('Asia/Bangkok', now())
  limit 1;

  if v_user_id is null then
    raise exception 'Invalid or expired session';
  end if;

  if p_work_date is null then
    raise exception 'Work date is required';
  end if;

  if p_work_date < ((timezone('Asia/Bangkok', now()))::date - interval '31 days')::date then
    raise exception 'Remark can only be saved within 31 days';
  end if;

  v_remark_type := lower(trim(coalesce(p_remark_type, '')));
  if v_remark_type not in ('absent', 'leave', 'personal_leave', 'sick_leave', 'annual_leave', 'normal_before_launch', 'holiday', 'forgot_checkin', 'other') then
    raise exception 'Invalid remark type';
  end if;

  insert into public.attendance_day_remarks (
    user_id,
    work_date,
    remark_type,
    remark_note,
    updated_at
  )
  values (
    v_user_id,
    p_work_date,
    v_remark_type,
    nullif(trim(p_remark_note), ''),
    timezone('Asia/Bangkok', now())
  )
  on conflict on constraint attendance_day_remarks_user_id_work_date_key do update
  set
    remark_type = excluded.remark_type,
    remark_note = excluded.remark_note,
    updated_at = timezone('Asia/Bangkok', now());

  return query
  select
    adr.id,
    adr.user_id as employee_id,
    adr.work_date,
    adr.remark_type,
    adr.remark_note,
    adr.updated_at
  from public.attendance_day_remarks as adr
  where lower(adr.user_id) = lower(v_user_id)
    and adr.work_date = p_work_date
  limit 1;
end;
$$;

insert into public.app_menus (menu_code, menu_name, menu_path, display_order, requires_pin)
values
  ('HR_MONITOR', 'HR Monitor', 'HRMonitor.html', 41, false)
on conflict (menu_code) do update
set
  menu_name = excluded.menu_name,
  menu_path = excluded.menu_path,
  display_order = excluded.display_order,
  requires_pin = excluded.requires_pin,
  is_active = true;

insert into public.app_role_menu_permissions (role_code, menu_code, can_access)
values
  ('ADMIN', 'HR_MONITOR', true),
  ('HR', 'HR_MONITOR', true)
on conflict (role_code, menu_code) do update
set can_access = excluded.can_access;

create or replace function public.get_hr_attendance_monitor(
  p_session_token text,
  p_work_date date default (timezone('Asia/Bangkok', now()))::date
)
returns table (
  employee_id text,
  employee_name text,
  department text,
  role text,
  attendance_id uuid,
  checkin_type text,
  checkin_at timestamp without time zone,
  checkout_at timestamp without time zone,
  address text,
  status text,
  field_points jsonb
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id text;
  v_has_access boolean;
begin
  select s.user_id
  into v_user_id
  from public.app_user_sessions as s
  where s.token_hash = p_session_token
    and s.revoked_at is null
    and s.expires_at > timezone('Asia/Bangkok', now())
  limit 1;

  if v_user_id is null then
    raise exception 'Invalid or expired session';
  end if;

  select exists (
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
      where lower(ur.user_id) = lower(v_user_id)
        and ur.is_active = true

      union

      select up.menu_code
      from public.app_user_menu_permissions as up
      join public.app_menus as m
        on m.menu_code = up.menu_code
        and m.is_active = true
      where lower(up.user_id) = lower(v_user_id)
        and up.permission_effect = 'ALLOW'
    ) as allowed
    where allowed.menu_code = 'HR_MONITOR'
      and not exists (
        select 1
        from public.app_user_menu_permissions as denied
        where lower(denied.user_id) = lower(v_user_id)
          and denied.menu_code = 'HR_MONITOR'
          and denied.permission_effect = 'DENY'
      )
  )
  into v_has_access;

  if not v_has_access then
    raise exception 'Access denied for HR Monitor';
  end if;

  return query
  select
    u.user_id::text as employee_id,
    coalesce(nullif(trim(u."Name"), ''), nullif(trim(u."NicKname"), ''), u.user_id)::text as employee_name,
    nullif(trim(u."Department"), '')::text as department,
    null::text as role,
    ar.id as attendance_id,
    ar.checkin_type,
    ar.checkin_at,
    ar.checkout_at,
    ar.address,
    case
      when ar.id is null then 'pending'
      when ar.checkout_at is not null then 'completed'
      when ((extract(hour from ar.checkin_at)::integer * 60) + extract(minute from ar.checkin_at)::integer) > 555 then 'late-over'
      when ((extract(hour from ar.checkin_at)::integer * 60) + extract(minute from ar.checkin_at)::integer) > 540 then 'late'
      else 'on-time'
    end as status,
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', afc.id,
            'attendance_id', afc.attendance_id,
            'sequence_no', afc.sequence_no,
            'location_name', afc.location_name,
            'checked_at', afc.checked_at,
            'captured_at', afc.captured_at,
            'latitude', afc.latitude,
            'longitude', afc.longitude,
            'accuracy_meters', afc.accuracy_meters,
            'distance_km', afc.distance_km,
            'address', afc.address,
            'note', afc.note,
            'photo_data_url', afc.photo_data_url
          )
          order by afc.sequence_no
        )
        from public.attendance_field_checkins as afc
        where afc.attendance_id = ar.id
      ),
      '[]'::jsonb
    ) as field_points
  from public."UserIDdemoDATA" as u
  left join public.attendance_records as ar
    on lower(ar.user_id) = lower(u.user_id)
    and ar.work_date = coalesce(p_work_date, (timezone('Asia/Bangkok', now()))::date)
  where lower(trim(coalesce(u."Company", ''))) = 'ardent'
  order by
    case when ar.id is null then 1 else 0 end,
    ar.checkin_at asc nulls last,
    u."Department" asc nulls last,
    coalesce(nullif(trim(u."Name"), ''), nullif(trim(u."NicKname"), ''), u.user_id) asc nulls last;
end;
$$;

drop function if exists public.get_my_attendance_history(text, date, date);

create or replace function public.get_my_attendance_history(
  p_session_token text,
  p_start_date date,
  p_end_date date
)
returns table (
  work_date date,
  attendance_id uuid,
  checkin_type text,
  checkin_at timestamp without time zone,
  checkout_at timestamp without time zone,
  address text,
  note text,
  remark_type text,
  remark_note text,
  remark_updated_at timestamp without time zone,
  field_points jsonb
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id text;
  v_start_date date;
  v_end_date date;
begin
  select s.user_id
  into v_user_id
  from public.app_user_sessions as s
  where s.token_hash = p_session_token
    and s.revoked_at is null
    and s.expires_at > timezone('Asia/Bangkok', now())
  limit 1;

  if v_user_id is null then
    raise exception 'Invalid or expired session';
  end if;

  v_start_date = coalesce(p_start_date, (timezone('Asia/Bangkok', now()))::date);
  v_end_date = coalesce(p_end_date, v_start_date);

  if v_end_date < v_start_date then
    raise exception 'End date must be greater than or equal to start date';
  end if;

  if v_end_date - v_start_date > 366 then
    raise exception 'Date range is too large';
  end if;

  return query
  select
    days.work_date::date,
    ar.id as attendance_id,
    ar.checkin_type,
    ar.checkin_at,
    ar.checkout_at,
    ar.address,
    ar.note,
    adr.remark_type,
    adr.remark_note,
    adr.updated_at as remark_updated_at,
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', afc.id,
            'attendance_id', afc.attendance_id,
            'sequence_no', afc.sequence_no,
            'location_name', afc.location_name,
            'checked_at', afc.checked_at,
            'captured_at', afc.captured_at,
            'latitude', afc.latitude,
            'longitude', afc.longitude,
            'accuracy_meters', afc.accuracy_meters,
            'distance_km', afc.distance_km,
            'address', afc.address,
            'note', afc.note,
            'photo_data_url', afc.photo_data_url
          )
          order by afc.sequence_no
        )
        from public.attendance_field_checkins as afc
        where afc.attendance_id = ar.id
      ),
      '[]'::jsonb
    ) as field_points
  from generate_series(v_start_date, v_end_date, interval '1 day') as days(work_date)
  left join public.attendance_records as ar
    on ar.work_date = days.work_date::date
    and lower(ar.user_id) = lower(v_user_id)
  left join public.attendance_day_remarks as adr
    on adr.work_date = days.work_date::date
    and lower(adr.user_id) = lower(v_user_id)
  order by days.work_date desc;
end;
$$;

grant execute on function public.record_attendance_checkin(
  text,
  text,
  timestamp without time zone,
  text,
  text,
  double precision,
  double precision,
  text,
  text,
  text
) to anon, authenticated;

grant execute on function public.record_attendance_checkout(
  text,
  uuid,
  text,
  timestamp without time zone,
  text,
  text,
  double precision,
  double precision,
  text,
  text
) to anon, authenticated;
grant execute on function public.get_today_attendance_status(text) to anon, authenticated;
grant execute on function public.get_attendance_server_time() to anon, authenticated;
grant execute on function public.record_attendance_field_checkin(
  text,
  uuid,
  timestamp without time zone,
  text,
  text,
  double precision,
  double precision,
  double precision,
  numeric,
  text,
  text,
  text
) to anon, authenticated;
grant execute on function public.get_today_attendance_field_checkins(text) to anon, authenticated;
grant execute on function public.save_my_attendance_day_remark(text, date, text, text) to anon, authenticated;
grant execute on function public.get_hr_attendance_monitor(text, date) to anon, authenticated;
grant execute on function public.get_my_attendance_history(text, date, date) to anon, authenticated;
