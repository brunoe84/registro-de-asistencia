-- Unir a una clase los alumnos y la asistencia de un evento (EV-…) o de otra clase (CL-…).
-- Sirve cuando un maestro creó un evento (u otra clase) por error en vez de marcar en su clase.
-- No duplica alumnos: se reconocen por la persona de la base o por el nombre (en cualquier orden).
-- No cambia marcas que ya existen en la clase. El evento o la clase de origen no se borran.
--
-- confirmar = false: solo calcula lo que pasaría (vista previa) y no guarda nada. La vista previa
--   trae 'fechas_origen' ({ "AAAA-MM-DD": cantidad de marcas }) para que la app pregunte qué hacer
--   con las fechas que no están en el calendario de la clase.
-- fechas: { "fecha del origen": "fecha de la clase" | "omitir" }. Las fechas que no aparecen se pasan
--   tal cual; si caen fuera del calendario quedan como fechas extra de la clase.

create or replace function public.unir_codigo_a_clase(clase uuid, codigo_origen text, confirmar boolean default false, fechas jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.clases%rowtype;
  v_cod text := upper(trim(coalesce(codigo_origen, '')));
  v_tipo text;
  v_titulo text := '';
  v_detalle text := '';
  v_origen_id uuid;
  v_fuente jsonb := '[]'::jsonb;
  v_fechas_origen jsonb;
  v_dest date;
  v_map text;
  al jsonb;
  m record;
  v_alumno uuid;
  v_retirado boolean;
  v_pid uuid;
  n_fuente integer := 0;
  n_nuevos integer := 0;
  n_ya integer := 0;
  n_reactivados integer := 0;
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
    return jsonb_build_object('estado', 'no_existe_clase');
  end if;
  if not public.puede_usar_clase(clase) then
    return jsonb_build_object('estado', 'sin_acceso');
  end if;

  -- ---------- Origen: evento ----------
  if v_cod like 'EV-%' then
    v_tipo := 'evento';
    select e.id, e.titulo, to_char(e.fecha, 'YYYY-MM-DD') into v_origen_id, v_titulo, v_detalle
    from public.eventos e where upper(e.codigo) = v_cod;
    if v_origen_id is null then
      return jsonb_build_object('estado', 'no_existe');
    end if;
    if not public.puede_usar_evento(v_origen_id) then
      return jsonb_build_object('estado', 'sin_acceso_origen', 'tipo', v_tipo);
    end if;
    -- Cada asistente confirmado del evento queda como "asistió" en la fecha del evento.
    select coalesce(jsonb_agg(jsonb_build_object(
      'nombre', a.nombre, 'pid', a.persona_id, 'estaca', a.estaca, 'barrio', a.barrio,
      'marcas', jsonb_build_object(to_char(e.fecha, 'YYYY-MM-DD'), 'P'))), '[]'::jsonb)
    into v_fuente
    from public.evento_asistentes a join public.eventos e on e.id = a.evento_id
    where a.evento_id = v_origen_id and a.borrado_en is null and a.estado = 'ok';

  -- ---------- Origen: otra clase ----------
  else
    v_tipo := 'clase';
    select x.id, x.titulo, x.maestro_nombre into v_origen_id, v_titulo, v_detalle
    from public.clases x where upper(x.codigo) = v_cod;
    if v_origen_id is null then
      return jsonb_build_object('estado', 'no_existe');
    end if;
    if v_origen_id = clase then
      return jsonb_build_object('estado', 'misma');
    end if;
    if not public.puede_usar_clase(v_origen_id) then
      return jsonb_build_object('estado', 'sin_acceso_origen', 'tipo', v_tipo);
    end if;
    select coalesce(jsonb_agg(jsonb_build_object(
      'nombre', a.nombre, 'pid', a.persona_id, 'estaca', a.estaca, 'barrio', a.barrio,
      'marcas', coalesce((select jsonb_object_agg(to_char(s.fecha, 'YYYY-MM-DD'), s.estado)
                          from public.asistencia s where s.alumno_id = a.id), '{}'::jsonb))), '[]'::jsonb)
    into v_fuente
    from public.clase_alumnos a
    where a.clase_id = v_origen_id and a.retirado_en is null;
  end if;

  select coalesce(jsonb_object_agg(t.f, t.n), '{}'::jsonb) into v_fechas_origen
  from (select k.key as f, count(*) as n
        from jsonb_array_elements(v_fuente) a, jsonb_each_text(coalesce(a -> 'marcas', '{}'::jsonb)) k
        where k.value in ('P', 'F', 'T', 'M') group by k.key) t;

  -- ---------- Unir (en un bloque: la vista previa se deshace al final) ----------
  begin
    for al in select * from jsonb_array_elements(v_fuente) loop
      continue when public.clave_orden(al ->> 'nombre') = '';
      n_fuente := n_fuente + 1;
      v_pid := nullif(al ->> 'pid', '')::uuid;
      v_alumno := null; v_retirado := false;

      -- 1) La misma persona de la base. 2) El mismo nombre, aunque esté en otro orden.
      if v_pid is not null then
        select x.id, x.retirado_en is not null into v_alumno, v_retirado
        from public.clase_alumnos x where x.clase_id = clase and x.persona_id = v_pid limit 1;
      end if;
      if v_alumno is null then
        select x.id, x.retirado_en is not null into v_alumno, v_retirado
        from public.clase_alumnos x
        where x.clase_id = clase and public.clave_orden(x.nombre) = public.clave_orden(al ->> 'nombre')
        order by (x.retirado_en is null) desc
        limit 1;
      end if;

      if v_alumno is not null then
        if v_retirado then
          update public.clase_alumnos set retirado_en = null where id = v_alumno;
          n_reactivados := n_reactivados + 1;
        else
          n_ya := n_ya + 1;
        end if;
        -- Si el alumno no tenía persona de la base y el origen sí, se vincula.
        if v_pid is not null then
          update public.clase_alumnos x set persona_id = v_pid
          where x.id = v_alumno and x.persona_id is null
            and not exists (select 1 from public.clase_alumnos y where y.clase_id = clase and y.persona_id = v_pid);
        end if;
      else
        insert into public.clase_alumnos (clase_id, nombre, estaca, barrio, persona_id, origen, vinculo)
        values (clase, trim(al ->> 'nombre'), coalesce(al ->> 'estaca', ''), coalesce(al ->> 'barrio', ''), v_pid,
                'maestro', case when v_pid is not null then 'vinculado' else 'pendiente' end)
        on conflict do nothing
        returning id into v_alumno;
        if v_alumno is null then
          select x.id into v_alumno from public.clase_alumnos x
          where x.clase_id = clase and (x.clave = public.norm_nombre(al ->> 'nombre') or (v_pid is not null and x.persona_id = v_pid))
          limit 1;
          n_ya := n_ya + 1;
        else
          n_nuevos := n_nuevos + 1;
        end if;
      end if;
      continue when v_alumno is null;

      for m in select key as f_txt, value as estado from jsonb_each_text(coalesce(al -> 'marcas', '{}'::jsonb)) where value in ('P', 'F', 'T', 'M') loop
        -- Fecha elegida en la app para alinear con la clase (o "omitir" para no pasarla).
        v_map := coalesce(fechas, '{}'::jsonb) ->> m.f_txt;
        continue when v_map = 'omitir';
        v_dest := coalesce(nullif(v_map, '')::date, m.f_txt::date);
        insert into public.asistencia (clase_id, alumno_id, fecha, estado)
        values (clase, v_alumno, v_dest, m.estado)
        on conflict (alumno_id, fecha) do nothing;
        get diagnostics filas = row_count;
        if filas = 1 then
          n_marcas := n_marcas + 1;
          -- Fechas fuera del calendario de la clase se agregan como fechas extra para que se vean.
          if not (
            extract(dow from v_dest)::smallint = any (c.dias)
            and (c.inicio is null or v_dest >= c.inicio)
            and (c.fin is null or v_dest <= c.fin)
          ) and not (v_dest = any (c.fechas_extra)) and not (v_dest = any (extra)) then
            extra := extra || v_dest;
          end if;
        elsif exists (select 1 from public.asistencia z where z.alumno_id = v_alumno and z.fecha = v_dest and z.estado <> m.estado) then
          n_distintas := n_distintas + 1;
        end if;
      end loop;
    end loop;

    if array_length(extra, 1) > 0 then
      update public.clases set fechas_extra = (select array_agg(distinct d order by d) from unnest(fechas_extra || extra) d) where id = clase;
    end if;

    if not confirmar then
      raise exception using errcode = 'P0001', message = 'vista_previa';
    end if;
  exception when raise_exception then
    if sqlerrm <> 'vista_previa' then
      raise;
    end if;
  end;

  return jsonb_build_object(
    'estado', case when confirmar then 'unida' else 'vista' end,
    'codigo', c.codigo, 'tipo', v_tipo, 'titulo', v_titulo, 'detalle', v_detalle,
    'origen', n_fuente, 'alumnos', n_nuevos, 'ya_estaban', n_ya, 'reactivados', n_reactivados,
    'marcas', n_marcas, 'distintas', n_distintas, 'fechas_extra', coalesce(array_length(extra, 1), 0),
    'fechas_origen', v_fechas_origen);
end;
$$;

revoke execute on function public.unir_codigo_a_clase(uuid, text, boolean, jsonb) from public, anon;
grant execute on function public.unir_codigo_a_clase(uuid, text, boolean, jsonb) to authenticated;

notify pgrst, 'reload schema';
