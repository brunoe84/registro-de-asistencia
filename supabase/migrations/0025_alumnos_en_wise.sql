-- Marca "ya está en Wise2" por alumno de clase (solo la ve y la cambia el administrador).
-- Sirve para cruzar la lista que llevó el maestro con la lista "Scheduled Students" de Wise2:
-- el administrador pega esa lista en la Planilla y el sistema marca a quienes coinciden.
-- Quien queda sin marca es nuevo: falta inscribirlo en Wise.

alter table public.clase_alumnos add column if not exists en_wise_en timestamptz;

-- si: alumnos que están en Wise; no: alumnos que NO están (se les quita la marca).
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
  if not public.es_admin() then
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
revoke execute on function public.marcar_en_wise(uuid, uuid[], uuid[]) from public, anon;
grant execute on function public.marcar_en_wise(uuid, uuid[], uuid[]) to authenticated;