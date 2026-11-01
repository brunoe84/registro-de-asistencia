-- Registro de asistencia: esquema inicial.
-- Solo se guarda nombre, estaca y barrio de cada persona.
-- Cada maestro accede a sus clases; el administrador accede a todo.

create table public.perfiles (
  id uuid primary key references auth.users (id) on delete cascade,
  nombre text not null default '',
  rol text not null default 'maestro' check (rol in ('admin', 'maestro')),
  creado_en timestamptz not null default now()
);

create function public.es_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.perfiles
    where id = auth.uid() and rol = 'admin'
  );
$$;

-- Toda cuenta nueva nace como maestro. El rol solo se cambia desde el panel de Supabase.
create function public.crear_perfil()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.perfiles (id, nombre)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'nombre', ''));
  return new;
end;
$$;

create trigger al_crear_usuario
  after insert on auth.users
  for each row execute function public.crear_perfil();

create table public.personas (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  estaca text not null,
  barrio text not null default '',
  unique (nombre, estaca, barrio)
);

create table public.clases (
  id uuid primary key default gen_random_uuid(),
  titulo text not null,
  programa text not null check (programa in ('S', 'I')),
  estaca text not null,
  barrio text not null default '',
  dias smallint[] not null default '{}',
  maestro_id uuid not null default auth.uid() references public.perfiles (id),
  creado_en timestamptz not null default now()
);
create index clases_maestro_idx on public.clases (maestro_id);
create index clases_estaca_programa_idx on public.clases (estaca, programa);

create table public.clase_alumnos (
  id uuid primary key default gen_random_uuid(),
  clase_id uuid not null references public.clases (id) on delete cascade,
  persona_id uuid references public.personas (id) on delete set null,
  nombre text not null,
  estaca text not null default '',
  barrio text not null default '',
  agregado_en timestamptz not null default now(),
  unique (clase_id, id),
  unique (clase_id, persona_id)
);

create table public.asistencia (
  clase_id uuid not null,
  alumno_id uuid not null,
  fecha date not null,
  estado text not null check (estado in ('P', 'F')),
  marcado_por uuid not null default auth.uid() references public.perfiles (id),
  actualizado_en timestamptz not null default now(),
  primary key (alumno_id, fecha),
  foreign key (clase_id, alumno_id) references public.clase_alumnos (clase_id, id) on delete cascade
);
create index asistencia_clase_fecha_idx on public.asistencia (clase_id, fecha);

create function public.puede_usar_clase(clase uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.es_admin() or exists (
    select 1 from public.clases
    where id = clase and maestro_id = auth.uid()
  );
$$;

alter table public.perfiles enable row level security;
alter table public.personas enable row level security;
alter table public.clases enable row level security;
alter table public.clase_alumnos enable row level security;
alter table public.asistencia enable row level security;

-- Sin sesión iniciada no se puede leer ni escribir nada.
revoke all on all tables in schema public from anon;
revoke execute on function public.es_admin() from public, anon;
revoke execute on function public.puede_usar_clase(uuid) from public, anon;
revoke execute on function public.crear_perfil() from public, anon, authenticated;

grant select on public.perfiles to authenticated;
grant select, insert, update, delete on public.personas to authenticated;
grant select, insert, update, delete on public.clases to authenticated;
grant select, insert, update, delete on public.clase_alumnos to authenticated;
grant select, insert, update, delete on public.asistencia to authenticated;
revoke insert, update, delete on public.perfiles from authenticated;

create policy "ver perfil propio o admin" on public.perfiles
  for select to authenticated
  using (id = auth.uid() or public.es_admin());

create policy "cuentas leen personas" on public.personas
  for select to authenticated
  using (true);

create policy "admin agrega personas" on public.personas
  for insert to authenticated
  with check (public.es_admin());

create policy "admin edita personas" on public.personas
  for update to authenticated
  using (public.es_admin())
  with check (public.es_admin());

create policy "admin borra personas" on public.personas
  for delete to authenticated
  using (public.es_admin());

create policy "ver clases propias o admin" on public.clases
  for select to authenticated
  using (maestro_id = auth.uid() or public.es_admin());

create policy "crear clase propia o admin" on public.clases
  for insert to authenticated
  with check (maestro_id = auth.uid() or public.es_admin());

create policy "editar clase propia o admin" on public.clases
  for update to authenticated
  using (maestro_id = auth.uid() or public.es_admin())
  with check (maestro_id = auth.uid() or public.es_admin());

create policy "borrar clase propia o admin" on public.clases
  for delete to authenticated
  using (maestro_id = auth.uid() or public.es_admin());

create policy "alumnos de clase permitida" on public.clase_alumnos
  for all to authenticated
  using (public.puede_usar_clase(clase_id))
  with check (public.puede_usar_clase(clase_id));

create policy "asistencia de clase permitida" on public.asistencia
  for all to authenticated
  using (public.puede_usar_clase(clase_id))
  with check (public.puede_usar_clase(clase_id));

-- Cambios en vivo para el panel del administrador.
alter publication supabase_realtime add table public.clases, public.clase_alumnos, public.asistencia;
