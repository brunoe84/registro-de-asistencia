-- solicitar_acceso fallaba siempre con "column reference nombres is ambiguous": sus parámetros
-- (nombres, apellidos, barrio, estaca, programa) se llaman igual que columnas de solicitudes_acceso.
-- #variable_conflict use_variable hace que esos nombres sin tabla sean siempre los parámetros.
-- Además, reconocer al mismo maestro es más flexible: no hay contraseñas, basta identificarse.

-- ¿Alguna palabra escrita (3+ letras) se parece a una palabra del nombre? Igual, inicio de palabra
-- o con un error de tipeo (dos si es larga).
create or replace function public.palabra_parecida(clave text, texto text)
returns boolean
language sql
immutable
as $$
  select exists (
    select 1
    from unnest(string_to_array(public.norm_nombre(replace(coalesce(texto, ''), ',', ' ')), ' ')) as t,
      unnest(string_to_array(replace(coalesce(clave, ''), ',', ' '), ' ')) as w
    where length(t) >= 3 and length(w) >= 3 and t not in ('del', 'las', 'los')
      and (w = t or w like t || '%' or t like w || '%'
        or (length(t) >= 4 and extensions.levenshtein(t, w) <= case when length(t) >= 7 then 2 else 1 end))
  );
$$;

-- Es el mismo maestro si alguno de sus apellidos coincide con el maestro de la clase
-- ("Apellidos, Nombres") o con el nombre de quien ya la usa como maestro. Da igual en qué
-- casilla lo escriba.
create or replace function public.es_mismo_maestro(clase uuid, nombres text, apellidos text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from (
      select split_part(c.maestro_nombre, ',', 1) as n from public.clases c where c.id = clase
      union all
      select p.nombre from public.clase_accesos a join public.perfiles p on p.id = a.usuario_id
      where a.clase_id = clase and a.tipo in ('titular', 'dispositivo') and p.nombre <> ''
    ) x
    where public.palabra_parecida(public.norm_nombre(x.n), coalesce(nombres, '') || ' ' || coalesce(apellidos, ''))
  );
$$;
revoke execute on function public.es_mismo_maestro(uuid, text, text) from public, anon, authenticated;

create or replace function public.solicitar_acceso(clase uuid, nombres text, apellidos text, barrio text, estaca text, programa text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  mismo boolean;
  aprobado_antes boolean;
  entra boolean;
begin
  if auth.uid() is null then
    raise exception 'Sin sesión';
  end if;
  if trim(coalesce(nombres, '')) = '' or trim(coalesce(apellidos, '')) = '' then
    raise exception 'Faltan nombres o apellidos';
  end if;
  if public.tiene_acceso(clase) then
    return 'ya_tuya';
  end if;
  mismo := public.es_mismo_maestro(clase, nombres, apellidos);
  -- El administrador ya aprobó antes a esta persona (con este nombre) para esta clase:
  -- vuelve a entrar desde otro dispositivo o navegador sin esperar otra aprobación.
  aprobado_antes := not mismo and exists (
    select 1 from public.solicitudes_acceso s
    where s.clase_id = clase and s.estado = 'aprobada'
      and public.palabra_parecida(public.norm_nombre(s.apellidos), coalesce(nombres, '') || ' ' || coalesce(apellidos, ''))
  );
  entra := mismo or aprobado_antes;
  if entra then
    perform public.dar_acceso(clase, auth.uid(), case when mismo then 'dispositivo' else 'colaborador' end, null);
    update public.solicitudes_acceso s set estado = 'aprobada', resuelto_en = now()
    where s.clase_id = clase and s.usuario_id = auth.uid() and s.estado = 'pendiente';
  end if;
  insert into public.solicitudes_acceso (clase_id, usuario_id, nombres, apellidos, barrio, estaca, programa, estado, resuelto_en)
  values (clase, auth.uid(), trim(nombres), trim(apellidos), trim(coalesce(barrio, '')), coalesce(estaca, ''),
    case when programa in ('S', 'I') then programa else 'S' end,
    case when entra then 'aprobada' else 'pendiente' end, case when entra then now() end)
  on conflict do nothing;
  update public.perfiles p set nombre = left(trim(nombres || ' ' || apellidos), 80) where p.id = auth.uid() and p.nombre = '';
  return case when mismo then 'acceso' when aprobado_antes then 'acceso_colaborador' else 'pendiente' end;
end;
$$;

notify pgrst, 'reload schema';
