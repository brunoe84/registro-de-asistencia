-- Entornos (fase 4): vista regional del administrador general.
-- Requiere 0036, 0037 y 0038 aplicadas antes.
--
-- El administrador general puede pedir datos de cualquier entorno en una consulta puntual, sin cambiar
-- el entorno en el que está trabajando: la app manda el encabezado "x-entorno" con el id del entorno.
-- Así el Resumen regional calcula cada programa con las mismas funciones de sus propios informes.
-- Para cualquier otra cuenta el encabezado no tiene efecto.

begin;

create or replace function public.entorno_actual()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  with p as (
    select pf.id, pf.general, pf.entorno_activo from public.perfiles pf
    where pf.id = auth.uid() and pf.rol = 'admin'
  ),
  h as (
    select case when x.v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then x.v::uuid end as e
    from (select nullif(current_setting('request.headers', true), '')::json ->> 'x-entorno' as v) x
  )
  select coalesce(
    -- El general, en una consulta con "x-entorno": ese entorno (si está activo).
    (select e.id from p cross join h join public.entornos e on e.id = h.e and e.estado = 'activo' where p.general),
    -- El que eligió (si puede usarlo).
    (select e.id from p join public.entornos e on e.id = p.entorno_activo and e.estado = 'activo'
      where p.general or exists (select 1 from public.entorno_admins a where a.usuario_id = p.id and a.entorno_id = e.id)),
    -- El primero que administra.
    (select a.entorno_id from p join public.entorno_admins a on a.usuario_id = p.id
      join public.entornos e on e.id = a.entorno_id and e.estado = 'activo'
      order by e.creado_en, e.id limit 1),
    -- El general que no administra ninguno: el más antiguo.
    (select e.id from p join public.entornos e on e.estado = 'activo' where p.general order by e.creado_en, e.id limit 1)
  );
$$;

notify pgrst, 'reload schema';

commit;
