-- En Seminario la inscripción por QR también pide datos del padre o la madre: nombre (ya existía como
-- "tutor"), celular, correo y dirección de la casa. Solo el administrador los ve.

create or replace function public.datos_inscripcion(d jsonb)
returns jsonb
language sql
immutable
as $$
  select coalesce(jsonb_object_agg(k, left(trim(d ->> k), case when k = 'direccion' then 160 else 80 end)), '{}'::jsonb)
  from unnest(array['estaca', 'barrio', 'miembro', 'cedula', 'usuario', 'nacimiento', 'celular', 'acuerdo',
    'tutor', 'tutor_celular', 'tutor_correo', 'direccion']) k
  where coalesce(trim(d ->> k), '') <> ''
    and (k not in ('cedula', 'usuario') or coalesce(d ->> 'miembro', 'si') = 'si');
$$;

notify pgrst, 'reload schema';
