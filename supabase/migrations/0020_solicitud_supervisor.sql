-- Supervisores: la primera vez que entran se identifican (nombres, apellidos, celular, estaca y
-- barrio) y piden acceso a una o varias clases a la vez. Cada clase queda como una solicitud
-- pendiente con rol 'supervisor' que el administrador aprueba o rechaza (como las demás). Al
-- aprobarla entra como colaborador sin fecha de fin.

alter table public.solicitudes_acceso
  add column if not exists rol text not null default 'colaborador',
  add column if not exists celular text not null default '';
alter table public.solicitudes_acceso drop constraint if exists solicitudes_acceso_rol_check;
alter table public.solicitudes_acceso add constraint solicitudes_acceso_rol_check check (rol in ('colaborador', 'supervisor'));

create or replace function public.solicitar_supervision(clases uuid[], nombres text, apellidos text, celular text, barrio text, estaca text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  v_cel text := regexp_replace(coalesce(celular, ''), '\D', '', 'g');
  v_id uuid;
  v_prog text;
  enviadas integer := 0;
  ya integer := 0;
  filas integer;
begin
  if auth.uid() is null then
    raise exception 'Sin sesión';
  end if;
  if trim(coalesce(nombres, '')) = '' or trim(coalesce(apellidos, '')) = '' then
    raise exception 'Faltan nombres o apellidos';
  end if;
  if length(v_cel) < 9 then
    raise exception 'Escribe tu número de celular';
  end if;
  if trim(coalesce(barrio, '')) = '' or trim(coalesce(estaca, '')) = '' then
    raise exception 'Faltan la estaca o el barrio';
  end if;
  if coalesce(cardinality(clases), 0) = 0 then
    raise exception 'Elige al menos una clase';
  end if;
  if cardinality(clases) > 40 then
    raise exception 'Son demasiadas clases a la vez (máximo 40)';
  end if;
  foreach v_id in array clases loop
    select c.programa into v_prog from public.clases c where c.id = v_id;
    if v_prog is null then continue; end if;
    if public.tiene_acceso(v_id) then ya := ya + 1; continue; end if;
    insert into public.solicitudes_acceso (clase_id, usuario_id, nombres, apellidos, barrio, estaca, programa, rol, celular)
    values (v_id, auth.uid(), left(trim(nombres), 60), left(trim(apellidos), 60), left(trim(barrio), 80), estaca, v_prog, 'supervisor', left(v_cel, 15))
    on conflict do nothing;
    get diagnostics filas = row_count;
    if filas = 0 then
      -- Ya tenía una solicitud pendiente para esa clase: ahora es de supervisor.
      update public.solicitudes_acceso s set rol = 'supervisor', celular = left(v_cel, 15)
      where s.clase_id = v_id and s.usuario_id = auth.uid() and s.estado = 'pendiente';
    end if;
    enviadas := enviadas + 1;
  end loop;
  update public.perfiles p set nombre = left(trim(nombres || ' ' || apellidos), 80) where p.id = auth.uid() and p.nombre = '';
  return jsonb_build_object('enviadas', enviadas, 'ya_tenia', ya);
end;
$$;
revoke execute on function public.solicitar_supervision(uuid[], text, text, text, text, text) from public, anon;
grant execute on function public.solicitar_supervision(uuid[], text, text, text, text, text) to authenticated;

-- El administrador ve el rol y el celular de cada solicitud.
drop function if exists public.solicitudes_pendientes();
create function public.solicitudes_pendientes()
returns table (id uuid, clase_id uuid, codigo text, maestro text, horario text, nombres text, apellidos text, barrio text, estaca text, programa text, creado_en timestamptz, rol text, celular text, usuario_id uuid)
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
  select s.id, s.clase_id, c.codigo, c.maestro_nombre, c.horario, s.nombres, s.apellidos, s.barrio, s.estaca, s.programa, s.creado_en, s.rol, s.celular, s.usuario_id
  from public.solicitudes_acceso s
  join public.clases c on c.id = s.clase_id
  where s.estado = 'pendiente'
  order by s.creado_en;
end;
$$;
revoke execute on function public.solicitudes_pendientes() from public, anon;
grant execute on function public.solicitudes_pendientes() to authenticated;

-- Búsqueda para el supervisor: por maestro, curso, título u horario (todas las palabras escritas
-- deben aparecer en alguno de ellos). No devuelve el código de clases ajenas.
create or replace function public.buscar_clases_supervisor(texto text)
returns table (id uuid, titulo text, maestro text, programa text, estaca text, horario text, curso text, tengo_acceso boolean, solicitud_pendiente boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, r.titulo, r.maestro_nombre, r.programa, r.estaca, r.horario, r.curso, r.tengo_acceso, r.solicitud_pendiente
  from (
    select c.*,
      public.puntaje_nombre(public.norm_nombre(c.maestro_nombre || ' ' || coalesce(c.curso, '') || ' ' || coalesce(c.titulo, '') || ' ' || coalesce(c.horario, '')), texto) as puntos,
      public.tiene_acceso(c.id) as tengo_acceso,
      exists (select 1 from public.solicitudes_acceso s where s.clase_id = c.id and s.usuario_id = auth.uid() and s.estado = 'pendiente') as solicitud_pendiente
    from public.clases c
    where length(public.norm_nombre(texto)) >= 3
  ) r
  where r.puntos is not null
  order by r.puntos desc, r.maestro_nombre, r.horario
  limit 30;
$$;
revoke execute on function public.buscar_clases_supervisor(text) from public, anon;
grant execute on function public.buscar_clases_supervisor(text) to authenticated;

notify pgrst, 'reload schema';
