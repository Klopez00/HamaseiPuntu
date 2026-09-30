-- Hamasei Puntu · ranking general (todos los usuarios) + opción de no aparecer
-- Sustituye a los antiguos 05 y 06. Ejecutar en un editor en blanco. Idempotente.
--
-- Por defecto todos los usuarios aparecen en el ranking general (show_in_global = true).
-- Cada usuario puede salirse desde la app (show_in_global = false); entonces no aparece
-- y sus puntos no cuentan para las posiciones de los demás.
-- El ranking de grupo no se ve afectado: los miembros de un mismo grupo siempre se ven entre sí.
--
-- p_period: 'week' (semana actual, lunes-domingo, Europe/Berlin) o 'all' (total histórico)
-- p_limit : tamaño del top (1-50). Siempre devuelve también la fila del usuario que llama,
--           si aparece en el ranking, aunque quede fuera del top.
-- Solo expone apodo y puntos; nunca correo ni identificador de Google.

alter table public.profiles
  add column if not exists show_in_global boolean not null default true;

create or replace function public.global_ranking(p_period text default 'week', p_limit int default 10)
returns table (user_id uuid, nickname text, points numeric, rank int, is_me boolean)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_limit int  := least(greatest(coalesce(p_limit, 10), 1), 50);
  v_week  date := date_trunc('week', (now() at time zone 'Europe/Berlin')::timestamp)::date;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  if p_period not in ('week', 'all') then
    raise exception 'invalid_period';
  end if;

  return query
  with t as (
    select s.user_id as uid, sum(s.points) as pts
    from public.sessions s
    join public.profiles pr on pr.id = s.user_id and pr.show_in_global
    where p_period = 'all' or s.day >= v_week
    group by s.user_id
    having sum(s.points) > 0
  ),
  r as (
    select t.uid, t.pts, (rank() over (order by t.pts desc))::int as rk
    from t
  )
  select r.uid, p.nickname, r.pts, r.rk, (r.uid = v_uid)
  from r
  join public.profiles p on p.id = r.uid
  where r.rk <= v_limit or r.uid = v_uid
  order by r.rk, p.nickname;
end;
$$;

revoke all on function public.global_ranking(text, int) from public, anon;
grant execute on function public.global_ranking(text, int) to authenticated;
