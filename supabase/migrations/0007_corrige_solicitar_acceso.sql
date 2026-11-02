-- solicitar_acceso fallaba siempre con "column reference nombres is ambiguous": sus parámetros
-- (nombres, apellidos, barrio, estaca, programa) se llaman igual que columnas de solicitudes_acceso.
-- #variable_conflict use_variable hace que esos nombres sin tabla sean siempre los parámetros.
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
      and public.alguna_palabra(public.norm_nombre(s.nombres), nombres)
      and public.alguna_palabra(public.norm_nombre(s.apellidos), apellidos)
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
