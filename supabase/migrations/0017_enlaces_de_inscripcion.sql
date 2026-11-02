-- Enlaces de inscripción (uno para Seminario y otro para Instituto) que el administrador comparte
-- con QR: el joven se busca en la base (o escribe sus datos si no está), completa lo que falta,
-- acepta el acuerdo de su programa y queda en la lista de inscritos para pasarlo a Wise2.
-- Los inscritos se ven por programa, vengan del QR de una clase o de estos enlaces.

alter table public.inscripciones alter column clase_id drop not null;
alter table public.inscripciones add column programa text check (programa in ('S', 'I'));
alter table public.inscripciones add column origen text not null default 'clase' check (origen in ('clase', 'enlace'));
update public.inscripciones i set programa = c.programa from public.clases c where c.id = i.clase_id and i.programa is null;
create index inscripciones_persona on public.inscripciones (persona_id, programa) where persona_id is not null;

create table public.enlaces_inscripcion (
  programa text primary key check (programa in ('S', 'I')),
  token text unique,
  creado_en timestamptz not null default now()
);
alter table public.enlaces_inscripcion enable row level security;
revoke all on public.enlaces_inscripcion from anon, authenticated;

-- Al inscribirse desde la clase también se guarda el programa.
create or replace function public.inscripciones_poner_programa()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.programa is null and new.clase_id is not null then
    select c.programa into new.programa from public.clases c where c.id = new.clase_id;
  end if;
  return new;
end;
$$;
create trigger inscripciones_programa before insert on public.inscripciones
  for each row execute function public.inscripciones_poner_programa();

-- El administrador prende, consulta o apaga el enlace de un programa.
create or replace function public.enlace_inscripcion(prog text, activo boolean default true)
returns text
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  t text;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  if prog not in ('S', 'I') then
    raise exception 'Programa no válido';
  end if;
  if not activo then
    update public.enlaces_inscripcion e set token = null where e.programa = prog;
    return null;
  end if;
  select e.token into t from public.enlaces_inscripcion e where e.programa = prog;
  if t is null then
    t := substr(replace(gen_random_uuid()::text, '-', ''), 1, 14);
    insert into public.enlaces_inscripcion (programa, token) values (prog, t)
    on conflict (programa) do update set token = excluded.token, creado_en = now();
  end if;
  return t;
end;
$$;

-- Lo que ve el joven al abrir el enlace.
create or replace function public.inscripcion_por_enlace(token text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select jsonb_build_object('estado', 'abierto', 'programa', e.programa) from public.enlaces_inscripcion e where e.token is not null and e.token = inscripcion_por_enlace.token),
    jsonb_build_object('estado', 'no_existe'));
$$;

-- Buscarse en la base (al menos 3 letras; pocos resultados).
create or replace function public.buscar_para_inscripcion(token text, texto text)
returns table (id uuid, nombre text, estaca text, barrio text, ya_inscrito boolean)
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
  select p.id, p.nombre, p.estaca, p.barrio,
    exists (select 1 from public.inscripciones i where i.persona_id = p.id and i.programa = prog)
  from public.personas p
  where public.puntaje_nombre(p.clave, texto) is not null
  order by (p.programa = prog) desc, public.puntaje_nombre(p.clave, texto) desc, p.nombre
  limit 15;
end;
$$;

-- Enviar la inscripción. persona: de la base; si no, nombres y apellidos.
-- Si ya había una inscripción pendiente de la misma persona en el programa, se actualiza.
create or replace function public.inscribirme(token text, persona uuid default null, nombres text default null, apellidos text default null, datos jsonb default '{}')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  prog text;
  p public.personas%rowtype;
  nom text;
  d jsonb;
  previa uuid;
  acuerdo_ok text;
begin
  select e.programa into prog from public.enlaces_inscripcion e where e.token is not null and e.token = token;
  if prog is null then
    raise exception 'Este enlace de inscripción ya no está activo';
  end if;
  if persona is not null then
    select * into p from public.personas x where x.id = persona;
    if p.id is null then
      raise exception 'No encontramos a esa persona';
    end if;
    nom := p.nombre;
  else
    if coalesce(trim(nombres), '') = '' or coalesce(trim(apellidos), '') = '' then
      raise exception 'Escribe tus nombres y apellidos';
    end if;
    nom := left(initcap(trim(apellidos)) || ', ' || initcap(trim(nombres)), 120);
  end if;
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
  select i.id into previa from public.inscripciones i
  where i.programa = prog and i.atendida_en is null
    and ((p.id is not null and i.persona_id = p.id) or (p.id is null and i.persona_id is null and public.norm_nombre(i.nombre) = public.norm_nombre(nom)))
  order by i.creado_en desc limit 1;
  if previa is not null then
    update public.inscripciones i set datos = i.datos || d, creado_en = now() where i.id = previa;
  else
    insert into public.inscripciones (programa, origen, persona_id, nombre, datos)
    values (prog, 'enlace', p.id, nom, d);
  end if;
  return jsonb_build_object('estado', case when previa is null then 'inscrito' else 'actualizado' end, 'nombre', nom, 'programa', prog);
end;
$$;

-- Inscritos para el administrador, por programa.
drop function if exists public.inscripciones_wise(boolean);
create function public.inscripciones_wise(atendidas boolean default false, prog text default null)
returns table (id uuid, nombre text, datos jsonb, creado_en timestamptz, atendida_en timestamptz, aprobada text,
  maestro text, horario text, programa text, estaca text, en_base boolean, barrio text, origen text)
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
    i.origen
  from public.inscripciones i
  left join public.clases c on c.id = i.clase_id
  where ((atendidas and i.atendida_en is not null) or (not atendidas and i.atendida_en is null))
    and (prog is null or coalesce(i.programa, c.programa) = prog)
  order by i.creado_en desc
  limit 1000;
end;
$$;

revoke execute on function public.enlace_inscripcion(text, boolean) from public, anon;
revoke execute on function public.inscripcion_por_enlace(text) from public;
revoke execute on function public.buscar_para_inscripcion(text, text) from public;
revoke execute on function public.inscribirme(text, uuid, text, text, jsonb) from public;
revoke execute on function public.inscripciones_wise(boolean, text) from public, anon;
grant execute on function public.enlace_inscripcion(text, boolean) to authenticated;
-- El joven que abre el enlace no necesita sesión: estas funciones exigen el token del enlace.
grant execute on function public.inscripcion_por_enlace(text) to anon, authenticated;
grant execute on function public.buscar_para_inscripcion(text, text) to anon, authenticated;
grant execute on function public.inscribirme(text, uuid, text, text, jsonb) to anon, authenticated;
grant execute on function public.inscripciones_wise(boolean, text) to authenticated;

notify pgrst, 'reload schema';
