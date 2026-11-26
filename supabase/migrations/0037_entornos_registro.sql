-- Entornos (fase 2): "Crear nuevo administrador" y aprobación del administrador general.
-- Requiere 0036_entornos.sql aplicada antes.
--
-- * El formulario crea la cuenta (correo y contraseña) con los datos de la solicitud. Solo se registra
--   la solicitud si el correo es @churchofjesuschrist.org (se revisa aquí, no solo en la pantalla).
-- * La solicitud queda pendiente hasta que el administrador general la aprueba: recién ahí se activa
--   el entorno (con los periodos del entorno principal como punto de partida) y la cuenta pasa a ser
--   administradora de ese entorno.
-- * El administrador general también puede rechazar, suspender, reactivar y corregir datos y estacas.

begin;

-- ---------- 1. Registrar o actualizar una solicitud (uso interno) ----------
-- datos: { programa, asistente_nombre, asistente_celular, coordinador_nombre, coordinador_celular,
--          estacas: [{ estaca, S: true|false, I: true|false }] }
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
  select distinct e, left(btrim(t ->> 'estaca'), 80), p
  from jsonb_array_elements(case when jsonb_typeof(p_datos -> 'estacas') = 'array' then p_datos -> 'estacas' else '[]'::jsonb end) t
  cross join unnest(array['S', 'I']) p
  where btrim(coalesce(t ->> 'estaca', '')) <> '' and coalesce(t ->> p, '') in ('true', 't', '1')
  on conflict do nothing;
  return e;
end;
$$;

-- ---------- 2. Al crear la cuenta: perfil y, si viene del formulario, la solicitud ----------
create or replace function public.crear_perfil()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  s jsonb := new.raw_user_meta_data -> 'solicitud_entorno';
  correo text := lower(btrim(coalesce(new.email, '')));
begin
  insert into public.perfiles (id, nombre)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'nombre', ''));
  if jsonb_typeof(s) = 'object' and correo like '%@churchofjesuschrist.org' then
    begin
      perform public.registrar_solicitud_entorno(new.id, correo, s);
    exception when others then
      -- Nunca impedir que se cree la cuenta; la solicitud se puede volver a enviar al entrar.
      raise warning 'Solicitud de entorno no registrada: %', sqlerrm;
    end;
  end if;
  return new;
end;
$$;

-- ---------- 3. Para quien se registró ----------
create or replace function public.mi_solicitud_entorno()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('id', x.id, 'programa', x.programa, 'estado', x.estado, 'creado_en', x.creado_en)
  from public.entornos x
  where x.solicitado_por = auth.uid()
  order by x.creado_en desc
  limit 1;
$$;

-- Cuenta que ya existe (entró con su correo y contraseña) y todavía no es administradora.
create or replace function public.solicitar_entorno(datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  correo text;
begin
  select lower(btrim(u.email)) into correo from auth.users u where u.id = auth.uid();
  if correo is null or correo not like '%@churchofjesuschrist.org' then
    raise exception 'Usa tu correo @churchofjesuschrist.org';
  end if;
  if public.es_admin() then
    raise exception 'Esta cuenta ya es administradora';
  end if;
  perform public.registrar_solicitud_entorno(auth.uid(), correo, datos);
  return public.mi_solicitud_entorno();
end;
$$;

-- ---------- 4. Administrador general ----------
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
                   where s.entorno_id = x.id and s.estaca = c.estaca and s.programa = c.programa))
    ) order by (x.estado = 'pendiente') desc, x.creado_en)
    from public.entornos x), '[]'::jsonb);
end;
$$;

-- Aprobar ('activo'), rechazar, suspender o reactivar. El entorno principal no se puede apagar.
create or replace function public.resolver_entorno(entorno uuid, estado text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  x public.entornos%rowtype;
  correo text;
begin
  if not public.es_general() then
    raise exception 'Solo el administrador general' using errcode = '42501';
  end if;
  if estado not in ('activo', 'rechazado', 'suspendido') then
    raise exception 'Estado no válido';
  end if;
  select * into x from public.entornos e where e.id = entorno;
  if x.id is null then
    raise exception 'Ese entorno no existe';
  end if;
  if estado <> 'activo' then
    if x.id = public.entorno_por_defecto() then
      raise exception 'El entorno principal no se puede rechazar ni suspender';
    end if;
    update public.entornos e set estado = resolver_entorno.estado where e.id = entorno;
    update public.perfiles p set entorno_activo = null where p.entorno_activo = entorno;
    return;
  end if;
  -- Aprobar: la cuenta que lo pidió pasa a administrarlo (solo con correo de la Iglesia).
  if x.solicitado_por is not null then
    select lower(btrim(u.email)) into correo from auth.users u where u.id = x.solicitado_por;
    if correo is null or correo not like '%@churchofjesuschrist.org' then
      raise exception 'La cuenta que lo pidió no tiene correo @churchofjesuschrist.org';
    end if;
    insert into public.entorno_admins (entorno_id, usuario_id) values (entorno, x.solicitado_por)
    on conflict do nothing;
    update public.perfiles p set rol = 'admin' where p.id = x.solicitado_por and p.rol <> 'admin';
  end if;
  update public.entornos e set
    estado = 'activo',
    aprobado_en = coalesce(e.aprobado_en, now()),
    ajustes = case when e.ajustes = '{}'::jsonb
                   then coalesce((select d.ajustes from public.entornos d where d.id = public.entorno_por_defecto() and d.id <> e.id), '{}'::jsonb)
                   else e.ajustes end
  where e.id = entorno;
end;
$$;

-- Corregir datos y estacas de un entorno. datos: los mismos campos del formulario; "estacas" reemplaza todas.
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
    select distinct entorno, left(btrim(t ->> 'estaca'), 80), p
    from jsonb_array_elements(datos -> 'estacas') t
    cross join unnest(array['S', 'I']) p
    where btrim(coalesce(t ->> 'estaca', '')) <> '' and coalesce(t ->> p, '') in ('true', 't', '1')
    on conflict do nothing;
  end if;
end;
$$;

-- mi_entorno: además, para el general, cuántas solicitudes esperan su aprobación.
create or replace function public.mi_entorno()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  ent uuid := public.entorno_actual();
  r jsonb;
begin
  if ent is null then
    return null;
  end if;
  select jsonb_build_object(
    'id', x.id, 'programa', x.programa, 'ajustes', x.ajustes, 'general', public.es_general(),
    'pendientes', case when public.es_general() then (select count(*) from public.entornos y where y.estado = 'pendiente') else 0 end,
    'estacas', coalesce((select jsonb_agg(jsonb_build_object('estaca', s.estaca, 'programa', s.programa) order by s.estaca, s.programa)
                         from public.entorno_estacas s where s.entorno_id = x.id), '[]'::jsonb),
    'entornos', coalesce((select jsonb_agg(jsonb_build_object('id', y.id, 'programa', y.programa, 'estado', y.estado) order by y.creado_en)
                          from public.entornos y
                          where public.es_general() or (y.estado = 'activo' and exists (
                            select 1 from public.entorno_admins a where a.entorno_id = y.id and a.usuario_id = auth.uid()))), '[]'::jsonb))
  into r
  from public.entornos x where x.id = ent;
  return r;
end;
$$;

-- ---------- 5. Permisos ----------
revoke execute on function public.registrar_solicitud_entorno(uuid, text, jsonb) from public, anon, authenticated;
revoke execute on function public.mi_solicitud_entorno() from public, anon;
revoke execute on function public.solicitar_entorno(jsonb) from public, anon;
revoke execute on function public.entornos_admin() from public, anon;
revoke execute on function public.resolver_entorno(uuid, text) from public, anon;
revoke execute on function public.guardar_entorno(uuid, jsonb) from public, anon;
grant execute on function public.mi_solicitud_entorno() to authenticated;
grant execute on function public.solicitar_entorno(jsonb) to authenticated;
grant execute on function public.entornos_admin() to authenticated;
grant execute on function public.resolver_entorno(uuid, text) to authenticated;
grant execute on function public.guardar_entorno(uuid, jsonb) to authenticated;

notify pgrst, 'reload schema';

commit;
