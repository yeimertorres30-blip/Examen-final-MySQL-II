/* 
PASO 1
Seleccionamos la base de datos del proyecto coworking_db para trabajar sobre ella.
*/
USE coworking_db;

/* 
PASO 2
Eliminamos la tabla reservas_externas si ya existe (para poder volver a crearla sin error).
Luego la creamos con los campos solicitados: id, plataforma, fecha_reserva, espacio_id, 
usuario_externo y duración. Se agregaron campos adicionales necesarios para el funcionamiento 
(hora_inicio, estado, id_reserva_interna, motivo_rechazo y fecha_registro).
También se definen las claves foráneas hacia espacio y reserva, un CHECK para validar 
que la duración sea positiva y los índices para mejorar el rendimiento de las búsquedas.
*/

DROP TABLE IF EXISTS reservas_externas;

CREATE TABLE reservas_externas (
    id INT AUTO_INCREMENT PRIMARY KEY,
    plataforma VARCHAR(50)  NOT NULL,
    fecha_reserva DATE NOT NULL,
    hora_inicio TIME NOT NULL DEFAULT '09:00:00',
    espacio_id INT NOT NULL,
    usuario_externo VARCHAR(150) NOT NULL,
    duracion INT NOT NULL COMMENT 'Duración en horas',
    estado ENUM('pendiente','importada','rechazada') NOT NULL DEFAULT 'pendiente',
    id_reserva_interna  INT NULL,
    motivo_rechazo VARCHAR(255) NULL,
    fecha_registro DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    CONSTRAINT fk_reservas_ext_espacio 
        FOREIGN KEY (espacio_id) REFERENCES espacio(id_espacio)
        ON DELETE RESTRICT ON UPDATE CASCADE,
        
    CONSTRAINT fk_reservas_ext_reserva 
        FOREIGN KEY (id_reserva_interna) REFERENCES reserva(id_reserva)
        ON DELETE SET NULL ON UPDATE CASCADE,
        
    CONSTRAINT chk_duracion CHECK (duracion > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE INDEX idx_reservas_ext_plataforma ON reservas_externas(plataforma);
CREATE INDEX idx_reservas_ext_fecha      ON reservas_externas(fecha_reserva);
CREATE INDEX idx_reservas_ext_estado     ON reservas_externas(estado);

/* 
PASO 3
Creamos el procedimiento sp_importar_reserva_externa.
Este procedimiento recibe el id de una reserva externa y hace lo siguiente:
1. Lee los datos de la reserva externa.
2. Valida que exista y que esté en estado pendiente.
3. Calcula la hora de fin sumando la duración.
4. Verifica que el espacio exista y no esté en mantenimiento.
5. Valida que no haya conflicto de horario con reservas internas existentes.
6. Busca un usuario temporal por email o lo crea si no existe.
7. Inserta la reserva interna en estado confirmada.
8. Marca la reserva externa como importada y guarda el id de la reserva interna.
9. Registra la operación en la tabla de auditoría.
*/

DELIMITER $$

DROP PROCEDURE IF EXISTS sp_importar_reserva_externa$$

CREATE PROCEDURE sp_importar_reserva_externa(
    IN  p_id_reserva_externa INT,
    OUT p_id_reserva_interna INT,
    OUT p_mensaje            VARCHAR(255)
)
BEGIN
    DECLARE v_plataforma VARCHAR(50);
    DECLARE v_fecha DATE;
    DECLARE v_hora_inicio TIME;
    DECLARE v_espacio_id INT;
    DECLARE v_usuario_ext VARCHAR(150);
    DECLARE v_duracion INT;
    DECLARE v_estado_ext VARCHAR(20);
    DECLARE v_hora_fin TIME;
    DECLARE v_id_usuario INT;
    DECLARE v_solapado INT DEFAULT 0;
    DECLARE v_estado_espacio VARCHAR(20);
    DECLARE v_doc_temporal VARCHAR(20);
    DECLARE v_email_temporal VARCHAR(100);

    -- Leer la reserva externa
    SELECT plataforma, fecha_reserva, hora_inicio, espacio_id, 
           usuario_externo, duracion, estado
    INTO   v_plataforma, v_fecha, v_hora_inicio, v_espacio_id,
           v_usuario_ext, v_duracion, v_estado_ext
    FROM   reservas_externas
    WHERE  id = p_id_reserva_externa;

    -- Validar que exista
    IF v_plataforma IS NULL THEN
        SIGNAL SQLSTATE '45000' 
        SET MESSAGE_TEXT = 'Error: La reserva externa no existe.';
    END IF;

    -- Solo se importan las que están pendientes
    IF v_estado_ext <> 'pendiente' THEN
        SIGNAL SQLSTATE '45000' 
        SET MESSAGE_TEXT = 'Error: Solo se pueden importar reservas en estado pendiente.';
    END IF;

    -- Calcular hora de fin
    SET v_hora_fin = ADDTIME(v_hora_inicio, SEC_TO_TIME(v_duracion * 3600));

    -- Verificar el espacio
    SELECT estado_disponibilidad 
    INTO   v_estado_espacio
    FROM   espacio
    WHERE  id_espacio = v_espacio_id;

    IF v_estado_espacio IS NULL THEN
        SIGNAL SQLSTATE '45000' 
        SET MESSAGE_TEXT = 'Error: El espacio indicado no existe.';
    END IF;

    -- Si el espacio está en mantenimiento se rechaza
    IF v_estado_espacio = 'mantenimiento' THEN
        UPDATE reservas_externas
        SET estado = 'rechazada',
            motivo_rechazo = 'Espacio en mantenimiento'
        WHERE id = p_id_reserva_externa;

        SET p_id_reserva_interna = NULL;
        SET p_mensaje = 'Reserva rechazada: el espacio está en mantenimiento.';
    ELSE
        -- Validar que no haya solapamiento de horarios
        SELECT COUNT(*) 
        INTO   v_solapado
        FROM   reserva
        WHERE  id_espacio = v_espacio_id
          AND  fecha_reserva = v_fecha
          AND  estado_reserva IN ('pendiente', 'confirmada')
          AND  (v_hora_inicio < hora_fin AND v_hora_fin > hora_inicio);

        IF v_solapado > 0 THEN
            UPDATE reservas_externas
            SET estado = 'rechazada',
                motivo_rechazo = CONCAT('Conflicto de horario con ', v_solapado, ' reserva(s) existente(s)')
            WHERE id = p_id_reserva_externa;

            SET p_id_reserva_interna = NULL;
            SET p_mensaje = 'Reserva rechazada por conflicto de horario.';
        ELSE
            -- Buscar o crear usuario temporal
            SET v_email_temporal = CONCAT(
                LOWER(REPLACE(REPLACE(v_usuario_ext, ' ', '.'), '@', '')),
                '@externo.', LOWER(v_plataforma), '.tmp'
            );

            SELECT id_usuario 
            INTO   v_id_usuario
            FROM   usuario
            WHERE  email = v_email_temporal
            LIMIT  1;

            IF v_id_usuario IS NULL THEN
                SET v_doc_temporal = CONCAT('EXT-', LPAD(FLOOR(RAND() * 999999), 6, '0'));

                INSERT INTO usuario (
                    tipo_documento, tipo_usuario, numero_documento,
                    primer_nombre, primer_apellido,
                    fecha_nacimiento, email
                ) VALUES (
                    'CC', 'comun', v_doc_temporal,
                    SUBSTRING_INDEX(v_usuario_ext, ' ', 1),
                    IF(LOCATE(' ', v_usuario_ext) > 0,
                       SUBSTRING(v_usuario_ext, LOCATE(' ', v_usuario_ext) + 1),
                       'Externo'),
                    '1990-01-01',
                    v_email_temporal
                );

                SET v_id_usuario = LAST_INSERT_ID();

                INSERT INTO log_auditoria (tabla_afectada, operacion, descripcion)
                VALUES ('usuario', 'INSERT',
                        CONCAT('Usuario temporal creado desde ', v_plataforma,
                               ' - ID: ', v_id_usuario));
            END IF;

            -- Crear la reserva interna
            INSERT INTO reserva (
                id_usuario, id_espacio, fecha_reserva,
                hora_inicio, hora_fin, numero_asistentes, estado_reserva
            ) VALUES (
                v_id_usuario, v_espacio_id, v_fecha,
                v_hora_inicio, v_hora_fin, 1, 'confirmada'
            );

            SET p_id_reserva_interna = LAST_INSERT_ID();

            -- Marcar la externa como importada
            UPDATE reservas_externas
            SET estado = 'importada',
                id_reserva_interna = p_id_reserva_interna,
                motivo_rechazo = NULL
            WHERE id = p_id_reserva_externa;

            INSERT INTO log_auditoria (tabla_afectada, operacion, descripcion)
            VALUES ('reserva', 'INSERT',
                    CONCAT('Reserva externa ID ', p_id_reserva_externa,
                           ' convertida a reserva interna ID ', p_id_reserva_interna));

            SET p_mensaje = CONCAT('Importación exitosa. Reserva interna ID: ', p_id_reserva_interna);
        END IF;
    END IF;
END$$

DELIMITER ;

/* 
PASO 4
Insertamos 5 registros de ejemplo en la tabla reservas_externas 
para poder probar el procedimiento de importación.
*/

INSERT INTO reservas_externas 
    (plataforma, fecha_reserva, hora_inicio, espacio_id, usuario_externo, duracion)
VALUES
    ('Airbnb',    '2026-10-15', '10:00:00', 1, 'Carlos Mendoza', 3),
    ('Meetup',    '2026-10-16', '14:00:00', 2, 'Ana Torres Meetup', 2),
    ('Eventbrite','2026-10-17', '09:00:00', 3, 'Luis Ramírez', 4),
    ('Airbnb',    '2026-10-18', '11:00:00', 1, 'Sofía Vargas', 2),
    ('Meetup',    '2026-10-20', '16:00:00', 4, 'Pedro Gómez', 1);



/* 
PASO 5
Ejemplo de prueba del procedimiento:
Se llama al procedimiento con el id 1, se guardan los resultados 
en variables de sesión y luego se consultan para verificar 
que la reserva externa se convirtió correctamente en una reserva interna.
*/


CALL sp_importar_reserva_externa(1, @id_reserva, @msg);
SELECT @id_reserva AS id_reserva_creada, @msg AS resultado;

SELECT * FROM reservas_externas WHERE id = 1;
SELECT * FROM reserva WHERE id_reserva = @id_reserva;
SELECT * FROM usuario WHERE email LIKE '%@externo.%';
