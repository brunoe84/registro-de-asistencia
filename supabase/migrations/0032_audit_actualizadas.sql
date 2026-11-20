-- Audit · Clases con retraso: el administrador marca una clase cuando ya la puso al día en Wise2.
-- La marca vale mientras el Audit / Class Roll leídos sean anteriores a ella; si un Excel más nuevo
-- la sigue mostrando con retraso, el cliente la vuelve a mostrar como pendiente.

create table if not exists public.audit_actualizadas (
  clave text primary key,               -- clave de la clase de Wise (wise_clases.clave) o "a:..." si no está vinculada
  marcado_en timestamptz not null default now()
);
alter table public.audit_actualizadas enable row level security;
revoke all on public.audit_actualizadas from public, anon, authenticated;

create or replace function public.marcar_audit_actualizada(clave text, hecho boolean)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  v timestamptz := now();
begin
  if not public.es_admin() then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  if hecho then
    insert into public.audit_actualizadas as a (clave, marcado_en) values (clave, v)
    on conflict on constraint audit_actualizadas_pkey do update set marcado_en = v;
    return v;
  end if;
  delete from public.audit_actualizadas a where a.clave = clave;
  return null;
end;
$$;

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
  return query select a.clave, a.marcado_en from public.audit_actualizadas a;
end;
$$;

revoke execute on function public.marcar_audit_actualizada(text, boolean) from public, anon;
revoke execute on function public.audit_actualizadas_admin() from public, anon;
grant execute on function public.marcar_audit_actualizada(text, boolean) to authenticated;
grant execute on function public.audit_actualizadas_admin() to authenticated;
