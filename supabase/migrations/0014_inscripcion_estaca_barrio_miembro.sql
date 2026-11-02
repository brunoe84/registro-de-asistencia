-- Datos de inscripción completos de quien no está en la lista: estaca, barrio, si es miembro de la
-- Iglesia y, solo si lo es, cédula de miembro y usuario de su cuenta de la Iglesia; además fecha
-- de nacimiento y celular. Al aprobarlo, se agrega a la clase con su estaca y barrio.

create or replace function public.datos_inscripcion(d jsonb)
returns jsonb
language sql
immutable
as $$
  select coalesce(jsonb_object_agg(k, left(trim(d ->> k), 80)), '{}'::jsonb)
  from unnest(array['estaca', 'barrio', 'miembro', 'cedula', 'usuario', 'nacimiento', 'celular']) k
  where coalesce(trim(d ->> k), '') <> ''
    -- Cédula y usuario solo si dijo que es miembro.
    and (k not in ('cedula', 'usuario') or coalesce(d ->> 'miembro', 'si') = 'si');
$$;

create or replace function public.resolver_qr_clase(solicitud uuid, aprobar boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  q public.asistencia_qr%rowtype;
  p public.personas%rowtype;
  ins jsonb;
  al uuid;
begin
  select * into q from public.asistencia_qr x where x.id = solicitud;
  if q.id is null then
    return;
  end if;
  if not public.puede_usar_clase(q.clase_id) then
    raise exception 'No tienes acceso a esta clase';
  end if;
  if q.estado <> 'pendiente' then
    return;
  end if;
  if aprobar then
    al := q.alumno_id;
    if al is null then
      if q.persona_id is not null then
        select * into p from public.personas x where x.id = q.persona_id;
      end if;
      select i.datos into ins from public.inscripciones i where i.qr_id = q.id limit 1;
      select x.id into al from public.clase_alumnos x
      where x.clase_id = q.clase_id and ((p.id is not null and x.persona_id = p.id) or x.clave = public.norm_nombre(q.nombre))
      limit 1;
      if al is null then
        insert into public.clase_alumnos (clase_id, persona_id, nombre, estaca, barrio)
        values (q.clase_id, p.id, q.nombre, coalesce(p.estaca, ins ->> 'estaca', ''), coalesce(p.barrio, ins ->> 'barrio', ''))
        on conflict do nothing
        returning id into al;
      end if;
      if al is null then
        select x.id into al from public.clase_alumnos x
        where x.clase_id = q.clase_id and ((p.id is not null and x.persona_id = p.id) or x.clave = public.norm_nombre(q.nombre))
        limit 1;
      end if;
      update public.clase_alumnos x set retirado_en = null where x.id = al;
      update public.inscripciones i set alumno_id = al where i.qr_id = q.id;
    end if;
    insert into public.asistencia (clase_id, alumno_id, fecha, estado, marcado_por)
    values (q.clase_id, al, q.fecha, 'P', auth.uid())
    on conflict (alumno_id, fecha) do update set estado = 'P', marcado_por = auth.uid(), actualizado_en = now();
    update public.asistencia_qr x set estado = 'aprobada', alumno_id = al, resuelto_en = now() where x.id = q.id;
  else
    update public.asistencia_qr x set estado = 'rechazada', resuelto_en = now() where x.id = q.id;
    delete from public.inscripciones i where i.qr_id = q.id and i.atendida_en is null;
  end if;
end;
$$;

notify pgrst, 'reload schema';
