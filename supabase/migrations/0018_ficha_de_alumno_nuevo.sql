-- Ficha de inscripción para los alumnos nuevos que agrega el maestro.
-- Al agregar un alumno nuevo, el maestro escribe su WhatsApp y le envía un enlace PERSONAL
-- (?f=TOKEN) con el formulario de su programa (Seminario o Instituto). El alumno no se busca:
-- el enlace ya sabe quién es. Mientras no la complete, la ficha está "pendiente" (naranja);
-- cuando la completa, queda "completa" (dorado). El administrador la ve en Inscritos para Wise,
-- puede reenviar el enlace y marca cuando lo inscribió en Wise2.
-- El maestro solo ve el estado de la ficha y el WhatsApp que él mismo escribió.

alter table public.inscripciones drop constraint if exists inscripciones_origen_check;
alter table public.inscripciones add constraint inscripciones_origen_check check (origen in ('clase', 'enlace', 'maestro'));
alter table public.inscripciones add column if not exists token text unique;
alter table public.inscripciones add column if not exists whatsapp text;
alter table public.inscripciones add column if not exists completada_en timestamptz;
alter table public.inscripciones add column if not exists enviado_en timestamptz;
alter table public.inscripciones add column if not exists envios integer not null default 0;
-- Las inscripciones que ya existían las llenó el propio joven: están completas.
update public.inscripciones set completada_en = creado_en where completada_en is null and origen <> 'maestro';
create index if not exists inscripciones_alumno on public.inscripciones (alumno_id) where alumno_id is not null;

-- El maestro (o quien tenga acceso a la clase) pide la ficha de un alumno de su clase.
-- Si ya la tenía, devuelve el mismo enlace y cuenta un envío más.
-- token: el celular del maestro lo genera para poder abrir WhatsApp al instante.
create or replace function public.preinscribir_alumno(alumno uuid, celular text, token text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  a public.clase_alumnos%rowtype;
  previa public.inscripciones%rowtype;
  cel text;
  t text;
begin
  select * into a from public.clase_alumnos x where x.id = alumno;
  if a.id is null then
    raise exception 'No encontramos a ese alumno';
  end if;
  if not public.puede_usar_clase(a.clase_id) then
    raise exception 'No tienes acceso a esta clase';
  end if;
  cel := left(trim(coalesce(celular, '')), 30);
  if length(regexp_replace(cel, '\D', '', 'g')) < 7 then
    raise exception 'Escribe el número de WhatsApp del alumno';
  end if;
  select * into previa from public.inscripciones x
  where x.alumno_id = alumno and x.origen = 'maestro'
  order by x.creado_en desc limit 1;
  if previa.id is not null then
    update public.inscripciones x
    set whatsapp = cel,
        datos = case when x.completada_en is null then x.datos || jsonb_build_object('celular', cel) else x.datos end,
        enviado_en = now(), envios = x.envios + 1
    where x.id = previa.id;
    return jsonb_build_object('token', previa.token, 'completa', previa.completada_en is not null);
  end if;
  t := case when coalesce(token, '') ~ '^[A-Za-z0-9]{16,40}$' then token else replace(gen_random_uuid()::text, '-', '') end;
  insert into public.inscripciones (clase_id, alumno_id, persona_id, nombre, datos, origen, token, whatsapp, enviado_en, envios)
  values (a.clase_id, a.id, a.persona_id, a.nombre,
    public.datos_inscripcion(jsonb_build_object('celular', cel, 'estaca', a.estaca, 'barrio', a.barrio)),
    'maestro', t, cel, now(), 1);
  return jsonb_build_object('token', t, 'completa', false);
end;
$$;

-- Estado de las fichas de una clase, para el maestro (sin los datos privados).
create or replace function public.fichas_de_clase(clase uuid)
returns table (alumno_id uuid, token text, whatsapp text, completa boolean, inscrito boolean, enviado_en timestamptz, envios integer)
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
  select i.alumno_id, i.token, coalesce(i.whatsapp, ''), i.completada_en is not null, i.atendida_en is not null, i.enviado_en, i.envios
  from public.inscripciones i
  where i.clase_id = clase and i.origen = 'maestro' and i.alumno_id is not null;
end;
$$;

-- El administrador (o el maestro de la clase) anota que volvió a enviar el enlace.
create or replace function public.ficha_enviada(ficha text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  c uuid;
  hay boolean;
begin
  select true, i.clase_id into hay, c from public.inscripciones i where i.token = ficha;
  if hay is null then
    raise exception 'No encontramos esa ficha';
  end if;
  if not (public.es_admin() or (c is not null and public.puede_usar_clase(c))) then
    raise exception 'No tienes acceso a esta ficha';
  end if;
  update public.inscripciones i set enviado_en = now(), envios = i.envios + 1 where i.token = ficha;
end;
$$;

-- Lo que ve el alumno al abrir su enlace: solo su nombre, programa, estaca, barrio y WhatsApp.
create or replace function public.ficha_por_token(ficha text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select jsonb_build_object(
        'estado', case when i.atendida_en is not null then 'inscrito' when i.completada_en is not null then 'completa' else 'abierta' end,
        'programa', coalesce(i.programa, c.programa),
        'nombre', i.nombre,
        'estaca', coalesce(i.datos ->> 'estaca', ''),
        'barrio', coalesce(i.datos ->> 'barrio', ''),
        'celular', coalesce(i.whatsapp, ''),
        'maestro', coalesce(c.maestro_nombre, ''))
     from public.inscripciones i
     left join public.clases c on c.id = i.clase_id
     where i.origen = 'maestro' and i.token is not null and i.token = ficha_por_token.ficha),
    jsonb_build_object('estado', 'no_existe'));
$$;

-- El alumno envía su ficha (o la corrige mientras no lo hayan inscrito en Wise2).
create or replace function public.completar_ficha(ficha text, datos jsonb default '{}')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  r public.inscripciones%rowtype;
  prog text;
  d jsonb;
  acuerdo_ok text;
begin
  select * into r from public.inscripciones x where x.origen = 'maestro' and x.token is not null and x.token = ficha;
  if r.id is null then
    raise exception 'Este enlace de inscripción no existe. Pide a tu maestro que te lo envíe otra vez.';
  end if;
  if r.atendida_en is not null then
    raise exception 'Tu inscripción ya fue registrada. Si necesitas corregir algo, avisa a tu maestro.';
  end if;
  prog := coalesce(r.programa, (select c.programa from public.clases c where c.id = r.clase_id));
  if coalesce(datos ->> 'nacimiento', '') = '' or coalesce(datos ->> 'celular', '') = '' then
    raise exception 'Escribe tu fecha de nacimiento y tu celular';
  end if;
  -- (En plpgsql un CASE dentro de la condición de un IF se confunde con su THEN.)
  acuerdo_ok := case when prog = 'S' then 'Seminario 2/19' else 'Instituto 2/19' end;
  if coalesce(datos ->> 'acuerdo', '') <> acuerdo_ok then
    raise exception 'Para inscribirte debes aceptar el acuerdo de inscripción';
  end if;
  if prog = 'S' and (coalesce(trim(datos ->> 'tutor'), '') = '' or coalesce(trim(datos ->> 'tutor_celular'), '') = '') then
    raise exception 'Escribe el nombre y el número de tu padre o madre';
  end if;
  d := public.datos_inscripcion(datos) || jsonb_build_object('acepto_en', now());
  update public.inscripciones x set datos = x.datos || d, completada_en = now() where x.id = r.id;
  return jsonb_build_object('estado', case when r.completada_en is null then 'completa' else 'actualizada' end, 'nombre', r.nombre, 'programa', prog);
end;
$$;

-- Inscritos para el administrador: ahora también trae el estado de la ficha y el enlace.
drop function if exists public.inscripciones_wise(boolean, text);
create function public.inscripciones_wise(atendidas boolean default false, prog text default null)
returns table (id uuid, nombre text, datos jsonb, creado_en timestamptz, atendida_en timestamptz, aprobada text,
  maestro text, horario text, programa text, estaca text, en_base boolean, barrio text, origen text,
  completada_en timestamptz, token text, whatsapp text, enviado_en timestamptz, envios integer, retirado boolean)
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
    case when i.qr_id is null then '' else coalesce((select q.estado from public.asistencia_qr q where q.id = i.qr_id), 'aprobada') end,
    coalesce(c.maestro_nombre, ''), coalesce(c.horario, ''), coalesce(i.programa, c.programa),
    coalesce(c.estaca, (select x.estaca from public.personas x where x.id = i.persona_id), ''),
    i.persona_id is not null,
    coalesce((select x.barrio from public.personas x where x.id = i.persona_id), ''),
    i.origen, i.completada_en, i.token, coalesce(i.whatsapp, ''), i.enviado_en, i.envios,
    i.origen = 'maestro' and (i.alumno_id is null or exists (select 1 from public.clase_alumnos a where a.id = i.alumno_id and a.retirado_en is not null))
  from public.inscripciones i
  left join public.clases c on c.id = i.clase_id
  where ((atendidas and i.atendida_en is not null) or (not atendidas and i.atendida_en is null))
    and (prog is null or coalesce(i.programa, c.programa) = prog)
  order by i.creado_en desc
  limit 1000;
end;
$$;

revoke execute on function public.preinscribir_alumno(uuid, text, text) from public, anon;
revoke execute on function public.fichas_de_clase(uuid) from public, anon;
revoke execute on function public.ficha_enviada(text) from public, anon;
revoke execute on function public.ficha_por_token(text) from public;
revoke execute on function public.completar_ficha(text, jsonb) from public;
revoke execute on function public.inscripciones_wise(boolean, text) from public, anon;
grant execute on function public.preinscribir_alumno(uuid, text, text) to authenticated;
grant execute on function public.fichas_de_clase(uuid) to authenticated;
grant execute on function public.ficha_enviada(text) to authenticated;
-- El alumno que abre su enlace no necesita sesión: estas funciones exigen el token de su ficha.
grant execute on function public.ficha_por_token(text) to anon, authenticated;
grant execute on function public.completar_ficha(text, jsonb) to anon, authenticated;
grant execute on function public.inscripciones_wise(boolean, text) to authenticated;

notify pgrst, 'reload schema';
