-- Hamasei Puntu · permisos base para usuarios con sesión (rol authenticated)
-- Las políticas RLS filtran filas, pero antes el rol necesita permiso sobre la tabla.
-- Idempotente: se puede ejecutar más de una vez.

grant usage on schema public to authenticated;

-- profiles: leer, crear y editar el propio perfil (RLS limita a tu fila)
grant select, insert, update on public.profiles to authenticated;

-- Solo lectura: las escrituras pasan por las RPC (complete_session, join_group, leave_group)
grant select on public.sessions      to authenticated;
grant select on public.study_groups  to authenticated;
grant select on public.group_members to authenticated;
