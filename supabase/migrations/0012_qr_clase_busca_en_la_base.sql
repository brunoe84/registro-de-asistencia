-- QR de clase: el alumno que no está en la lista también se encuentra en la base general al
-- escribir su nombre. Elige quién es, su asistencia queda por aprobar y, si el maestro la aprueba,
-- se agrega a la clase ya vinculado con la base (estaca y barrio).

alter table public.asistencia_qr add column persona_id uuid references public.personas (id) on delete set null;

-- Quien no está en la lista deja sus datos para inscribirlo: cédula de la Iglesia, usuario de su
-- cuenta de la Iglesia, fecha de nacimiento y celular. Solo los ve quien tiene acceso a la clase.
alter table public.asistencia_qr add column datos jsonb not null default '{}';
alter table public.clase_alumnos add column inscripcion jsonb;

create or replace function public.datos_inscripcion(d jsonb)
returns jsonb
language sql
immutable
as $$
  select coalesce(jsonb_object_agg(k, left(trim(d ->> k), 60)), '{}'::jsonb)
  from unnest(array['cedula', 'usuario', 'nacimiento', 'celular']) k
  where coalesce(trim(d ->> k), '') <> '';
$$;

-- Primero los alumnos de la clase; después personas de la base que no están en ella
-- (las de la estaca de la clase primero).
drop function public.buscar_alumno_qr(text, text);
create function public.buscar_alumno_qr(token text, texto text)
returns table (id uuid, nombre text, barrio text, en_clase boolean, ya_enviada boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  c public.clases%rowtype;
  hoy date := public.hoy_lima();
begin
  select * into c from public.clases x where x.qr is not null and x.qr = token;
  if c.id is null or not public.dia_de_clase(c, hoy) then
    raise exception 'El QR de esta clase no está activo hoy';
  end if;
  if not exists (select 1 from unnest(string_to_array(public.norm_nombre(replace(texto, ',', ' ')), ' ')) t where length(t) >= 3) then
    return;
  end if;
  return query
  (select a.id, a.nombre, a.barrio, true,
    exists (select 1 from public.asistencia_qr q where q.alumno_id = a.id and q.fecha = hoy)
  from public.clase_alumnos a
  where a.clase_id = c.id and a.retirado_en is null and public.puntaje_nombre(a.clave, texto) is not null
  order by public.puntaje_nombre(a.clave, texto) desc, a.nombre
  limit 10)
  union all
  (select p.id, p.nombre, p.barrio, false,
    exists (select 1 from public.asistencia_qr q where q.clase_id = c.id and q.persona_id = p.id and q.fecha = hoy)
  from public.personas p
  where public.puntaje_nombre(p.clave, texto) is not null
    and not exists (select 1 from public.clase_alumnos a where a.clase_id = c.id and a.persona_id = p.id and a.retirado_en is null)
  order by (public.norm_nombre(p.estaca) = public.norm_nombre(c.estaca)) desc, public.puntaje_nombre(p.clave, texto) desc, p.nombre
  limit 10);
end;
$$;

-- Si el celular ya sabe quién es y no está en la lista, también se le sugiere (desde la base).
create or replace function public.clase_por_qr(token text, persona uuid default null, nombre text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  c public.clases%rowtype;
  hoy date := public.hoy_lima();
  sug jsonb;
begin
  select * into c from public.clases x where x.qr is not null and x.qr = token;
  if c.id is null then
    return jsonb_build_object('estado', 'no_existe');
  end if;
  if not public.dia_de_clase(c, hoy) then
    return jsonb_build_object('estado', 'sin_clase', 'titulo', c.titulo, 'maestro', c.maestro_nombre, 'programa', c.programa,
      'proxima', (select min(d)::date from generate_series(hoy + 1, hoy + 21, interval '1 day') d where public.dia_de_clase(c, d::date)));
  end if;
  select jsonb_build_object('id', a.id, 'nombre', a.nombre) into sug
  from public.clase_alumnos a
  where a.clase_id = c.id and a.retirado_en is null
    and ((persona is not null and a.persona_id = persona)
      or (coalesce(nombre, '') <> '' and public.clave_orden(a.nombre) = public.clave_orden(nombre)))
  order by (a.persona_id = persona) desc nulls last
  limit 1;
  if sug is null and persona is not null then
    select jsonb_build_object('persona_id', p.id, 'nombre', p.nombre) into sug from public.personas p where p.id = persona;
  end if;
  return jsonb_build_object('estado', 'abierto', 'titulo', c.titulo, 'maestro', c.maestro_nombre, 'programa', c.programa,
    'horario', c.horario, 'fecha', hoy, 'sugerido', sug);
end;
$$;

-- Envío: alumno (de la lista), persona (de la base) o nombres y apellidos escritos.
drop function public.marcar_por_qr_clase(text, uuid, text, text, text);
create function public.marcar_por_qr_clase(token text, alumno uuid default null, nombres text default null, apellidos text default null, dispositivo text default '', persona uuid default null, datos jsonb default '{}')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  c public.clases%rowtype;
  a public.clase_alumnos%rowtype;
  p public.personas%rowtype;
  hoy date := public.hoy_lima();
  nom text;
  filas integer;
begin
  select * into c from public.clases x where x.qr is not null and x.qr = token;
  if c.id is null or not public.dia_de_clase(c, hoy) then
    raise exception 'El QR de esta clase no está activo hoy';
  end if;
  if alumno is not null then
    select * into a from public.clase_alumnos x where x.id = alumno and x.clase_id = c.id and x.retirado_en is null;
    if a.id is null then
      raise exception 'Ese alumno no está en esta clase';
    end if;
  elsif persona is not null then
    select * into p from public.personas x where x.id = persona;
    if p.id is null then
      raise exception 'No encontramos a esa persona';
    end if;
    -- Si ya está en la lista (por la base o por su nombre), se usa su fila.
    select * into a from public.clase_alumnos x
    where x.clase_id = c.id and x.retirado_en is null and (x.persona_id = p.id or x.clave = p.clave)
    limit 1;
    nom := p.nombre;
  else
    if coalesce(trim(nombres), '') = '' or coalesce(trim(apellidos), '') = '' then
      raise exception 'Escribe tus nombres y apellidos';
    end if;
    nom := left(initcap(trim(apellidos)) || ', ' || initcap(trim(nombres)), 120);
    select * into a from public.clase_alumnos x
    where x.clase_id = c.id and x.retirado_en is null and public.clave_orden(x.nombre) = public.clave_orden(nom)
    limit 1;
  end if;
  if a.id is not null then
    nom := a.nombre;
    if exists (select 1 from public.asistencia m where m.alumno_id = a.id and m.fecha = hoy and m.estado in ('P', 'T', 'M')) then
      return jsonb_build_object('estado', 'ya_presente', 'nombre', nom, 'alumno_id', a.id, 'persona_id', a.persona_id);
    end if;
  end if;
  if a.id is null and (coalesce(datos ->> 'nacimiento', '') = '' or coalesce(datos ->> 'celular', '') = '') then
    raise exception 'Escribe tu fecha de nacimiento y tu celular';
  end if;
  insert into public.asistencia_qr (clase_id, alumno_id, persona_id, nombre, fecha, dispositivo, datos)
  values (c.id, a.id, case when a.id is null then p.id end, nom, hoy, coalesce(dispositivo, ''),
    case when a.id is null then public.datos_inscripcion(datos) else '{}'::jsonb end)
  on conflict do nothing;
  get diagnostics filas = row_count;
  return jsonb_build_object('estado', case when filas = 1 then 'enviada' else 'ya_enviada' end,
    'nombre', nom, 'alumno_id', a.id, 'persona_id', coalesce(a.persona_id, p.id), 'nuevo', a.id is null);
end;
$$;

-- Al aprobar a quien no estaba en la lista, se agrega a la clase (vinculado a la base si se eligió de ahí).
create or replace function public.resolver_qr_clase(solicitud uuid, aprobar boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  q public.asistencia_qr%rowtype;
  p public.personas%rowtype;
  al uuid;
begin
  select * into q from public.asistencia_qr x where x.id = solicitud;
  if q.id is null then
    return;
  end if;
  if not public.puede_usar_clase(q.clase_id) then
    raise exception 'No tienes acceso a esta clase';
  end if;
  if q.estado <> 'pendiente' then
    return;
  end if;
  if aprobar then
    al := q.alumno_id;
    if al is null then
      if q.persona_id is not null then
        select * into p from public.personas x where x.id = q.persona_id;
      end if;
      select x.id into al from public.clase_alumnos x
      where x.clase_id = q.clase_id and ((p.id is not null and x.persona_id = p.id) or x.clave = public.norm_nombre(q.nombre))
      limit 1;
      if al is null then
        insert into public.clase_alumnos (clase_id, persona_id, nombre, estaca, barrio)
        values (q.clase_id, p.id, q.nombre, coalesce(p.estaca, ''), coalesce(p.barrio, ''))
        on conflict do nothing
        returning id into al;
      end if;
      if al is null then
        select x.id into al from public.clase_alumnos x
        where x.clase_id = q.clase_id and ((p.id is not null and x.persona_id = p.id) or x.clave = public.norm_nombre(q.nombre))
        limit 1;
      end if;
      update public.clase_alumnos x set retirado_en = null,
        inscripcion = case when q.datos = '{}'::jsonb then x.inscripcion else coalesce(x.inscripcion, '{}'::jsonb) || q.datos end
      where x.id = al;
    end if;
    insert into public.asistencia (clase_id, alumno_id, fecha, estado, marcado_por)
    values (q.clase_id, al, q.fecha, 'P', auth.uid())
    on conflict (alumno_id, fecha) do update set estado = 'P', marcado_por = auth.uid(), actualizado_en = now();
    update public.asistencia_qr x set estado = 'aprobada', alumno_id = al, resuelto_en = now() where x.id = q.id;
  else
    update public.asistencia_qr x set estado = 'rechazada', resuelto_en = now() where x.id = q.id;
  end if;
end;
$$;

-- El maestro ve también si viene de la base y los datos de inscripción.
drop function public.qr_pendientes_clase(uuid);
create function public.qr_pendientes_clase(clase uuid)
returns table (id uuid, alumno_id uuid, persona_id uuid, nombre text, fecha date, creado_en timestamptz, datos jsonb)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if not public.puede_usar_clase(clase) then
    raise exception 'No tienes acceso a esta clase';
  end if;
  return query
  select q.id, q.alumno_id, q.persona_id, q.nombre, q.fecha, q.creado_en, q.datos
  from public.asistencia_qr q
  where q.clase_id = clase and q.estado = 'pendiente'
  order by q.fecha desc, q.creado_en;
end;
$$;

revoke execute on function public.buscar_alumno_qr(text, text) from public;
revoke execute on function public.marcar_por_qr_clase(text, uuid, text, text, text, uuid, jsonb) from public;
revoke execute on function public.qr_pendientes_clase(uuid) from public, anon;
grant execute on function public.buscar_alumno_qr(text, text) to anon, authenticated;
grant execute on function public.marcar_por_qr_clase(text, uuid, text, text, text, uuid, jsonb) to anon, authenticated;
grant execute on function public.qr_pendientes_clase(uuid) to authenticated;

notify pgrst, 'reload schema';
