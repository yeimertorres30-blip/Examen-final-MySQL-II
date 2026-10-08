# Examen-final-MySQL-II

Integración de Reservas Externas para el sistema de Gestión de Coworking.

![Prueba del procedimiento](https://github.com/user-attachments/assets/3dd22627-4333-4bb7-86a0-e15629cbcf2a)

## Descripción

Este repositorio contiene el script desarrollado para el examen final de MySQL II.  
Se implementó la integración de reservas provenientes de plataformas externas (Airbnb, Meetup, Eventbrite, etc.) dentro de la base de datos `coworking_db`.

## Contenido del archivo

**`06_integracion_reservas_externas.sql`**

El script realiza lo siguiente:

1. **Crea la tabla `reservas_externas`**  
   Con los campos solicitados: `id`, `plataforma`, `fecha_reserva`, `espacio_id`, `usuario_externo` y `duracion`, además de campos de control (`estado`, `id_reserva_interna`, `motivo_rechazo`, etc.).

2. **Crea el procedimiento `sp_importar_reserva_externa`**  
   Que:
   - Lee la reserva externa
   - Valida que exista y esté pendiente
   - Calcula la hora de fin
   - Verifica el estado del espacio
   - Valida que no existan conflictos de horario con reservas internas
   - Crea un usuario temporal si no existe
   - Genera la reserva interna en estado `confirmada`
   - Marca la reserva externa como `importada`
   - Registra la operación en `log_auditoria`

3. **Inserta datos de ejemplo** para realizar pruebas.

4. **Incluye el ejemplo de ejecución** del procedimiento.

## Cómo ejecutar

1. Tener creada y poblada la base de datos `coworking_db` (estructura + datos iniciales).
2. Ejecutar el script completo en MySQL Workbench o cliente MySQL.
3. Probar con:

```sql
CALL sp_importar_reserva_externa(1, @id_reserva, @msg);
SELECT @id_reserva AS id_reserva_creada, @msg AS resultado;
