-- Informe para presidentes de estaca: listas de nombres detrás de cada cifra, para verlas también
-- desde el celular (donde no se pueden leer los Excel de Wise).
-- Solo nombres (sin edades ni fechas), por estaca. Se reemplazan cada vez que se vuelve a contar.
-- Las políticas de informe_estacas (solo administrador) se aplican también a esta columna.

alter table public.informe_estacas add column if not exists nombres jsonb not null default '{}'::jsonb;

notify pgrst, 'reload schema';
