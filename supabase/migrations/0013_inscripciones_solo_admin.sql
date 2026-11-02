-- Los datos de inscripción (cédula, usuario de la Iglesia, nacimiento, celular) que deja quien no
-- está en la lista de la clase los ve SOLO el administrador, para inscribirlo en Wise2.
-- Se pasan a una tabla propia; el maestro solo ve el nombre al aprobar la asistencia.

create table public.inscripciones (
  id uuid primary key default gen_random_uuid(),
  clase_id uuid not null references public.clases (id) on delete cascade,
  alumno_id uuid references public.clase_alumnos (id) on delete set null,
  persona_id uuid references public.personas (id) on delete set null,
  qr_id uuid references public.asistencia_qr (id) on delete set null,
  nombre text not null,
  datos jsonb not null,
  creado_en timestamptz not null default now(),
  atendida_en timestamptz
);
create index inscripciones_pendientes on public.inscripciones (creado_en) where atendida_en is null;
alter table public.inscripciones enable row level security;
revoke all on public.inscripciones from anon, authenticated;

-- Lo que ya se hubiera guardado en las columnas anteriores.
insert into public.inscripciones (clase_id, alumno_id, persona_id, qr_id, nombre, datos, creado_en)
select q.clase_id, q.alumno_id, q.persona_id, q.id, q.nombre, q.datos, q.creado_en
from public.asistencia_qr q where q.datos <> '{}'::jsonb;
insert into public.inscripciones (clase_id, alumno_id, persona_id, nombre, datos)
select a.clase_id, a.id, a.persona_id, a.nombre, a.inscripcion
from public.clase_alumnos a
where a.inscripcion is not null and a.inscripcion <> '{}'::jsonb
  and not exists (select 1 from public.inscripciones i where i.alumno_id = a.id);
alter table public.asistencia_qr drop column datos;
alter table public.clase_alumnos drop column inscripcion;

create or replace function public.marcar_por_qr_clase(token text, alumno uuid default null, nombres text default null, apellidos text default null, dispositivo text default '', persona uuid default null, datos jsonb default '{}')
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
  qid uuid;
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
  insert into public.asistencia_qr (clase_id, alumno_id, persona_id, nombre, fecha, dispositivo)
  values (c.id, a.id, case when a.id is null then p.id end, nom, hoy, coalesce(dispositivo, ''))
  on conflict do nothing
  returning id into qid;
  if qid is not null and a.id is null then
    insert into public.inscripciones (clase_id, persona_id, qr_id, nombre, datos)
    values (c.id, p.id, qid, nom, public.datos_inscripcion(datos));
  end if;
  return jsonb_build_object('estado', case when qid is not null then 'enviada' else 'ya_enviada' end,
    'nombre', nom, 'alumno_id', a.id, 'persona_id', coalesce(a.persona_id, p.id), 'nuevo', a.id is null);
end;
$$;

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
      update public.clase_alumnos x set retirado_en = null where x.id = al;
      update public.inscripciones i set alumno_id = al where i.qr_id = q.id;
    end if;
    insert into public.asistencia (clase_id, alumno_id, fecha, estado, marcado_por)
    values (q.clase_id, al, q.fecha, 'P', auth.uid())
    on conflict (alumno_id, fecha) do update set estado = 'P', marcado_por = auth.uid(), actualizado_en = now();
    update public.asistencia_qr x set estado = 'aprobada', alumno_id = al, resuelto_en = now() where x.id = q.id;
  else
    update public.asistencia_qr x set estado = 'rechazada', resuelto_en = now() where x.id = q.id;
    -- Si el maestro dice que no vino, no hace falta inscribirlo.
    delete from public.inscripciones i where i.qr_id = q.id and i.atendida_en is null;
  end if;
end;
$$;

-- El maestro ve el nombre; los datos de inscripción solo llegan si quien pregunta es el administrador.
create or replace function public.qr_pendientes_clase(clase uuid)
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
  select q.id, q.alumno_id, q.persona_id, q.nombre, q.fecha, q.creado_en,
    case when public.es_admin() then (select i.datos from public.inscripciones i where i.qr_id = q.id limit 1) end
  from public.asistencia_qr q
  where q.clase_id = clase and q.estado = 'pendiente'
  order by q.fecha desc, q.creado_en;
end;
$$;

-- Para el administrador: personas por inscribir en Wise2.
create or replace function public.inscripciones_wise(atendidas boolean default false)
returns table (id uuid, nombre text, datos jsonb, creado_en timestamptz, atendida_en timestamptz, aprobada text,
  maestro text, horario text, programa text, estaca text, en_base boolean, barrio text)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  return query
  select i.id, i.nombre, i.datos, i.creado_en, i.atendida_en,
    coalesce((select q.estado from public.asistencia_qr q where q.id = i.qr_id), 'aprobada'),
    c.maestro_nombre, c.horario, c.programa, c.estaca, i.persona_id is not null,
    coalesce((select p.barrio from public.personas p where p.id = i.persona_id), '')
  from public.inscripciones i
  join public.clases c on c.id = i.clase_id
  where (atendidas and i.atendida_en is not null) or (not atendidas and i.atendida_en is null)
  order by i.creado_en desc
  limit 500;
end;
$$;

create or replace function public.atender_inscripcion(inscripcion uuid, atendida boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  update public.inscripciones i set atendida_en = case when atendida then now() end where i.id = inscripcion;
end;
$$;

revoke execute on function public.inscripciones_wise(boolean) from public, anon;
revoke execute on function public.atender_inscripcion(uuid, boolean) from public, anon;
grant execute on function public.inscripciones_wise(boolean) to authenticated;
grant execute on function public.atender_inscripcion(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
