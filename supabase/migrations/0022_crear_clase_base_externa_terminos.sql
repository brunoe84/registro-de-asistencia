-- Requiere 0021 aplicada antes (redefine contadores_admin y buscar_clases_inscripcion).
--
-- 1. Términos y Condiciones / Política de Privacidad: se registra quién los aceptó, qué versión y
--    al hacer qué (crear evento, crear o adoptar clase, colaborar...).
-- 2. Crear clase (cualquier usuario): queda como titular. base 'ica' = clase del Programa Ica
--    (aparece en el panel del administrador); base 'propia' = clase privada con su propia lista
--    (no aparece en Seguimiento, Alertas, Inscritos ni en las búsquedas públicas de clases).
-- 3. Base externa de un evento: el organizador sube una lista (solo nombre, estaca, barrio y
--    programa). Si el evento tiene base propia, la búsqueda al marcar y el QR buscan en ella y no
--    en la base del Programa Ica.

-- ---------- 1. Términos ----------
create table if not exists public.aceptaciones_terminos (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references public.perfiles (id) on delete cascade,
  version text not null,
  contexto text not null default '',
  aceptado_en timestamptz not null default now()
);
create index if not exists aceptaciones_usuario on public.aceptaciones_terminos (usuario_id, version);
alter table public.aceptaciones_terminos enable row level security;
revoke all on public.aceptaciones_terminos from anon, authenticated;

create or replace function public.version_terminos()
returns text
language sql
immutable
as $$ select '2026-11'::text $$;

create or replace function public.aceptar_terminos(version text, contexto text default '')
returns void
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if auth.uid() is null then
    raise exception 'Sesión no válida';
  end if;
  if version <> public.version_terminos() then
    raise exception 'Actualiza la aplicación para aceptar los términos vigentes';
  end if;
  insert into public.aceptaciones_terminos (usuario_id, version, contexto)
  values (auth.uid(), version, left(coalesce(contexto, ''), 40));
end;
$$;

create or replace function public.acepto_terminos()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.aceptaciones_terminos a
                 where a.usuario_id = auth.uid() and a.version = public.version_terminos());
$$;

-- ---------- 2. Clases creadas por usuarios ----------
alter table public.clases add column if not exists base text not null default 'ica' check (base in ('ica', 'propia'));
alter table public.clases add column if not exists creado_por uuid references public.perfiles (id) on delete set null;

-- Alumnos de clases con base propia: no se vinculan con la base del Programa Ica.
create or replace function public.alumno_antes_guardar()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  es_maestro boolean := auth.uid() is not null and not public.es_admin();
  p public.personas%rowtype;
begin
  if tg_op = 'UPDATE' then
    if es_maestro then
      new.vinculo := old.vinculo;
      new.origen := old.origen;
      new.persona_id := old.persona_id;
    end if;
    return new;
  end if;
  if es_maestro then
    new.origen := 'maestro';
    new.vinculo := 'pendiente';
  end if;
  if (select c.base from public.clases c where c.id = new.clase_id) = 'propia' then
    new.persona_id := null;
    return new;
  end if;
  if new.persona_id is not null then
    select * into p from public.personas where id = new.persona_id;
  elsif new.vinculo = 'pendiente' and (select count(*) from public.personas x where x.clave = public.norm_nombre(new.nombre)) = 1 then
    select * into p from public.personas x where x.clave = public.norm_nombre(new.nombre);
  end if;
  if p.id is not null then
    new.persona_id := p.id;
    new.vinculo := 'vinculado';
    new.estaca := p.estaca;
    new.barrio := p.barrio;
    if p.programa = '' then
      update public.personas set programa = (select c.programa from public.clases c where c.id = new.clase_id) where id = p.id;
    end if;
  else
    new.persona_id := null;
  end if;
  return new;
end;
$$;

-- datos: {programa, curso, horario, titulo, maestro, estaca, barrio, dias[], inicio, fin, base,
--         alumnos: [{nombre, estaca, barrio}]}  (alumnos solo con base propia; máx. 500)
create or replace function public.crear_clase(datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  b text := case when datos ->> 'base' = 'propia' then 'propia' else 'ica' end;
  prog text := datos ->> 'programa';
  mae text := left(trim(coalesce(datos ->> 'maestro', '')), 60);
  cur text := left(trim(coalesce(datos ->> 'curso', '')), 80);
  hor text := left(trim(coalesce(datos ->> 'horario', '')), 40);
  tit text := left(trim(coalesce(datos ->> 'titulo', '')), 80);
  est text := left(trim(coalesce(datos ->> 'estaca', '')), 80);
  bar text := left(trim(coalesce(datos ->> 'barrio', '')), 80);
  d smallint[];
  ini date := nullif(datos ->> 'inicio', '')::date;
  fn date := nullif(datos ->> 'fin', '')::date;
  nueva public.clases%rowtype;
  a jsonb;
  n integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Sesión no válida';
  end if;
  if not public.acepto_terminos() then
    raise exception 'Debes aceptar los Términos y Condiciones y la Política de Privacidad';
  end if;
  if prog not in ('S', 'I') then
    raise exception 'Elige Seminario o Instituto';
  end if;
  if mae = '' then
    raise exception 'Escribe el nombre del maestro';
  end if;
  if b = 'ica' and est = '' then
    raise exception 'Elige la estaca';
  end if;
  select coalesce(array_agg(distinct x::smallint order by x::smallint), '{}') into d
  from jsonb_array_elements_text(coalesce(datos -> 'dias', '[]'::jsonb)) x
  where x ~ '^[0-6]$';
  if cardinality(d) = 0 then
    raise exception 'Elige al menos un día de clase';
  end if;
  if ini is not null and fn is not null and fn < ini then
    raise exception 'El fin no puede ser antes del inicio';
  end if;
  if tit = '' then
    tit := case when prog = 'I' then coalesce(nullif(cur, ''), mae) else coalesce(nullif(concat_ws(' · ', nullif(cur, ''), nullif(hor, '')), ''), mae) end;
  end if;

  begin
    insert into public.clases (titulo, programa, estaca, barrio, dias, maestro_nombre, horario, curso, inicio, fin, base, creado_por)
    values (tit, prog, est, bar, d, mae, hor, cur, coalesce(ini, (now() at time zone 'America/Lima')::date), fn, b, auth.uid())
    returning * into nueva;
  exception when unique_violation then
    raise exception 'Ya existe una clase con ese maestro, curso y horario. Búscala con «Buscar mi clase».';
  end;

  perform public.dar_acceso(nueva.id, auth.uid(), 'titular', null);
  update public.perfiles x set nombre = mae where x.id = auth.uid() and x.nombre = '';

  if b = 'propia' then
    for a in select * from jsonb_array_elements(coalesce(datos -> 'alumnos', '[]'::jsonb)) limit 500 loop
      continue when coalesce(trim(a ->> 'nombre'), '') = '';
      insert into public.clase_alumnos (clase_id, nombre, estaca, barrio)
      values (nueva.id, left(trim(a ->> 'nombre'), 120), left(trim(coalesce(a ->> 'estaca', '')), 80), left(trim(coalesce(a ->> 'barrio', '')), 80))
      on conflict do nothing;
      n := n + 1;
    end loop;
  end if;
  return jsonb_build_object('id', nueva.id, 'codigo', nueva.codigo, 'alumnos', n);
end;
$$;

-- ---------- Panel del administrador: solo clases del Programa Ica ----------
create or replace function public.resumen_clases()
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
    (select count(*) from public.clase_accesos a where a.clase_id = c.id and a.tipo = 'colaborador' and (a.vence_en is null or a.vence_en > now())),
    (select count(*) from public.asistencia m where m.clase_id = c.id and m.estado <> 'F'),
    (select count(*) from public.asistencia m where m.clase_id = c.id),
    c.ultimo_cambio_maestro, c.cambios_maestro, c.dias, c.inicio, c.fin, c.fechas_extra, c.fechas_omitidas,
    (select max(m.fecha) from public.asistencia m where m.clase_id = c.id),
    (select count(*) from public.clase_accesos a join public.suscripciones_push s on s.usuario_id = a.usuario_id where a.clase_id = c.id and a.tipo in ('titular', 'dispositivo'))
  from public.clases c
  where c.base = 'ica'
  order by c.maestro_nombre, c.horario;
end;
$$;

create or replace function public.alertas_base()
returns table (id uuid, nombre text, vinculo text, origen text, ultimo_intento timestamptz, clase_id uuid, codigo text, maestro text, programa text, estaca text, horario text)
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
  select a.id, a.nombre, a.vinculo, a.origen, a.ultimo_intento, c.id, c.codigo, c.maestro_nombre, c.programa, c.estaca, c.horario
  from public.clase_alumnos a
  join public.clases c on c.id = a.clase_id
  where a.vinculo in ('pendiente', 'no_miembro') and a.retirado_en is null and c.base = 'ica'
  order by a.vinculo, c.estaca, a.nombre;
end;
$$;

create or replace function public.contadores_admin()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  return jsonb_build_object(
    'solicitudes', (select count(*) from public.solicitudes_acceso where estado = 'pendiente'),
    'alertas', (select count(*) from public.clase_alumnos a join public.clases c on c.id = a.clase_id
                where a.vinculo = 'pendiente' and a.retirado_en is null and c.base = 'ica'),
    'inscripciones', (select count(*) from public.inscripciones i left join public.clases c on c.id = i.clase_id
                      where i.atendida_en is null and coalesce(c.base, 'ica') = 'ica'),
    'inscripciones_S', (select count(*) from public.inscripciones i left join public.clases c on c.id = i.clase_id
                        where i.atendida_en is null and coalesce(c.base, 'ica') = 'ica' and coalesce(i.programa, c.programa) = 'S'),
    'inscripciones_I', (select count(*) from public.inscripciones i left join public.clases c on c.id = i.clase_id
                        where i.atendida_en is null and coalesce(c.base, 'ica') = 'ica' and coalesce(i.programa, c.programa) = 'I')
  );
end;
$$;

-- Inscritos para Wise: sin los que vienen de clases privadas (base propia).
create or replace function public.inscripciones_wise(atendidas boolean default false, prog text default null)
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
    and coalesce(c.base, 'ica') = 'ica'
  order by i.creado_en desc
  limit 1000;
end;
$$;

-- Búsquedas públicas de clases: las privadas solo las ve quien ya tiene acceso.
create or replace function public.buscar_clases(texto text)
returns table (id uuid, codigo text, titulo text, maestro text, programa text, estaca text, horario text, curso text, adoptada boolean, tengo_acceso boolean, solicitud_pendiente boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, case when r.tengo_acceso or public.es_admin() then r.codigo end, r.titulo, r.maestro_nombre, r.programa, r.estaca, r.horario, r.curso,
    r.adoptada, r.tengo_acceso, r.solicitud_pendiente
  from (
    select c.*,
      public.puntaje_nombre(public.norm_nombre(c.maestro_nombre), texto) as puntos,
      exists (select 1 from public.clase_accesos a where a.clase_id = c.id and a.tipo = 'titular') as adoptada,
      public.tiene_acceso(c.id) as tengo_acceso,
      exists (select 1 from public.solicitudes_acceso s where s.clase_id = c.id and s.usuario_id = auth.uid() and s.estado = 'pendiente') as solicitud_pendiente
    from public.clases c
    where length(public.norm_nombre(texto)) >= 3
  ) r
  where r.puntos is not null and (r.base = 'ica' or r.tengo_acceso)
  order by r.puntos desc, r.maestro_nombre, r.horario
  limit 20;
$$;

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
    where length(public.norm_nombre(texto)) >= 3 and c.base = 'ica'
  ) r
  where r.puntos is not null
  order by r.puntos desc, r.maestro_nombre, r.horario
  limit 30;
$$;

-- Elegir maestro al inscribirse (0021): solo clases del Programa Ica.
create or replace function public.buscar_clases_inscripcion(token text, texto text, estaca text default null)
returns table (id uuid, maestro text, curso text, horario text, estaca_clase text, barrio text, dias smallint[], alumnos integer, coincide text)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  prog text;
begin
  select e.programa into prog from public.enlaces_inscripcion e where e.token is not null and e.token = token;
  if prog is null then
    raise exception 'Este enlace de inscripción ya no está activo';
  end if;
  if not exists (select 1 from unnest(string_to_array(public.norm_nombre(replace(texto, ',', ' ')), ' ')) t where length(t) >= 3) then
    return;
  end if;
  return query
  select r.id, r.maestro_nombre, r.curso, r.horario, r.estaca, r.barrio_txt, r.dias, r.n_alumnos,
    case when r.p_maestro is not null then 'maestro' else 'barrio' end
  from (
    select c.id, c.maestro_nombre, c.curso, c.horario, c.estaca, c.dias,
      coalesce(nullif(c.barrio, ''), b.principal, '') as barrio_txt,
      coalesce(b.n, 0)::int as n_alumnos,
      public.puntaje_nombre(public.norm_nombre(c.maestro_nombre), texto) as p_maestro,
      public.puntaje_nombre('barrio rama ' || public.norm_nombre(c.barrio || ' ' || coalesce(b.todos, '')), texto) as p_barrio
    from public.clases c
    left join lateral (
      select count(*) as n,
        string_agg(distinct a.barrio, ' ') as todos,
        mode() within group (order by nullif(a.barrio, '')) as principal
      from public.clase_alumnos a
      where a.clase_id = c.id and a.retirado_en is null
    ) b on true
    where c.programa = prog and c.base = 'ica'
      and coalesce(c.maestro_nombre, '') <> ''
      and (c.fin is null or c.fin >= current_date - 14)
  ) r
  where r.p_maestro is not null or r.p_barrio is not null
  order by (r.p_maestro is not null) desc,
    (coalesce(estaca, '') <> '' and r.estaca = estaca) desc,
    coalesce(r.p_maestro, r.p_barrio) desc, r.maestro_nombre, r.horario
  limit 15;
end;
$$;

-- ---------- 3. Base externa de un evento ----------
create table if not exists public.evento_base (
  id uuid primary key default gen_random_uuid(),
  evento_id uuid not null references public.eventos (id) on delete cascade,
  nombre text not null,
  clave text generated always as (public.norm_nombre(nombre)) stored,
  estaca text not null default '',
  barrio text not null default '',
  programa text not null default ''
);
create index if not exists evento_base_evento on public.evento_base (evento_id);
alter table public.evento_base enable row level security;
revoke all on public.evento_base from anon, authenticated;

create or replace function public.tiene_base_propia(evento uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select exists (select 1 from public.evento_base b where b.evento_id = evento) $$;

-- Reemplaza la lista del evento (filas = [] la borra y vuelve a la base del Programa Ica).
-- Solo guarda nombre, estaca, barrio y programa; cualquier otro dato se ignora.
create or replace function public.cargar_base_evento(evento uuid, filas jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  n integer;
begin
  if not (public.es_admin() or exists (select 1 from public.evento_accesos a
          where a.evento_id = evento and a.usuario_id = auth.uid() and a.tipo = 'organizador')) then
    raise exception 'Solo quien organiza el evento puede cambiar su base de datos';
  end if;
  if jsonb_array_length(coalesce(filas, '[]'::jsonb)) > 20000 then
    raise exception 'La lista tiene demasiadas filas (máximo 20 000)';
  end if;
  delete from public.evento_base b where b.evento_id = evento;
  insert into public.evento_base (evento_id, nombre, estaca, barrio, programa)
  select evento, left(trim(f ->> 'n'), 120), left(trim(coalesce(f ->> 'k', '')), 80), left(trim(coalesce(f ->> 'w', '')), 80),
    case when f ->> 'g' in ('S', 'I') then f ->> 'g' else '' end
  from jsonb_array_elements(coalesce(filas, '[]'::jsonb)) f
  where coalesce(trim(f ->> 'n'), '') <> '';
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Buscar para marcar: en la base propia del evento si la tiene; si no, en la del Programa Ica.
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
  if public.tiene_base_propia(evento) then
    return query
    select r.id, r.nombre, r.estaca, r.barrio, r.en_filtro
    from (
      select b.id, b.nombre, b.estaca, b.barrio, public.puntaje_nombre(b.clave, texto) as puntos,
        (coalesce(f_estaca, '') = '' or b.estaca = f_estaca) and (coalesce(f_barrio, '') = '' or b.barrio = f_barrio) as en_filtro
      from public.evento_base b
      where b.evento_id = evento and length(public.norm_nombre(texto)) >= 2
    ) r
    where r.puntos is not null
    order by r.en_filtro desc, r.puntos desc, r.nombre
    limit 40;
    return;
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

-- QR del evento: con base propia, el asistente se busca en ella.
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
  if not exists (select 1 from unnest(string_to_array(public.norm_nombre(replace(texto, ',', ' ')), ' ')) t
      where length(t) >= 3 and t not in ('del', 'las', 'los')) then
    return;
  end if;
  if public.tiene_base_propia(e.id) then
    return query
    select r.id, r.nombre, r.barrio, r.estaca,
      exists (select 1 from public.evento_asistentes a where a.evento_id = e.id and a.clave = r.clave and a.borrado_en is null)
    from (
      select b.id, b.nombre, b.barrio, b.estaca, b.clave, public.puntaje_nombre(b.clave, texto) as puntos
      from public.evento_base b where b.evento_id = e.id
    ) r
    where r.puntos is not null
    order by r.puntos desc, r.nombre
    limit 15;
    return;
  end if;
  return query
  select r.id, r.nombre, r.barrio, r.estaca,
    exists (select 1 from public.evento_asistentes a where a.evento_id = e.id and a.persona_id = r.id and a.borrado_en is null)
  from (
    select p.id, p.nombre, p.barrio, p.estaca, public.puntaje_nombre(p.clave, texto) as puntos
    from public.personas p
  ) r
  where r.puntos is not null
  order by (e.barrio <> '' and r.barrio = e.barrio) desc,
    (public.norm_nombre(r.estaca) = public.norm_nombre(e.estaca)) desc,
    r.puntos desc, r.nombre
  limit 15;
end;
$$;

-- Registro desde el QR: si persona_id es de la base propia del evento, se usa ese nombre.
create or replace function public.asistente_en_evento(e public.eventos, quien jsonb, origen_nuevo text, estado_nuevo text, de uuid, por text, dispositivo_nuevo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  p public.personas%rowtype;
  xb public.evento_base%rowtype;
  a public.evento_asistentes%rowtype;
  nom text;
  creada boolean := false;
begin
  if (quien ->> 'persona_id') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into xb from public.evento_base x where x.id = (quien ->> 'persona_id')::uuid and x.evento_id = e.id;
    if xb.id is null then
      select * into p from public.personas x where x.id = (quien ->> 'persona_id')::uuid;
    end if;
  end if;
  if p.id is not null then
    nom := p.nombre;
    select * into a from public.evento_asistentes x where x.evento_id = e.id and x.persona_id = p.id and x.borrado_en is null;
  else
    if xb.id is not null then
      nom := xb.nombre;
    else
      nom := left(trim(initcap(trim(coalesce(quien ->> 'apellidos', ''))) || ', ' || initcap(trim(coalesce(quien ->> 'nombres', '')))), 120);
      if coalesce(trim(quien ->> 'apellidos'), '') = '' or coalesce(trim(quien ->> 'nombres'), '') = '' then
        return null;
      end if;
    end if;
    -- ¿Ya está por su nombre (registro manual, de la base o de la lista propia)?
    select * into a from public.evento_asistentes x
    where x.evento_id = e.id and x.borrado_en is null and x.clave = public.norm_nombre(nom)
    order by x.creado_en limit 1;
  end if;
  if a.id is null then
    insert into public.evento_asistentes (evento_id, id_cliente, persona_id, nombre, estaca, barrio, origen, estado,
      acompanante_de, registrado_por, dispositivo, datos)
    values (e.id, 'q' || replace(gen_random_uuid()::text, '-', ''), p.id, nom,
      coalesce(p.estaca, nullif(xb.estaca, ''), nullif(trim(quien ->> 'estaca'), ''), e.estaca),
      coalesce(p.barrio, nullif(xb.barrio, ''), trim(coalesce(quien ->> 'barrio', ''))),
      origen_nuevo, estado_nuevo, de, por, dispositivo_nuevo,
      case when p.id is null and xb.id is null then jsonb_build_object('manual', jsonb_build_object('nombres', initcap(trim(quien ->> 'nombres')), 'apellidos', initcap(trim(quien ->> 'apellidos')))) else '{}'::jsonb end)
    on conflict do nothing
    returning * into a;
    creada := a.id is not null;
    if a.id is null then
      select * into a from public.evento_asistentes x
      where x.evento_id = e.id and x.borrado_en is null
        and ((p.id is not null and x.persona_id = p.id) or x.clave = public.norm_nombre(nom))
      order by x.creado_en limit 1;
    end if;
  end if;
  return jsonb_build_object('id', a.id, 'nombre', a.nombre, 'creada', creada, 'estado', a.estado, 'acompanante_de', a.acompanante_de);
end;
$$;

-- ---------- Permisos ----------
revoke execute on function public.version_terminos() from public, anon;
revoke execute on function public.aceptar_terminos(text, text) from public, anon;
revoke execute on function public.acepto_terminos() from public, anon;
revoke execute on function public.crear_clase(jsonb) from public, anon;
revoke execute on function public.tiene_base_propia(uuid) from public, anon, authenticated;
revoke execute on function public.cargar_base_evento(uuid, jsonb) from public, anon;
revoke execute on function public.asistente_en_evento(public.eventos, jsonb, text, text, uuid, text, text) from public, anon, authenticated;
grant execute on function public.version_terminos() to authenticated;
grant execute on function public.aceptar_terminos(text, text) to authenticated;
grant execute on function public.acepto_terminos() to authenticated;
grant execute on function public.crear_clase(jsonb) to authenticated;
grant execute on function public.cargar_base_evento(uuid, jsonb) to authenticated;

notify pgrst, 'reload schema';
