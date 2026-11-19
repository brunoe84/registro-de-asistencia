-- Audit de Wise ("Audit - Marking Attendance"): clases con retraso en marcar la asistencia.
-- El administrador lo lee de la carpeta "DEL DÍA" junto con el Class Roll; se guarda la última versión.

create table if not exists public.wise_audit (
  id smallint primary key default 1 check (id = 1),
  filas jsonb not null default '[]',   -- [{ programa, estaca, maestro, curso, seccion, hora, desde, sesiones }]
  archivo text not null default '',
  archivo_en timestamptz,
  actualizado_en timestamptz not null default now()
);
alter table public.wise_audit enable row level security;
revoke all on public.wise_audit from public, anon, authenticated;

create or replace function public.cargar_audit(filas jsonb, archivo text, archivo_en timestamptz)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  insert into public.wise_audit as a (id, filas, archivo, archivo_en, actualizado_en)
  values (1, coalesce(filas, '[]'::jsonb), coalesce(archivo, ''), archivo_en, now())
  on conflict (id) do update set filas = excluded.filas, archivo = excluded.archivo, archivo_en = excluded.archivo_en, actualizado_en = now();
  return jsonb_array_length(coalesce(filas, '[]'::jsonb));
end;
$$;

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
  return query select a.filas, a.archivo, a.archivo_en, a.actualizado_en from public.wise_audit a where a.id = 1;
end;
$$;

revoke execute on function public.cargar_audit(jsonb, text, timestamptz) from public, anon;
revoke execute on function public.audit_admin() from public, anon;
grant execute on function public.cargar_audit(jsonb, text, timestamptz) to authenticated;
grant execute on function public.audit_admin() to authenticated;
