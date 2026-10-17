# Matriz de pruebas de aceptación — Reglamento v6.0

Antes de abrir una liga real, ejecutar y documentar estos casos con usuarios de prueba.

## Puntuación individual
- 0–4 goles = 0 puntos por goles; 5–9 = 1; 10–14 = 2.
- 0–2 asistencias = 0; 3–5 = 1; 6–8 = 2.
- Cada victoria añade 1; cada bloque completo de 2 derrotas resta 1; empates no alteran la puntuación.
- Verificar que los restos no se trasladan a otra jornada.
- Verificar que una fuente manual sustituye a eventos y viceversa; la fuente previa debe quedar en historial.

## MVP
- Orden 1/2/3 produce 3/2/1 puntos de voto.
- Empate de voto se resuelve por más votos de primera posición.
- Si persiste, gana el mayor resultado base.
- Si persiste, todos los empatados son MVP.
- Todos los MVP compartidos con base positiva reciben ×1,5, aunque sus bases difieran; base cero o negativa no se multiplica.
- Ausencia de voto de un participante no invalida los votos restantes.
- Candidatos no disponibles al abrir no se pueden votar.

## Fantasy
- Se exige exactamente 3 IDs distintos y disponibles.
- Una selección inválida o ausente puntúa 0 en esa jornada.
- Si el jugador no participó, su aporte fantasy es 0.
- Los tres elegidos se bloquean en la siguiente jornada oficial cerrada.
- Una jornada cancelada no consume la restricción.
- Primera jornada: no hay jugadores bloqueados.
- Antes de abrir, validar que todos los participantes activos tengan al menos tres jugadores elegibles.

## Ciclo de jornada
- Cierre bloquea votos y selecciones y calcula resultados una sola vez sin duplicar acumulados.
- Cierre no permitido hasta confirmar que las estadísticas están completas.
- Cancelación elimina resultados de esa jornada, no otorga MVP y no cuenta como jornada oficial disputada.
- Reapertura bloquea votos/selecciones por defecto y solo permite las acciones seleccionadas explícitamente por admin.
- Corrección posterior al cierre recalcula puntos, MVP y fantasy sin duplicar resultados.

## Seguridad
- Participante A no puede leer votos/selecciones de B antes del cierre.
- Participante no puede llamar funciones administrativas con éxito.
- Usuario sin membresía no puede leer datos de la liga.
- Código de invitación incorrecto es rechazado.
- Todos los cambios administrativos exigen motivo y generan auditoría.
- No hay claves privadas en el cliente ni en el repositorio.
