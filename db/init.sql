SET NAMES utf8mb4;
SET CHARACTER SET utf8mb4;

CREATE DATABASE IF NOT EXISTS tienda_perritos
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;

USE tienda_perritos;

CREATE TABLE IF NOT EXISTS productos (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    nombre VARCHAR(100) NOT NULL,
    descripcion VARCHAR(255),
    precio DECIMAL(10,2) UNSIGNED NOT NULL,
    stock INT UNSIGNED NOT NULL DEFAULT 0,
    CONSTRAINT uq_productos_nombre UNIQUE (nombre)
) CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;

INSERT IGNORE INTO productos (nombre, descripcion, precio, stock) VALUES
('Alimento Cachorro Premium', 'Sabor a pollo, razas pequeñas', 19990.00, 15),
('Alimento Adulto Light', 'Control de peso, razas medianas', 17990.00, 8),
('Snacks Dentales', 'Ayuda a la limpieza dental', 5990.00, 30),
('Alimento Adulto Pedigree', 'Sabor carne', 15990.00, 40),
('Bravery Pollo Adulto Raza Pequeña', 'Sabor a pollo', 25990.00, 20);