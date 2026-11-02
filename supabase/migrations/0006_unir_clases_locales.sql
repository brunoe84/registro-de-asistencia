-- Clases creadas en un dispositivo antes de la base en línea: encontrar su clase en línea
-- (por alumnos, maestro y curso) y unir sus alumnos y asistencia sin pisar lo que ya hay.

-- El nombre con sus palabras ordenadas: "Pérez García, Juan" y "Juan Pérez García" dan lo mismo.
create function public.clave_orden(texto text)
returns text
language sql
immutable
as $$
  select array_to_string(array(
    select w from unnest(string_to_array(replace(public.norm_nombre(texto), ',', ''), ' ')) as w
    where w <> '' order by w
  ), ' ');
$$;

-- Todas las palabras escritas (al menos dos) coinciden con el nombre, sin tolerar errores.
create function public.nombre_completo_coincide(nombre text, texto text)
returns boolean
language sql
immutable
as $$
  select public.puntaje_nombre(public.norm_nombre(nombre), texto, false) is not null
    and (select count(*) from unnest(string_to_array(public.norm_nombre(replace(texto, ',', ' ')), ' ')) t
         where t <> '' and t not in ('de', 'del', 'la', 'las', 'los', 'y', 'e')) >= 2;
$$;

-- datos: { maestro, titulo, programa, estaca, alumnos: ["nombre", ...] }
create function public.sugerir_clase_local(datos jsonb)
returns table (id uuid, maestro text, programa text, estaca text, horario text, curso text, alumnos bigint, coincidentes bigint, puntos integer, adoptada boolean, tengo_acceso boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Sin sesión';
  end if;
  return query
  with locales as (
    select distinct public.clave_orden(n) as k
    from jsonb_array_elements_text(coalesce(datos -> 'alumnos', '[]'::jsonb)) as n
    where public.clave_orden(n) <> ''
  ), n_local as (
    select count(*) as n from locales
  ), base as (
    select c.id, c.maestro_nombre, c.programa, c.estaca, c.horario, c.curso,
      (select count(*) from public.clase_alumnos x where x.clase_id = c.id and x.retirado_en is null) as total,
      (select count(distinct l.k) from public.clase_alumnos x join locales l on l.k = public.clave_orden(x.nombre)
        where x.clase_id = c.id) as comunes,
      case
        when public.nombre_completo_coincide(c.maestro_nombre, coalesce(datos ->> 'maestro', '')) then 40
        when public.alguna_palabra(public.norm_nombre(c.maestro_nombre), coalesce(datos ->> 'maestro', '')) then 15
        else 0 end as p_maestro,
      case when public.puntaje_nombre(public.norm_nombre(c.curso || ' ' || c.titulo), coalesce(datos ->> 'titulo', '')) is not null then 15 else 0 end as p_curso,
      (case when c.programa = datos ->> 'programa' then 5 else 0 end) + (case when c.estaca = datos ->> 'estaca' then 5 else 0 end) as p_otros
    from public.clases c
  )
  select b.id, b.maestro_nombre, b.programa, b.estaca, b.horario, b.curso, b.total, b.comunes,
    (b.p_maestro + b.p_curso + b.p_otros + round(60.0 * b.comunes / greatest(1, least((select n from n_local), b.total))))::int as pts,
    exists (select 1 from public.clase_accesos a where a.clase_id = b.id and a.tipo = 'titular'),
    public.tiene_acceso(b.id)
  from base b
  where b.comunes >= 2 or b.p_maestro = 40
  order by pts desc, b.comunes desc
  limit 3;
end;
$$;

-- datos: { maestro, alumnos: [{ nombre, estaca, barrio, marcas: { "2026-10-01": "P", ... } }] }
-- Da acceso si la clase está libre o si es el mismo maestro. Luego agrega los alumnos que faltan
-- y las marcas de fechas sin marcar; las marcas que ya existen en línea no se cambian.
create function public.unir_clase_local(clase uuid, datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.clases%rowtype;
  al jsonb;
  m record;
  alumno uuid;
  n_alumnos integer := 0;
  n_marcas integer := 0;
  n_distintas integer := 0;
  filas integer;
  extra date[] := '{}';
begin
  if auth.uid() is null then
    raise exception 'Sin sesión';
  end if;
  select * into c from public.clases x where x.id = clase;
  if c.id is null then
    return jsonb_build_object('estado', 'no_existe');
  end if;

  if not public.puede_usar_clase(clase) then
    if public.dar_acceso(clase, auth.uid(), 'titular', null) then
      null;
    elsif exists (
      select 1 from (
        select c.maestro_nombre as n
        union all
        select p.nombre from public.clase_accesos a join public.perfiles p on p.id = a.usuario_id
        where a.clase_id = clase and a.tipo in ('titular', 'dispositivo')
      ) x
      where public.nombre_completo_coincide(x.n, coalesce(datos ->> 'maestro', ''))
    ) then
      perform public.dar_acceso(clase, auth.uid(), 'dispositivo', null);
    else
      return jsonb_build_object('estado', 'sin_acceso');
    end if;
  end if;

  for al in select * from jsonb_array_elements(coalesce(datos -> 'alumnos', '[]'::jsonb)) loop
    continue when public.clave_orden(al ->> 'nombre') = '';
    select x.id into alumno
    from public.clase_alumnos x
    where x.clase_id = clase and public.clave_orden(x.nombre) = public.clave_orden(al ->> 'nombre')
    order by (x.retirado_en is null) desc
    limit 1;
    if alumno is null then
      insert into public.clase_alumnos (clase_id, nombre, estaca, barrio)
      values (clase, trim(al ->> 'nombre'), coalesce(al ->> 'estaca', ''), coalesce(al ->> 'barrio', ''))
      on conflict on constraint clase_alumnos_clave do nothing
      returning id into alumno;
      if alumno is null then
        select x.id into alumno from public.clase_alumnos x where x.clase_id = clase and x.clave = public.norm_nombre(al ->> 'nombre');
      else
        n_alumnos := n_alumnos + 1;
      end if;
    end if;
    continue when alumno is null;

    for m in select key::date as fecha, value as estado from jsonb_each_text(coalesce(al -> 'marcas', '{}'::jsonb)) where value in ('P', 'F', 'T', 'M') loop
      insert into public.asistencia (clase_id, alumno_id, fecha, estado)
      values (clase, alumno, m.fecha, m.estado)
      on conflict (alumno_id, fecha) do nothing;
      get diagnostics filas = row_count;
      if filas = 1 then
        n_marcas := n_marcas + 1;
        -- Fechas que no caen en el calendario de la clase se agregan como fechas extra para que se vean.
        if not (
          extract(dow from m.fecha)::smallint = any (c.dias)
          and (c.inicio is null or m.fecha >= c.inicio)
          and (c.fin is null or m.fecha <= c.fin)
        ) and not (m.fecha = any (c.fechas_extra)) and not (m.fecha = any (extra)) then
          extra := extra || m.fecha;
        end if;
      elsif exists (select 1 from public.asistencia z where z.alumno_id = alumno and z.fecha = m.fecha and z.estado <> m.estado) then
        n_distintas := n_distintas + 1;
      end if;
    end loop;
    alumno := null;
  end loop;

  if array_length(extra, 1) > 0 then
    update public.clases set fechas_extra = (select array_agg(distinct d order by d) from unnest(fechas_extra || extra) d) where id = clase;
  end if;

  return jsonb_build_object('estado', 'unida', 'codigo', c.codigo, 'alumnos', n_alumnos, 'marcas', n_marcas, 'distintas', n_distintas);
end;
$$;

revoke execute on function public.sugerir_clase_local(jsonb) from public, anon;
revoke execute on function public.unir_clase_local(uuid, jsonb) from public, anon;
grant execute on function public.sugerir_clase_local(jsonb) to authenticated;
grant execute on function public.unir_clase_local(uuid, jsonb) to authenticated;

notify pgrst, 'reload schema';
