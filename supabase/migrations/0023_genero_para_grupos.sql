-- Género para formar grupos en los eventos (mezclar hombres y mujeres, o separarlos).
-- Se toma de la columna Género/Sexo/Gender al cargar la base: 'H' hombre, 'M' mujer, '' sin dato.
-- Quien no tiene el dato en la base se deduce por el nombre en el celular; ese cálculo no se guarda aquí.

alter table public.personas add column if not exists genero text not null default '' check (genero in ('', 'H', 'M'));
alter table public.evento_base add column if not exists genero text not null default '' check (genero in ('', 'H', 'M'));

-- ---------- Cargar la base del Programa Ica (ahora con género) ----------
-- Un archivo sin columna de género no borra el género que ya estaba guardado.
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
      case when f.programa in ('S', 'I') then f.programa else '' end as programa,
      case when f.genero in ('H', 'M') then f.genero else '' end as genero,
      public.norm_nombre(f.nombre) as clave
    from jsonb_to_recordset(filas) as f(nombre text, estaca text, barrio text, programa text, genero text)
    where trim(coalesce(f.nombre, '')) <> '';
  update public.personas p
  set estaca = e.estaca, barrio = e.barrio, programa = coalesce(nullif(e.programa, ''), p.programa), genero = coalesce(nullif(e.genero, ''), p.genero)
  from entrada e
  where p.clave = e.clave and (p.estaca, p.barrio, p.programa, p.genero) is distinct from
    (e.estaca, e.barrio, coalesce(nullif(e.programa, ''), p.programa), coalesce(nullif(e.genero, ''), p.genero));
  insert into public.personas (nombre, estaca, barrio, programa, genero)
  select e.nombre, e.estaca, e.barrio, e.programa, e.genero
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

-- ---------- Base propia de un evento (ahora con género, campo "x") ----------
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
  insert into public.evento_base (evento_id, nombre, estaca, barrio, programa, genero)
  select evento, left(trim(f ->> 'n'), 120), left(trim(coalesce(f ->> 'k', '')), 80), left(trim(coalesce(f ->> 'w', '')), 80),
    case when f ->> 'g' in ('S', 'I') then f ->> 'g' else '' end,
    case when f ->> 'x' in ('H', 'M') then f ->> 'x' else '' end
  from jsonb_array_elements(coalesce(filas, '[]'::jsonb)) f
  where coalesce(trim(f ->> 'n'), '') <> '';
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ---------- Género de los asistentes de un evento ----------
-- Devuelve solo id de la fila y género, para quien usa el evento. Busca en la base propia del
-- evento si la tiene; si no, en la del Programa Ica (por persona vinculada o por nombre).
create or replace function public.generos_evento(evento uuid)
returns table (id text, genero text)
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
    select a.id_cliente, max(b.genero)
    from public.evento_asistentes a
    join public.evento_base b on b.evento_id = a.evento_id and b.clave = a.clave and b.genero <> ''
    where a.evento_id = evento and a.borrado_en is null
    group by a.id_cliente;
    return;
  end if;
  return query
  select a.id_cliente, coalesce(max(p1.genero), max(p2.genero))
  from public.evento_asistentes a
  left join public.personas p1 on p1.id = a.persona_id and p1.genero <> ''
  left join public.personas p2 on a.persona_id is null and p2.clave = a.clave and p2.genero <> ''
  where a.evento_id = evento and a.borrado_en is null
  group by a.id_cliente
  having coalesce(max(p1.genero), max(p2.genero)) is not null;
end;
$$;

revoke execute on function public.generos_evento(uuid) from public, anon;
grant execute on function public.generos_evento(uuid) to authenticated;
