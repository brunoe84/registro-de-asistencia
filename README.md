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

Excepción: quien se registra con el QR de una clase sin estar en su lista deja su cédula de la Iglesia, usuario de la Iglesia, fecha de nacimiento y celular para inscribirlo en Wise2. Esos datos están en la tabla `inscripciones` y **solo el administrador** los puede ver.

Este repositorio es público. No subas aquí nombres ni exportes de alumnos: van solo en Supabase, protegidos por RLS. En `index.html` solo va la clave pública de Supabase (`anon` o `publishable`). La clave `service_role` o `secret` nunca debe llegar al código ni al navegador.

## Base de datos

El esquema, los permisos y el tiempo real están en `supabase/migrations/`. Ejecuta los archivos en orden. Cada maestro accede a las clases que adoptó o le autorizaron; el administrador accede a todas.

## Clases

Las clases se crean desde **Todas las clases → programa → Importar clases**, con los Excel Class Roll. Los archivos en `CLASES/` y `data/` son privados y Git los ignora.

El maestro que entra desde otro celular o la PC pide acceso con su nombre: si coincide al menos un nombre y un apellido con el maestro de la clase, entra al instante. Con otro nombre, la solicitud espera la aprobación del administrador.

Para invitar a un colaborador, el maestro elige en **Compartir** cuánto durará el acceso (1 semana, 1 mes o todo el periodo) y envía el código de invitación. Cada código sirve para una sola persona; al usarse aparece otro. El código fijo de la clase no da acceso.

Las clases que un maestro creó en su dispositivo antes de la base en línea aparecen en el inicio: la app busca su clase en línea (por alumnos, maestro y curso) y, si él confirma, suma sus alumnos y su asistencia sin cambiar lo que ya estaba marcado.

## Eventos

Los eventos se guardan en línea: el organizador y quienes entran con el código del evento (EV-…) marcan en la misma lista.

En **Compartir → QR de asistencia** el organizador crea un QR. El asistente lo escanea, busca su nombre (o escribe sus datos si no está en la base) y puede anotar a quienes vinieron con él. Su celular lo recuerda para los siguientes eventos. Los acompañantes quedan **por aprobar** hasta que un colaborador confirma que vinieron, o hasta que ellos mismos escanean el QR. El QR solo funciona desde el día antes hasta el día después del evento, y para buscar en la base hay que escribir nombre y apellido.

En la pestaña **Grupos** se reparte la lista al azar en grupos del mismo tamaño, con 0, 1 o 2 líderes por grupo.

## Base de personas

Al subir el export de Potenciales de Wise se guardan nombre, estaca, barrio y programa (columna *Program Name*). El maestro filtra por programa, estaca y barrio al agregar alumnos.

## Recordatorios

La función `supabase/functions/recordatorios` avisa al celular de los maestros con más de una semana de atraso. La base de datos la ejecuta a las 7:00, 12:00, 17:00 y 22:00 (hora de Perú). Sus claves privadas están solo en los secretos de Supabase.
