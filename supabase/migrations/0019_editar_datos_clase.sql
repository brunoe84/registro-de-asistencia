-- Editar los datos de una clase en línea: título, curso, horario, maestro, programa,
-- estaca, barrio, días y fechas de inicio y fin.
-- Pueden hacerlo el administrador y el maestro que adoptó la clase (titular, o el mismo
-- maestro en otro dispositivo). Los colaboradores no.

create or replace function public.puede_editar_clase(clase uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.es_admin() or exists (
    select 1 from public.clase_accesos
    where clase_id = clase and usuario_id = auth.uid()
      and tipo in ('titular', 'dispositivo')
      and (vence_en is null or vence_en > now())
  );
$$;
revoke execute on function public.puede_editar_clase(uuid) from public, anon;
grant execute on function public.puede_editar_clase(uuid) to authenticated;

create or replace function public.editar_datos_clase(clase uuid, datos jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  v_titulo text := left(trim(coalesce(datos ->> 'titulo', '')), 80);
  v_maestro text := left(trim(coalesce(datos ->> 'maestro', '')), 60);
  v_curso text := left(trim(coalesce(datos ->> 'curso', '')), 80);
  v_horario text := left(trim(coalesce(datos ->> 'horario', '')), 40);
  v_programa text := coalesce(datos ->> 'programa', '');
  v_estaca text := trim(coalesce(datos ->> 'estaca', ''));
  v_barrio text := left(trim(coalesce(datos ->> 'barrio', '')), 80);
  v_dias smallint[];
  v_inicio date := nullif(datos ->> 'inicio', '')::date;
  v_fin date := nullif(datos ->> 'fin', '')::date;
begin
  if not public.puede_editar_clase(clase) then
    raise exception 'Solo el maestro de la clase o el administrador pueden editar sus datos';
  end if;
  if v_titulo = '' then raise exception 'Escribe el título de la clase'; end if;
  if v_maestro = '' then raise exception 'Escribe el nombre del maestro'; end if;
  if v_programa not in ('S', 'I') then raise exception 'Programa no válido'; end if;
  if v_estaca = '' then raise exception 'Elige la estaca'; end if;

  select coalesce(array_agg(distinct d::smallint order by d::smallint), '{}')
    into v_dias
  from jsonb_array_elements_text(coalesce(datos -> 'dias', '[]'::jsonb)) as d
  where d ~ '^[0-6]$';
  if cardinality(v_dias) = 0 then raise exception 'Elige al menos un día de clase'; end if;
  if v_inicio is not null and v_fin is not null and v_fin < v_inicio then
    raise exception 'La fecha de fin no puede ser antes del inicio';
  end if;

  begin
    update public.clases c
    set titulo = v_titulo,
        maestro_nombre = v_maestro,
        curso = v_curso,
        horario = v_horario,
        programa = v_programa,
        estaca = v_estaca,
        barrio = v_barrio,
        dias = v_dias,
        inicio = coalesce(v_inicio, c.inicio),
        fin = coalesce(v_fin, c.fin)
    where c.id = clase;
  exception when unique_violation then
    raise exception 'Ya existe otra clase con el mismo maestro, programa, estaca, horario y curso';
  end;
end;
$$;
revoke execute on function public.editar_datos_clase(uuid, jsonb) from public, anon;
grant execute on function public.editar_datos_clase(uuid, jsonb) to authenticated;
