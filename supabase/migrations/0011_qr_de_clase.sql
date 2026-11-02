-- QR de asistencia para clases: el alumno lo escanea, elige quién es y envía su asistencia del día.
-- No cuenta hasta que el maestro la aprueba (así nadie marca desde su casa con una foto del QR).
-- El QR es siempre el mismo, pero solo funciona los días que toca clase: en Seminario, cada día
-- de clase; en Instituto, el día de la semana de la clase (al día siguiente queda inútil hasta la
-- semana siguiente).

alter table public.clases add column qr text unique;

create table public.asistencia_qr (
  id uuid primary key default gen_random_uuid(),
  clase_id uuid not null references public.clases (id) on delete cascade,
  -- null: el alumno no estaba en la lista; al aprobar se agrega a la clase.
  alumno_id uuid references public.clase_alumnos (id) on delete cascade,
  nombre text not null,
  fecha date not null,
  estado text not null default 'pendiente' check (estado in ('pendiente', 'aprobada', 'rechazada')),
  dispositivo text not null default '',
  creado_en timestamptz not null default now(),
  resuelto_en timestamptz
);
create unique index asistencia_qr_unica on public.asistencia_qr (clase_id, fecha, coalesce(alumno_id::text, public.norm_nombre(nombre)));
create index asistencia_qr_pendientes on public.asistencia_qr (clase_id) where estado = 'pendiente';

alter table public.asistencia_qr enable row level security;
revoke all on public.asistencia_qr from anon, authenticated;
-- Solo lectura para quien usa la clase, para que el aviso al maestro llegue en tiempo real.
grant select on public.asistencia_qr to authenticated;
create policy "ver asistencia por qr de clase permitida" on public.asistencia_qr
  for select to authenticated using (public.puede_usar_clase(clase_id));
alter publication supabase_realtime add table public.asistencia_qr;

-- ¿La fecha es un día de clase? Días de la semana dentro de inicio y fin, más las fechas extra y
-- menos las omitidas. Una clase sin días cargados acepta cualquier día.
create or replace function public.dia_de_clase(c public.clases, f date)
returns boolean
language sql
stable
set search_path = ''
as $$
  select f = any (c.fechas_extra) or (
    (coalesce(array_length(c.dias, 1), 0) = 0 or extract(dow from f)::smallint = any (c.dias))
    and (c.inicio is null or f >= c.inicio)
    and (c.fin is null or f <= c.fin)
    and not (f = any (c.fechas_omitidas))
  );
$$;

create or replace function public.hoy_lima()
returns date
language sql
stable
as $$
  select (now() at time zone 'America/Lima')::date;
$$;

-- El maestro (o quien tiene acceso) prende o apaga el QR de su clase.
create or replace function public.qr_clase(clase uuid, activo boolean)
returns text
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  t text;
begin
  if not public.puede_usar_clase(clase) then
    raise exception 'No tienes acceso a esta clase';
  end if;
  if activo then
    select c.qr into t from public.clases c where c.id = clase;
    if t is null then
      t := substr(replace(gen_random_uuid()::text, '-', ''), 1, 14);
      update public.clases c set qr = t where c.id = clase;
    end if;
  else
    update public.clases c set qr = null where c.id = clase;
  end if;
  return t;
end;
$$;

-- Lo que ve el alumno al escanear. Si el celular ya sabe quién es (persona o nombre), sugiere al alumno.
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
  return jsonb_build_object('estado', 'abierto', 'titulo', c.titulo, 'maestro', c.maestro_nombre, 'programa', c.programa,
    'horario', c.horario, 'fecha', hoy, 'sugerido', sug);
end;
$$;

-- El alumno busca su nombre solo dentro de la lista de su clase.
create or replace function public.buscar_alumno_qr(token text, texto text)
returns table (id uuid, nombre text, ya_enviada boolean)
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
  select a.id, a.nombre,
    exists (select 1 from public.asistencia_qr q where q.alumno_id = a.id and q.fecha = hoy)
  from public.clase_alumnos a
  where a.clase_id = c.id and a.retirado_en is null and public.puntaje_nombre(a.clave, texto) is not null
  order by public.puntaje_nombre(a.clave, texto) desc, a.nombre
  limit 10;
end;
$$;

-- El alumno envía su asistencia de hoy. alumno: id de la lista; si no está, nombres y apellidos.
create or replace function public.marcar_por_qr_clase(token text, alumno uuid default null, nombres text default null, apellidos text default null, dispositivo text default '')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  c public.clases%rowtype;
  a public.clase_alumnos%rowtype;
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
    nom := a.nombre;
    if exists (select 1 from public.asistencia m where m.alumno_id = a.id and m.fecha = hoy and m.estado in ('P', 'T', 'M')) then
      return jsonb_build_object('estado', 'ya_presente', 'nombre', nom, 'alumno_id', a.id, 'persona_id', a.persona_id);
    end if;
  else
    if coalesce(trim(nombres), '') = '' or coalesce(trim(apellidos), '') = '' then
      raise exception 'Escribe tus nombres y apellidos';
    end if;
    nom := left(initcap(trim(apellidos)) || ', ' || initcap(trim(nombres)), 120);
    -- Si en realidad sí está en la lista, se usa su fila.
    select * into a from public.clase_alumnos x
    where x.clase_id = c.id and x.retirado_en is null and public.clave_orden(x.nombre) = public.clave_orden(nom)
    limit 1;
    if a.id is not null then nom := a.nombre; end if;
  end if;
  insert into public.asistencia_qr (clase_id, alumno_id, nombre, fecha, dispositivo)
  values (c.id, a.id, nom, hoy, coalesce(dispositivo, ''))
  on conflict do nothing;
  get diagnostics filas = row_count;
  return jsonb_build_object('estado', case when filas = 1 then 'enviada' else 'ya_enviada' end,
    'nombre', nom, 'alumno_id', a.id, 'persona_id', a.persona_id);
end;
$$;

-- Para el maestro: asistencias por QR que esperan su aprobación.
create or replace function public.qr_pendientes_clase(clase uuid)
returns table (id uuid, alumno_id uuid, nombre text, fecha date, creado_en timestamptz)
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
  select q.id, q.alumno_id, q.nombre, q.fecha, q.creado_en
  from public.asistencia_qr q
  where q.clase_id = clase and q.estado = 'pendiente'
  order by q.fecha desc, q.creado_en;
end;
$$;

-- Aprobar: marca presente (y agrega a la clase a quien no estaba en la lista). Rechazar: no marca nada.
create or replace function public.resolver_qr_clase(solicitud uuid, aprobar boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  q public.asistencia_qr%rowtype;
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
      insert into public.clase_alumnos (clase_id, nombre)
      values (q.clase_id, q.nombre)
      on conflict on constraint clase_alumnos_clave do nothing
      returning id into al;
      if al is null then
        select x.id into al from public.clase_alumnos x where x.clase_id = q.clase_id and x.clave = public.norm_nombre(q.nombre);
      end if;
      update public.clase_alumnos x set retirado_en = null where x.id = al;
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

revoke execute on function public.dia_de_clase(public.clases, date) from public, anon, authenticated;
revoke execute on function public.qr_clase(uuid, boolean) from public, anon;
revoke execute on function public.clase_por_qr(text, uuid, text) from public;
revoke execute on function public.buscar_alumno_qr(text, text) from public;
revoke execute on function public.marcar_por_qr_clase(text, uuid, text, text, text) from public;
revoke execute on function public.qr_pendientes_clase(uuid) from public, anon;
revoke execute on function public.resolver_qr_clase(uuid, boolean) from public, anon;
-- El alumno que escanea no necesita sesión: estas funciones exigen el token del QR.
grant execute on function public.clase_por_qr(text, uuid, text) to anon, authenticated;
grant execute on function public.buscar_alumno_qr(text, text) to anon, authenticated;
grant execute on function public.marcar_por_qr_clase(text, uuid, text, text, text) to anon, authenticated;
grant execute on function public.qr_clase(uuid, boolean) to authenticated;
grant execute on function public.qr_pendientes_clase(uuid) to authenticated;
grant execute on function public.resolver_qr_clase(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
