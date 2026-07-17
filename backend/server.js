const express = require("express");
const cors = require("cors");
const mysql = require("mysql2/promise");

const app = express();

app.use(cors());
app.use(express.json());

let pool;

/**
 * Obtiene y valida la configuración requerida para iniciar el backend.
 * Las credenciales deben ser entregadas en tiempo de ejecución mediante
 * variables de entorno, Kubernetes Secrets y ConfigMaps.
 */
function getConfig() {
  const requiredEnvVars = [
    "DB_HOST",
    "DB_USER",
    "DB_PASSWORD",
    "DB_NAME",
    "DB_PORT",
  ];

  const missingEnvVars = requiredEnvVars.filter(
    (variable) =>
      typeof process.env[variable] !== "string" ||
      process.env[variable].trim() === ""
  );

  if (missingEnvVars.length > 0) {
    throw new Error(
      `Faltan variables de entorno requeridas: ${missingEnvVars.join(", ")}`
    );
  }

  const port = Number(process.env.PORT || 3001);
  const dbPort = Number(process.env.DB_PORT);

  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error("PORT debe ser un puerto válido.");
  }

  if (!Number.isInteger(dbPort) || dbPort <= 0 || dbPort > 65535) {
    throw new Error("DB_PORT debe ser un puerto válido.");
  }

  return {
    port,
    database: {
      host: process.env.DB_HOST.trim(),
      user: process.env.DB_USER.trim(),
      password: process.env.DB_PASSWORD,
      name: process.env.DB_NAME.trim(),
      port: dbPort,
    },
  };
}

/**
 * Inicializa el pool y comprueba que MySQL acepte consultas.
 */
async function initDb(databaseConfig) {
  pool = mysql.createPool({
  host: databaseConfig.host,
  user: databaseConfig.user,
  password: databaseConfig.password,
  database: databaseConfig.name,
  port: databaseConfig.port,
  charset: "utf8mb4",
  waitForConnections: true,
  connectionLimit: 10,
  queueLimit: 0,
});

  await pool.query("SELECT 1");

  console.log(
    `Conexión MySQL validada en ${databaseConfig.host}:${databaseConfig.port}/${databaseConfig.name}.`
  );
}

/**
 * Convierte y valida un identificador recibido desde la URL.
 */
function parsePositiveId(value) {
  const id = Number(value);

  if (!Number.isInteger(id) || id <= 0) {
    return null;
  }

  return id;
}

/**
 * Valida y normaliza los datos enviados para crear o actualizar productos.
 */
function validateProduct(body) {
  const { nombre, descripcion, precio, stock } = body;

  const normalizedName =
    typeof nombre === "string" ? nombre.trim() : "";

  const normalizedDescription =
    typeof descripcion === "string" && descripcion.trim() !== ""
      ? descripcion.trim()
      : null;

  const normalizedPrice = Number(precio);
  const normalizedStock = Number(stock);

  if (normalizedName === "") {
    return {
      error: "El nombre es obligatorio.",
    };
  }

  if (
    !Number.isFinite(normalizedPrice) ||
    normalizedPrice < 0
  ) {
    return {
      error: "El precio debe ser un número mayor o igual a cero.",
    };
  }

  if (
    !Number.isInteger(normalizedStock) ||
    normalizedStock < 0
  ) {
    return {
      error: "El stock debe ser un número entero mayor o igual a cero.",
    };
  }

  return {
    product: {
      nombre: normalizedName,
      descripcion: normalizedDescription,
      precio: normalizedPrice,
      stock: normalizedStock,
    },
  };
}

/**
 * Registra errores internos sin exponer detalles sensibles al cliente.
 */
function handleError(
  res,
  error,
  message = "Error interno del servidor."
) {
  console.error(message, error);

  return res.status(500).json({
    message,
  });
}

/**
 * Devuelve todos los productos.
 */
app.get("/api/productos", async (req, res) => {
  try {
    const [rows] = await pool.query(
      `SELECT id, nombre, descripcion, precio, stock
       FROM productos
       ORDER BY id DESC`
    );

    return res.json(rows);
  } catch (error) {
    return handleError(
      res,
      error,
      "No se pudieron obtener los productos."
    );
  }
});

/**
 * Devuelve un producto por su identificador.
 */
app.get("/api/productos/:id", async (req, res) => {
  const id = parsePositiveId(req.params.id);

  if (id === null) {
    return res.status(400).json({
      message: "El ID del producto debe ser un entero positivo.",
    });
  }

  try {
    const [rows] = await pool.query(
      `SELECT id, nombre, descripcion, precio, stock
       FROM productos
       WHERE id = ?`,
      [id]
    );

    if (rows.length === 0) {
      return res.status(404).json({
        message: "Producto no encontrado.",
      });
    }

    return res.json(rows[0]);
  } catch (error) {
    return handleError(
      res,
      error,
      "No se pudo obtener el producto."
    );
  }
});

/**
 * Crea un producto.
 */
app.post("/api/productos", async (req, res) => {
  const validation = validateProduct(req.body);

  if (validation.error) {
    return res.status(400).json({
      message: validation.error,
    });
  }

  const {
    nombre,
    descripcion,
    precio,
    stock,
  } = validation.product;

  try {
    const [result] = await pool.query(
      `INSERT INTO productos
        (nombre, descripcion, precio, stock)
       VALUES (?, ?, ?, ?)`,
      [nombre, descripcion, precio, stock]
    );

    const [rows] = await pool.query(
      `SELECT id, nombre, descripcion, precio, stock
       FROM productos
       WHERE id = ?`,
      [result.insertId]
    );

    return res.status(201).json(rows[0]);
  } catch (error) {
    return handleError(
      res,
      error,
      "No se pudo crear el producto."
    );
  }
});

/**
 * Actualiza un producto existente.
 */
app.put("/api/productos/:id", async (req, res) => {
  const id = parsePositiveId(req.params.id);

  if (id === null) {
    return res.status(400).json({
      message: "El ID del producto debe ser un entero positivo.",
    });
  }

  const validation = validateProduct(req.body);

  if (validation.error) {
    return res.status(400).json({
      message: validation.error,
    });
  }

  const {
    nombre,
    descripcion,
    precio,
    stock,
  } = validation.product;

  try {
    const [result] = await pool.query(
      `UPDATE productos
       SET nombre = ?,
           descripcion = ?,
           precio = ?,
           stock = ?
       WHERE id = ?`,
      [nombre, descripcion, precio, stock, id]
    );

    if (result.affectedRows === 0) {
      return res.status(404).json({
        message: "Producto no encontrado.",
      });
    }

    const [rows] = await pool.query(
      `SELECT id, nombre, descripcion, precio, stock
       FROM productos
       WHERE id = ?`,
      [id]
    );

    return res.json(rows[0]);
  } catch (error) {
    return handleError(
      res,
      error,
      "No se pudo actualizar el producto."
    );
  }
});

/**
 * Elimina un producto.
 */
app.delete("/api/productos/:id", async (req, res) => {
  const id = parsePositiveId(req.params.id);

  if (id === null) {
    return res.status(400).json({
      message: "El ID del producto debe ser un entero positivo.",
    });
  }

  try {
    const [result] = await pool.query(
      "DELETE FROM productos WHERE id = ?",
      [id]
    );

    if (result.affectedRows === 0) {
      return res.status(404).json({
        message: "Producto no encontrado.",
      });
    }

    return res.json({
      message: "Producto eliminado correctamente.",
    });
  } catch (error) {
    return handleError(
      res,
      error,
      "No se pudo eliminar el producto."
    );
  }
});

/**
 * Liveness: confirma que el proceso Express está funcionando.
 */
app.get("/api/health", (req, res) => {
  return res.json({
    status: "ok",
    message: "Backend de tienda de perritos en ejecución.",
  });
});

/**
 * Readiness: confirma que el backend puede consultar MySQL.
 */
app.get("/api/ready", async (req, res) => {
  if (!pool) {
    return res.status(503).json({
      status: "not ready",
      database: "not initialized",
    });
  }

  try {
    await pool.query("SELECT 1");

    return res.json({
      status: "ready",
      database: "connected",
    });
  } catch (error) {
    console.error(
      "La base de datos no está disponible:",
      error.message
    );

    return res.status(503).json({
      status: "not ready",
      database: "disconnected",
    });
  }
});

/**
 * Inicializa MySQL y levanta el servidor HTTP.
 */
async function startServer() {
  try {
    const config = getConfig();

    await initDb(config.database);

    return app.listen(config.port, () => {
      console.log(
        `Servidor backend escuchando en puerto ${config.port}.`
      );
    });
  } catch (error) {
    console.error(
      "No fue posible iniciar el backend:",
      error.message
    );

    process.exitCode = 1;
    return null;
  }
}

/**
 * Solo inicia el servidor cuando este archivo se ejecuta directamente.
 * Al importarlo desde las pruebas, el servidor no se levanta automáticamente.
 */
if (require.main === module) {
  startServer();
}

module.exports = {
  app,
  getConfig,
  initDb,
  parsePositiveId,
  validateProduct,
  startServer,
};