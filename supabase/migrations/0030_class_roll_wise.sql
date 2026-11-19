-- Class Roll de Wise2 dentro de la app.
-- El administrador lee los Excel diarios (carpeta "DEL DÍA") y se guardan aquí, una fila por clase de Wise.
-- NO reemplaza la asistencia de la app: se muestra al lado (colores suaves) para comparar.
-- Cada clase de Wise se vincula con una clase de la app (automático o a mano); las que no tienen
-- pareja aparecen en una lista para crearlas.

create table if not exists public.wise_clases (
  clave text primary key,                       -- programa|estaca|maestro|horario|curso (normalizados)
  programa text not null check (programa in ('S', 'I')),
  estaca text not null default '',
  maestro text not null default '',
  horario text not null default '',
  curso text not null default '',
  titulo text not null default '',
  unidad text not null default '',
  periodo text not null default '',
  total integer,
  fechas date[] not null default '{}',
  alumnos jsonb not null default '[]',          -- [{ n:"Apellidos, Nombres", m:{ "2026-10-19":"P" | "F" | ... } }]
  archivo text not null default '',
  archivo_en timestamptz,                       -- fecha del Excel leído
  actualizado_en timestamptz not null default now(),
  clase_id uuid references public.clases(id) on delete set null,
  vinculo text not null default '' check (vinculo in ('', 'auto', 'manual', 'creada')),
  ignorada boolean not null default false
);
create unique index if not exists wise_clases_clase_uq on public.wise_clases (clase_id) where clase_id is not null;
alter table public.wise_clases enable row level security;
revoke all on public.wise_clases from public, anon, authenticated;

-- Administrador: guarda (o actualiza) las clases leídas del Class Roll. No toca el vínculo ni "ignorada".
create or replace function public.cargar_class_roll(filas jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare n integer;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  insert into public.wise_clases as w (clave, programa, estaca, maestro, horario, curso, titulo, unidad, periodo, total, fechas, alumnos, archivo, archivo_en, actualizado_en)
  select f ->> 'clave', f ->> 'programa', coalesce(f ->> 'estaca', ''), coalesce(f ->> 'maestro', ''), coalesce(f ->> 'horario', ''),
         coalesce(f ->> 'curso', ''), coalesce(f ->> 'titulo', ''), coalesce(f ->> 'unidad', ''), coalesce(f ->> 'periodo', ''),
         nullif(f ->> 'total', '')::integer,
         coalesce(array(select jsonb_array_elements_text(f -> 'fechas'))::date[], '{}'),
         coalesce(f -> 'alumnos', '[]'::jsonb),
         coalesce(f ->> 'archivo', ''), nullif(f ->> 'archivo_en', '')::timestamptz, now()
  from jsonb_array_elements(filas) f
  where coalesce(f ->> 'clave', '') <> ''
  on conflict (clave) do update set
    programa = excluded.programa, estaca = excluded.estaca, maestro = excluded.maestro, horario = excluded.horario,
    curso = excluded.curso, titulo = excluded.titulo, unidad = excluded.unidad, periodo = excluded.periodo,
    total = excluded.total, fechas = excluded.fechas, alumnos = excluded.alumnos,
    archivo = excluded.archivo, archivo_en = excluded.archivo_en, actualizado_en = now();
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Administrador: todas las clases de Wise guardadas (con su vínculo).
create or replace function public.wise_clases_admin()
returns table (clave text, programa text, estaca text, maestro text, horario text, curso text, titulo text, unidad text, periodo text,
  total integer, fechas date[], alumnos jsonb, archivo text, archivo_en timestamptz, actualizado_en timestamptz,
  clase_id uuid, vinculo text, ignorada boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  return query
    select w.clave, w.programa, w.estaca, w.maestro, w.horario, w.curso, w.titulo, w.unidad, w.periodo, w.total, w.fechas, w.alumnos,
           w.archivo, w.archivo_en, w.actualizado_en, w.clase_id, w.vinculo, w.ignorada
    from public.wise_clases w
    order by w.programa, w.estaca, w.maestro, w.horario;
end;
$$;

-- Administrador: vincula una clase de Wise con una clase de la app (clase = null la desvincula),
-- o la marca como ignorada. Una clase de la app solo puede tener una clase de Wise.
create or replace function public.vincular_wise_clase(wise text, clase uuid, modo text default 'manual', ignorar boolean default false)
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
  if clase is not null then
    update public.wise_clases w set clase_id = null, vinculo = '' where w.clase_id = clase and w.clave <> wise;
  end if;
  update public.wise_clases w
     set clase_id = clase,
         vinculo = case when clase is null then '' else coalesce(nullif(modo, ''), 'manual') end,
         ignorada = coalesce(ignorar, false)
   where w.clave = wise;
end;
$$;

-- Maestro o administrador: lo que dice Wise de su clase (para mostrarlo al lado de la asistencia de la app).
create or replace function public.wise_de_clase(clase uuid)
returns table (clave text, fechas date[], alumnos jsonb, archivo_en timestamptz, actualizado_en timestamptz)
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
    select w.clave, w.fechas, w.alumnos, w.archivo_en, w.actualizado_en
    from public.wise_clases w
    where w.clase_id = clase
    limit 1;
end;
$$;

revoke execute on function public.cargar_class_roll(jsonb) from public, anon;
revoke execute on function public.wise_clases_admin() from public, anon;
revoke execute on function public.vincular_wise_clase(text, uuid, text, boolean) from public, anon;
revoke execute on function public.wise_de_clase(uuid) from public, anon;
grant execute on function public.cargar_class_roll(jsonb) to authenticated;
grant execute on function public.wise_clases_admin() to authenticated;
grant execute on function public.vincular_wise_clase(text, uuid, text, boolean) to authenticated;
grant execute on function public.wise_de_clase(uuid) to authenticated;
