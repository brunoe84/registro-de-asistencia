-- Clases importadas, adopción por maestros, solicitudes de acceso y alertas de base.
-- Una clase tiene un solo titular (quien la adopta). Otras personas entran con aprobación del administrador.

create function public.norm_nombre(texto text)
returns text
language sql
immutable
as $$
  select trim(regexp_replace(regexp_replace(regexp_replace(
    translate(lower(coalesce(texto, '')), 'áàäâéèëêíìïîóòöôúùüûñ', 'aaaaeeeeiiiioooouuuun'),
    '[^a-z, ]', ' ', 'g'), '\s*,\s*', ', ', 'g'), '\s+', ' ', 'g'));
$$;

create or replace function public.clave_coincide(clave text, texto text)
returns boolean
language sql
immutable
as $$
  select not exists (
    select 1 from unnest(string_to_array(public.norm_nombre(replace(texto, ',', ' ')), ' ')) as t
    where t <> '' and (' ' || replace(clave, ',', ' ')) not like '% ' || t || '%'
  );
$$;

-- ---------- Personas ----------
alter table public.personas
  add column clave text generated always as (public.norm_nombre(nombre)) stored;
create index personas_clave_idx on public.personas (clave);

drop policy "cuentas leen personas" on public.personas;
create policy "admin lee personas" on public.personas
  for select to authenticated
  using (public.es_admin());

create table public.cargas_base (
  id uuid primary key default gen_random_uuid(),
  archivo text not null default '',
  total integer not null default 0,
  nuevas integer not null default 0,
  resueltas integer not null default 0,
  siguen integer not null default 0,
  cargado_en timestamptz not null default now()
);

-- ---------- Clases ----------
drop policy "ver clases propias o admin" on public.clases;
drop policy "crear clase propia o admin" on public.clases;
drop policy "editar clase propia o admin" on public.clases;
drop policy "borrar clase propia o admin" on public.clases;
drop index public.clases_maestro_idx;
alter table public.clases drop column maestro_id;

create function public.nuevo_codigo_clase()
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
    exit when not exists (select 1 from public.clases c where c.codigo = nuevo);
  end loop;
  return nuevo;
end;
$$;

alter table public.clases
  add column codigo text unique default public.nuevo_codigo_clase(),
  add column maestro_nombre text not null default '',
  add column horario text not null default '',
  add column curso text not null default '',
  add column unidad text not null default '',
  add column periodo text not null default '',
  add column inicio date,
  add column fechas_extra date[] not null default '{}',
  add column fechas_omitidas date[] not null default '{}',
  add constraint clases_identidad unique (programa, estaca, maestro_nombre, horario, curso);
alter table public.clases alter column codigo set not null;

-- ---------- Accesos y solicitudes ----------
create table public.clase_accesos (
  clase_id uuid not null references public.clases (id) on delete cascade,
  usuario_id uuid not null references public.perfiles (id) on delete cascade,
  tipo text not null check (tipo in ('titular', 'colaborador')),
  creado_en timestamptz not null default now(),
  primary key (clase_id, usuario_id)
);
create unique index clase_un_titular on public.clase_accesos (clase_id) where tipo = 'titular';
create index clase_accesos_usuario_idx on public.clase_accesos (usuario_id);

create table public.solicitudes_acceso (
  id uuid primary key default gen_random_uuid(),
  clase_id uuid not null references public.clases (id) on delete cascade,
  usuario_id uuid not null default auth.uid() references public.perfiles (id) on delete cascade,
  nombres text not null,
  apellidos text not null,
  barrio text not null,
  estaca text not null,
  programa text not null check (programa in ('S', 'I')),
  estado text not null default 'pendiente' check (estado in ('pendiente', 'aprobada', 'rechazada')),
  creado_en timestamptz not null default now(),
  resuelto_en timestamptz
);
create unique index solicitud_una_pendiente on public.solicitudes_acceso (clase_id, usuario_id) where estado = 'pendiente';

create or replace function public.puede_usar_clase(clase uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.es_admin() or exists (
    select 1 from public.clase_accesos
    where clase_id = clase and usuario_id = auth.uid()
  );
$$;

create policy "ver clase con acceso" on public.clases
  for select to authenticated
  using (public.puede_usar_clase(id));

create policy "admin crea clases" on public.clases
  for insert to authenticated
  with check (public.es_admin());

create policy "admin edita clases" on public.clases
  for update to authenticated
  using (public.es_admin())
  with check (public.es_admin());

create policy "admin borra clases" on public.clases
  for delete to authenticated
  using (public.es_admin());

create policy "ver acceso propio o admin" on public.clase_accesos
  for select to authenticated
  using (usuario_id = auth.uid() or public.es_admin());

create policy "admin quita accesos" on public.clase_accesos
  for delete to authenticated
  using (public.es_admin());

create policy "ver solicitud propia o admin" on public.solicitudes_acceso
  for select to authenticated
  using (usuario_id = auth.uid() or public.es_admin());

create policy "crear solicitud propia" on public.solicitudes_acceso
  for insert to authenticated
  with check (usuario_id = auth.uid() and estado = 'pendiente');

alter table public.cargas_base enable row level security;
alter table public.clase_accesos enable row level security;
alter table public.solicitudes_acceso enable row level security;

create policy "admin ve cargas" on public.cargas_base
  for select to authenticated
  using (public.es_admin());

-- ---------- Alumnos y asistencia ----------
alter table public.clase_alumnos
  add column clave text generated always as (public.norm_nombre(nombre)) stored,
  add column vinculo text not null default 'pendiente' check (vinculo in ('vinculado', 'pendiente', 'no_miembro')),
  add column origen text not null default 'importado' check (origen in ('importado', 'maestro')),
  add column ultimo_intento timestamptz,
  add column retirado_en timestamptz,
  add constraint clase_alumnos_clave unique (clase_id, clave);
create index clase_alumnos_vinculo_idx on public.clase_alumnos (vinculo) where vinculo = 'pendiente';

alter table public.asistencia drop constraint asistencia_estado_check;
alter table public.asistencia add constraint asistencia_estado_check check (estado in ('P', 'F', 'T', 'M'));
alter table public.asistencia alter column marcado_por drop not null;

-- El vínculo con la base lo decide el sistema o el administrador, nunca el maestro.
create function public.alumno_antes_guardar()
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
  else
    new.persona_id := null;
  end if;
  return new;
end;
$$;

create trigger alumno_antes_guardar
  before insert or update on public.clase_alumnos
  for each row execute function public.alumno_antes_guardar();

create or replace function public.vincular_alumnos()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  resueltas integer;
  siguen integer;
begin
  if auth.uid() is not null and not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  with unicos as (
    select clave, min(id::text)::uuid as id from public.personas group by clave having count(*) = 1
  ), hechos as (
    update public.clase_alumnos a
    set persona_id = u.id, vinculo = 'vinculado', estaca = p.estaca, barrio = p.barrio
    from unicos u join public.personas p on p.id = u.id
    where a.vinculo = 'pendiente' and a.clave = u.clave
    returning 1
  )
  select count(*) into resueltas from hechos;
  update public.clase_alumnos set ultimo_intento = now() where vinculo = 'pendiente';
  get diagnostics siguen = row_count;
  return jsonb_build_object('resueltas', resueltas, 'siguen', siguen);
end;
$$;

-- ---------- Funciones para el maestro ----------
create function public.guardar_mi_nombre(nombre_nuevo text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.perfiles set nombre = left(trim(nombre_nuevo), 80) where id = auth.uid();
$$;

create function public.buscar_clases(texto text)
returns table (id uuid, codigo text, titulo text, maestro text, programa text, estaca text, horario text, curso text, adoptada boolean, tengo_acceso boolean, solicitud_pendiente boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id, c.codigo, c.titulo, c.maestro_nombre, c.programa, c.estaca, c.horario, c.curso,
    exists (select 1 from public.clase_accesos a where a.clase_id = c.id and a.tipo = 'titular'),
    exists (select 1 from public.clase_accesos a where a.clase_id = c.id and a.usuario_id = auth.uid()),
    exists (select 1 from public.solicitudes_acceso s where s.clase_id = c.id and s.usuario_id = auth.uid() and s.estado = 'pendiente')
  from public.clases c
  where length(public.norm_nombre(texto)) >= 3
    and public.clave_coincide(public.norm_nombre(c.maestro_nombre), texto)
  order by c.maestro_nombre, c.horario
  limit 20;
$$;

create function public.adoptar_clase(clase uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  filas integer;
begin
  if exists (select 1 from public.clase_accesos where clase_id = clase and usuario_id = auth.uid()) then
    return 'ya_tuya';
  end if;
  insert into public.clase_accesos (clase_id, usuario_id, tipo)
  values (clase, auth.uid(), 'titular')
  on conflict do nothing;
  get diagnostics filas = row_count;
  return case when filas = 1 then 'adoptada' else 'ocupada' end;
end;
$$;

create function public.mis_clases()
returns table (id uuid, codigo text, titulo text, maestro text, programa text, estaca text, horario text, curso text, tipo text, alumnos bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id, c.codigo, c.titulo, c.maestro_nombre, c.programa, c.estaca, c.horario, c.curso, a.tipo,
    (select count(*) from public.clase_alumnos x where x.clase_id = c.id and x.retirado_en is null)
  from public.clase_accesos a
  join public.clases c on c.id = a.clase_id
  where a.usuario_id = auth.uid()
  order by c.maestro_nombre, c.horario;
$$;

create function public.mis_solicitudes()
returns table (id uuid, maestro text, horario text, estado text, creado_en timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select s.id, c.maestro_nombre, c.horario, s.estado, s.creado_en
  from public.solicitudes_acceso s
  join public.clases c on c.id = s.clase_id
  where s.usuario_id = auth.uid() and s.estado = 'pendiente'
  order by s.creado_en desc;
$$;

create function public.buscar_personas(texto text)
returns table (id uuid, nombre text, estaca text, barrio text)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.nombre, p.estaca, p.barrio
  from public.personas p
  where length(public.norm_nombre(texto)) >= 3
    and (public.es_admin() or exists (select 1 from public.clase_accesos a where a.usuario_id = auth.uid()))
    and public.clave_coincide(p.clave, texto)
  order by p.nombre
  limit 25;
$$;

create function public.actualizar_calendario(clase uuid, dias_nuevos smallint[], extra date[], omitidas date[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.puede_usar_clase(clase) then
    raise exception 'Sin acceso a esta clase';
  end if;
  update public.clases
  set dias = dias_nuevos, fechas_extra = extra, fechas_omitidas = omitidas
  where id = clase;
end;
$$;

-- ---------- Funciones para el administrador ----------
create function public.resumen_clases()
returns table (id uuid, codigo text, titulo text, maestro text, programa text, estaca text, horario text, curso text, alumnos bigint, alertas bigint, titular text, colaboradores bigint, presentes bigint, marcas bigint, ultima_marca timestamptz)
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
    (select count(*) from public.clase_accesos a where a.clase_id = c.id and a.tipo = 'colaborador'),
    (select count(*) from public.asistencia m where m.clase_id = c.id and m.estado <> 'F'),
    (select count(*) from public.asistencia m where m.clase_id = c.id),
    (select max(m.actualizado_en) from public.asistencia m where m.clase_id = c.id)
  from public.clases c
  order by c.maestro_nombre, c.horario;
end;
$$;

create function public.contadores_admin()
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
    'alertas', (select count(*) from public.clase_alumnos where vinculo = 'pendiente' and retirado_en is null)
  );
end;
$$;

create function public.solicitudes_pendientes()
returns table (id uuid, clase_id uuid, codigo text, maestro text, horario text, nombres text, apellidos text, barrio text, estaca text, programa text, creado_en timestamptz)
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
  select s.id, s.clase_id, c.codigo, c.maestro_nombre, c.horario, s.nombres, s.apellidos, s.barrio, s.estaca, s.programa, s.creado_en
  from public.solicitudes_acceso s
  join public.clases c on c.id = s.clase_id
  where s.estado = 'pendiente'
  order by s.creado_en;
end;
$$;

create function public.resolver_solicitud(solicitud uuid, aprobar boolean)
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
    insert into public.clase_accesos (clase_id, usuario_id, tipo)
    values (s.clase_id, s.usuario_id, 'colaborador')
    on conflict do nothing;
    update public.perfiles set nombre = trim(s.nombres || ' ' || s.apellidos)
    where id = s.usuario_id and nombre = '';
  end if;
end;
$$;

create function public.accesos_de_clase(clase uuid)
returns table (usuario_id uuid, nombre text, tipo text, creado_en timestamptz)
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
  select a.usuario_id, coalesce(nullif(p.nombre, ''), 'Sin nombre'), a.tipo, a.creado_en
  from public.clase_accesos a
  join public.perfiles p on p.id = a.usuario_id
  where a.clase_id = clase
  order by a.tipo desc, a.creado_en;
end;
$$;

create function public.alertas_base()
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
  where a.vinculo in ('pendiente', 'no_miembro') and a.retirado_en is null
  order by a.vinculo, c.estaca, a.nombre;
end;
$$;

create function public.etiquetar_alumno(alumno uuid, vinculo_nuevo text, persona uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  p public.personas%rowtype;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  if vinculo_nuevo = 'vinculado' then
    select * into strict p from public.personas where id = persona;
    update public.clase_alumnos
    set vinculo = 'vinculado', persona_id = p.id, nombre = p.nombre, estaca = p.estaca, barrio = p.barrio
    where id = alumno;
  elsif vinculo_nuevo in ('pendiente', 'no_miembro') then
    update public.clase_alumnos
    set vinculo = vinculo_nuevo, persona_id = null
    where id = alumno;
  else
    raise exception 'Vínculo no válido';
  end if;
end;
$$;

create function public.cargar_personas(filas jsonb, archivo text default '')
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
    select distinct on (public.norm_nombre(f.nombre)) trim(f.nombre) as nombre, coalesce(f.estaca, '') as estaca, coalesce(f.barrio, '') as barrio, public.norm_nombre(f.nombre) as clave
    from jsonb_to_recordset(filas) as f(nombre text, estaca text, barrio text)
    where trim(coalesce(f.nombre, '')) <> '';
  update public.personas p
  set estaca = e.estaca, barrio = e.barrio
  from entrada e
  where p.clave = e.clave and (p.estaca, p.barrio) is distinct from (e.estaca, e.barrio);
  insert into public.personas (nombre, estaca, barrio)
  select e.nombre, e.estaca, e.barrio
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

-- Crear o completar una clase desde el reporte. Volver a importar no pisa las correcciones del maestro.
create function public.importar_clase(datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_id uuid;
  fue_nueva boolean;
  n_alumnos integer;
  n_marcas integer;
begin
  if auth.uid() is not null and not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  insert into public.clases (titulo, programa, estaca, barrio, dias, maestro_nombre, horario, curso, unidad, periodo, inicio)
  values (
    datos ->> 'titulo', datos ->> 'programa', datos ->> 'estaca', '',
    array(select jsonb_array_elements_text(datos -> 'dias'))::smallint[],
    datos ->> 'maestro', datos ->> 'horario', datos ->> 'curso', coalesce(datos ->> 'unidad', ''), coalesce(datos ->> 'periodo', ''),
    (datos ->> 'inicio')::date
  )
  on conflict on constraint clases_identidad do update
    set inicio = least(public.clases.inicio, excluded.inicio), periodo = excluded.periodo
  returning id, (xmax = 0) into c_id, fue_nueva;

  with entrada as (
    select a ->> 'nombre' as nombre from jsonb_array_elements(datos -> 'alumnos') a
  ), nuevos as (
    insert into public.clase_alumnos (clase_id, nombre, estaca, origen)
    select c_id, e.nombre, datos ->> 'estaca', 'importado' from entrada e
    on conflict on constraint clase_alumnos_clave do nothing
    returning 1
  )
  select count(*) into n_alumnos from nuevos;

  with entrada as (
    select public.norm_nombre(a ->> 'nombre') as clave, m.key::date as fecha, m.value as estado
    from jsonb_array_elements(datos -> 'alumnos') a,
      jsonb_each_text(a -> 'marcas') m
  ), nuevas as (
    insert into public.asistencia (clase_id, alumno_id, fecha, estado)
    select c_id, x.id, e.fecha, e.estado
    from entrada e
    join public.clase_alumnos x on x.clase_id = c_id and x.clave = e.clave
    on conflict (alumno_id, fecha) do nothing
    returning 1
  )
  select count(*) into n_marcas from nuevas;

  return jsonb_build_object('clase', c_id, 'nueva', fue_nueva, 'alumnos', n_alumnos, 'marcas', n_marcas);
end;
$$;

-- ---------- Permisos ----------
revoke all on public.cargas_base, public.clase_accesos, public.solicitudes_acceso from anon;
revoke update, insert on public.clases from anon;
grant select on public.cargas_base to authenticated;
grant select, delete on public.clase_accesos to authenticated;
grant select, insert on public.solicitudes_acceso to authenticated;

do $$
declare
  f text;
begin
  foreach f in array array[
    'public.vincular_alumnos()', 'public.guardar_mi_nombre(text)', 'public.buscar_clases(text)', 'public.adoptar_clase(uuid)',
    'public.mis_clases()', 'public.mis_solicitudes()', 'public.buscar_personas(text)',
    'public.actualizar_calendario(uuid, smallint[], date[], date[])', 'public.resumen_clases()', 'public.contadores_admin()',
    'public.solicitudes_pendientes()', 'public.resolver_solicitud(uuid, boolean)', 'public.accesos_de_clase(uuid)',
    'public.alertas_base()', 'public.etiquetar_alumno(uuid, text, uuid)', 'public.cargar_personas(jsonb, text)', 'public.importar_clase(jsonb)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;
revoke execute on function public.alumno_antes_guardar() from public, anon, authenticated;

alter publication supabase_realtime add table public.solicitudes_acceso, public.clase_accesos;
