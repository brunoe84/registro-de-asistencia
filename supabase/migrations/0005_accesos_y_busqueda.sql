-- El mismo maestro en varios dispositivos, unirse a una clase con su código,
-- programa de cada persona y búsqueda de nombres más tolerante.

create extension if not exists fuzzystrmatch with schema extensions;

-- ---------- Búsqueda de nombres ----------
-- Cada palabra escrita debe coincidir con alguna palabra del nombre, en cualquier orden:
-- igual (3 puntos), inicio de palabra (2) o, si se permite, con uno o dos errores de tipeo (0).
-- Devuelve null si alguna palabra no coincide. "de", "la", "y"... no cuentan.
create function public.puntaje_nombre(clave text, texto text, aproximado boolean default true)
returns integer
language sql
immutable
as $$
  select case when count(*) = 0 or bool_or(m.p is null) then null else sum(m.p)::int end
  from (
    select (
      select max(case
        when w = t then 3
        when w like t || '%' and (aproximado or length(t) >= 3) then 2
        when aproximado and length(t) >= 4
          and least(extensions.levenshtein(t, w), extensions.levenshtein(t, left(w, length(t)))) <= case when length(t) >= 6 then 2 else 1 end then 0
      end)
      from unnest(string_to_array(replace(coalesce(clave, ''), ',', ''), ' ')) as w
      where w <> ''
    ) as p
    from unnest(string_to_array(public.norm_nombre(replace(texto, ',', ' ')), ' ')) as t
    where t <> '' and t not in ('de', 'del', 'la', 'las', 'los', 'y', 'e')
  ) m;
$$;

-- ¿Alguna palabra del texto coincide (igual o inicio de 3+ letras) con el nombre?
create function public.alguna_palabra(clave text, texto text)
returns boolean
language sql
immutable
as $$
  select exists (
    select 1
    from unnest(string_to_array(public.norm_nombre(replace(texto, ',', ' ')), ' ')) as t,
      unnest(string_to_array(replace(coalesce(clave, ''), ',', ''), ' ')) as w
    where length(t) >= 2 and t not in ('de', 'del', 'la', 'las', 'los')
      and (w = t or (length(t) >= 3 and w like t || '%'))
  );
$$;

-- ---------- Programa de cada persona ----------
alter table public.personas
  add column programa text not null default '' check (programa in ('', 'S', 'I'));
create index personas_estaca_barrio_idx on public.personas (estaca, barrio);

-- Recupera el programa de quienes ya están en alguna clase.
update public.personas p
set programa = x.programa
from (
  select a.persona_id, min(c.programa) as programa
  from public.clase_alumnos a
  join public.clases c on c.id = a.clase_id
  where a.persona_id is not null
  group by a.persona_id
  having count(distinct c.programa) = 1
) x
where x.persona_id = p.id and p.programa = '';

-- Al vincular un alumno con la base, la persona hereda el programa de la clase si no lo tenía.
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

create or replace function public.cargar_personas(filas jsonb, archivo text default '')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  n_nuevas integer;
  resultado jsonb;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  create temporary table entrada on commit drop as
    select distinct on (public.norm_nombre(f.nombre)) trim(f.nombre) as nombre, coalesce(f.estaca, '') as estaca, coalesce(f.barrio, '') as barrio,
      case when f.programa in ('S', 'I') then f.programa else '' end as programa, public.norm_nombre(f.nombre) as clave
    from jsonb_to_recordset(filas) as f(nombre text, estaca text, barrio text, programa text)
    where trim(coalesce(f.nombre, '')) <> '';
  update public.personas p
  set estaca = e.estaca, barrio = e.barrio, programa = coalesce(nullif(e.programa, ''), p.programa)
  from entrada e
  where p.clave = e.clave and (p.estaca, p.barrio, p.programa) is distinct from (e.estaca, e.barrio, coalesce(nullif(e.programa, ''), p.programa));
  insert into public.personas (nombre, estaca, barrio, programa)
  select e.nombre, e.estaca, e.barrio, e.programa
  from entrada e
  where not exists (select 1 from public.personas p where p.clave = e.clave)
  on conflict do nothing;
  get diagnostics n_nuevas = row_count;
  resultado := public.vincular_alumnos();
  insert into public.cargas_base (archivo, total, nuevas, resueltas, siguen)
  values (archivo, (select count(*) from entrada), n_nuevas, (resultado ->> 'resueltas')::int, (resultado ->> 'siguen')::int);
  return resultado || jsonb_build_object('nuevas', n_nuevas, 'total', (select count(*) from entrada));
end;
$$;

-- ---------- Buscar alumnos con filtros ----------
-- Las personas que cumplen el filtro van primero; las demás se devuelven marcadas para "ver fuera del filtro".
-- Una persona sin programa conocido cuenta como dentro del filtro de programa.
drop function public.buscar_personas(text);
create function public.buscar_personas(texto text, f_programa text default null, f_estaca text default null, f_barrio text default null)
returns table (id uuid, nombre text, estaca text, barrio text, programa text, en_filtro boolean, aproximado boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, r.nombre, r.estaca, r.barrio, r.programa, r.en_filtro, r.puntos < 2 * r.palabras
  from (
    select p.id, p.nombre, p.estaca, p.barrio, p.programa,
      public.puntaje_nombre(p.clave, texto) as puntos,
      (select count(*) from unnest(string_to_array(public.norm_nombre(replace(texto, ',', ' ')), ' ')) t
        where t <> '' and t not in ('de', 'del', 'la', 'las', 'los', 'y', 'e')) as palabras,
      (coalesce(f_programa, '') = '' or p.programa in ('', f_programa))
        and (coalesce(f_estaca, '') = '' or p.estaca = f_estaca)
        and (coalesce(f_barrio, '') = '' or p.barrio = f_barrio) as en_filtro
    from public.personas p
    where length(public.norm_nombre(texto)) >= 3
      and (public.es_admin() or exists (select 1 from public.clase_accesos a where a.usuario_id = auth.uid()))
  ) r
  where r.puntos is not null
  order by r.en_filtro desc, r.puntos desc, r.nombre
  limit 40;
$$;

create function public.barrios_por_estaca()
returns table (estaca text, barrio text, personas bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select p.estaca, p.barrio, count(*)
  from public.personas p
  where p.barrio <> ''
    and (public.es_admin() or exists (select 1 from public.clase_accesos a where a.usuario_id = auth.uid()))
  group by p.estaca, p.barrio
  order by p.estaca, p.barrio;
$$;

-- ---------- Accesos ----------
-- "dispositivo": el mismo maestro titular entrando desde otro celular o la PC.
-- vence_en: los colaboradores invitados con código tienen acceso por un tiempo.
alter table public.clase_accesos drop constraint clase_accesos_tipo_check;
alter table public.clase_accesos add constraint clase_accesos_tipo_check check (tipo in ('titular', 'dispositivo', 'colaborador'));
alter table public.clase_accesos add column vence_en timestamptz;

create function public.tiene_acceso(clase uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.clase_accesos
    where clase_id = clase and usuario_id = auth.uid() and (vence_en is null or vence_en > now())
  );
$$;

create or replace function public.puede_usar_clase(clase uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.es_admin() or public.tiene_acceso(clase);
$$;

-- ---------- Buscar clases ----------
-- El código solo se muestra a quien ya tiene acceso: con el código se entra a la clase.
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
  where r.puntos is not null
  order by r.puntos desc, r.maestro_nombre, r.horario
  limit 20;
$$;

-- Da acceso reemplazando un acceso vencido. Devuelve false si no se pudo (p. ej. la clase ya tiene titular).
create function public.dar_acceso(clase uuid, usuario uuid, tipo_nuevo text, vence timestamptz)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  filas integer;
begin
  delete from public.clase_accesos
  where clase_id = clase and usuario_id = usuario and vence_en is not null and vence_en <= now();
  insert into public.clase_accesos (clase_id, usuario_id, tipo, vence_en)
  values (clase, usuario, tipo_nuevo, vence)
  on conflict do nothing;
  get diagnostics filas = row_count;
  return filas = 1;
end;
$$;

create or replace function public.adoptar_clase(clase uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.tiene_acceso(clase) then
    return 'ya_tuya';
  end if;
  return case when public.dar_acceso(clase, auth.uid(), 'titular', null) then 'adoptada' else 'ocupada' end;
end;
$$;

create or replace function public.resolver_solicitud(solicitud uuid, aprobar boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.solicitudes_acceso%rowtype;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  update public.solicitudes_acceso
  set estado = case when aprobar then 'aprobada' else 'rechazada' end, resuelto_en = now()
  where id = solicitud and estado = 'pendiente'
  returning * into s;
  if s.id is not null and aprobar then
    perform public.dar_acceso(s.clase_id, s.usuario_id, 'colaborador', null);
    update public.perfiles set nombre = trim(s.nombres || ' ' || s.apellidos)
    where id = s.usuario_id and nombre = '';
  end if;
end;
$$;

drop function public.mis_clases();
create function public.mis_clases()
returns table (id uuid, codigo text, titulo text, maestro text, programa text, estaca text, horario text, curso text, tipo text, alumnos bigint, dias smallint[], inicio date, fin date, fechas_extra date[], fechas_omitidas date[], ultima_fecha date, vence_en timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id, c.codigo, c.titulo, c.maestro_nombre, c.programa, c.estaca, c.horario, c.curso, a.tipo,
    (select count(*) from public.clase_alumnos x where x.clase_id = c.id and x.retirado_en is null),
    c.dias, c.inicio, c.fin, c.fechas_extra, c.fechas_omitidas,
    (select max(m.fecha) from public.asistencia m where m.clase_id = c.id),
    a.vence_en
  from public.clase_accesos a
  join public.clases c on c.id = a.clase_id
  where a.usuario_id = auth.uid() and (a.vence_en is null or a.vence_en > now())
  order by c.maestro_nombre, c.horario;
$$;

drop function public.accesos_de_clase(uuid);
create function public.accesos_de_clase(clase uuid)
returns table (usuario_id uuid, nombre text, tipo text, creado_en timestamptz, vence_en timestamptz)
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
  select a.usuario_id, coalesce(nullif(p.nombre, ''), 'Sin nombre'), a.tipo, a.creado_en, a.vence_en
  from public.clase_accesos a
  join public.perfiles p on p.id = a.usuario_id
  where a.clase_id = clase
  order by a.tipo desc, a.creado_en;
end;
$$;

-- ---------- Invitaciones de un solo uso ----------
-- Cada clase tiene una invitación activa (CL-…). Quien la usa entra como colaborador por una semana,
-- un mes o todo el periodo; luego se crea otra invitación para la siguiente persona.
-- El código fijo de la clase ya no da acceso a quien no lo tiene.
create table public.invitaciones (
  codigo text primary key,
  clase_id uuid not null references public.clases (id) on delete cascade,
  duracion text not null default 'semana' check (duracion in ('semana', 'mes', 'periodo')),
  creada_en timestamptz not null default now(),
  usada_por uuid references public.perfiles (id) on delete set null,
  usada_en timestamptz
);
create unique index invitacion_activa on public.invitaciones (clase_id) where usada_en is null;
alter table public.invitaciones enable row level security;
revoke all on public.invitaciones from anon, authenticated;

create or replace function public.nuevo_codigo_clase()
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
    nuevo := 'CL-' || (
      select string_agg(substr(letras, 1 + floor(random() * length(letras))::int, 1), '')
      from generate_series(1, 5)
    );
    exit when not exists (select 1 from public.clases c where c.codigo = nuevo)
      and not exists (select 1 from public.invitaciones i where i.codigo = nuevo);
  end loop;
  return nuevo;
end;
$$;

create function public.vence_invitacion(duracion text, fin date)
returns timestamptz
language sql
stable
as $$
  select case duracion
    when 'semana' then now() + interval '7 days'
    when 'mes' then now() + interval '1 month'
    else case when fin is null then null
      else greatest(now() + interval '1 day', ((fin + 1)::timestamp at time zone 'America/Lima')) end
  end;
$$;

-- El maestro (o el administrador) ve la invitación activa y puede cambiar su duración.
create function public.invitacion_de_clase(clase uuid, duracion_nueva text default null)
returns table (codigo text, duracion text, vence_en timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  i public.invitaciones%rowtype;
  f date;
begin
  if not (public.es_admin() or exists (
    select 1 from public.clase_accesos a
    where a.clase_id = clase and a.usuario_id = auth.uid() and a.tipo in ('titular', 'dispositivo')
  )) then
    raise exception 'Solo el maestro de la clase puede invitar';
  end if;
  if duracion_nueva is not null and duracion_nueva not in ('semana', 'mes', 'periodo') then
    raise exception 'Duración no válida';
  end if;
  select * into i from public.invitaciones x where x.clase_id = clase and x.usada_en is null;
  if i.codigo is null then
    insert into public.invitaciones (codigo, clase_id, duracion)
    values (public.nuevo_codigo_clase(), clase, coalesce(duracion_nueva, 'semana'))
    returning * into i;
  elsif duracion_nueva is not null and duracion_nueva <> i.duracion then
    update public.invitaciones x set duracion = duracion_nueva where x.codigo = i.codigo returning * into i;
  end if;
  select c.fin into f from public.clases c where c.id = clase;
  return query select i.codigo, i.duracion, public.vence_invitacion(i.duracion, f);
end;
$$;

-- Es el mismo maestro si al menos un nombre y un apellido coinciden con el maestro de la clase
-- o con el nombre que dio quien la adoptó.
create function public.es_mismo_maestro(clase uuid, nombres text, apellidos text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from (
      select c.maestro_nombre as n from public.clases c where c.id = clase
      union all
      select p.nombre from public.clase_accesos a join public.perfiles p on p.id = a.usuario_id
      where a.clase_id = clase and a.tipo in ('titular', 'dispositivo')
    ) x
    where public.alguna_palabra(public.norm_nombre(x.n), nombres)
      and public.alguna_palabra(public.norm_nombre(x.n), apellidos)
  );
$$;

create function public.solicitar_acceso(clase uuid, nombres text, apellidos text, barrio text, estaca text, programa text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  mismo boolean;
  aprobado_antes boolean;
  entra boolean;
begin
  if auth.uid() is null then
    raise exception 'Sin sesión';
  end if;
  if trim(coalesce(nombres, '')) = '' or trim(coalesce(apellidos, '')) = '' then
    raise exception 'Faltan nombres o apellidos';
  end if;
  if public.tiene_acceso(clase) then
    return 'ya_tuya';
  end if;
  mismo := public.es_mismo_maestro(clase, nombres, apellidos);
  -- El administrador ya aprobó antes a esta persona (con este nombre) para esta clase:
  -- vuelve a entrar desde otro dispositivo o navegador sin esperar otra aprobación.
  aprobado_antes := not mismo and exists (
    select 1 from public.solicitudes_acceso s
    where s.clase_id = clase and s.estado = 'aprobada'
      and public.alguna_palabra(public.norm_nombre(s.nombres), nombres)
      and public.alguna_palabra(public.norm_nombre(s.apellidos), apellidos)
  );
  entra := mismo or aprobado_antes;
  if entra then
    perform public.dar_acceso(clase, auth.uid(), case when mismo then 'dispositivo' else 'colaborador' end, null);
    update public.solicitudes_acceso set estado = 'aprobada', resuelto_en = now()
    where clase_id = clase and usuario_id = auth.uid() and estado = 'pendiente';
  end if;
  insert into public.solicitudes_acceso (clase_id, usuario_id, nombres, apellidos, barrio, estaca, programa, estado, resuelto_en)
  values (clase, auth.uid(), trim(nombres), trim(apellidos), trim(barrio), estaca, case when programa in ('S', 'I') then programa else 'S' end,
    case when entra then 'aprobada' else 'pendiente' end, case when entra then now() end)
  on conflict do nothing;
  update public.perfiles set nombre = left(trim(nombres || ' ' || apellidos), 80) where id = auth.uid() and nombre = '';
  return case when mismo then 'acceso' when aprobado_antes then 'acceso_colaborador' else 'pendiente' end;
end;
$$;

-- Entrar con un código: una invitación activa da acceso de colaborador por su duración y se renueva.
-- Con el código fijo de la clase solo entra quien ya tiene acceso.
create function public.unirme_con_codigo(codigo_clase text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cod text := upper(trim(codigo_clase));
  i public.invitaciones%rowtype;
  c public.clases%rowtype;
  vence timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Sin sesión';
  end if;
  select * into i from public.invitaciones x where x.codigo = cod for update;
  if i.codigo is not null then
    select * into c from public.clases x where x.id = i.clase_id;
    if public.tiene_acceso(c.id) then
      return jsonb_build_object('estado', 'ya_tuya', 'codigo', c.codigo);
    end if;
    if i.usada_en is not null then
      return jsonb_build_object('estado', 'usado');
    end if;
    vence := public.vence_invitacion(i.duracion, c.fin);
    perform public.dar_acceso(c.id, auth.uid(), 'colaborador', vence);
    update public.invitaciones set usada_por = auth.uid(), usada_en = now() where codigo = i.codigo;
    insert into public.invitaciones (codigo, clase_id, duracion) values (public.nuevo_codigo_clase(), c.id, i.duracion);
    return jsonb_build_object('estado', 'acceso', 'codigo', c.codigo, 'vence_en', vence);
  end if;
  select * into c from public.clases x where x.codigo = cod;
  if c.id is null then
    return jsonb_build_object('estado', 'no_existe');
  end if;
  if public.tiene_acceso(c.id) then
    return jsonb_build_object('estado', 'ya_tuya', 'codigo', c.codigo);
  end if;
  return jsonb_build_object('estado', 'sin_invitacion');
end;
$$;

-- Los recordatorios también llegan a los otros dispositivos del maestro titular.
create or replace function public.clases_para_recordatorio()
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
  where a.tipo in ('titular', 'dispositivo')
    and exists (select 1 from public.suscripciones_push s where s.usuario_id = a.usuario_id);
$$;

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
  order by c.maestro_nombre, c.horario;
end;
$$;

-- ---------- Permisos ----------
revoke execute on function public.es_mismo_maestro(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.dar_acceso(uuid, uuid, text, timestamptz) from public, anon, authenticated;
revoke execute on function public.tiene_acceso(uuid) from public, anon;
do $$
declare
  f text;
begin
  foreach f in array array[
    'public.buscar_personas(text, text, text, text)', 'public.barrios_por_estaca()', 'public.buscar_clases(text)',
    'public.solicitar_acceso(uuid, text, text, text, text, text)', 'public.unirme_con_codigo(text)', 'public.cargar_personas(jsonb, text)',
    'public.mis_clases()', 'public.accesos_de_clase(uuid)', 'public.invitacion_de_clase(uuid, text)', 'public.adoptar_clase(uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

notify pgrst, 'reload schema';
