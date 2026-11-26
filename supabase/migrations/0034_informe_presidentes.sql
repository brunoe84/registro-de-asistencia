-- Informe para presidentes de estaca (Informes · Presidentes de estaca).
-- La app lo cuenta en el navegador del administrador con Potenciales.xlsx y Programados.xlsx de Wise.
-- Aquí se guardan SOLO los totales por barrio y estaca (sin nombres, edades ni fechas de personas),
-- más los datos del encabezado que escribe el administrador (presidente, responsable, teléfono, correo, nota).

create table if not exists public.informe_estacas (
  estaca text primary key,
  datos jsonb not null default '{}'::jsonb,
  cabecera jsonb not null default '{}'::jsonb,
  actualizado_en timestamptz not null default now()
);

alter table public.informe_estacas enable row level security;

drop policy if exists "admin ve informe estacas" on public.informe_estacas;
create policy "admin ve informe estacas" on public.informe_estacas
  for select to authenticated using (public.es_admin());
drop policy if exists "admin crea informe estacas" on public.informe_estacas;
create policy "admin crea informe estacas" on public.informe_estacas
  for insert to authenticated with check (public.es_admin());
drop policy if exists "admin cambia informe estacas" on public.informe_estacas;
create policy "admin cambia informe estacas" on public.informe_estacas
  for update to authenticated using (public.es_admin()) with check (public.es_admin());

revoke all on public.informe_estacas from anon;
grant select, insert, update on public.informe_estacas to authenticated;

notify pgrst, 'reload schema';
