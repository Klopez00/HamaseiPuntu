-- Hamasei Puntu · migración: puntos por rendimiento (decimales, 0-16 por sesión)
-- Ejecutar DESPUÉS de 01 y 02. Editor en blanco -> pegar -> Run.
-- Las vistas dependen de sessions.points, así que se recrean.

begin;

drop view if exists private.weekly_winners;
drop view if exists private.weekly_points;
drop function if exists public.weekly_ranking(uuid, date);
drop function if exists public.complete_session();

alter table public.sessions drop constraint if exists sessions_points_check;
alter table public.sessions alter column points type numeric(4,1);
alter table public.sessions
  add constraint sessions_points_range check (points >= 0 and points <= 16);

create view private.weekly_points as
select
  m.group_id,
  s.user_id,
  date_trunc('week', s.day::timestamp)::date as week,
  sum(s.points)      as points,
  count(*)::int      as sessions
from public.group_members m
join public.sessions s
  on s.user_id = m.user_id
 and s.completed_at >= m.joined_at
 and (m.left_at is null or s.completed_at < m.left_at)
group by m.group_id, s.user_id, date_trunc('week', s.day::timestamp)::date;

create view private.weekly_winners as
select group_id, user_id, week, points
from (
  select w.*, max(w.points) over (partition by w.group_id, w.week) as max_points
  from private.weekly_points w
) t
where points = max_points
  and points > 0
  and week < date_trunc('week', (now() at time zone 'Europe/Berlin')::timestamp)::date;

create or replace function public.weekly_ranking(p_group uuid, p_week date default null)
returns table (user_id uuid, nickname text, points numeric, sessions int, rank int)
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

-- El cliente envía los puntos de la sesión (0-16, con bonus incluido);
-- el servidor los recorta a 0-16, redondea a 1 decimal y aplica el tope de 50/día.
create or replace function public.complete_session(p_points numeric)
returns table (awarded numeric, total_today numeric)
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid   uuid    := auth.uid();
  v_today date    := (now() at time zone 'Europe/Berlin')::date;
  v_pts   numeric := round(least(greatest(coalesce(p_points, 0), 0), 16), 1);
  v_done  numeric;
  v_award numeric;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_uid::text, 0));

  select coalesce(sum(s.points), 0) into v_done
  from public.sessions s
  where s.user_id = v_uid and s.day = v_today;

  v_award := greatest(0, least(v_pts, 50 - v_done));

  insert into public.sessions (user_id, points) values (v_uid, v_award);

  return query select v_award, v_done + v_award;
end;
$$;

revoke all on function public.weekly_ranking(uuid, date) from public, anon;
revoke all on function public.complete_session(numeric)  from public, anon;
grant execute on function public.weekly_ranking(uuid, date) to authenticated;
grant execute on function public.complete_session(numeric)  to authenticated;

commit;
