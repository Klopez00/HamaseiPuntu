-- Hamasei Puntu · vistas y RPC de lectura
-- Ejecutar DESPUÉS de 01_schema.sql (SQL Editor -> New query -> Run)

create schema if not exists private;

-- Puntos por grupo, usuario y semana (lunes-domingo, Europe/Berlin),
-- contando solo sesiones dentro de cada periodo de membresía.
create or replace view private.weekly_points as
select
  m.group_id,
  s.user_id,
  date_trunc('week', s.day::timestamp)::date as week,
  sum(s.points)::int as points,
  count(*)::int      as sessions
from public.group_members m
join public.sessions s
  on s.user_id = m.user_id
 and s.completed_at >= m.joined_at
 and (m.left_at is null or s.completed_at < m.left_at)
group by m.group_id, s.user_id, date_trunc('week', s.day::timestamp)::date;

-- Ganadores por semana cerrada: máximo de puntos > 0; empate = ganan todos.
create or replace view private.weekly_winners as
select group_id, user_id, week, points
from (
  select w.*, max(w.points) over (partition by w.group_id, w.week) as max_points
  from private.weekly_points w
) t
where points = max_points
  and points > 0
  and week < date_trunc('week', (now() at time zone 'Europe/Berlin')::timestamp)::date;

-- ========== RPC de lectura ==========

-- Ranking de una semana (por defecto, la actual)
create or replace function public.weekly_ranking(p_group uuid, p_week date default null)
returns table (user_id uuid, nickname text, points int, sessions int, rank int)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_group_member(p_group) then
    raise exception 'not_a_member';
  end if;

  return query
  select w.user_id, p.nickname, w.points, w.sessions,
         (rank() over (order by w.points desc))::int
  from private.weekly_points w
  join public.profiles p on p.id = w.user_id
  where w.group_id = p_group
    and w.week = coalesce(
          p_week,
          date_trunc('week', (now() at time zone 'Europe/Berlin')::timestamp)::date)
  order by 5, 2;
end;
$$;

-- Semanas ganadas por miembro en un grupo
create or replace function public.weeks_won(p_group uuid)
returns table (user_id uuid, nickname text, weeks_won int)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_group_member(p_group) then
    raise exception 'not_a_member';
  end if;

  return query
  select x.user_id, p.nickname, count(*)::int
  from private.weekly_winners x
  join public.profiles p on p.id = x.user_id
  where x.group_id = p_group
  group by x.user_id, p.nickname
  order by 3 desc, 2;
end;
$$;

-- Racha del usuario: días consecutivos con al menos una sesión.
-- La racha sigue viva si practicó hoy o ayer.
create or replace function public.my_streak()
returns table (current_streak int, best_streak int)
language sql stable security definer set search_path = ''
as $$
  with d as (
    select distinct s.day from public.sessions s where s.user_id = auth.uid()
  ),
  g as (
    select d.day, d.day - (row_number() over (order by d.day))::int as grp from d
  ),
  runs as (
    select max(g.day) as end_day, count(*)::int as len from g group by g.grp
  )
  select
    coalesce((select r.len from runs r
              where r.end_day >= (now() at time zone 'Europe/Berlin')::date - 1
              order by r.end_day desc limit 1), 0),
    coalesce((select max(r.len) from runs r), 0);
$$;

revoke all on function public.weekly_ranking(uuid, date) from public, anon;
revoke all on function public.weeks_won(uuid)            from public, anon;
revoke all on function public.my_streak()                from public, anon;
grant execute on function public.weekly_ranking(uuid, date) to authenticated;
grant execute on function public.weeks_won(uuid)            to authenticated;
grant execute on function public.my_streak()                to authenticated;
