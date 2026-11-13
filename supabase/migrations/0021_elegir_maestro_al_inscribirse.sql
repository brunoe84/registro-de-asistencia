-- Al inscribirse con el enlace o QR general (Seminario o Instituto, sin clase), el joven puede
-- elegir a su maestro al final: escribe el nombre del maestro o, si no lo sabe, el de su barrio,
-- y queda en la lista de esa clase en ese momento. Es opcional ("Todavía no tengo maestro").
--
-- 1. inscribirme devuelve también el id de la inscripción (misma firma: los celulares con la
--    versión anterior siguen funcionando).
-- 2. buscar_clases_inscripcion(token, texto, estaca): clases activas del programa del enlace que
--    coinciden con el maestro o con el barrio (el de la clase o el de sus alumnos).
-- 3. unirme_a_clase_inscripcion(token, inscripcion, clase): agrega al joven a la lista de la clase.

-- ---------- 1. inscribirme devuelve el id ----------
create or replace function public.inscribirme(token text, persona uuid default null, nombres text default null, apellidos text default null, datos jsonb default '{}')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  prog text;
  p public.personas%rowtype;
  nom text;
  d jsonb;
  previa uuid;
  nueva uuid;
  acuerdo_ok text;
begin
  select e.programa into prog from public.enlaces_inscripcion e where e.token is not null and e.token = token;
  if prog is null then
    raise exception 'Este enlace de inscripción ya no está activo';
  end if;
  if persona is not null then
    select * into p from public.personas x where x.id = persona;
    if p.id is null then
      raise exception 'No encontramos a esa persona';
    end if;
    nom := p.nombre;
  else
    if coalesce(trim(nombres), '') = '' or coalesce(trim(apellidos), '') = '' then
      raise exception 'Escribe tus nombres y apellidos';
    end if;
    nom := left(initcap(trim(apellidos)) || ', ' || initcap(trim(nombres)), 120);
  end if;
  if coalesce(datos ->> 'nacimiento', '') = '' or coalesce(datos ->> 'celular', '') = '' then
    raise exception 'Escribe tu fecha de nacimiento y tu celular';
  end if;
  -- (En plpgsql un CASE dentro de la condición de un IF se confunde con su THEN.)
  acuerdo_ok := case when prog = 'S' then 'Seminario 2/19' else 'Instituto 2/19' end;
  if coalesce(datos ->> 'acuerdo', '') <> acuerdo_ok then
    raise exception 'Para inscribirte debes aceptar el acuerdo de inscripción';
  end if;
  if prog = 'S' and (coalesce(trim(datos ->> 'tutor'), '') = '' or coalesce(trim(datos ->> 'tutor_celular'), '') = '') then
    raise exception 'Escribe el nombre y el número de tu padre o madre';
  end if;
  d := public.datos_inscripcion(datos) || jsonb_build_object('acepto_en', now());
  select i.id into previa from public.inscripciones i
  where i.programa = prog and i.atendida_en is null
    and ((p.id is not null and i.persona_id = p.id) or (p.id is null and i.persona_id is null and public.norm_nombre(i.nombre) = public.norm_nombre(nom)))
  order by i.creado_en desc limit 1;
  if previa is not null then
    update public.inscripciones i set datos = i.datos || d, creado_en = now() where i.id = previa;
    nueva := previa;
  else
    insert into public.inscripciones (programa, origen, persona_id, nombre, datos)
    values (prog, 'enlace', p.id, nom, d)
    returning id into nueva;
  end if;
  return jsonb_build_object('estado', case when previa is null then 'inscrito' else 'actualizado' end, 'nombre', nom, 'programa', prog, 'id', nueva);
end;
$$;

-- ---------- 2. Buscar la clase por maestro o barrio ----------
-- Clases del programa del enlace que no terminaron hace más de 2 semanas.
-- coincide: 'maestro' si el texto coincide con su nombre; 'barrio' si coincide con el barrio de la
-- clase o el de sus alumnos. Primero las de la estaca del joven.
create or replace function public.buscar_clases_inscripcion(token text, texto text, estaca text default null)
returns table (id uuid, maestro text, curso text, horario text, estaca_clase text, barrio text, dias smallint[], alumnos integer, coincide text)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  prog text;
begin
  select e.programa into prog from public.enlaces_inscripcion e where e.token is not null and e.token = token;
  if prog is null then
    raise exception 'Este enlace de inscripción ya no está activo';
  end if;
  if not exists (select 1 from unnest(string_to_array(public.norm_nombre(replace(texto, ',', ' ')), ' ')) t where length(t) >= 3) then
    return;
  end if;
  return query
  select r.id, r.maestro_nombre, r.curso, r.horario, r.estaca, r.barrio_txt, r.dias, r.n_alumnos,
    case when r.p_maestro is not null then 'maestro' else 'barrio' end
  from (
    select c.id, c.maestro_nombre, c.curso, c.horario, c.estaca, c.dias,
      coalesce(nullif(c.barrio, ''), b.principal, '') as barrio_txt,
      coalesce(b.n, 0)::int as n_alumnos,
      public.puntaje_nombre(public.norm_nombre(c.maestro_nombre), texto) as p_maestro,
      public.puntaje_nombre('barrio rama ' || public.norm_nombre(c.barrio || ' ' || coalesce(b.todos, '')), texto) as p_barrio
    from public.clases c
    left join lateral (
      select count(*) as n,
        string_agg(distinct a.barrio, ' ') as todos,
        mode() within group (order by nullif(a.barrio, '')) as principal
      from public.clase_alumnos a
      where a.clase_id = c.id and a.retirado_en is null
    ) b on true
    where c.programa = prog
      and coalesce(c.maestro_nombre, '') <> ''
      and (c.fin is null or c.fin >= current_date - 14)
  ) r
  where r.p_maestro is not null or r.p_barrio is not null
  order by (r.p_maestro is not null) desc,
    (coalesce(estaca, '') <> '' and r.estaca = estaca) desc,
    coalesce(r.p_maestro, r.p_barrio) desc, r.maestro_nombre, r.horario
  limit 15;
end;
$$;

-- ---------- 3. Unirse a la clase elegida ----------
-- Solo para una inscripción de este enlace hecha en las últimas 24 horas (el id llega al
-- celular que la envió). Si el joven ya está en la lista (por persona o por nombre), se reactiva.
create or replace function public.unirme_a_clase_inscripcion(token text, inscripcion uuid, clase uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  prog text;
  i public.inscripciones%rowtype;
  c public.clases%rowtype;
  p public.personas%rowtype;
  al uuid;
  ya boolean := false;
begin
  select e.programa into prog from public.enlaces_inscripcion e where e.token is not null and e.token = token;
  if prog is null then
    raise exception 'Este enlace de inscripción ya no está activo';
  end if;
  select * into i from public.inscripciones x where x.id = inscripcion;
  if i.id is null or i.programa <> prog or i.creado_en < now() - interval '24 hours' then
    raise exception 'Vuelve a enviar tu inscripción para elegir a tu maestro';
  end if;
  select * into c from public.clases x where x.id = clase;
  if c.id is null or c.programa <> prog or (c.fin is not null and c.fin < current_date - 14) then
    raise exception 'Esa clase no está disponible';
  end if;
  if i.persona_id is not null then
    select * into p from public.personas x where x.id = i.persona_id;
  end if;

  select x.id, x.retirado_en is null into al, ya from public.clase_alumnos x
  where x.clase_id = c.id and ((p.id is not null and x.persona_id = p.id) or x.clave = public.norm_nombre(i.nombre))
  limit 1;
  if al is null then
    insert into public.clase_alumnos (clase_id, persona_id, nombre, estaca, barrio)
    values (c.id, p.id, i.nombre, coalesce(p.estaca, i.datos ->> 'estaca', ''), coalesce(p.barrio, i.datos ->> 'barrio', ''))
    on conflict do nothing
    returning id into al;
    if al is null then -- carrera: otro registro lo agregó al mismo tiempo
      select x.id into al from public.clase_alumnos x
      where x.clase_id = c.id and ((p.id is not null and x.persona_id = p.id) or x.clave = public.norm_nombre(i.nombre))
      limit 1;
    end if;
  else
    update public.clase_alumnos x set retirado_en = null where x.id = al;
  end if;
  update public.inscripciones x set clase_id = c.id, alumno_id = al where x.id = i.id;

  return jsonb_build_object('estado', case when ya then 'ya_estaba' else 'unido' end,
    'maestro', c.maestro_nombre, 'curso', c.curso, 'horario', c.horario, 'dias', c.dias);
end;
$$;

revoke execute on function public.buscar_clases_inscripcion(text, text, text) from public;
revoke execute on function public.unirme_a_clase_inscripcion(text, uuid, uuid) from public;
-- El joven que abre el enlace no necesita sesión: ambas funciones exigen el token del enlace.
grant execute on function public.buscar_clases_inscripcion(text, text, text) to anon, authenticated;
grant execute on function public.unirme_a_clase_inscripcion(text, uuid, uuid) to anon, authenticated;

notify pgrst, 'reload schema';
