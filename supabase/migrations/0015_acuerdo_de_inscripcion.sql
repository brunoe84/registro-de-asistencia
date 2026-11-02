-- Quien se inscribe con el QR de una clase debe aceptar el acuerdo de la ficha de inscripción de
-- su programa (Seminario o Instituto, versión 2/19). En Seminario también da el nombre del padre,
-- madre o tutor que da su permiso. Se guarda qué acuerdo aceptó y cuándo.

create or replace function public.datos_inscripcion(d jsonb)
returns jsonb
language sql
immutable
as $$
  select coalesce(jsonb_object_agg(k, left(trim(d ->> k), 80)), '{}'::jsonb)
  from unnest(array['estaca', 'barrio', 'miembro', 'cedula', 'usuario', 'nacimiento', 'celular', 'acuerdo', 'tutor']) k
  where coalesce(trim(d ->> k), '') <> ''
    and (k not in ('cedula', 'usuario') or coalesce(d ->> 'miembro', 'si') = 'si');
$$;

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
  acuerdo text;
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
  if a.id is null then
    if coalesce(datos ->> 'nacimiento', '') = '' or coalesce(datos ->> 'celular', '') = '' then
      raise exception 'Escribe tu fecha de nacimiento y tu celular';
    end if;
    acuerdo := case when c.programa = 'S' then 'Seminario 2/19' else 'Instituto 2/19' end;
    if coalesce(datos ->> 'acuerdo', '') <> acuerdo then
      raise exception 'Para inscribirte debes aceptar el acuerdo de inscripción';
    end if;
    if c.programa = 'S' and coalesce(trim(datos ->> 'tutor'), '') = '' then
      raise exception 'Escribe el nombre de tu padre, madre o tutor';
    end if;
  end if;
  insert into public.asistencia_qr (clase_id, alumno_id, persona_id, nombre, fecha, dispositivo)
  values (c.id, a.id, case when a.id is null then p.id end, nom, hoy, coalesce(dispositivo, ''))
  on conflict do nothing
  returning id into qid;
  if qid is not null and a.id is null then
    insert into public.inscripciones (clase_id, persona_id, qr_id, nombre, datos)
    values (c.id, p.id, qid, nom, public.datos_inscripcion(datos) || jsonb_build_object('acepto_en', now()));
  end if;
  return jsonb_build_object('estado', case when qid is not null then 'enviada' else 'ya_enviada' end,
    'nombre', nom, 'alumno_id', a.id, 'persona_id', coalesce(a.persona_id, p.id), 'nuevo', a.id is null);
end;
$$;

notify pgrst, 'reload schema';
