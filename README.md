# Registro de asistencia

Asistencia de Seminarios e Institutos para las estacas Cañete, Chincha, Ica, Nasca y Pisco.

`index.html` es la aplicación actual de check-in, sin la base de personas. Es el punto de partida de la migración.

## Tecnología elegida

| Parte | Elección |
|---|---|
| Lenguaje | TypeScript |
| Frontend y servidor | Next.js en Vercel |
| Base de datos | PostgreSQL en Supabase |
| Acceso | Supabase Auth, con reglas Row Level Security |
| Tiempo real | Supabase Realtime |

## Regla de datos personales

De cada persona solo se guarda nombre, estaca y barrio. El programa (Seminario o Instituto) pertenece a la clase.

Este repositorio es público. No subas aquí nombres ni exportes de alumnos: van solo en Supabase, protegidos por RLS. Las claves van en las variables de entorno de Vercel, nunca en el código. La clave `service_role` de Supabase nunca debe llegar al navegador.

## Base de datos

El esquema, los permisos y el tiempo real están en `supabase/migrations/0001_esquema_inicial.sql`. Cada maestro accede a sus clases y el administrador a todas.
