-- Seguimiento: fecha de adopción, último cambio hecho por el maestro y datos para calcular retrasos.

alter table public.clases
  add column cambios_maestro integer not null default 0,
  add column ultimo_cambio_maestro timestamptz;

-- Solo cuentan los cambios de maestros: ni la importación ni las correcciones del administrador.
create function public.registrar_cambio_maestro()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  clase uuid := case when tg_op = 'DELETE' then old.clase_id else new.clase_id end;
begin
  if auth.uid() is not null and not public.es_admin() then
    update public.clases
    set cambios_maestro = cambios_maestro + 1, ultimo_cambio_maestro = now()
    where id = clase;
  end if;
  return null;
end;
$$;
revoke execute on function public.registrar_cambio_maestro() from public, anon, authenticated;

create trigger cambio_en_asistencia
  after insert or update or delete on public.asistencia
  for each row execute function public.registrar_cambio_maestro();

create trigger cambio_en_alumnos
  after insert or update or delete on public.clase_alumnos
  for each row execute function public.registrar_cambio_maestro();

drop function public.mis_clases();
create function public.mis_clases()
returns table (id uuid, codigo text, titulo text, maestro text, programa text, estaca text, horario text, curso text, tipo text, alumnos bigint, dias smallint[], inicio date, fechas_extra date[], fechas_omitidas date[], ultima_fecha date)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id, c.codigo, c.titulo, c.maestro_nombre, c.programa, c.estaca, c.horario, c.curso, a.tipo,
    (select count(*) from public.clase_alumnos x where x.clase_id = c.id and x.retirado_en is null),
    c.dias, c.inicio, c.fechas_extra, c.fechas_omitidas,
    (select max(m.fecha) from public.asistencia m where m.clase_id = c.id)
  from public.clase_accesos a
  join public.clases c on c.id = a.clase_id
  where a.usuario_id = auth.uid()
  order by c.maestro_nombre, c.horario;
$$;

drop function public.resumen_clases();
create function public.resumen_clases()
returns table (id uuid, codigo text, titulo text, maestro text, programa text, estaca text, horario text, curso text, alumnos bigint, alertas bigint, titular text, adoptada_en timestamptz, colaboradores bigint, presentes bigint, marcas bigint, ultimo_cambio timestamptz, cambios integer, dias smallint[], inicio date, fechas_extra date[], fechas_omitidas date[], ultima_fecha date)
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
    c.ultimo_cambio_maestro, c.cambios_maestro, c.dias, c.inicio, c.fechas_extra, c.fechas_omitidas,
    (select max(m.fecha) from public.asistencia m where m.clase_id = c.id)
  from public.clases c
  order by c.maestro_nombre, c.horario;
end;
$$;

revoke execute on function public.mis_clases() from public, anon;
revoke execute on function public.resumen_clases() from public, anon;
grant execute on function public.mis_clases() to authenticated;
grant execute on function public.resumen_clases() to authenticated;

notify pgrst, 'reload schema';
