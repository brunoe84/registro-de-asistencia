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

Este repositorio es público. No subas aquí nombres, edades, firmas ni exportes de alumnos: esos datos van solo en Supabase, protegidos por RLS. Las claves van en las variables de entorno de Vercel, nunca en el código. La clave `service_role` de Supabase nunca debe llegar al navegador.
