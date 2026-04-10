-- ============================================================
-- SISTEMA DE GESTION DE PATICO DETALLES
-- Base de datos: bdpep
-- Fecha: 09 de abril de 2026
-- ============================================================
/*
\c postgres
drop database bdpep;
create database bdpep;
\c bdpep
*/
--Creacion de las tablas

create table tmstatus(
pkid integer not null primary key,
descripcion text not null);

--Insertar datos de status
insert into tmstatus(pkid,descripcion) values
(0,'Inactivo'),
(1,'Activo');

CREATE TABLE tmreabastecer(
    pkcodigo text NOT NULL PRIMARY KEY,
    categoria text NOT NULL,
    nombre text NOT NULL,
    foto bytea,
    fecha_adquisicion DATE NOT NULL,
    fecha_vencimiento DATE NULL DEFAULT NULL,
    notas text NOT NULL,
    comprobado_por text NOT NULL,
    proveedor text NOT NULL,
    precio_unitario numeric(15,2) NOT NULL,
    cantidad numeric(5) NOT NULL,
    costo_total numeric(15,2) NOT NULL,
    fkid integer NOT NULL DEFAULT 1,
    FOREIGN KEY(fkid) REFERENCES tmstatus(pkid) ON UPDATE CASCADE ON DELETE RESTRICT
);

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
total_venta NUMERIC(20,2) NOT NULL,
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

-- Indice unico parcial: permite como maximo una notificacion no leida por producto
CREATE UNIQUE INDEX IF NOT EXISTS ux_notif_unread_per_product ON tmnotificaciones(fkcodigo) WHERE leida = false;

-- Crear tabla permanente de detalles de venta en lugar de temporal
CREATE TABLE tdventas (
    id_detalle SERIAL PRIMARY KEY,
    fknum_factura integer,
    fkcodigo text,
    cantidad numeric(5),
    FOREIGN KEY (fknum_factura) REFERENCES tmventas(pknum_factura),
    FOREIGN KEY (fkcodigo) REFERENCES tmreabastecer(pkcodigo)
);

-- Crear funcion por detalle que actualiza inventario y notificaciones
CREATE OR REPLACE FUNCTION fn_actualizar_inventario_detalle()
RETURNS TRIGGER AS $$
BEGIN
    -- Reducir inventario para este detalle
    UPDATE tdinventario
    SET restantes = GREATEST(0, restantes - NEW.cantidad)
    WHERE fkcodigo = NEW.fkcodigo;

    -- Si no existia fila de inventario, crearla
    IF NOT FOUND THEN
        INSERT INTO tdinventario(fkcodigo, restantes, fkid)
        SELECT NEW.fkcodigo, GREATEST(0, cantidad - NEW.cantidad), 1
        FROM tmreabastecer WHERE pkcodigo = NEW.fkcodigo;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Crear trigger de actualizacion de inventario sobre detalles (tdventas)
CREATE TRIGGER tr_actualizar_inventario
AFTER INSERT ON tdventas
FOR EACH ROW
EXECUTE FUNCTION fn_actualizar_inventario_detalle();

--Insertar datos de usuarios

insert into tmusuarios(pkusuario,contra,cargo) values
('admin','ad123','Administrador');

-- Funcion y trigger: Reportar stock bajo cuando tdinventario.restantes < 10
-- Evita duplicar notificaciones si ya existe una no leida para el mismo producto
CREATE OR REPLACE FUNCTION fn_reportar_stock_bajo()
RETURNS TRIGGER AS $$
BEGIN
    -- Para INSERT: si ya viene con menos de 10
    IF TG_OP = 'INSERT' THEN
        IF NEW.restantes < 10 THEN
            IF EXISTS (SELECT 1 FROM tmnotificaciones WHERE fkcodigo = NEW.fkcodigo AND leida = false) THEN
                -- Actualizar la notificacion no-leida existente con el nuevo mensaje y timestamp
                UPDATE tmnotificaciones
                SET mensaje = 'ALERTA: Quedan ' || NEW.restantes || ' unidades de ' || COALESCE((SELECT nombre FROM tmreabastecer WHERE pkcodigo = NEW.fkcodigo), NEW.fkcodigo),
                    fecha_creacion = CURRENT_TIMESTAMP
                WHERE fkcodigo = NEW.fkcodigo AND leida = false;
            ELSE
                -- Insertar nueva notificacion si no existe una no-leida
                BEGIN
                    INSERT INTO tmnotificaciones(fkcodigo, mensaje)
                    VALUES (NEW.fkcodigo, 'ALERTA: Quedan ' || NEW.restantes || ' unidades de ' || COALESCE((SELECT nombre FROM tmreabastecer WHERE pkcodigo = NEW.fkcodigo), NEW.fkcodigo));
                EXCEPTION WHEN unique_violation THEN
                    -- insercion concurrente, ignorar
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
