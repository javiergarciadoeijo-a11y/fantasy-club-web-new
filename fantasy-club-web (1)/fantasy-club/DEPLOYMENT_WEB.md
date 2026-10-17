# Publicar Fantasy Club Web (resumen)

1. Configura Supabase siguiendo `README.md` y valida las migraciones SQL y RLS.
2. Configura `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` en el hosting.
3. Ejecuta `npm run build` y publica `dist/` en un hosting HTTPS.
4. Prueba login, crear/unirse a liga, privacidad de votos, picks y acciones de administración con cuentas de prueba.
5. Solo entonces comparte la URL y los códigos de invitación con tus amigos.

El archivo fuente no equivale a una web ya alojada. La URL pública aparecerá cuando alguien publique `dist/` en un hosting y configure el backend.
