# Fantasy Club Web — versión web privada

Aplicación web responsive para iPhone, Android y ordenador. Puede añadirse a la pantalla de inicio como acceso directo/PWA. Mantiene el reglamento funcional v6.0 definido para Fantasy Club; no se han cambiado las reglas de puntuación, MVP, selecciones, restricciones de repetición, jornadas ni auditoría.

## Estado actual

Este es un paquete de desarrollo, **no un sitio publicado ni un servicio listo para producción**. Incluye frontend, manifiesto web, esquema SQL y funciones del servidor. Antes de invitar a la liga hay que configurar Supabase y ejecutar y validar las migraciones en un proyecto real. El SQL incluido no se ha probado contra una instancia real de PostgreSQL/Supabase en este entorno.

## Requisitos
- Node.js 20 o superior y npm.
- Un proyecto Supabase para autenticación y base de datos.
- Un servicio de hosting estático con HTTPS (por ejemplo, Netlify, Vercel o Cloudflare Pages).

## Configurar Supabase
1. Crea un proyecto en Supabase.
2. En SQL Editor ejecuta `backend/schema-foundation.sql` y después `backend/v6-functions.sql`.
3. Antes de producción, revisa y prueba las políticas RLS, permisos y funciones con una cuenta administradora y dos cuentas participantes. No uses datos reales hasta pasar las pruebas de `docs/PRUEBAS_REGLAS_V6.md`.
4. En Authentication, desactiva el registro público si la liga debe ser solo por invitación. El administrador invita a las cuentas desde Supabase Auth; cada participante inicia sesión y usa el código de la liga.
5. Configura las URLs de redirección de autenticación para el dominio final.
6. Nunca publiques la clave `service_role`. En el navegador solo se usa la clave pública `anon`/publishable.

## Ejecutar localmente
```bash
npm install
cp .env.example .env
# Completa VITE_SUPABASE_URL y VITE_SUPABASE_ANON_KEY en .env
npm run dev
```

## Crear versión de producción
```bash
npm run build
npm run preview
```
La salida de producción queda en `dist/`. Publica esa carpeta en un hosting estático con HTTPS. En el panel del hosting, define las variables de entorno `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` antes de construir.

### Netlify (ejemplo)
- Build command: `npm run build`
- Publish directory: `dist`
- Añade las dos variables `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` en Site configuration → Environment variables.
- Vuelve a desplegar tras configurar variables.

### Vercel (ejemplo)
- Framework: Vite
- Build command: `npm run build`
- Output directory: `dist`
- Añade las dos variables de entorno y despliega.

## Instalar en los móviles
- **iPhone:** abre el enlace HTTPS en Safari → Compartir → Añadir a pantalla de inicio.
- **Android:** abre el enlace HTTPS en Chrome → menú ⋮ → Instalar aplicación o Añadir a pantalla de inicio (la opción depende del dispositivo).
- También se puede compartir simplemente el enlace web. Cada amigo necesitará su propia cuenta autorizada y el código de invitación de la liga.

## Reglas v6.0
La puntuación individual es `floor(goles/5) + floor(asistencias/3) + victorias - floor(derrotas/2)`. Los empates valen cero y los restos no se arrastran. El voto MVP es secreto hasta el cierre, con puntuación 3/2/1 y desempates definidos en v6.0; MVP compartidos con puntos base positivos reciben multiplicador 1,5. Cada participante elige tres jugadores; se aplican los bloqueos de repetición, la regla de jornada cancelada, las estadísticas confirmadas y la auditoría obligatoria según v6.0.

## Antes de abrir la liga
- Ejecutar y validar todas las migraciones SQL en Supabase.
- Probar privacidad de votos y selecciones antes del cierre.
- Probar empates, MVP compartido, puntuaciones negativas/cero, cancelaciones, correcciones y reaperturas.
- Revisar las políticas de acceso por liga y el registro de auditoría.
