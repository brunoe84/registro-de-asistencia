-- "Al día en Wise": el administrador marca una clase cuando ya pasó su asistencia a Wise2.
-- La marca vale mientras el maestro no haga cambios nuevos (ultimo_cambio_maestro posterior la anula).

alter table public.clases add column if not exists wise_al_dia_en timestamptz;

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
  if not public.es_admin() then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  update public.clases c set wise_al_dia_en = v where c.id = clase;
  return v;
end;
$$;
revoke execute on function public.marcar_clase_wise(uuid, boolean) from public, anon;
grant execute on function public.marcar_clase_wise(uuid, boolean) to authenticated;

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
  return query select c.id, c.wise_al_dia_en from public.clases c where c.wise_al_dia_en is not null;
end;
$$;
revoke execute on function public.clases_wise_al_dia() from public, anon;
grant execute on function public.clases_wise_al_dia() to authenticated;