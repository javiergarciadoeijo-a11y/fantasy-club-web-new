# Backend Supabase — Fantasy Club v6.0

Orden de ejecución en SQL Editor:
1. `schema-foundation.sql`
2. `v6-functions.sql`

El primer archivo crea las tablas base y políticas iniciales; el segundo añade las funciones transaccionales de acceso, selecciones, voto, estadísticas, disponibilidad, cancelación, reapertura, cierre y recálculo.

## Alta inicial
1. Crea tu usuario administrador en Supabase Authentication (por invitación desde el panel del proyecto).
2. Inicia sesión en Fantasy Club.
3. En la pantalla de configuración crea la liga privada. El creador queda como admin.
4. Copia el código de invitación que aparece en Inicio y compártelo solo con tus participantes.
5. Invita primero sus correos en Supabase Auth; luego podrán iniciar sesión y usar el código.

## Advertencias importantes
- No se debe usar una clave `service_role` en la app.
- Ejecuta las pruebas con usuarios separados antes de datos reales.
- El proyecto necesita revisión de seguridad SQL/RLS antes de producción. El SQL es un punto de partida implementable, no una certificación de seguridad.
- La auditoría de aplicación registra acciones y motivos; un administrador de infraestructura con acceso SQL podría modificar la base de datos. Para un registro legalmente inmutable se requiere almacenamiento externo append-only.
