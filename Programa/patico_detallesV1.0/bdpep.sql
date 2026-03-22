--   	\i C:/Users/EDWARD/OneDrive/Escritorio/Tarea/Ingenieria/Programa/patico_detallesV1.0/bdpep.sql
--      \i C:/Users/Paula/OneDrive/Escritorio/patico_detalles/bdpep.sql
-- Si falta un disparador meter lo de fecha actualizacion en la ventana de reabastecer

\c postgres
drop database bdpep;
create database bdpep;
\c bdpep

--Creacion de las tablas

create table tmstatus(
pkid integer not null primary key,
descripcion text not null);

--Insertar datos de status
insert into tmstatus(pkid,descripcion) values
(0,'Inactivo'),
(1,'Activo');

create table tmreabastecer(
pkcodigo text not null primary key,
categoria text not null,
nombre text not null,
foto bytea, -- Removido el NOT NULL para hacer la foto opcional
fecha_adquisicion text not null,
fecha_vencimiento text not null default 'No aplica',
notas text not null,
comprobado_por text not null,
proveedor text not null,
precio_unitario numeric(15,2) not null,
cantidad numeric(5) not null,
costo_total numeric(15,2) not null,
fkid integer not null default 1,
foreign key(fkid) references tmstatus(pkid) on update cascade on delete restrict);

create table tdinventario(
fkcodigo text not null primary key,
restantes numeric(5) not null,
fkid integer not null,
foreign key(fkid) references tmstatus(pkid) on update cascade on delete restrict,
foreign key(fkcodigo) references tmreabastecer(pkcodigo) on update cascade on delete restrict);

create table tmventas(
pknum_factura SERIAL PRIMARY KEY,
nombre TEXT NOT NULL,
fecha_venta date NOT NULL DEFAULT CURRENT_DATE,
archivo BYTEA NOT NULL,
total_venta Numeric(20) not null,
fkid integer not null default 1,
foreign key(fkid) references tmstatus(pkid) on update cascade on delete restrict);

create table tmusuarios(
pkusuario text not null primary key,
contra text not null,
cargo text not null,
fkid integer not null default 1,
foreign key(fkid) references tmstatus(pkid) on update cascade on delete restrict);

-- Crear tabla para notificaciones
CREATE TABLE tmnotificaciones (
    id_notificacion SERIAL PRIMARY KEY,
    fkcodigo text NOT NULL,
    mensaje TEXT NOT NULL,
    fecha_creacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    leida BOOLEAN DEFAULT FALSE,
    FOREIGN KEY (fkcodigo) REFERENCES tmreabastecer(pkcodigo)
);

-- Índice único parcial: permite como máximo una notificación no leída por producto
CREATE UNIQUE INDEX IF NOT EXISTS ux_notif_unread_per_product ON tmnotificaciones(fkcodigo) WHERE leida = false;

-- Crear tabla permanente de detalles de venta en lugar de temporal
CREATE TABLE tdventas (
    id_detalle SERIAL,
    fknum_factura integer,
    fkcodigo text,
    cantidad numeric(5),
    FOREIGN KEY (fknum_factura) REFERENCES tmventas(pknum_factura),
    FOREIGN KEY (fkcodigo) REFERENCES tmreabastecer(pkcodigo)
);



-- Función para actualizar inventario (simplificada y corregida)
CREATE OR REPLACE FUNCTION fn_actualizar_inventario()
RETURNS TRIGGER AS $$
BEGIN
    -- Reducir inventario basado en los detalles de venta
    WITH detalles_venta AS (
        SELECT fkcodigo, SUM(cantidad) as total_vendido
        FROM tdventas
        WHERE fknum_factura = NEW.pknum_factura
        GROUP BY fkcodigo
    )
    UPDATE tdinventario i
    SET restantes = GREATEST(0, i.restantes - dv.total_vendido)
    FROM detalles_venta dv
    WHERE i.fkcodigo = dv.fkcodigo;

    -- Generar notificaciones para productos con stock bajo
    -- Usar ON CONFLICT para evitar duplicados aun en condiciones de carrera
    -- Insertar notificación solo si no existe ya una no leída para el mismo producto
    -- Construir conjunto de productos con stock bajo y mensaje actualizado
    WITH low AS (
        SELECT 
            i.fkcodigo,
            'ALERTA: Quedan ' || i.restantes || ' unidades de ' || r.nombre AS mensaje
        FROM tdinventario i
        JOIN tmreabastecer r ON r.pkcodigo = i.fkcodigo
        WHERE i.restantes < 10
    )
    -- 1) Actualizar notificaciones no leídas existentes con el nuevo mensaje y timestamp
    UPDATE tmnotificaciones n
    SET mensaje = l.mensaje,
        fecha_creacion = CURRENT_TIMESTAMP
    FROM low l
    WHERE n.fkcodigo = l.fkcodigo
      AND n.leida = false;

    -- 2) Insertar nuevas notificaciones para productos que no tienen una no-leída
    BEGIN
        INSERT INTO tmnotificaciones(fkcodigo, mensaje)
        SELECT i.fkcodigo,
               'ALERTA: Quedan ' || i.restantes || ' unidades de ' || r.nombre
        FROM tdinventario i
        JOIN tmreabastecer r ON r.pkcodigo = i.fkcodigo
        WHERE i.restantes < 10
          AND NOT EXISTS (
              SELECT 1 FROM tmnotificaciones n2 WHERE n2.fkcodigo = i.fkcodigo AND n2.leida = false
          );
    EXCEPTION WHEN unique_violation THEN
        -- Inserción concurrente: otra transacción creó la notificación, ignorar
        NULL;
    END;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;



-- Crear función por detalle que actualiza inventario y notificaciones
CREATE OR REPLACE FUNCTION fn_actualizar_inventario_detalle()
RETURNS TRIGGER AS $$
BEGIN
    -- Reducir inventario para este detalle
    UPDATE tdinventario
    SET restantes = GREATEST(0, restantes - NEW.cantidad)
    WHERE fkcodigo = NEW.fkcodigo;

    -- Si no existía fila de inventario, crearla basada en tmreabastecer.cantidad
    IF NOT FOUND THEN
        INSERT INTO tdinventario(fkcodigo, restantes, fkid)
        SELECT NEW.fkcodigo, GREATEST(0, cantidad - NEW.cantidad), 1
        FROM tmreabastecer WHERE pkcodigo = NEW.fkcodigo;
    END IF;

    -- Obtener el stock actual para decidir notificación
    -- Usar subselect para obtener el valor actualizado
    PERFORM 1;

    IF (SELECT restantes FROM tdinventario WHERE fkcodigo = NEW.fkcodigo) < 10 THEN
        -- Si hay notificación no-leída existente, actualizar mensaje y fecha
        IF EXISTS (SELECT 1 FROM tmnotificaciones WHERE fkcodigo = NEW.fkcodigo AND leida = false) THEN
            UPDATE tmnotificaciones
            SET mensaje = 'ALERTA: Quedan ' || (SELECT restantes FROM tdinventario WHERE fkcodigo = NEW.fkcodigo) || ' unidades de ' || COALESCE((SELECT nombre FROM tmreabastecer WHERE pkcodigo = NEW.fkcodigo), NEW.fkcodigo),
                fecha_creacion = CURRENT_TIMESTAMP
            WHERE fkcodigo = NEW.fkcodigo AND leida = false;
        ELSE
            -- Insertar nueva notificación (tolerante a carrera)
            BEGIN
                INSERT INTO tmnotificaciones(fkcodigo, mensaje)
                VALUES (
                    NEW.fkcodigo,
                    'ALERTA: Quedan ' || (SELECT restantes FROM tdinventario WHERE fkcodigo = NEW.fkcodigo) || ' unidades de ' || COALESCE((SELECT nombre FROM tmreabastecer WHERE pkcodigo = NEW.fkcodigo), NEW.fkcodigo)
                );
            EXCEPTION WHEN unique_violation THEN
                NULL;
            END;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Crear trigger de actualización de inventario sobre detalles (tdventas)
CREATE TRIGGER tr_actualizar_inventario
AFTER INSERT ON tdventas
FOR EACH ROW
EXECUTE FUNCTION fn_actualizar_inventario_detalle();

--Insertar datos de usuarios

insert into tmusuarios(pkusuario,contra,cargo) values
('admin','ad123','Administrador');

-- Función y trigger: Reportar stock bajo cuando tdinventario.restantes < 10
-- Evita duplicar notificaciones si ya existe una no leída para el mismo producto
CREATE OR REPLACE FUNCTION fn_reportar_stock_bajo()
RETURNS TRIGGER AS $$
BEGIN
    -- Para INSERT: si ya viene con menos de 10
    IF TG_OP = 'INSERT' THEN
        IF NEW.restantes < 10 THEN
            IF EXISTS (SELECT 1 FROM tmnotificaciones WHERE fkcodigo = NEW.fkcodigo AND leida = false) THEN
                -- Actualizar la notificación no-leída existente con el nuevo mensaje y timestamp
                UPDATE tmnotificaciones
                SET mensaje = 'ALERTA: Quedan ' || NEW.restantes || ' unidades de ' || COALESCE((SELECT nombre FROM tmreabastecer WHERE pkcodigo = NEW.fkcodigo), NEW.fkcodigo),
                    fecha_creacion = CURRENT_TIMESTAMP
                WHERE fkcodigo = NEW.fkcodigo AND leida = false;
            ELSE
                -- Insertar nueva notificación si no existe una no-leída
                BEGIN
                    INSERT INTO tmnotificaciones(fkcodigo, mensaje)
                    VALUES (NEW.fkcodigo, 'ALERTA: Quedan ' || NEW.restantes || ' unidades de ' || COALESCE((SELECT nombre FROM tmreabastecer WHERE pkcodigo = NEW.fkcodigo), NEW.fkcodigo));
                EXCEPTION WHEN unique_violation THEN
                    -- inserción concurrente, ignorar
                    NULL;
                END;
            END IF;
        END IF;

    -- Para UPDATE: solo cuando se cruza el umbral (antes >=10 y ahora <10)
    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW.restantes < 10 AND (OLD.restantes IS NULL OR OLD.restantes >= 10) THEN
            IF EXISTS (SELECT 1 FROM tmnotificaciones WHERE fkcodigo = NEW.fkcodigo AND leida = false) THEN
                UPDATE tmnotificaciones
                SET mensaje = 'ALERTA: Quedan ' || NEW.restantes || ' unidades de ' || COALESCE((SELECT nombre FROM tmreabastecer WHERE pkcodigo = NEW.fkcodigo), NEW.fkcodigo),
                    fecha_creacion = CURRENT_TIMESTAMP
                WHERE fkcodigo = NEW.fkcodigo AND leida = false;
            ELSE
                BEGIN
                    INSERT INTO tmnotificaciones(fkcodigo, mensaje)
                    VALUES (NEW.fkcodigo, 'ALERTA: Quedan ' || NEW.restantes || ' unidades de ' || COALESCE((SELECT nombre FROM tmreabastecer WHERE pkcodigo = NEW.fkcodigo), NEW.fkcodigo));
                EXCEPTION WHEN unique_violation THEN
                    NULL;
                END;
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER tr_reportar_stock_bajo
AFTER INSERT OR UPDATE ON tdinventario
FOR EACH ROW
EXECUTE FUNCTION fn_reportar_stock_bajo();



















