# Registro de asistencia

Asistencia de Seminarios e Institutos para las estacas Cañete, Chincha, Ica, Nasca y Pisco.

`index.html` es la aplicación: maestros entran a su clase y el administrador ve todas las clases en vivo. Se publica tal cual en Vercel, sin paso de compilación.

## Tecnología elegida

| Parte | Elección |
|---|---|
| Frontend | HTML y JavaScript en un solo archivo, en Vercel (migrar a TypeScript y Next.js queda para más adelante) |
| Base de datos | PostgreSQL en Supabase |
| Acceso | Supabase Auth, con reglas Row Level Security |
| Tiempo real | Supabase Realtime |

## Regla de datos personales

De cada persona solo se guarda nombre, estaca y barrio. El programa (Seminario o Instituto) pertenece a la clase.

Este repositorio es público. No subas aquí nombres ni exportes de alumnos: van solo en Supabase, protegidos por RLS. En `index.html` solo va la clave pública de Supabase (`anon` o `publishable`). La clave `service_role` o `secret` nunca debe llegar al código ni al navegador.

## Base de datos

El esquema, los permisos y el tiempo real están en `supabase/migrations/`. Ejecuta los archivos en orden. Cada maestro accede a las clases que adoptó o le autorizaron; el administrador accede a todas.

## Clases

Las clases se crean desde **Todas las clases → programa → Importar clases**, con los Excel Class Roll. Los archivos en `CLASES/` y `data/` son privados y Git los ignora.
