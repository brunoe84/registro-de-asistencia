-- Entornos: cada programa (asistente administrativo + coordinador) trabaja en su propio entorno.
--
-- * Un entorno se define por sus pares estaca + programa (S = Seminario, I = Instituto). Las clases,
--   la base de personas y el Class Roll de Wise se reparten por esos pares. Si dos entornos comparten
--   un par, los dos ven esas clases (los maestros no tienen que elegir nada).
-- * Lo que era único para todos pasa a ser de cada entorno: Audit, clases marcadas en el Audit,
--   llave de inscripciones, enlaces de inscripción, informe para presidentes y registro de cargas.
-- * El administrador general (los administradores que ya existían) ve todos los entornos y puede
--   trabajar en cualquiera ("entorno activo"). Un administrador de entorno solo ve el suyo.
-- * Todo lo que existe hoy queda en el entorno "Programa Ica".
--
-- Se aplica una sola vez, completa (va dentro de una transacción: si algo falla, no cambia nada).

begin;

-- ---------- 1. Tablas ----------
create table if not exists public.entornos (
  id uuid primary key default gen_random_uuid(),
  programa text not null,                         -- nombre del programa, p. ej. "Programa Ica"
  asistente_nombre text not null default '',
  asistente_celular text not null default '',
  coordinador_nombre text not null default '',
  coordinador_celular text not null default '',
  correo text not null default '',                -- correo con el que se registró el asistente
  estado text not null default 'pendiente' check (estado in ('pendiente', 'activo', 'rechazado', 'suspendido')),
  ajustes jsonb not null default '{}'::jsonb,     -- periodos y feriados del entorno
  solicitado_por uuid references public.perfiles (id) on delete set null,
  creado_en timestamptz not null default now(),
  aprobado_en timestamptz
);

create table if not exists public.entorno_estacas (
  entorno_id uuid not null references public.entornos (id) on delete cascade,
  estaca text not null,
  programa text not null check (programa in ('S', 'I')),
  primary key (entorno_id, estaca, programa)
);
create index if not exists entorno_estacas_par on public.entorno_estacas (estaca, programa);

create table if not exists public.entorno_admins (
  entorno_id uuid not null references public.entornos (id) on delete cascade,
  usuario_id uuid not null references public.perfiles (id) on delete cascade,
  creado_en timestamptz not null default now(),
  primary key (entorno_id, usuario_id)
);
create index if not exists entorno_admins_usuario on public.entorno_admins (usuario_id);

alter table public.entornos enable row level security;
alter table public.entorno_estacas enable row level security;
alter table public.entorno_admins enable row level security;
revoke all on public.entornos, public.entorno_estacas, public.entorno_admins from anon, authenticated;

-- Administrador general y entorno en el que está trabajando.
alter table public.perfiles add column if not exists general boolean not null default false;
alter table public.perfiles add column if not exists entorno_activo uuid references public.entornos (id) on delete set null;

-- ---------- 2. Funciones base ----------
create or replace function public.es_general()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.perfiles p where p.id = auth.uid() and p.rol = 'admin' and p.general);
$$;

-- Administrador aprobado: el general o quien administra al menos un entorno activo.
create or replace function public.es_admin()
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
        select 1 from public.entorno_admins a join public.entornos e on e.id = a.entorno_id and e.estado = 'activo'
        where a.usuario_id = p.id))
  );
$$;

-- Entorno más antiguo activo (el de los datos que ya existían).
create or replace function public.entorno_por_defecto()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select e.id from public.entornos e where e.estado = 'activo' order by e.creado_en, e.id limit 1;
$$;

-- Entorno en el que trabaja el administrador ahora: el que eligió (si puede usarlo), si no el
-- primero que administra; el general, si no administra ninguno, el más antiguo. Null si no es admin.
create or replace function public.entorno_actual()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  with p as (
    select pf.id, pf.general, pf.entorno_activo from public.perfiles pf
    where pf.id = auth.uid() and pf.rol = 'admin'
  )
  select coalesce(
    (select e.id from p join public.entornos e on e.id = p.entorno_activo and e.estado = 'activo'
      where p.general or exists (select 1 from public.entorno_admins a where a.usuario_id = p.id and a.entorno_id = e.id)),
    (select a.entorno_id from p join public.entorno_admins a on a.usuario_id = p.id
      join public.entornos e on e.id = a.entorno_id and e.estado = 'activo'
      order by e.creado_en, e.id limit 1),
    (select e.id from p join public.entornos e on e.estado = 'activo' where p.general order by e.creado_en, e.id limit 1)
  );
$$;

-- ¿El par estaca + programa es del entorno e? Programa vacío = cualquiera de los dos.
create or replace function public.par_de(e uuid, estaca text, programa text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select e is not null and exists (
    select 1 from public.entorno_estacas x
    where x.entorno_id = e and x.estaca = par_de.estaca
      and (coalesce(par_de.programa, '') = '' or x.programa = par_de.programa)
  );
$$;

-- ¿Es del entorno en el que trabaja ahora? (para los listados del panel)
create or replace function public.en_entorno(estaca text, programa text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.par_de(public.entorno_actual(), estaca, programa);
$$;

-- ¿Este administrador puede ver algo de esa estaca y programa? El general, todo; el de entorno,
-- lo de cualquiera de los entornos que administra. (para permisos sobre una clase o un dato)
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
        where a.usuario_id = p.id and x.estaca = admin_ve.estaca
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
        where a.usuario_id = p.id and x.estaca = c.estaca and x.programa = c.programa))
  );
$$;

-- ¿Administra el entorno e? (para datos que son de un entorno: Audit, inscripciones, llave...)
create or replace function public.admin_de(e uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select e is not null and exists (
    select 1 from public.perfiles p
    where p.id = auth.uid() and p.rol = 'admin'
      and (p.general or exists (
        select 1 from public.entorno_admins a join public.entornos x on x.id = a.entorno_id and x.estado = 'activo'
        where a.usuario_id = p.id and a.entorno_id = e))
  );
$$;

-- Entorno al que va lo de una clase (inscripciones, llave para cifrar): el más antiguo que tiene
-- su estaca y programa; si ninguno la tiene, el entorno por defecto.
create or replace function public.entorno_de_clase(clase uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select case when entorno_de_clase.clase is null then null else coalesce(
    (select x.entorno_id from public.clases c
      join public.entorno_estacas x on x.estaca = c.estaca and x.programa = c.programa
      join public.entornos e on e.id = x.entorno_id and e.estado = 'activo'
      where c.id = entorno_de_clase.clase order by e.creado_en, e.id limit 1),
    public.entorno_por_defecto()) end;
$$;

-- ---------- 3. Columnas de entorno en lo que es de cada entorno ----------
alter table public.wise_audit add column if not exists entorno_id uuid references public.entornos (id) on delete cascade;
alter table public.audit_actualizadas add column if not exists entorno_id uuid references public.entornos (id) on delete cascade;
alter table public.llave_inscripciones add column if not exists entorno_id uuid references public.entornos (id) on delete cascade;
alter table public.enlaces_inscripcion add column if not exists entorno_id uuid references public.entornos (id) on delete cascade;
alter table public.informe_estacas add column if not exists entorno_id uuid references public.entornos (id) on delete cascade;
alter table public.cargas_base add column if not exists entorno_id uuid references public.entornos (id) on delete cascade;
alter table public.inscripciones add column if not exists entorno_id uuid references public.entornos (id) on delete set null;

-- ---------- 4. Programa Ica: el entorno de todo lo que ya existe ----------
do $$
declare
  ica uuid;
begin
  select e.id into ica from public.entornos e where e.programa = 'Programa Ica' order by e.creado_en limit 1;
  if ica is null then
    insert into public.entornos (programa, estado, ajustes, creado_en, aprobado_en)
    values ('Programa Ica', 'activo',
      '{"v":"2026-10-15T19:53:46.000Z","periods":{"S":[{"n":"1er Periodo","s":"","e":""},{"n":"2do Periodo","s":"2026-08-03","e":"2026-11-28"}],"I":[{"n":"1er Periodo","s":"","e":""},{"n":"2do Periodo","s":"","e":""},{"n":"3er Periodo","s":"2026-10-12","e":"2026-11-28"}]},"holidays":[]}'::jsonb,
      '2026-01-01 00:00:00-05', now())
    returning id into ica;
  end if;

  -- Sus estacas (Seminario e Instituto) y, para no dejar nada afuera, todo par que ya tenga clases o Class Roll.
  insert into public.entorno_estacas (entorno_id, estaca, programa)
  select ica, k, p
  from unnest(array['Cañete Perú Stake', 'Chincha Perú Stake', 'Ica Perú Stake', 'Nazca Perú District', 'Pisco Perú Stake']) k
  cross join unnest(array['S', 'I']) p
  union
  select ica, c.estaca, c.programa from public.clases c
  where c.base = 'ica' and coalesce(c.estaca, '') <> '' and c.programa in ('S', 'I')
  union
  select ica, w.estaca, w.programa from public.wise_clases w
  where coalesce(w.estaca, '') <> '' and w.programa in ('S', 'I')
  on conflict do nothing;

  -- Los administradores que ya existían: generales y administradores de Programa Ica.
  update public.perfiles set general = true where rol = 'admin';
  insert into public.entorno_admins (entorno_id, usuario_id)
  select ica, p.id from public.perfiles p where p.rol = 'admin'
  on conflict do nothing;

  update public.wise_audit set entorno_id = ica where entorno_id is null;
  update public.audit_actualizadas set entorno_id = ica where entorno_id is null;
  update public.llave_inscripciones set entorno_id = ica where entorno_id is null;
  update public.enlaces_inscripcion set entorno_id = ica where entorno_id is null;
  update public.informe_estacas set entorno_id = ica where entorno_id is null;
  update public.cargas_base set entorno_id = ica where entorno_id is null;
  update public.inscripciones set entorno_id = ica where entorno_id is null;
end;
$$;

-- ---------- 5. Claves: de "uno para todos" a "uno por entorno" ----------
-- Audit: una fila por entorno.
alter table public.wise_audit drop column if exists id;
alter table public.wise_audit alter column entorno_id set not null;
alter table public.wise_audit alter column entorno_id set default public.entorno_actual();
alter table public.wise_audit add primary key (entorno_id);

-- Clases marcadas como actualizadas en el Audit.
alter table public.audit_actualizadas drop constraint if exists audit_actualizadas_pkey;
alter table public.audit_actualizadas alter column entorno_id set not null;
alter table public.audit_actualizadas alter column entorno_id set default public.entorno_actual();
alter table public.audit_actualizadas add constraint audit_actualizadas_pkey primary key (entorno_id, clave);

-- Llave de inscripciones: una por entorno.
alter table public.llave_inscripciones drop column if exists id;
alter table public.llave_inscripciones alter column entorno_id set not null;
alter table public.llave_inscripciones alter column entorno_id set default public.entorno_actual();
alter table public.llave_inscripciones add primary key (entorno_id);

-- Enlaces de inscripción: uno por entorno y programa.
alter table public.enlaces_inscripcion drop constraint if exists enlaces_inscripcion_pkey;
alter table public.enlaces_inscripcion alter column entorno_id set not null;
alter table public.enlaces_inscripcion alter column entorno_id set default public.entorno_actual();
alter table public.enlaces_inscripcion add constraint enlaces_inscripcion_pkey primary key (entorno_id, programa);

-- Informe para presidentes: cada entorno con sus totales y su encabezado por estaca.
alter table public.informe_estacas drop constraint if exists informe_estacas_pkey;
alter table public.informe_estacas alter column entorno_id set not null;
alter table public.informe_estacas alter column entorno_id set default public.entorno_actual();
alter table public.informe_estacas add constraint informe_estacas_pkey primary key (entorno_id, estaca);

-- Registro de cargas de la base de personas.
alter table public.cargas_base alter column entorno_id set default public.entorno_actual();
create index if not exists cargas_base_entorno on public.cargas_base (entorno_id);

-- Inscripciones: el entorno que las atiende (y con cuya llave se cifran).
create index if not exists inscripciones_entorno on public.inscripciones (entorno_id);

create or replace function public.inscripcion_entorno()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.entorno_id is null then
    new.entorno_id := coalesce(public.entorno_de_clase(new.clase_id), public.entorno_por_defecto());
  end if;
  return new;
end;
$$;
drop trigger if exists inscripcion_entorno on public.inscripciones;
create trigger inscripcion_entorno before insert on public.inscripciones
  for each row execute function public.inscripcion_entorno();

-- ---------- 6. Permisos sobre clases y eventos ----------
create or replace function public.puede_usar_clase(clase uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.tiene_acceso(clase) or public.admin_ve_clase(clase);
$$;

create or replace function public.puede_editar_clase(clase uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.admin_ve_clase(clase) or exists (
    select 1 from public.clase_accesos
    where clase_id = clase and usuario_id = auth.uid()
      and tipo in ('titular', 'dispositivo')
      and (vence_en is null or vence_en > now())
  );
$$;

-- Eventos: quien tiene acceso; el administrador general; el de entorno, si el evento es de una de sus estacas.
create or replace function public.puede_usar_evento(evento uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.evento_accesos a where a.evento_id = evento and a.usuario_id = auth.uid()
  ) or public.es_general() or (public.es_admin() and exists (
    select 1 from public.eventos e where e.id = evento and coalesce(e.estaca, '') <> '' and public.admin_ve(e.estaca, null)
  ));
$$;

-- ---------- 7. Funciones reescritas a mano ----------
create or replace function public.resolver_solicitud(solicitud uuid, aprobar boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.solicitudes_acceso%rowtype;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  select * into s from public.solicitudes_acceso x where x.id = solicitud;
  if s.id is null or not public.admin_ve_clase(s.clase_id) then
    raise exception 'Esa solicitud no es de tu entorno';
  end if;
  update public.solicitudes_acceso
  set estado = case when aprobar then 'aprobada' else 'rechazada' end, resuelto_en = now()
  where id = solicitud and estado = 'pendiente'
  returning * into s;
  if s.id is not null and aprobar then
    perform public.dar_acceso(s.clase_id, s.usuario_id, 'colaborador', null);
    update public.perfiles set nombre = trim(s.nombres || ' ' || s.apellidos)
    where id = s.usuario_id and nombre = '';
  end if;
end;
$$;

create or replace function public.vincular_wise_clase(wise text, clase uuid, modo text default 'manual', ignorar boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if not public.es_admin()
     or (clase is not null and not public.admin_ve_clase(clase))
     or not exists (select 1 from public.wise_clases w where w.clave = wise and public.admin_ve(w.estaca, w.programa)) then
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

create or replace function public.cargar_audit(filas jsonb, archivo text, archivo_en timestamptz)
returns integer
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
  insert into public.wise_audit as a (entorno_id, filas, archivo, archivo_en, actualizado_en)
  values (ent, coalesce(filas, '[]'::jsonb), coalesce(archivo, ''), archivo_en, now())
  on conflict (entorno_id) do update set filas = excluded.filas, archivo = excluded.archivo, archivo_en = excluded.archivo_en, actualizado_en = now();
  return jsonb_array_length(coalesce(filas, '[]'::jsonb));
end;
$$;

create or replace function public.marcar_audit_actualizada(clave text, hecho boolean)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  v timestamptz := now();
  ent uuid := public.entorno_actual();
begin
  if not public.es_admin() or ent is null then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  if hecho then
    insert into public.audit_actualizadas as a (entorno_id, clave, marcado_en) values (ent, clave, v)
    on conflict on constraint audit_actualizadas_pkey do update set marcado_en = v;
    return v;
  end if;
  delete from public.audit_actualizadas a where a.entorno_id = ent and a.clave = clave;
  return null;
end;
$$;

create or replace function public.enlace_inscripcion(prog text, activo boolean default true)
returns text
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  t text;
  ent uuid := public.entorno_actual();
begin
  if not public.es_admin() or ent is null then
    raise exception 'Solo el administrador';
  end if;
  if prog not in ('S', 'I') then
    raise exception 'Programa no válido';
  end if;
  if not activo then
    update public.enlaces_inscripcion e set token = null where e.entorno_id = ent and e.programa = prog;
    return null;
  end if;
  select e.token into t from public.enlaces_inscripcion e where e.entorno_id = ent and e.programa = prog;
  if t is null then
    t := substr(replace(gen_random_uuid()::text, '-', ''), 1, 14);
    insert into public.enlaces_inscripcion (entorno_id, programa, token) values (ent, prog, t)
    on conflict (entorno_id, programa) do update set token = excluded.token, creado_en = now();
  end if;
  return t;
end;
$$;

create or replace function public.guardar_llave_inscripciones(datos jsonb, reemplazar boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  ent uuid := public.entorno_actual();
begin
  if not public.es_admin() or ent is null then
    raise exception 'Solo el administrador';
  end if;
  if coalesce(datos ->> 'publica', '') = '' or coalesce(datos ->> 'privada_cifrada', '') = ''
     or coalesce(datos ->> 'sal', '') = '' or coalesce(datos ->> 'iv', '') = '' then
    raise exception 'Llave incompleta';
  end if;
  if exists (select 1 from public.llave_inscripciones l where l.entorno_id = ent) and not reemplazar then
    raise exception 'Ya existe una llave de inscripciones. Abre la existente con tu contraseña.';
  end if;
  insert into public.llave_inscripciones (entorno_id, publica, privada_cifrada, sal, iv, iteraciones, creada_en)
  values (ent, datos ->> 'publica', datos ->> 'privada_cifrada', datos ->> 'sal', datos ->> 'iv',
          coalesce((datos ->> 'iteraciones')::int, 310000), now())
  on conflict (entorno_id) do update set publica = excluded.publica, privada_cifrada = excluded.privada_cifrada,
    sal = excluded.sal, iv = excluded.iv, iteraciones = excluded.iteraciones, creada_en = now();
end;
$$;

-- Llave pública para cifrar una inscripción: la del entorno que la va a atender. Se reconoce por el
-- token (enlace de inscripción, QR de la clase o ficha) o por la clase; sin datos, el entorno por defecto.
drop function if exists public.llave_publica_inscripciones();
create or replace function public.llave_publica_inscripciones(token text default null, clase uuid default null)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select l.publica from public.llave_inscripciones l
  where l.entorno_id = coalesce(
    (select e.entorno_id from public.enlaces_inscripcion e where llave_publica_inscripciones.token is not null and e.token = llave_publica_inscripciones.token),
    (select public.entorno_de_clase(c.id) from public.clases c where llave_publica_inscripciones.token is not null and c.qr = llave_publica_inscripciones.token),
    (select i.entorno_id from public.inscripciones i where llave_publica_inscripciones.token is not null and i.token = llave_publica_inscripciones.token),
    public.entorno_de_clase(llave_publica_inscripciones.clase),
    public.entorno_por_defecto());
$$;

-- ---------- 8. Para la app: el entorno en el que trabaja el administrador ----------
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

-- El general entra a cualquier entorno activo; un administrador, a los que administra.
create or replace function public.cambiar_entorno(entorno uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if not exists (select 1 from public.entornos e where e.id = entorno and e.estado = 'activo')
     or not (public.es_general() or exists (select 1 from public.entorno_admins a where a.entorno_id = entorno and a.usuario_id = auth.uid())) then
    raise exception 'No puedes entrar a ese entorno' using errcode = '42501';
  end if;
  update public.perfiles p set entorno_activo = entorno where p.id = auth.uid();
  return public.mi_entorno();
end;
$$;

-- ---------- 9. Funciones del panel con el filtro de entorno (versión vigente + filtro) ----------

-- (vigente en 0005_accesos_y_busqueda)
create or replace function public.accesos_de_clase(clase uuid)
returns table (usuario_id uuid, nombre text, tipo text, creado_en timestamptz, vence_en timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.admin_ve_clase(clase) then
    raise exception 'Solo el administrador';
  end if;
  return query
  select a.usuario_id, coalesce(nullif(p.nombre, ''), 'Sin nombre'), a.tipo, a.creado_en, a.vence_en
  from public.clase_accesos a
  join public.perfiles p on p.id = a.usuario_id
  where a.clase_id = clase
  order by a.tipo desc, a.creado_en;
end;
$$;

-- (vigente en 0022_crear_clase_base_externa_terminos)
create or replace function public.alertas_base()
returns table (id uuid, nombre text, vinculo text, origen text, ultimo_intento timestamptz, clase_id uuid, codigo text, maestro text, programa text, estaca text, horario text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  return query
  select a.id, a.nombre, a.vinculo, a.origen, a.ultimo_intento, c.id, c.codigo, c.maestro_nombre, c.programa, c.estaca, c.horario
  from public.clase_alumnos a
  join public.clases c on c.id = a.clase_id
  where a.vinculo in ('pendiente', 'no_miembro') and a.retirado_en is null and c.base = 'ica' and public.en_entorno(c.estaca, c.programa)
  order by a.vinculo, c.estaca, a.nombre;
end;
$$;

-- (vigente en 0024_inscripciones_cifradas)
create or replace function public.atender_inscripcion(inscripcion uuid, atendida boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  update public.inscripciones i set
    atendida_en = case when atendida then now() end,
    datos = case when atendida then (i.datos - public.claves_sensibles()) - 'cifrado' else i.datos end
  where i.id = inscripcion and (public.es_general() or i.entorno_id = public.entorno_actual());
end;
$$;

-- (vigente en 0032_audit_actualizadas)
create or replace function public.audit_actualizadas_admin()
returns table (clave text, marcado_en timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  return query select a.clave, a.marcado_en from public.audit_actualizadas a where a.entorno_id = public.entorno_actual();
end;
$$;

-- (vigente en 0031_audit_retrasos)
create or replace function public.audit_admin()
returns table (filas jsonb, archivo text, archivo_en timestamptz, actualizado_en timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  return query select a.filas, a.archivo, a.archivo_en, a.actualizado_en from public.wise_audit a where a.entorno_id = public.entorno_actual();
end;
$$;

-- (vigente en 0027_mensajes_al_maestro)
create or replace function public.borrar_mensaje_clase(mensaje uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if not public.admin_ve_clase((select m.clase_id from public.clase_mensajes m where m.id = mensaje)) then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  delete from public.clase_mensajes m where m.id = mensaje;
end;
$$;

-- (vigente en 0022_crear_clase_base_externa_terminos)
create or replace function public.buscar_clases(texto text)
returns table (id uuid, codigo text, titulo text, maestro text, programa text, estaca text, horario text, curso text, adoptada boolean, tengo_acceso boolean, solicitud_pendiente boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, case when r.tengo_acceso or public.admin_ve(r.estaca, r.programa) then r.codigo end, r.titulo, r.maestro_nombre, r.programa, r.estaca, r.horario, r.curso,
    r.adoptada, r.tengo_acceso, r.solicitud_pendiente
  from (
    select c.*,
      public.puntaje_nombre(public.norm_nombre(c.maestro_nombre), texto) as puntos,
      exists (select 1 from public.clase_accesos a where a.clase_id = c.id and a.tipo = 'titular') as adoptada,
      public.tiene_acceso(c.id) as tengo_acceso,
      exists (select 1 from public.solicitudes_acceso s where s.clase_id = c.id and s.usuario_id = auth.uid() and s.estado = 'pendiente') as solicitud_pendiente
    from public.clases c
    where length(public.norm_nombre(texto)) >= 3
  ) r
  where r.puntos is not null and (r.base = 'ica' or r.tengo_acceso)
  order by r.puntos desc, r.maestro_nombre, r.horario
  limit 20;
$$;

-- (vigente en 0022_crear_clase_base_externa_terminos)
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
  ent uuid;
begin
  select e.programa, e.entorno_id into prog, ent from public.enlaces_inscripcion e where e.token is not null and e.token = token;
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
    where c.programa = prog and c.base = 'ica' and public.par_de(ent, c.estaca, c.programa)
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

-- (vigente en 0023_genero_para_grupos)
create or replace function public.cargar_base_evento(evento uuid, filas jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  n integer;
begin
  if not ((public.es_admin() and public.puede_usar_evento(evento)) or exists (select 1 from public.evento_accesos a
          where a.evento_id = evento and a.usuario_id = auth.uid() and a.tipo = 'organizador')) then
    raise exception 'Solo quien organiza el evento puede cambiar su base de datos';
  end if;
  if jsonb_array_length(coalesce(filas, '[]'::jsonb)) > 20000 then
    raise exception 'La lista tiene demasiadas filas (máximo 20 000)';
  end if;
  delete from public.evento_base b where b.evento_id = evento;
  insert into public.evento_base (evento_id, nombre, estaca, barrio, programa, genero)
  select evento, left(trim(f ->> 'n'), 120), left(trim(coalesce(f ->> 'k', '')), 80), left(trim(coalesce(f ->> 'w', '')), 80),
    case when f ->> 'g' in ('S', 'I') then f ->> 'g' else '' end,
    case when f ->> 'x' in ('H', 'M') then f ->> 'x' else '' end
  from jsonb_array_elements(coalesce(filas, '[]'::jsonb)) f
  where coalesce(trim(f ->> 'n'), '') <> '';
  get diagnostics n = row_count;
  return n;
end;
$$;

-- (vigente en 0029_celular_por_maestro)
create or replace function public.celular_maestro(clase uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  v_maestro uuid;
  v_nombre text;
  v text;
begin
  if not public.admin_ve_clase(clase) then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  select c.maestro_id, lower(btrim(coalesce(c.maestro_nombre, ''))) into v_maestro, v_nombre
    from public.clases c where c.id = clase;
  -- El último número guardado para este maestro (en esta o en otra de sus clases).
  select nullif(c.maestro_celular, '') into v
    from public.clases c
   where coalesce(c.maestro_celular, '') <> ''
     and (c.id = clase
          or (v_maestro is not null and c.maestro_id = v_maestro)
          or (v_nombre <> '' and lower(btrim(coalesce(c.maestro_nombre, ''))) = v_nombre))
   order by c.maestro_celular_en desc nulls last, (c.id = clase) desc
   limit 1;
  if v is null and v_maestro is not null then
    select nullif(s.celular, '') into v
      from public.solicitudes_acceso s
     where s.usuario_id = v_maestro and coalesce(s.celular, '') <> ''
     order by s.creado_en desc limit 1;
  end if;
  return coalesce(v, '');
end;
$$;

-- (vigente en 0024_inscripciones_cifradas)
create or replace function public.cifrar_inscripciones(filas jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  f jsonb;
  n integer := 0;
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  for f in select * from jsonb_array_elements(coalesce(filas, '[]'::jsonb)) loop
    continue when jsonb_typeof(f -> 'cifrado') <> 'object';
    update public.inscripciones i
    set datos = (i.datos - public.claves_sensibles()) || jsonb_build_object('cifrado', f -> 'cifrado')
    where i.id = (f ->> 'id')::uuid and i.entorno_id = public.entorno_actual();
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- (vigente en 0026_clase_al_dia_en_wise)
create or replace function public.clases_wise_al_dia()
returns table (id uuid, al_dia_en timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  return query select c.id, c.wise_al_dia_en from public.clases c where c.wise_al_dia_en is not null and public.en_entorno(c.estaca, c.programa);
end;
$$;

-- (vigente en 0022_crear_clase_base_externa_terminos)
create or replace function public.contadores_admin()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  return jsonb_build_object(
    'solicitudes', (select count(*) from public.solicitudes_acceso s join public.clases c on c.id = s.clase_id where s.estado = 'pendiente' and public.en_entorno(c.estaca, c.programa)),
    'alertas', (select count(*) from public.clase_alumnos a join public.clases c on c.id = a.clase_id
                where a.vinculo = 'pendiente' and a.retirado_en is null and c.base = 'ica' and public.en_entorno(c.estaca, c.programa)),
    'inscripciones', (select count(*) from public.inscripciones i left join public.clases c on c.id = i.clase_id
                      where i.atendida_en is null and coalesce(c.base, 'ica') = 'ica' and i.entorno_id = public.entorno_actual()),
    'inscripciones_S', (select count(*) from public.inscripciones i left join public.clases c on c.id = i.clase_id
                        where i.atendida_en is null and coalesce(c.base, 'ica') = 'ica' and i.entorno_id = public.entorno_actual() and coalesce(i.programa, c.programa) = 'S'),
    'inscripciones_I', (select count(*) from public.inscripciones i left join public.clases c on c.id = i.clase_id
                        where i.atendida_en is null and coalesce(c.base, 'ica') = 'ica' and i.entorno_id = public.entorno_actual() and coalesce(i.programa, c.programa) = 'I')
  );
end;
$$;

-- (vigente en 0027_mensajes_al_maestro)
create or replace function public.dejar_mensaje_clase(clase uuid, texto text, tipo text default 'aviso')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare v uuid;
begin
  if not public.admin_ve_clase(clase) then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  insert into public.clase_mensajes (clase_id, tipo, texto)
  values (clase, coalesce(nullif(tipo, ''), 'aviso'), btrim(texto))
  returning id into v;
  return v;
end;
$$;

-- (vigente en 0002_clases_adopcion_alertas)
create or replace function public.etiquetar_alumno(alumno uuid, vinculo_nuevo text, persona uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  p public.personas%rowtype;
begin
  if not public.admin_ve_clase((select x.clase_id from public.clase_alumnos x where x.id = alumno)) then
    raise exception 'Solo el administrador';
  end if;
  if vinculo_nuevo = 'vinculado' then
    select * into strict p from public.personas where id = persona;
    update public.clase_alumnos
    set vinculo = 'vinculado', persona_id = p.id, nombre = p.nombre, estaca = p.estaca, barrio = p.barrio
    where id = alumno;
  elsif vinculo_nuevo in ('pendiente', 'no_miembro') then
    update public.clase_alumnos
    set vinculo = vinculo_nuevo, persona_id = null
    where id = alumno;
  else
    raise exception 'Vínculo no válido';
  end if;
end;
$$;

-- (vigente en 0018_ficha_de_alumno_nuevo)
create or replace function public.ficha_enviada(ficha text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  c uuid;
  hay boolean;
  ent uuid;
begin
  select true, i.clase_id, i.entorno_id into hay, c, ent from public.inscripciones i where i.token = ficha;
  if hay is null then
    raise exception 'No encontramos esa ficha';
  end if;
  if not (public.admin_de(ent) or (c is not null and public.puede_usar_clase(c))) then
    raise exception 'No tienes acceso a esta ficha';
  end if;
  update public.inscripciones i set enviado_en = now(), envios = i.envios + 1 where i.token = ficha;
end;
$$;

-- (vigente en 0029_celular_por_maestro)
create or replace function public.guardar_celular_maestro(clase uuid, celular text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  v text := left(regexp_replace(coalesce(celular, ''), '[^0-9+]', '', 'g'), 16);
  v_maestro uuid;
  v_nombre text;
begin
  if not public.admin_ve_clase(clase) then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  select c.maestro_id, lower(btrim(coalesce(c.maestro_nombre, ''))) into v_maestro, v_nombre
    from public.clases c where c.id = clase;
  update public.clases c
     set maestro_celular = nullif(v, ''), maestro_celular_en = now()
   where c.id = clase
      or (v_maestro is not null and c.maestro_id = v_maestro)
      or (v_nombre <> '' and lower(btrim(coalesce(c.maestro_nombre, ''))) = v_nombre);
  return v;
end;
$$;

-- (vigente en 0021_elegir_maestro_al_inscribirse)
create or replace function public.inscribirme(token text, persona uuid default null, nombres text default null, apellidos text default null, datos jsonb default '{}')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  prog text;
  ent uuid;
  p public.personas%rowtype;
  nom text;
  d jsonb;
  previa uuid;
  nueva uuid;
  acuerdo_ok text;
begin
  select e.programa, e.entorno_id into prog, ent from public.enlaces_inscripcion e where e.token is not null and e.token = token;
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
  where i.programa = prog and i.atendida_en is null and i.entorno_id is not distinct from ent
    and ((p.id is not null and i.persona_id = p.id) or (p.id is null and i.persona_id is null and public.norm_nombre(i.nombre) = public.norm_nombre(nom)))
  order by i.creado_en desc limit 1;
  if previa is not null then
    update public.inscripciones i set datos = i.datos || d, creado_en = now() where i.id = previa;
    nueva := previa;
  else
    insert into public.inscripciones (entorno_id, programa, origen, persona_id, nombre, datos)
    values (ent, prog, 'enlace', p.id, nom, d)
    returning id into nueva;
  end if;
  return jsonb_build_object('estado', case when previa is null then 'inscrito' else 'actualizado' end, 'nombre', nom, 'programa', prog, 'id', nueva);
end;
$$;

-- (vigente en 0022_crear_clase_base_externa_terminos)
create or replace function public.inscripciones_wise(atendidas boolean default false, prog text default null)
returns table (id uuid, nombre text, datos jsonb, creado_en timestamptz, atendida_en timestamptz, aprobada text,
  maestro text, horario text, programa text, estaca text, en_base boolean, barrio text, origen text,
  completada_en timestamptz, token text, whatsapp text, enviado_en timestamptz, envios integer, retirado boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  return query
  select i.id, i.nombre, i.datos, i.creado_en, i.atendida_en,
    case when i.qr_id is null then '' else coalesce((select q.estado from public.asistencia_qr q where q.id = i.qr_id), 'aprobada') end,
    coalesce(c.maestro_nombre, ''), coalesce(c.horario, ''), coalesce(i.programa, c.programa),
    coalesce(c.estaca, (select x.estaca from public.personas x where x.id = i.persona_id), ''),
    i.persona_id is not null,
    coalesce((select x.barrio from public.personas x where x.id = i.persona_id), ''),
    i.origen, i.completada_en, i.token, coalesce(i.whatsapp, ''), i.enviado_en, i.envios,
    i.origen = 'maestro' and (i.alumno_id is null or exists (select 1 from public.clase_alumnos a where a.id = i.alumno_id and a.retirado_en is not null))
  from public.inscripciones i
  left join public.clases c on c.id = i.clase_id
  where ((atendidas and i.atendida_en is not null) or (not atendidas and i.atendida_en is null))
    and (prog is null or coalesce(i.programa, c.programa) = prog)
    and coalesce(c.base, 'ica') = 'ica'
    and i.entorno_id = public.entorno_actual()
  order by i.creado_en desc
  limit 1000;
end;
$$;

-- (vigente en 0005_accesos_y_busqueda)
create or replace function public.invitacion_de_clase(clase uuid, duracion_nueva text default null)
returns table (codigo text, duracion text, vence_en timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  i public.invitaciones%rowtype;
  f date;
begin
  if not (public.admin_ve_clase(clase) or exists (
    select 1 from public.clase_accesos a
    where a.clase_id = clase and a.usuario_id = auth.uid() and a.tipo in ('titular', 'dispositivo')
  )) then
    raise exception 'Solo el maestro de la clase puede invitar';
  end if;
  if duracion_nueva is not null and duracion_nueva not in ('semana', 'mes', 'periodo') then
    raise exception 'Duración no válida';
  end if;
  select * into i from public.invitaciones x where x.clase_id = clase and x.usada_en is null;
  if i.codigo is null then
    insert into public.invitaciones (codigo, clase_id, duracion)
    values (public.nuevo_codigo_clase(), clase, coalesce(duracion_nueva, 'semana'))
    returning * into i;
  elsif duracion_nueva is not null and duracion_nueva <> i.duracion then
    update public.invitaciones x set duracion = duracion_nueva where x.codigo = i.codigo returning * into i;
  end if;
  select c.fin into f from public.clases c where c.id = clase;
  return query select i.codigo, i.duracion, public.vence_invitacion(i.duracion, f);
end;
$$;

-- (vigente en 0024_inscripciones_cifradas)
create or replace function public.llave_admin_inscripciones()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  return (select jsonb_build_object('publica', l.publica, 'privada_cifrada', l.privada_cifrada, 'sal', l.sal, 'iv', l.iv,
            'iteraciones', l.iteraciones, 'creada_en', l.creada_en)
          from public.llave_inscripciones l where l.entorno_id = public.entorno_actual());
end;
$$;

-- (vigente en 0026_clase_al_dia_en_wise)
create or replace function public.marcar_clase_wise(clase uuid, al_dia boolean)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  v timestamptz := case when al_dia then now() else null end;
begin
  if not public.admin_ve_clase(clase) then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  update public.clases c set wise_al_dia_en = v where c.id = clase;
  return v;
end;
$$;

-- (vigente en 0025_alumnos_en_wise)
create or replace function public.marcar_en_wise(clase uuid, si uuid[] default '{}', no uuid[] default '{}')
returns integer
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  n integer := 0;
  m integer := 0;
begin
  if not public.admin_ve_clase(clase) then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  update public.clase_alumnos a set en_wise_en = coalesce(a.en_wise_en, now())
    where a.clase_id = clase and a.id = any(coalesce(si, '{}'));
  get diagnostics n = row_count;
  update public.clase_alumnos a set en_wise_en = null
    where a.clase_id = clase and a.id = any(coalesce(no, '{}')) and a.en_wise_en is not null;
  get diagnostics m = row_count;
  return n + m;
end;
$$;

-- (vigente en 0027_mensajes_al_maestro)
create or replace function public.mensajes_de_clase(clase uuid)
returns table (id uuid, tipo text, texto text, creado_en timestamptz, visto_en timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if not public.admin_ve_clase(clase) then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  return query
    select m.id, m.tipo, m.texto, m.creado_en, m.visto_en
    from public.clase_mensajes m
    where m.clase_id = clase
    order by m.creado_en desc
    limit 50;
end;
$$;

-- (vigente en 0013_inscripciones_solo_admin)
create or replace function public.qr_pendientes_clase(clase uuid)
returns table (id uuid, alumno_id uuid, persona_id uuid, nombre text, fecha date, creado_en timestamptz, datos jsonb)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if not public.puede_usar_clase(clase) then
    raise exception 'No tienes acceso a esta clase';
  end if;
  return query
  select q.id, q.alumno_id, q.persona_id, q.nombre, q.fecha, q.creado_en,
    case when public.admin_ve_clase(clase) then (select i.datos from public.inscripciones i where i.qr_id = q.id limit 1) end
  from public.asistencia_qr q
  where q.clase_id = clase and q.estado = 'pendiente'
  order by q.fecha desc, q.creado_en;
end;
$$;

-- (vigente en 0022_crear_clase_base_externa_terminos)
create or replace function public.resumen_clases()
returns table (id uuid, codigo text, titulo text, maestro text, programa text, estaca text, horario text, curso text, alumnos bigint, alertas bigint, titular text, adoptada_en timestamptz, colaboradores bigint, presentes bigint, marcas bigint, ultimo_cambio timestamptz, cambios integer, dias smallint[], inicio date, fin date, fechas_extra date[], fechas_omitidas date[], ultima_fecha date, recordatorios bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  return query
  select c.id, c.codigo, c.titulo, c.maestro_nombre, c.programa, c.estaca, c.horario, c.curso,
    (select count(*) from public.clase_alumnos x where x.clase_id = c.id and x.retirado_en is null),
    (select count(*) from public.clase_alumnos x where x.clase_id = c.id and x.retirado_en is null and x.vinculo = 'pendiente'),
    (select coalesce(nullif(p.nombre, ''), 'Sin nombre') from public.clase_accesos a join public.perfiles p on p.id = a.usuario_id where a.clase_id = c.id and a.tipo = 'titular'),
    (select a.creado_en from public.clase_accesos a where a.clase_id = c.id and a.tipo = 'titular'),
    (select count(*) from public.clase_accesos a where a.clase_id = c.id and a.tipo = 'colaborador' and (a.vence_en is null or a.vence_en > now())),
    (select count(*) from public.asistencia m where m.clase_id = c.id and m.estado <> 'F'),
    (select count(*) from public.asistencia m where m.clase_id = c.id),
    c.ultimo_cambio_maestro, c.cambios_maestro, c.dias, c.inicio, c.fin, c.fechas_extra, c.fechas_omitidas,
    (select max(m.fecha) from public.asistencia m where m.clase_id = c.id),
    (select count(*) from public.clase_accesos a join public.suscripciones_push s on s.usuario_id = a.usuario_id where a.clase_id = c.id and a.tipo in ('titular', 'dispositivo'))
  from public.clases c
  where c.base = 'ica' and public.en_entorno(c.estaca, c.programa)
  order by c.maestro_nombre, c.horario;
end;
$$;

-- (vigente en 0020_solicitud_supervisor)
create or replace function public.solicitudes_pendientes()
returns table (id uuid, clase_id uuid, codigo text, maestro text, horario text, nombres text, apellidos text, barrio text, estaca text, programa text, creado_en timestamptz, rol text, celular text, usuario_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador';
  end if;
  return query
  select s.id, s.clase_id, c.codigo, c.maestro_nombre, c.horario, s.nombres, s.apellidos, s.barrio, s.estaca, s.programa, s.creado_en, s.rol, s.celular, s.usuario_id
  from public.solicitudes_acceso s
  join public.clases c on c.id = s.clase_id
  where s.estado = 'pendiente' and public.en_entorno(c.estaca, c.programa)
  order by s.creado_en;
end;
$$;

-- (vigente en 0021_elegir_maestro_al_inscribirse)
create or replace function public.unirme_a_clase_inscripcion(token text, inscripcion uuid, clase uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  prog text;
  ent uuid;
  i public.inscripciones%rowtype;
  c public.clases%rowtype;
  p public.personas%rowtype;
  al uuid;
  ya boolean := false;
begin
  select e.programa, e.entorno_id into prog, ent from public.enlaces_inscripcion e where e.token is not null and e.token = token;
  if prog is null then
    raise exception 'Este enlace de inscripción ya no está activo';
  end if;
  select * into i from public.inscripciones x where x.id = inscripcion;
  if i.id is null or i.programa <> prog or i.creado_en < now() - interval '24 hours' then
    raise exception 'Vuelve a enviar tu inscripción para elegir a tu maestro';
  end if;
  select * into c from public.clases x where x.id = clase;
  if c.id is null or c.programa <> prog or not public.par_de(ent, c.estaca, c.programa) or (c.fin is not null and c.fin < current_date - 14) then
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

-- (vigente en 0030_class_roll_wise)
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
    where public.en_entorno(w.estaca, w.programa)
    order by w.programa, w.estaca, w.maestro, w.horario;
end;
$$;


-- ---------- 10. Políticas (RLS) ----------
drop policy if exists "ver perfil propio o admin" on public.perfiles;
create policy "ver perfil propio o admin" on public.perfiles
  for select to authenticated using (id = auth.uid() or public.es_general());

drop policy if exists "admin crea clases" on public.clases;
create policy "admin crea clases" on public.clases
  for insert to authenticated with check (public.admin_ve(estaca, programa));
drop policy if exists "admin edita clases" on public.clases;
create policy "admin edita clases" on public.clases
  for update to authenticated using (public.admin_ve_clase(id)) with check (public.admin_ve(estaca, programa));
drop policy if exists "admin borra clases" on public.clases;
create policy "admin borra clases" on public.clases
  for delete to authenticated using (public.admin_ve_clase(id));

drop policy if exists "ver acceso propio o admin" on public.clase_accesos;
create policy "ver acceso propio o admin" on public.clase_accesos
  for select to authenticated using (usuario_id = auth.uid() or public.admin_ve_clase(clase_id));
drop policy if exists "admin quita accesos" on public.clase_accesos;
create policy "admin quita accesos" on public.clase_accesos
  for delete to authenticated using (public.admin_ve_clase(clase_id));

drop policy if exists "ver solicitud propia o admin" on public.solicitudes_acceso;
create policy "ver solicitud propia o admin" on public.solicitudes_acceso
  for select to authenticated using (usuario_id = auth.uid() or public.admin_ve_clase(clase_id));

drop policy if exists "admin ve cargas" on public.cargas_base;
create policy "admin ve cargas" on public.cargas_base
  for select to authenticated using (public.es_admin() and entorno_id = public.entorno_actual());

drop policy if exists "admin ve informe estacas" on public.informe_estacas;
create policy "admin ve informe estacas" on public.informe_estacas
  for select to authenticated using (public.es_admin() and entorno_id = public.entorno_actual());
drop policy if exists "admin crea informe estacas" on public.informe_estacas;
create policy "admin crea informe estacas" on public.informe_estacas
  for insert to authenticated with check (public.es_admin() and entorno_id = public.entorno_actual());
drop policy if exists "admin cambia informe estacas" on public.informe_estacas;
create policy "admin cambia informe estacas" on public.informe_estacas
  for update to authenticated using (public.es_admin() and entorno_id = public.entorno_actual())
  with check (public.es_admin() and entorno_id = public.entorno_actual());

-- ---------- 11. Permisos de ejecución ----------
revoke execute on function public.es_general() from public, anon;
revoke execute on function public.entorno_actual() from public, anon;
revoke execute on function public.par_de(uuid, text, text) from public, anon;
revoke execute on function public.en_entorno(text, text) from public, anon;
revoke execute on function public.admin_ve(text, text) from public, anon;
revoke execute on function public.admin_ve_clase(uuid) from public, anon;
revoke execute on function public.admin_de(uuid) from public, anon;
revoke execute on function public.mi_entorno() from public, anon;
revoke execute on function public.cambiar_entorno(uuid) from public, anon;
grant execute on function public.es_general() to authenticated;
grant execute on function public.entorno_actual() to authenticated;
grant execute on function public.par_de(uuid, text, text) to authenticated;
grant execute on function public.en_entorno(text, text) to authenticated;
grant execute on function public.admin_ve(text, text) to authenticated;
grant execute on function public.admin_ve_clase(uuid) to authenticated;
grant execute on function public.admin_de(uuid) to authenticated;
grant execute on function public.mi_entorno() to authenticated;
grant execute on function public.cambiar_entorno(uuid) to authenticated;

revoke execute on function public.entorno_por_defecto() from public, anon, authenticated;
revoke execute on function public.entorno_de_clase(uuid) from public, anon, authenticated;
revoke execute on function public.inscripcion_entorno() from public, anon, authenticated;

revoke execute on function public.llave_publica_inscripciones(text, uuid) from public;
grant execute on function public.llave_publica_inscripciones(text, uuid) to anon, authenticated;

notify pgrst, 'reload schema';

commit;
