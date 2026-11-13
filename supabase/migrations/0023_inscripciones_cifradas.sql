-- Datos sensibles de inscripción CIFRADOS de punta a punta.
-- El administrador crea una contraseña; su celular genera un par de llaves (RSA-OAEP). La llave
-- pública queda aquí para que el celular del joven cifre sus datos antes de enviarlos. La llave
-- privada se guarda aquí CIFRADA con la contraseña del administrador (PBKDF2 + AES-GCM): el
-- servidor nunca puede leer los datos. Cualquier dispositivo del administrador la abre con la
-- contraseña.
-- Sensibles: cedula, usuario, nacimiento, celular, tutor, tutor_celular, tutor_correo, direccion.
-- Quedan en claro (los necesita la lista): estaca, barrio, miembro, acuerdo.
-- Al marcar una inscripción como "ya inscrita en Wise", sus datos sensibles se borran del servidor
-- (quedan solo en el dispositivo del administrador).

create table if not exists public.llave_inscripciones (
  id integer primary key default 1 check (id = 1),
  publica text not null,
  privada_cifrada text not null,
  sal text not null,
  iv text not null,
  iteraciones integer not null,
  creada_en timestamptz not null default now()
);
alter table public.llave_inscripciones enable row level security;
revoke all on public.llave_inscripciones from anon, authenticated;

-- Claves que se consideran sensibles.
create or replace function public.claves_sensibles()
returns text[]
language sql
immutable
as $$ select array['cedula', 'usuario', 'nacimiento', 'celular', 'tutor', 'tutor_celular', 'tutor_correo', 'direccion'] $$;

-- Limpieza de los datos de inscripción. Si llegan cifrados, se guarda el bloque cifrado y NINGÚN
-- dato sensible en claro (el celular manda marcadores "*" solo para pasar las validaciones).
create or replace function public.datos_inscripcion(d jsonb)
returns jsonb
language sql
immutable
as $$
  select case
    when jsonb_typeof(d -> 'cifrado') = 'object' then
      coalesce((select jsonb_object_agg(k, left(trim(d ->> k), 80))
                from unnest(array['estaca', 'barrio', 'miembro', 'acuerdo']) k
                where coalesce(trim(d ->> k), '') <> ''), '{}'::jsonb)
      || jsonb_build_object('cifrado', jsonb_build_object(
           'v', left(coalesce(d -> 'cifrado' ->> 'v', '1'), 4),
           'k', left(coalesce(d -> 'cifrado' ->> 'k', ''), 1000),
           'iv', left(coalesce(d -> 'cifrado' ->> 'iv', ''), 40),
           'c', left(coalesce(d -> 'cifrado' ->> 'c', ''), 6000)))
    else
      coalesce((select jsonb_object_agg(k, left(trim(d ->> k), case when k = 'direccion' then 160 else 80 end))
                from unnest(array['estaca', 'barrio', 'miembro', 'cedula', 'usuario', 'nacimiento', 'celular', 'acuerdo',
                  'tutor', 'tutor_celular', 'tutor_correo', 'direccion']) k
                where coalesce(trim(d ->> k), '') <> ''
                  and (k not in ('cedula', 'usuario') or coalesce(d ->> 'miembro', 'si') = 'si')), '{}'::jsonb)
  end;
$$;

-- Para el celular del joven (sin sesión): la llave pública, o null si aún no se creó.
create or replace function public.llave_publica_inscripciones()
returns text
language sql
stable
security definer
set search_path = ''
as $$ select l.publica from public.llave_inscripciones l where l.id = 1 $$;

-- Para el administrador: todo lo necesario para abrir la llave con su contraseña.
create or replace function public.llave_admin_inscripciones()
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
  return (select jsonb_build_object('publica', l.publica, 'privada_cifrada', l.privada_cifrada, 'sal', l.sal, 'iv', l.iv,
            'iteraciones', l.iteraciones, 'creada_en', l.creada_en)
          from public.llave_inscripciones l where l.id = 1);
end;
$$;

-- Crea la llave (una sola vez). reemplazar = true SOLO si se olvidó la contraseña: los datos
-- cifrados con la llave anterior ya no se podrán leer.
create or replace function public.guardar_llave_inscripciones(datos jsonb, reemplazar boolean default false)
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
  if coalesce(datos ->> 'publica', '') = '' or coalesce(datos ->> 'privada_cifrada', '') = ''
     or coalesce(datos ->> 'sal', '') = '' or coalesce(datos ->> 'iv', '') = '' then
    raise exception 'Llave incompleta';
  end if;
  if exists (select 1 from public.llave_inscripciones) and not reemplazar then
    raise exception 'Ya existe una llave de inscripciones. Abre la existente con tu contraseña.';
  end if;
  insert into public.llave_inscripciones (id, publica, privada_cifrada, sal, iv, iteraciones, creada_en)
  values (1, datos ->> 'publica', datos ->> 'privada_cifrada', datos ->> 'sal', datos ->> 'iv',
          coalesce((datos ->> 'iteraciones')::int, 310000), now())
  on conflict (id) do update set publica = excluded.publica, privada_cifrada = excluded.privada_cifrada,
    sal = excluded.sal, iv = excluded.iv, iteraciones = excluded.iteraciones, creada_en = now();
end;
$$;

-- El celular del administrador cifra las inscripciones que aún estaban en claro (enviadas antes de
-- crear la llave o desde una versión antigua): se reemplazan los datos sensibles por el bloque cifrado.
create or replace function public.cifrar_inscripciones(filas jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  f jsonb;
  n integer := 0;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  for f in select * from jsonb_array_elements(coalesce(filas, '[]'::jsonb)) loop
    continue when jsonb_typeof(f -> 'cifrado') <> 'object';
    update public.inscripciones i
    set datos = (i.datos - public.claves_sensibles()) || jsonb_build_object('cifrado', f -> 'cifrado')
    where i.id = (f ->> 'id')::uuid;
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- Al marcarla como inscrita en Wise, sus datos sensibles se borran del servidor.
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
  update public.inscripciones i set
    atendida_en = case when atendida then now() end,
    datos = case when atendida then (i.datos - public.claves_sensibles()) - 'cifrado' else i.datos end
  where i.id = inscripcion;
end;
$$;

revoke execute on function public.llave_publica_inscripciones() from public;
revoke execute on function public.llave_admin_inscripciones() from public, anon;
revoke execute on function public.guardar_llave_inscripciones(jsonb, boolean) from public, anon;
revoke execute on function public.cifrar_inscripciones(jsonb) from public, anon;
grant execute on function public.llave_publica_inscripciones() to anon, authenticated;
grant execute on function public.llave_admin_inscripciones() to authenticated;
grant execute on function public.guardar_llave_inscripciones(jsonb, boolean) to authenticated;
grant execute on function public.cifrar_inscripciones(jsonb) to authenticated;

notify pgrst, 'reload schema';
