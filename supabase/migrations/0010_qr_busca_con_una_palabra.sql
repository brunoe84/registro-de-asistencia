-- En el celular, quien escribía solo su nombre ("Karen") no veía a nadie, porque se exigían
-- nombre y apellido. Ahora basta una palabra de 3 letras o más; con más palabras se afina.
-- Primero salen los del barrio y la estaca del evento.
create or replace function public.buscar_en_qr(token text, texto text)
returns table (id uuid, nombre text, barrio text, estaca text, registrado boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  e public.eventos%rowtype;
begin
  select * into e from public.evento_de_qr(token);
  if e.id is null then
    raise exception 'El QR no está activo';
  end if;
  if not exists (select 1 from unnest(string_to_array(public.norm_nombre(replace(texto, ',', ' ')), ' ')) t
      where length(t) >= 3 and t not in ('del', 'las', 'los')) then
    return;
  end if;
  return query
  select r.id, r.nombre, r.barrio, r.estaca,
    exists (select 1 from public.evento_asistentes a where a.evento_id = e.id and a.persona_id = r.id and a.borrado_en is null)
  from (
    select p.id, p.nombre, p.barrio, p.estaca, public.puntaje_nombre(p.clave, texto) as puntos
    from public.personas p
  ) r
  where r.puntos is not null
  order by (e.barrio <> '' and r.barrio = e.barrio) desc,
    (public.norm_nombre(r.estaca) = public.norm_nombre(e.estaca)) desc,
    r.puntos desc, r.nombre
  limit 15;
end;
$$;

notify pgrst, 'reload schema';
