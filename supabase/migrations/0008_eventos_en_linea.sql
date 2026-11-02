-- Eventos en línea: el organizador y sus colaboradores marcan en la misma lista, y los asistentes
-- se registran solos escaneando un QR (con sus acompañantes, que un colaborador aprueba).
-- Los grupos o compañías que se forman con la lista se guardan en meta.

-- ---------- Tablas ----------
create table public.eventos (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique,
  titulo text not null,
  estaca text not null default '',
  barrio text not null default '',
  fecha date not null default (now() at time zone 'America/Lima')::date,
  -- Lo demás del formulario (datos por asistente, preguntas, WhatsApp, grupos): tal cual lo usa la app.
  meta jsonb not null default '{}',
  -- Token del QR para asistentes; null = QR apagado.
  qr text unique,
  creado_por uuid references public.perfiles (id) on delete set null default auth.uid(),
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);

create table public.evento_accesos (
  evento_id uuid not null references public.eventos (id) on delete cascade,
  usuario_id uuid not null references public.perfiles (id) on delete cascade,
  tipo text not null check (tipo in ('organizador', 'colaborador')),
  creado_en timestamptz not null default now(),
  primary key (evento_id, usuario_id)
);

create table public.evento_asistentes (
  id uuid primary key default gen_random_uuid(),
  evento_id uuid not null references public.eventos (id) on delete cascade,
  -- Id de la fila en el dispositivo que la creó; las que llegan por QR usan 'q' + id.
  id_cliente text not null,
  persona_id uuid references public.personas (id) on delete set null,
  nombre text not null,
  clave text generated always as (public.norm_nombre(nombre)) stored,
  estaca text not null default '',
  barrio text not null default '',
  origen text not null default 'base' check (origen in ('base', 'manual', 'qr', 'acompanante')),
  -- 'por_aprobar': lo anotó un amigo como acompañante; un colaborador confirma que vino.
  estado text not null default 'ok' check (estado in ('ok', 'por_aprobar')),
  acompanante_de uuid references public.evento_asistentes (id) on delete set null,
  registrado_por text not null default '',
  dispositivo text not null default '',
  -- Respuestas a las preguntas, datos de inscripción manual, etc.
  datos jsonb not null default '{}',
  firma text,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  borrado_en timestamptz,
  borrado_por text,
  unique (evento_id, id_cliente)
);
create unique index evento_asistentes_persona on public.evento_asistentes (evento_id, persona_id)
  where persona_id is not null and borrado_en is null;
create index evento_asistentes_clave on public.evento_asistentes (evento_id, clave) where borrado_en is null;

alter table public.eventos enable row level security;
alter table public.evento_accesos enable row level security;
alter table public.evento_asistentes enable row level security;
-- Todo pasa por funciones; nadie lee ni escribe las tablas directamente.
revoke all on public.eventos, public.evento_accesos, public.evento_asistentes from anon, authenticated;

create or replace function public.puede_usar_evento(evento uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.es_admin() or exists (
    select 1 from public.evento_accesos a where a.evento_id = evento and a.usuario_id = auth.uid()
  );
$$;

create or replace function public.nuevo_codigo_evento()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  letras constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  nuevo text;
begin
  loop
    nuevo := 'EV-' || (
      select string_agg(substr(letras, 1 + floor(random() * length(letras))::int, 1), '')
      from generate_series(1, 5)
    );
    exit when not exists (select 1 from public.eventos e where e.codigo = nuevo);
  end loop;
  return nuevo;
end;
$$;

-- Una fila de asistente tal como la usa la app.
create or replace function public.fila_evento(a public.evento_asistentes)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', a.id_cliente,
    'sid', a.id,
    'pid', a.persona_id,
    'n', a.nombre,
    'src', a.origen,
    'estado', a.estado,
    'amigo', (select b.nombre from public.evento_asistentes b where b.id = a.acompanante_de),
    't', (extract(epoch from a.creado_en) * 1000)::bigint,
    'by', a.registrado_por,
    'dev', a.dispositivo,
    'data', jsonb_build_object('k', a.estaca, 'w', a.barrio),
    'custom', a.datos -> 'custom',
    'manual', a.datos -> 'manual',
    'sig', case when a.firma is not null then 1 end,
    'del', case when a.borrado_en is not null then true end,
    'delBy', a.borrado_por
  ));
$$;

-- ---------- Organizador y colaboradores ----------
-- Crea el evento en línea (con el código que ya tenía en el dispositivo, si está libre).
create or replace function public.crear_evento(codigo_deseado text, meta jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  e public.eventos%rowtype;
  cod text := upper(trim(coalesce(codigo_deseado, '')));
begin
  if auth.uid() is null then
    raise exception 'Sin sesión';
  end if;
  if coalesce(trim(meta ->> 'title'), '') = '' then
    raise exception 'Falta el título del evento';
  end if;
  if cod !~ '^EV-[A-Z0-9]{5}$' or exists (select 1 from public.eventos x where x.codigo = cod) then
    cod := public.nuevo_codigo_evento();
  end if;
  insert into public.eventos (codigo, titulo, estaca, barrio, fecha, meta)
  values (cod, trim(meta ->> 'title'), coalesce(meta ->> 'stake', ''), coalesce(meta ->> 'ward', ''),
    coalesce(nullif(meta ->> 'date', '')::date, (now() at time zone 'America/Lima')::date), meta)
  returning * into e;
  insert into public.evento_accesos (evento_id, usuario_id, tipo) values (e.id, auth.uid(), 'organizador');
  return jsonb_build_object('id', e.id, 'codigo', e.codigo);
end;
$$;

create or replace function public.actualizar_evento(evento uuid, meta jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if not public.puede_usar_evento(evento) then
    raise exception 'No tienes acceso a este evento';
  end if;
  update public.eventos e set
    titulo = coalesce(nullif(trim(meta ->> 'title'), ''), e.titulo),
    estaca = coalesce(meta ->> 'stake', e.estaca),
    barrio = coalesce(meta ->> 'ward', e.barrio),
    fecha = coalesce(nullif(meta ->> 'date', '')::date, e.fecha),
    meta = meta,
    actualizado_en = now()
  where e.id = evento;
end;
$$;

-- Entrar con el código del evento (EV-…) como colaborador.
create or replace function public.unirme_evento(codigo_evento text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  e public.eventos%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Sin sesión';
  end if;
  select * into e from public.eventos x where x.codigo = upper(trim(codigo_evento));
  if e.id is null then
    return jsonb_build_object('estado', 'no_existe');
  end if;
  insert into public.evento_accesos (evento_id, usuario_id, tipo) values (e.id, auth.uid(), 'colaborador')
  on conflict do nothing;
  return jsonb_build_object('estado', 'ok', 'id', e.id, 'codigo', e.codigo, 'meta', e.meta,
    'organizador', exists (select 1 from public.evento_accesos a where a.evento_id = e.id and a.usuario_id = auth.uid() and a.tipo = 'organizador'));
end;
$$;

-- Guarda filas marcadas en el dispositivo (nuevas, cambiadas o quitadas) y devuelve el evento completo.
-- Si otra persona ya marcó a la misma persona de la base, la fila nueva se ignora.
create or replace function public.sincronizar_evento(evento uuid, filas jsonb, desde timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  f jsonb;
  e public.eventos%rowtype;
begin
  if not public.puede_usar_evento(evento) then
    raise exception 'No tienes acceso a este evento';
  end if;
  for f in select * from jsonb_array_elements(coalesce(filas, '[]'::jsonb)) loop
    continue when coalesce(f ->> 'id', '') = '' or coalesce(trim(f ->> 'n'), '') = '';
    if exists (select 1 from public.evento_asistentes a where a.evento_id = evento and a.id_cliente = f ->> 'id') then
      update public.evento_asistentes a set
        estado = case when f ->> 'estado' in ('ok', 'por_aprobar') then f ->> 'estado' else a.estado end,
        datos = jsonb_strip_nulls(jsonb_build_object('custom', coalesce(f -> 'custom', a.datos -> 'custom'), 'manual', coalesce(f -> 'manual', a.datos -> 'manual'))),
        firma = coalesce(f ->> 'firma', a.firma),
        borrado_en = case when (f ->> 'del')::boolean is true then coalesce(a.borrado_en, now()) else null end,
        borrado_por = case when (f ->> 'del')::boolean is true then coalesce(f ->> 'delBy', '') else null end,
        actualizado_en = now()
      where a.evento_id = evento and a.id_cliente = f ->> 'id';
    elsif (f ->> 'del')::boolean is not true then
      insert into public.evento_asistentes (evento_id, id_cliente, persona_id, nombre, estaca, barrio, origen, estado,
        registrado_por, dispositivo, datos, firma, creado_en)
      values (evento, f ->> 'id',
        case when (f ->> 'pid') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          then (select p.id from public.personas p where p.id = (f ->> 'pid')::uuid) end,
        trim(f ->> 'n'), coalesce(f -> 'data' ->> 'k', ''), coalesce(f -> 'data' ->> 'w', ''),
        case when f ->> 'src' in ('base', 'manual', 'qr', 'acompanante') then f ->> 'src' else 'base' end,
        case when f ->> 'estado' = 'por_aprobar' then 'por_aprobar' else 'ok' end,
        coalesce(f ->> 'by', ''), coalesce(f ->> 'dev', ''),
        jsonb_strip_nulls(jsonb_build_object('custom', f -> 'custom', 'manual', f -> 'manual')),
        f ->> 'firma',
        coalesce(to_timestamp((f ->> 't')::double precision / 1000), now()))
      on conflict do nothing;
    end if;
  end loop;
  select * into e from public.eventos x where x.id = evento;
  return jsonb_build_object(
    'meta', e.meta,
    'qr', e.qr,
    'organizador', exists (select 1 from public.evento_accesos a where a.evento_id = evento and a.usuario_id = auth.uid() and a.tipo = 'organizador'),
    'filas', coalesce((
      select jsonb_agg(public.fila_evento(a) order by a.creado_en)
      from public.evento_asistentes a
      where a.evento_id = evento and (desde is null or a.actualizado_en > desde)
    ), '[]'::jsonb),
    'hasta', now()
  );
end;
$$;

create or replace function public.firmas_evento(evento uuid, ids text[])
returns table (id text, firma text)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if not public.puede_usar_evento(evento) then
    raise exception 'No tienes acceso a este evento';
  end if;
  return query
  select a.id_cliente, a.firma from public.evento_asistentes a
  where a.evento_id = evento and a.id_cliente = any (ids) and a.firma is not null;
end;
$$;

-- Buscar en la base para marcar en el evento.
create or replace function public.buscar_personas_evento(evento uuid, texto text, f_estaca text default null, f_barrio text default null)
returns table (id uuid, nombre text, estaca text, barrio text, en_filtro boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if not public.puede_usar_evento(evento) then
    raise exception 'No tienes acceso a este evento';
  end if;
  return query
  select r.id, r.nombre, r.estaca, r.barrio, r.en_filtro
  from (
    select p.id, p.nombre, p.estaca, p.barrio, public.puntaje_nombre(p.clave, texto) as puntos,
      (coalesce(f_estaca, '') = '' or p.estaca = f_estaca) and (coalesce(f_barrio, '') = '' or p.barrio = f_barrio) as en_filtro
    from public.personas p
    where length(public.norm_nombre(texto)) >= 2
  ) r
  where r.puntos is not null
  order by r.en_filtro desc, r.puntos desc, r.nombre
  limit 40;
end;
$$;

-- Prende, cambia o apaga el QR de asistentes.
create or replace function public.qr_evento(evento uuid, activo boolean)
returns text
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  t text;
begin
  if not public.puede_usar_evento(evento) then
    raise exception 'No tienes acceso a este evento';
  end if;
  if activo then
    select e.qr into t from public.eventos e where e.id = evento;
    if t is null then
      t := substr(replace(gen_random_uuid()::text, '-', ''), 1, 14);
      update public.eventos e set qr = t where e.id = evento;
    end if;
  else
    update public.eventos e set qr = null where e.id = evento;
  end if;
  return t;
end;
$$;

-- ---------- Asistentes que escanean el QR ----------
-- Solo se puede usar con un QR prendido y cerca de la fecha del evento.
create or replace function public.evento_de_qr(token text)
returns public.eventos
language sql
stable
security definer
set search_path = ''
as $$
  select e.* from public.eventos e
  where e.qr is not null and e.qr = token
    and (now() at time zone 'America/Lima')::date between e.fecha - 1 and e.fecha + 1;
$$;

create or replace function public.evento_por_qr(token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  e public.eventos%rowtype;
begin
  select * into e from public.eventos x where x.qr is not null and x.qr = token;
  if e.id is null then
    return jsonb_build_object('estado', 'no_existe');
  end if;
  return jsonb_build_object(
    'estado', case when (now() at time zone 'America/Lima')::date between e.fecha - 1 and e.fecha + 1 then 'abierto' else 'cerrado' end,
    'titulo', e.titulo, 'estaca', e.estaca, 'barrio', e.barrio, 'fecha', e.fecha);
end;
$$;

-- El asistente busca su nombre (o el de un acompañante). Para cuidar los datos de la base:
-- hay que escribir al menos dos palabras, se busca en la estaca del evento y salen pocos resultados.
create or replace function public.buscar_en_qr(token text, texto text)
returns table (id uuid, nombre text, barrio text, estaca text, registrado boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  e public.eventos%rowtype;
begin
  select * into e from public.evento_de_qr(token);
  if e.id is null then
    raise exception 'El QR no está activo';
  end if;
  if (select count(*) from unnest(string_to_array(public.norm_nombre(replace(texto, ',', ' ')), ' ')) t
      where length(t) >= 2 and t not in ('de', 'del', 'la', 'las', 'los', 'y', 'e')) < 2 then
    return;
  end if;
  return query
  select p.id, p.nombre, p.barrio, p.estaca,
    exists (select 1 from public.evento_asistentes a where a.evento_id = e.id and a.persona_id = p.id and a.borrado_en is null)
  from public.personas p
  where (e.estaca = '' or p.estaca = e.estaca)
    and public.puntaje_nombre(p.clave, texto) is not null
  order by (p.barrio = e.barrio) desc, public.puntaje_nombre(p.clave, texto) desc, p.nombre
  limit 8;
end;
$$;

-- Busca o crea la fila de una persona en el evento. quien: { persona_id } o { nombres, apellidos, estaca, barrio }.
create or replace function public.asistente_en_evento(e public.eventos, quien jsonb, origen_nuevo text, estado_nuevo text, de uuid, por text, dispositivo_nuevo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  p public.personas%rowtype;
  a public.evento_asistentes%rowtype;
  nom text;
  creada boolean := false;
begin
  if (quien ->> 'persona_id') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into p from public.personas x where x.id = (quien ->> 'persona_id')::uuid;
  end if;
  if p.id is not null then
    nom := p.nombre;
    select * into a from public.evento_asistentes x where x.evento_id = e.id and x.persona_id = p.id and x.borrado_en is null;
  else
    nom := left(trim(initcap(trim(coalesce(quien ->> 'apellidos', ''))) || ', ' || initcap(trim(coalesce(quien ->> 'nombres', '')))), 120);
    if coalesce(trim(quien ->> 'apellidos'), '') = '' or coalesce(trim(quien ->> 'nombres'), '') = '' then
      return null;
    end if;
    -- ¿Ya está por su nombre (registro manual o de la base)?
    select * into a from public.evento_asistentes x
    where x.evento_id = e.id and x.borrado_en is null and x.clave = public.norm_nombre(nom)
    order by x.creado_en limit 1;
  end if;
  if a.id is null then
    insert into public.evento_asistentes (evento_id, id_cliente, persona_id, nombre, estaca, barrio, origen, estado,
      acompanante_de, registrado_por, dispositivo, datos)
    values (e.id, 'q' || replace(gen_random_uuid()::text, '-', ''), p.id, nom,
      coalesce(p.estaca, nullif(trim(quien ->> 'estaca'), ''), e.estaca), coalesce(p.barrio, trim(coalesce(quien ->> 'barrio', ''))),
      origen_nuevo, estado_nuevo, de, por, dispositivo_nuevo,
      case when p.id is null then jsonb_build_object('manual', jsonb_build_object('nombres', initcap(trim(quien ->> 'nombres')), 'apellidos', initcap(trim(quien ->> 'apellidos')))) else '{}'::jsonb end)
    on conflict do nothing
    returning * into a;
    creada := a.id is not null;
    if a.id is null then
      select * into a from public.evento_asistentes x where x.evento_id = e.id and x.persona_id = p.id and x.borrado_en is null;
    end if;
  end if;
  return jsonb_build_object('id', a.id, 'nombre', a.nombre, 'creada', creada, 'estado', a.estado, 'acompanante_de', a.acompanante_de);
end;
$$;

-- Registro del asistente (y sus acompañantes) desde el QR.
create or replace function public.registrar_por_qr(token text, yo jsonb, acompanantes jsonb, dispositivo text default '')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  e public.eventos%rowtype;
  r jsonb;
  y jsonb;
  amigo text;
  estado_yo text;
  lista jsonb := '[]'::jsonb;
  q jsonb;
begin
  -- No pide sesión: muchos asistentes en el mismo WiFi chocarían con el límite de cuentas nuevas.
  select * into e from public.evento_de_qr(token);
  if e.id is null then
    raise exception 'El QR no está activo';
  end if;
  if jsonb_array_length(coalesce(acompanantes, '[]'::jsonb)) > 15 then
    raise exception 'Son demasiados acompañantes a la vez';
  end if;

  y := public.asistente_en_evento(e, yo, 'qr', 'ok', null, 'QR', coalesce(dispositivo, ''));
  if y is null then
    raise exception 'Escribe tus nombres y apellidos';
  end if;
  if (y ->> 'creada')::boolean then
    estado_yo := 'registrado';
  else
    -- Ya estaba: si un amigo lo anotó, ahora se confirma solo.
    select b.nombre into amigo from public.evento_asistentes b where b.id = (y ->> 'acompanante_de')::uuid;
    if y ->> 'estado' = 'por_aprobar' then
      update public.evento_asistentes a set estado = 'ok', actualizado_en = now() where a.id = (y ->> 'id')::uuid;
    end if;
    estado_yo := case when amigo is not null then 'por_amigo' else 'ya_estaba' end;
  end if;

  for q in select * from jsonb_array_elements(coalesce(acompanantes, '[]'::jsonb)) loop
    r := public.asistente_en_evento(e, q, 'acompanante', 'por_aprobar', (y ->> 'id')::uuid, y ->> 'nombre', coalesce(dispositivo, ''));
    continue when r is null or (r ->> 'id')::uuid = (y ->> 'id')::uuid;
    lista := lista || jsonb_build_object('nombre', r ->> 'nombre', 'estado', case when (r ->> 'creada')::boolean then 'agregado' else 'ya_estaba' end);
  end loop;
  update public.eventos x set actualizado_en = now() where x.id = e.id;

  return jsonb_build_object('estado', estado_yo, 'nombre', y ->> 'nombre', 'persona_id',
    (select a.persona_id from public.evento_asistentes a where a.id = (y ->> 'id')::uuid),
    'amigo', amigo, 'acompanantes', lista);
end;
$$;

-- ---------- Permisos ----------
revoke execute on function public.puede_usar_evento(uuid) from public, anon;
revoke execute on function public.nuevo_codigo_evento() from public, anon, authenticated;
revoke execute on function public.fila_evento(public.evento_asistentes) from public, anon, authenticated;
revoke execute on function public.evento_de_qr(text) from public, anon, authenticated;
revoke execute on function public.asistente_en_evento(public.eventos, jsonb, text, text, uuid, text, text) from public, anon, authenticated;
revoke execute on function public.crear_evento(text, jsonb) from public, anon;
revoke execute on function public.actualizar_evento(uuid, jsonb) from public, anon;
revoke execute on function public.unirme_evento(text) from public, anon;
revoke execute on function public.sincronizar_evento(uuid, jsonb, timestamptz) from public, anon;
revoke execute on function public.firmas_evento(uuid, text[]) from public, anon;
revoke execute on function public.buscar_personas_evento(uuid, text, text, text) from public, anon;
revoke execute on function public.qr_evento(uuid, boolean) from public, anon;
revoke execute on function public.evento_por_qr(text) from public;
revoke execute on function public.buscar_en_qr(text, text) from public;
revoke execute on function public.registrar_por_qr(text, jsonb, jsonb, text) from public;
-- El asistente que escanea el QR no necesita sesión: estas tres funciones exigen el token del QR.
grant execute on function public.evento_por_qr(text) to anon;
grant execute on function public.buscar_en_qr(text, text) to anon;
grant execute on function public.registrar_por_qr(text, jsonb, jsonb, text) to anon;
grant execute on function public.puede_usar_evento(uuid) to authenticated;
grant execute on function public.crear_evento(text, jsonb) to authenticated;
grant execute on function public.actualizar_evento(uuid, jsonb) to authenticated;
grant execute on function public.unirme_evento(text) to authenticated;
grant execute on function public.sincronizar_evento(uuid, jsonb, timestamptz) to authenticated;
grant execute on function public.firmas_evento(uuid, text[]) to authenticated;
grant execute on function public.buscar_personas_evento(uuid, text, text, text) to authenticated;
grant execute on function public.qr_evento(uuid, boolean) to authenticated;
grant execute on function public.evento_por_qr(text) to authenticated;
grant execute on function public.buscar_en_qr(text, text) to authenticated;
grant execute on function public.registrar_por_qr(text, jsonb, jsonb, text) to authenticated;

notify pgrst, 'reload schema';
