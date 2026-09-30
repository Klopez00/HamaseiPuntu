-- Hamasei Puntu · esquema base (tablas + RLS + RPC)
-- Pegar entero en Supabase -> SQL Editor -> New query -> Run

-- ========== TABLAS ==========

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nickname text not null,
  created_at timestamptz not null default now(),
  constraint nickname_format check (nickname ~ '^[A-Za-z0-9_ñÑ.-]{3,20}$')
);
create unique index profiles_nickname_key on public.profiles (lower(nickname));

create table public.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  completed_at timestamptz not null default now(),
  -- día natural en Europe/Berlin (mismo offset y DST que Madrid)
  day date generated always as ((completed_at at time zone 'Europe/Berlin')::date) stored,
  points smallint not null check (points between 0 and 16)
);
create index sessions_user_day on public.sessions (user_id, day);

create table public.study_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text not null unique default upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8)),
  created_at timestamptz not null default now()
);

create table public.group_members (
  id bigint generated always as identity primary key,
  group_id uuid not null references public.study_groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  check (left_at is null or left_at > joined_at)
);
-- una sola membresía activa por usuario y grupo; el histórico se conserva
create unique index group_members_active_key
  on public.group_members (group_id, user_id) where left_at is null;
create index group_members_user on public.group_members (user_id);

-- ========== FUNCIONES AUXILIARES (evitan recursión en RLS) ==========

create or replace function public.is_group_member(p_group uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.group_members
    where group_id = p_group and user_id = auth.uid() and left_at is null
  );
$$;

create or replace function public.shares_group_with(p_user uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.group_members me
    join public.group_members other on other.group_id = me.group_id
    where me.user_id = auth.uid() and me.left_at is null
      and other.user_id = p_user
  );
$$;

-- ========== RLS ==========

alter table public.profiles      enable row level security;
alter table public.sessions      enable row level security;
alter table public.study_groups  enable row level security;
alter table public.group_members enable row level security;

-- profiles: ves el tuyo y los de quienes comparten grupo contigo
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or public.shares_group_with(id));
create policy profiles_insert on public.profiles for insert to authenticated
  with check (id = (select auth.uid()));
create policy profiles_update on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- sessions: solo lectura de las propias; el insert va por complete_session()
create policy sessions_select on public.sessions for select to authenticated
  using (user_id = (select auth.uid()));

-- study_groups: solo lectura si eres miembro activo; los creas tú desde el panel
create policy groups_select on public.study_groups for select to authenticated
  using (public.is_group_member(id));

-- group_members: ves tu fila y las de tus grupos; alta/baja por RPC
create policy members_select on public.group_members for select to authenticated
  using (user_id = (select auth.uid()) or public.is_group_member(group_id));

-- ========== RPC ==========

-- Sesión completada: otorga LEAST(16, 50 - puntos_del_día); cuenta para racha aunque dé 0
create or replace function public.complete_session()
returns table (awarded int, total_today int)
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date := (now() at time zone 'Europe/Berlin')::date;
  v_done  int;
  v_award int;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  -- serializa llamadas concurrentes del mismo usuario (evita pasarse del tope)
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text, 0));

  select coalesce(sum(s.points), 0) into v_done
  from public.sessions s
  where s.user_id = v_uid and s.day = v_today;

  v_award := greatest(0, least(16, 50 - v_done));

  insert into public.sessions (user_id, points) values (v_uid, v_award);

  return query select v_award, v_done + v_award;
end;
$$;

-- Unirse a un grupo con código de invitación
create or replace function public.join_group(p_code text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_gid uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select id into v_gid from public.study_groups
  where invite_code = upper(trim(p_code));
  if v_gid is null then
    raise exception 'invalid_code';
  end if;

  insert into public.group_members (group_id, user_id)
  values (v_gid, v_uid)
  on conflict (group_id, user_id) where left_at is null do nothing;

  return v_gid;
end;
$$;

-- Salir de un grupo (conserva el histórico)
create or replace function public.leave_group(p_group uuid)
returns void
language sql security definer set search_path = ''
as $$
  update public.group_members
  set left_at = now()
  where group_id = p_group and user_id = auth.uid() and left_at is null;
$$;

-- Permisos: solo usuarios autenticados pueden ejecutar las RPC
revoke all on function public.complete_session()       from public, anon;
revoke all on function public.join_group(text)         from public, anon;
revoke all on function public.leave_group(uuid)        from public, anon;
revoke all on function public.is_group_member(uuid)    from public, anon;
revoke all on function public.shares_group_with(uuid)  from public, anon;
grant execute on function public.complete_session()       to authenticated;
grant execute on function public.join_group(text)         to authenticated;
grant execute on function public.leave_group(uuid)        to authenticated;
grant execute on function public.is_group_member(uuid)    to authenticated;
grant execute on function public.shares_group_with(uuid)  to authenticated;

-- ========== CREAR UN GRUPO (ejemplo, ejecutar aparte cuando quieras) ==========
-- insert into public.study_groups (name) values ('Grupo 1') returning id, invite_code;
