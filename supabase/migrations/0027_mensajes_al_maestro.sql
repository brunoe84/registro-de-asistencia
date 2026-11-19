-- Mensajes del administrador al maestro de una clase.
-- El administrador deja un mensaje (felicitación, urgente, recordatorio o aviso); el maestro lo ve
-- en una ventana emergente al abrir su clase y, al cerrarla, queda como "visto".
-- Solo se accede por funciones (sin permisos directos sobre la tabla).

create table if not exists public.clase_mensajes (
  id uuid primary key default gen_random_uuid(),
  clase_id uuid not null references public.clases(id) on delete cascade,
  tipo text not null default 'aviso' check (tipo in ('felicitacion','urgente','recordatorio','aviso')),
  texto text not null check (length(btrim(texto)) between 1 and 2000),
  creado_en timestamptz not null default now(),
  creado_por uuid default auth.uid(),
  visto_en timestamptz
);
create index if not exists clase_mensajes_clase_idx on public.clase_mensajes (clase_id, creado_en desc);
alter table public.clase_mensajes enable row level security;
revoke all on public.clase_mensajes from public, anon, authenticated;

-- Administrador: dejar un mensaje.
create or replace function public.dejar_mensaje_clase(clase uuid, texto text, tipo text default 'aviso')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare v uuid;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  insert into public.clase_mensajes (clase_id, tipo, texto)
  values (clase, coalesce(nullif(tipo, ''), 'aviso'), btrim(texto))
  returning id into v;
  return v;
end;
$$;

-- Administrador: historial de mensajes de una clase.
create or replace function public.mensajes_de_clase(clase uuid)
returns table (id uuid, tipo text, texto text, creado_en timestamptz, visto_en timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  return query
    select m.id, m.tipo, m.texto, m.creado_en, m.visto_en
    from public.clase_mensajes m
    where m.clase_id = clase
    order by m.creado_en desc
    limit 50;
end;
$$;

-- Administrador: borrar un mensaje.
create or replace function public.borrar_mensaje_clase(mensaje uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  delete from public.clase_mensajes m where m.id = mensaje;
end;
$$;

-- Maestro: mensajes sin leer de su clase.
create or replace function public.mensajes_pendientes(clase uuid)
returns table (id uuid, tipo text, texto text, creado_en timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if not public.puede_usar_clase(clase) then
    return;
  end if;
  return query
    select m.id, m.tipo, m.texto, m.creado_en
    from public.clase_mensajes m
    where m.clase_id = clase and m.visto_en is null
    order by m.creado_en;
end;
$$;

-- Maestro: marcar un mensaje como visto (el administrador no lo marca al abrir la clase).
create or replace function public.mensaje_visto(mensaje uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  update public.clase_mensajes m
     set visto_en = now()
   where m.id = mensaje
     and m.visto_en is null
     and public.puede_usar_clase(m.clase_id);
end;
$$;

revoke execute on function public.dejar_mensaje_clase(uuid, text, text) from public, anon;
revoke execute on function public.mensajes_de_clase(uuid) from public, anon;
revoke execute on function public.borrar_mensaje_clase(uuid) from public, anon;
revoke execute on function public.mensajes_pendientes(uuid) from public, anon;
revoke execute on function public.mensaje_visto(uuid) from public, anon;
grant execute on function public.dejar_mensaje_clase(uuid, text, text) to authenticated;
grant execute on function public.mensajes_de_clase(uuid) to authenticated;
grant execute on function public.borrar_mensaje_clase(uuid) to authenticated;
grant execute on function public.mensajes_pendientes(uuid) to authenticated;
grant execute on function public.mensaje_visto(uuid) to authenticated;
