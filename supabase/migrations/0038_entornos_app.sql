-- Entornos (fase 3): la app usa las estacas y los periodos de cada entorno.
-- Requiere 0036 y 0037 aplicadas antes.
--
-- * Nombres de estaca: "Ica", "Ica Peru Stake" e "Ica Perú Stake" son la misma estaca. Se comparan por
--   su núcleo (sin tildes ni las palabras Perú, Stake, District, Distrito, Estaca) y, al guardar las
--   estacas de un entorno, se usa el nombre completo que ya existe en el sistema.
-- * entornos_publicos(): estacas, periodos y feriados de los entornos activos. Lo usan los maestros y
--   los jóvenes (sin sesión de administrador) para ver las estacas y el calendario de su programa.
--   No trae contactos, correos ni nada sensible.
-- * guardar_ajustes_entorno(): el administrador guarda los periodos y feriados de su entorno.
-- * inscripcion_por_enlace(): además dice de qué entorno es el enlace.

begin;

-- ---------- 1. Núcleo y nombre completo de una estaca ----------
create or replace function public.nucleo_estaca(t text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select btrim(regexp_replace(regexp_replace(regexp_replace(
           translate(lower(coalesce(t, '')), 'áéíóúüñàèìòùâêîôû', 'aeiouunaeiouaeiou'),
           '\mnasca\M', 'nazca', 'g'),
           '\m(peru|stake|district|distrito|estaca)\M', ' ', 'g'),
           '[^a-z0-9]+', ' ', 'g'));
$$;

alter table public.entorno_estacas add column if not exists nucleo text generated always as (public.nucleo_estaca(estaca)) stored;
create index if not exists entorno_estacas_nucleo on public.entorno_estacas (nucleo, programa);

-- Nombre con que se guarda una estaca escrita a mano: el más completo que ya exista con el mismo
-- núcleo (en los entornos, las clases o el Class Roll); si es nueva, tal como se escribió.
create or replace function public.estaca_canonica(t text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  with n as (select public.nucleo_estaca(t) as v)
  select case when (select v from n) = '' then null else coalesce(
    (select s.estaca from public.entorno_estacas s, n where s.nucleo = n.v order by length(s.estaca) desc, s.estaca limit 1),
    (select c.estaca from (select distinct x.estaca from public.clases x where coalesce(x.estaca, '') <> '') c, n
      where public.nucleo_estaca(c.estaca) = n.v order by length(c.estaca) desc, c.estaca limit 1),
    (select w.estaca from (select distinct x.estaca from public.wise_clases x where coalesce(x.estaca, '') <> '') w, n
      where public.nucleo_estaca(w.estaca) = n.v order by length(w.estaca) desc, w.estaca limit 1),
    left(btrim(regexp_replace(coalesce(t, ''), '\s+', ' ', 'g')), 80)) end;
$$;

-- Lo que ya se guardó con nombre corto pasa al nombre completo (si existe).
update public.entorno_estacas s set estaca = public.estaca_canonica(s.estaca)
where public.estaca_canonica(s.estaca) is distinct from s.estaca
  and not exists (select 1 from public.entorno_estacas y
                  where y.entorno_id = s.entorno_id and y.programa = s.programa and y.estaca = public.estaca_canonica(s.estaca));

-- ---------- 2. Las comparaciones de estaca usan el núcleo ----------
create or replace function public.par_de(e uuid, estaca text, programa text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select e is not null and exists (
    select 1 from public.entorno_estacas x
    where x.entorno_id = e and x.nucleo = public.nucleo_estaca(par_de.estaca)
      and (coalesce(par_de.programa, '') = '' or x.programa = par_de.programa)
  );
$$;

create or replace function public.admin_ve(estaca text, programa text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.perfiles p
    where p.id = auth.uid() and p.rol = 'admin'
      and (p.general or exists (
        select 1 from public.entorno_admins a
        join public.entornos e on e.id = a.entorno_id and e.estado = 'activo'
        join public.entorno_estacas x on x.entorno_id = a.entorno_id
        where a.usuario_id = p.id and x.nucleo = public.nucleo_estaca(admin_ve.estaca)
          and (coalesce(admin_ve.programa, '') = '' or x.programa = admin_ve.programa)))
  );
$$;

create or replace function public.admin_ve_clase(clase uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.perfiles p join public.clases c on c.id = admin_ve_clase.clase
    where p.id = auth.uid() and p.rol = 'admin'
      and (p.general or exists (
        select 1 from public.entorno_admins a
        join public.entornos e on e.id = a.entorno_id and e.estado = 'activo'
        join public.entorno_estacas x on x.entorno_id = a.entorno_id
        where a.usuario_id = p.id and x.nucleo = public.nucleo_estaca(c.estaca) and x.programa = c.programa))
  );
$$;

create or replace function public.entorno_de_clase(clase uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select case when entorno_de_clase.clase is null then null else coalesce(
    (select x.entorno_id from public.clases c
      join public.entorno_estacas x on x.nucleo = public.nucleo_estaca(c.estaca) and x.programa = c.programa
      join public.entornos e on e.id = x.entorno_id and e.estado = 'activo'
      where c.id = entorno_de_clase.clase order by e.creado_en, e.id limit 1),
    public.entorno_por_defecto()) end;
$$;

-- ---------- 3. Al guardar las estacas de un entorno se usa el nombre completo ----------
create or replace function public.registrar_solicitud_entorno(p_usuario uuid, p_correo text, p_datos jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  e uuid;
  cel text := '[^0-9+]';
begin
  -- Una sola solicitud pendiente por cuenta: si ya hay una, se actualiza.
  select x.id into e from public.entornos x
  where x.solicitado_por = p_usuario and x.estado = 'pendiente'
  order by x.creado_en desc limit 1;
  if e is null then
    insert into public.entornos (programa, estado, solicitado_por, correo)
    values ('', 'pendiente', p_usuario, p_correo)
    returning id into e;
  end if;
  update public.entornos x set
    programa = left(btrim(coalesce(p_datos ->> 'programa', '')), 80),
    asistente_nombre = left(btrim(coalesce(p_datos ->> 'asistente_nombre', '')), 80),
    asistente_celular = left(regexp_replace(coalesce(p_datos ->> 'asistente_celular', ''), cel, '', 'g'), 16),
    coordinador_nombre = left(btrim(coalesce(p_datos ->> 'coordinador_nombre', '')), 80),
    coordinador_celular = left(regexp_replace(coalesce(p_datos ->> 'coordinador_celular', ''), cel, '', 'g'), 16),
    correo = p_correo
  where x.id = e;
  delete from public.entorno_estacas x where x.entorno_id = e;
  insert into public.entorno_estacas (entorno_id, estaca, programa)
  select distinct e, public.estaca_canonica(t ->> 'estaca'), p
  from jsonb_array_elements(case when jsonb_typeof(p_datos -> 'estacas') = 'array' then p_datos -> 'estacas' else '[]'::jsonb end) t
  cross join unnest(array['S', 'I']) p
  where public.estaca_canonica(t ->> 'estaca') is not null and coalesce(t ->> p, '') in ('true', 't', '1')
  on conflict do nothing;
  return e;
end;
$$;

create or replace function public.guardar_entorno(entorno uuid, datos jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  cel text := '[^0-9+]';
begin
  if not public.es_general() then
    raise exception 'Solo el administrador general' using errcode = '42501';
  end if;
  if not exists (select 1 from public.entornos e where e.id = entorno) then
    raise exception 'Ese entorno no existe';
  end if;
  update public.entornos e set
    programa = case when datos ? 'programa' and btrim(datos ->> 'programa') <> '' then left(btrim(datos ->> 'programa'), 80) else e.programa end,
    asistente_nombre = case when datos ? 'asistente_nombre' then left(btrim(coalesce(datos ->> 'asistente_nombre', '')), 80) else e.asistente_nombre end,
    asistente_celular = case when datos ? 'asistente_celular' then left(regexp_replace(coalesce(datos ->> 'asistente_celular', ''), cel, '', 'g'), 16) else e.asistente_celular end,
    coordinador_nombre = case when datos ? 'coordinador_nombre' then left(btrim(coalesce(datos ->> 'coordinador_nombre', '')), 80) else e.coordinador_nombre end,
    coordinador_celular = case when datos ? 'coordinador_celular' then left(regexp_replace(coalesce(datos ->> 'coordinador_celular', ''), cel, '', 'g'), 16) else e.coordinador_celular end
  where e.id = entorno;
  if jsonb_typeof(datos -> 'estacas') = 'array' then
    delete from public.entorno_estacas s where s.entorno_id = entorno;
    insert into public.entorno_estacas (entorno_id, estaca, programa)
    select distinct entorno, public.estaca_canonica(t ->> 'estaca'), p
    from jsonb_array_elements(datos -> 'estacas') t
    cross join unnest(array['S', 'I']) p
    where public.estaca_canonica(t ->> 'estaca') is not null and coalesce(t ->> p, '') in ('true', 't', '1')
    on conflict do nothing;
  end if;
end;
$$;

-- Clases de cada entorno (para la tarjeta del administrador general), comparando por núcleo.
create or replace function public.entornos_admin()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.es_general() then
    raise exception 'Solo el administrador general' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', x.id, 'programa', x.programa, 'estado', x.estado, 'correo', x.correo,
      'asistente_nombre', x.asistente_nombre, 'asistente_celular', x.asistente_celular,
      'coordinador_nombre', x.coordinador_nombre, 'coordinador_celular', x.coordinador_celular,
      'creado_en', x.creado_en, 'aprobado_en', x.aprobado_en,
      'principal', x.id = public.entorno_por_defecto(),
      'actual', x.id = public.entorno_actual(),
      'estacas', coalesce((select jsonb_agg(jsonb_build_object('estaca', s.estaca, 'programa', s.programa) order by s.estaca, s.programa)
                           from public.entorno_estacas s where s.entorno_id = x.id), '[]'::jsonb),
      'admins', coalesce((select jsonb_agg(jsonb_build_object('nombre', p.nombre, 'correo', coalesce(u.email, ''), 'general', p.general) order by a.creado_en)
                          from public.entorno_admins a
                          join public.perfiles p on p.id = a.usuario_id
                          left join auth.users u on u.id = a.usuario_id
                          where a.entorno_id = x.id), '[]'::jsonb),
      'clases', (select count(*) from public.clases c
                 where c.base = 'ica' and exists (select 1 from public.entorno_estacas s
                   where s.entorno_id = x.id and s.nucleo = public.nucleo_estaca(c.estaca) and s.programa = c.programa))
    ) order by (x.estado = 'pendiente') desc, x.creado_en)
    from public.entornos x), '[]'::jsonb);
end;
$$;

-- ---------- 4. Para la app ----------
create or replace function public.entornos_publicos()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', x.id, 'programa', x.programa, 'ajustes', x.ajustes,
    'estacas', coalesce((select jsonb_agg(jsonb_build_object('estaca', s.estaca, 'programa', s.programa) order by s.estaca, s.programa)
                         from public.entorno_estacas s where s.entorno_id = x.id), '[]'::jsonb)
  ) order by x.creado_en, x.id), '[]'::jsonb)
  from public.entornos x
  where x.estado = 'activo';
$$;

create or replace function public.guardar_ajustes_entorno(ajustes jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  ent uuid := public.entorno_actual();
begin
  if not public.es_admin() or ent is null then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  if jsonb_typeof(ajustes) <> 'object' or jsonb_typeof(ajustes -> 'periods') <> 'object' then
    raise exception 'Ajustes no válidos';
  end if;
  update public.entornos e set ajustes = guardar_ajustes_entorno.ajustes where e.id = ent;
  return guardar_ajustes_entorno.ajustes;
end;
$$;

create or replace function public.inscripcion_por_enlace(token text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select jsonb_build_object('estado', 'abierto', 'programa', e.programa, 'entorno', e.entorno_id)
     from public.enlaces_inscripcion e where e.token is not null and e.token = inscripcion_por_enlace.token),
    jsonb_build_object('estado', 'no_existe'));
$$;

-- ---------- 5. Permisos ----------
revoke execute on function public.estaca_canonica(text) from public, anon, authenticated;
revoke execute on function public.entornos_publicos() from public;
grant execute on function public.entornos_publicos() to anon, authenticated;
revoke execute on function public.guardar_ajustes_entorno(jsonb) from public, anon;
grant execute on function public.guardar_ajustes_entorno(jsonb) to authenticated;

notify pgrst, 'reload schema';

commit;
