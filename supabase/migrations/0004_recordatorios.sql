-- Recordatorios al celular y fecha de fin de cada clase.

alter table public.clases add column fin date;
update public.clases set fin = '2026-11-28' where fin is null;

create table public.suscripciones_push (
  endpoint text primary key,
  usuario_id uuid not null references public.perfiles (id) on delete cascade,
  p256dh text not null,
  auth text not null,
  creado_en timestamptz not null default now(),
  ultimo_envio timestamptz
);
create index suscripciones_push_usuario_idx on public.suscripciones_push (usuario_id);
alter table public.suscripciones_push enable row level security;
revoke all on public.suscripciones_push from anon, authenticated;

-- Un celular pertenece a la última sesión que activó los recordatorios en él.
create function public.guardar_suscripcion(punto text, clave_p256dh text, clave_auth text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.suscripciones_push (endpoint, usuario_id, p256dh, auth)
  values (punto, auth.uid(), clave_p256dh, clave_auth)
  on conflict (endpoint) do update
    set usuario_id = excluded.usuario_id, p256dh = excluded.p256dh, auth = excluded.auth;
$$;

create function public.quitar_suscripcion(punto text)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.suscripciones_push where endpoint = punto and usuario_id = auth.uid();
$$;

-- Solo para la función del servidor que envía los recordatorios.
create function public.clases_para_recordatorio()
returns table (usuario_id uuid, clase_id uuid, dias smallint[], inicio date, fin date, fechas_extra date[], fechas_omitidas date[], ultima_fecha date)
language sql
stable
security definer
set search_path = ''
as $$
  select a.usuario_id, c.id, c.dias, c.inicio, c.fin, c.fechas_extra, c.fechas_omitidas,
    (select max(m.fecha) from public.asistencia m where m.clase_id = c.id)
  from public.clase_accesos a
  join public.clases c on c.id = a.clase_id
  where a.tipo = 'titular'
    and exists (select 1 from public.suscripciones_push s where s.usuario_id = a.usuario_id);
$$;

drop function public.mis_clases();
create function public.mis_clases()
returns table (id uuid, codigo text, titulo text, maestro text, programa text, estaca text, horario text, curso text, tipo text, alumnos bigint, dias smallint[], inicio date, fin date, fechas_extra date[], fechas_omitidas date[], ultima_fecha date)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id, c.codigo, c.titulo, c.maestro_nombre, c.programa, c.estaca, c.horario, c.curso, a.tipo,
    (select count(*) from public.clase_alumnos x where x.clase_id = c.id and x.retirado_en is null),
    c.dias, c.inicio, c.fin, c.fechas_extra, c.fechas_omitidas,
    (select max(m.fecha) from public.asistencia m where m.clase_id = c.id)
  from public.clase_accesos a
  join public.clases c on c.id = a.clase_id
  where a.usuario_id = auth.uid()
  order by c.maestro_nombre, c.horario;
$$;

drop function public.resumen_clases();
create function public.resumen_clases()
returns table (id uuid, codigo text, titulo text, maestro text, programa text, estaca text, horario text, curso text, alumnos bigint, alertas bigint, titular text, adoptada_en timestamptz, colaboradores bigint, presentes bigint, marcas bigint, ultimo_cambio timestamptz, cambios integer, dias smallint[], inicio date, fin date, fechas_extra date[], fechas_omitidas date[], ultima_fecha date, recordatorios bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  return query
  select c.id, c.codigo, c.titulo, c.maestro_nombre, c.programa, c.estaca, c.horario, c.curso,
    (select count(*) from public.clase_alumnos x where x.clase_id = c.id and x.retirado_en is null),
    (select count(*) from public.clase_alumnos x where x.clase_id = c.id and x.retirado_en is null and x.vinculo = 'pendiente'),
    (select coalesce(nullif(p.nombre, ''), 'Sin nombre') from public.clase_accesos a join public.perfiles p on p.id = a.usuario_id where a.clase_id = c.id and a.tipo = 'titular'),
    (select a.creado_en from public.clase_accesos a where a.clase_id = c.id and a.tipo = 'titular'),
    (select count(*) from public.clase_accesos a where a.clase_id = c.id and a.tipo = 'colaborador'),
    (select count(*) from public.asistencia m where m.clase_id = c.id and m.estado <> 'F'),
    (select count(*) from public.asistencia m where m.clase_id = c.id),
    c.ultimo_cambio_maestro, c.cambios_maestro, c.dias, c.inicio, c.fin, c.fechas_extra, c.fechas_omitidas,
    (select max(m.fecha) from public.asistencia m where m.clase_id = c.id),
    (select count(*) from public.clase_accesos a join public.suscripciones_push s on s.usuario_id = a.usuario_id where a.clase_id = c.id and a.tipo = 'titular')
  from public.clases c
  order by c.maestro_nombre, c.horario;
end;
$$;

create or replace function public.importar_clase(datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_id uuid;
  fue_nueva boolean;
  n_alumnos integer;
  n_marcas integer;
begin
  if auth.uid() is not null and not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  insert into public.clases (titulo, programa, estaca, barrio, dias, maestro_nombre, horario, curso, unidad, periodo, inicio, fin)
  values (
    datos ->> 'titulo', datos ->> 'programa', datos ->> 'estaca', '',
    array(select jsonb_array_elements_text(datos -> 'dias'))::smallint[],
    datos ->> 'maestro', datos ->> 'horario', datos ->> 'curso', coalesce(datos ->> 'unidad', ''), coalesce(datos ->> 'periodo', ''),
    (datos ->> 'inicio')::date, nullif(datos ->> 'fin', '')::date
  )
  on conflict on constraint clases_identidad do update
    set inicio = least(public.clases.inicio, excluded.inicio), periodo = excluded.periodo, fin = greatest(public.clases.fin, excluded.fin)
  returning id, (xmax = 0) into c_id, fue_nueva;

  with entrada as (
    select a ->> 'nombre' as nombre from jsonb_array_elements(datos -> 'alumnos') a
  ), nuevos as (
    insert into public.clase_alumnos (clase_id, nombre, estaca, origen)
    select c_id, e.nombre, datos ->> 'estaca', 'importado' from entrada e
    on conflict on constraint clase_alumnos_clave do nothing
    returning 1
  )
  select count(*) into n_alumnos from nuevos;

  with entrada as (
    select public.norm_nombre(a ->> 'nombre') as clave, m.key::date as fecha, m.value as estado
    from jsonb_array_elements(datos -> 'alumnos') a,
      jsonb_each_text(a -> 'marcas') m
  ), nuevas as (
    insert into public.asistencia (clase_id, alumno_id, fecha, estado)
    select c_id, x.id, e.fecha, e.estado
    from entrada e
    join public.clase_alumnos x on x.clase_id = c_id and x.clave = e.clave
    on conflict (alumno_id, fecha) do nothing
    returning 1
  )
  select count(*) into n_marcas from nuevas;

  return jsonb_build_object('clase', c_id, 'nueva', fue_nueva, 'alumnos', n_alumnos, 'marcas', n_marcas);
end;
$$;

revoke execute on function public.mis_clases() from public, anon;
revoke execute on function public.resumen_clases() from public, anon;
revoke execute on function public.guardar_suscripcion(text, text, text) from public, anon;
revoke execute on function public.quitar_suscripcion(text) from public, anon;
revoke execute on function public.clases_para_recordatorio() from public, anon, authenticated;
grant execute on function public.mis_clases() to authenticated;
grant execute on function public.resumen_clases() to authenticated;
grant execute on function public.guardar_suscripcion(text, text, text) to authenticated;
grant execute on function public.quitar_suscripcion(text) to authenticated;
grant execute on function public.clases_para_recordatorio() to service_role;
grant select, update, delete on public.suscripciones_push to service_role;

notify pgrst, 'reload schema';
