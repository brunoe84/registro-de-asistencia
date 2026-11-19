-- El celular del maestro se recuerda por maestro: al guardarlo en una clase se copia a todas sus clases
-- (mismo maestro_id o, si la clase aún no tiene cuenta, el mismo nombre de maestro). Gana el último cambio.

alter table public.clases add column if not exists maestro_celular_en timestamptz;

create or replace function public.guardar_celular_maestro(clase uuid, celular text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  v text := left(regexp_replace(coalesce(celular, ''), '[^0-9+]', '', 'g'), 16);
  v_maestro uuid;
  v_nombre text;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  select c.maestro_id, lower(btrim(coalesce(c.maestro_nombre, ''))) into v_maestro, v_nombre
    from public.clases c where c.id = clase;
  update public.clases c
     set maestro_celular = nullif(v, ''), maestro_celular_en = now()
   where c.id = clase
      or (v_maestro is not null and c.maestro_id = v_maestro)
      or (v_nombre <> '' and lower(btrim(coalesce(c.maestro_nombre, ''))) = v_nombre);
  return v;
end;
$$;

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
  v_nombre text;
  v text;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  select c.maestro_id, lower(btrim(coalesce(c.maestro_nombre, ''))) into v_maestro, v_nombre
    from public.clases c where c.id = clase;
  -- El último número guardado para este maestro (en esta o en otra de sus clases).
  select nullif(c.maestro_celular, '') into v
    from public.clases c
   where coalesce(c.maestro_celular, '') <> ''
     and (c.id = clase
          or (v_maestro is not null and c.maestro_id = v_maestro)
          or (v_nombre <> '' and lower(btrim(coalesce(c.maestro_nombre, ''))) = v_nombre))
   order by c.maestro_celular_en desc nulls last, (c.id = clase) desc
   limit 1;
  if v is null and v_maestro is not null then
    select nullif(s.celular, '') into v
      from public.solicitudes_acceso s
     where s.usuario_id = v_maestro and coalesce(s.celular, '') <> ''
     order by s.creado_en desc limit 1;
  end if;
  return coalesce(v, '');
end;
$$;

revoke execute on function public.celular_maestro(uuid) from public, anon;
revoke execute on function public.guardar_celular_maestro(uuid, text) from public, anon;
grant execute on function public.celular_maestro(uuid) to authenticated;
grant execute on function public.guardar_celular_maestro(uuid, text) to authenticated;
