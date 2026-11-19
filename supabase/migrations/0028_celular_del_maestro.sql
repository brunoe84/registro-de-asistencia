-- Celular (WhatsApp) del maestro de cada clase, para que el administrador le envíe sus mensajes.
-- Solo el administrador lo lee y lo guarda (por funciones).
-- Si la clase aún no lo tiene, se sugiere el de otra clase del mismo maestro o el de una solicitud suya.

alter table public.clases add column if not exists maestro_celular text;

create or replace function public.celular_maestro(clase uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  v_maestro uuid;
  v text;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  select nullif(c.maestro_celular, ''), c.maestro_id into v, v_maestro from public.clases c where c.id = clase;
  if v is null and v_maestro is not null then
    select nullif(c.maestro_celular, '') into v
      from public.clases c
     where c.maestro_id = v_maestro and coalesce(c.maestro_celular, '') <> ''
     order by c.creado_en desc limit 1;
  end if;
  if v is null and v_maestro is not null then
    select nullif(s.celular, '') into v
      from public.solicitudes_acceso s
     where s.usuario_id = v_maestro and coalesce(s.celular, '') <> ''
     order by s.creado_en desc limit 1;
  end if;
  return coalesce(v, '');
end;
$$;

create or replace function public.guardar_celular_maestro(clase uuid, celular text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare v text := left(regexp_replace(coalesce(celular, ''), '[^0-9+]', '', 'g'), 16);
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  update public.clases c set maestro_celular = nullif(v, '') where c.id = clase;
  return v;
end;
$$;

revoke execute on function public.celular_maestro(uuid) from public, anon;
revoke execute on function public.guardar_celular_maestro(uuid, text) from public, anon;
grant execute on function public.celular_maestro(uuid) to authenticated;
grant execute on function public.guardar_celular_maestro(uuid, text) to authenticated;
