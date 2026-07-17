const request = require("supertest");

const {
  app,
  parsePositiveId,
  validateProduct,
} = require("../server");

describe("Funciones de validación", () => {
  describe("parsePositiveId", () => {
    test("acepta un identificador entero positivo", () => {
      expect(parsePositiveId("5")).toBe(5);
    });

    test("rechaza cero, negativos y valores no numéricos", () => {
      expect(parsePositiveId("0")).toBeNull();
      expect(parsePositiveId("-2")).toBeNull();
      expect(parsePositiveId("abc")).toBeNull();
    });
  });

  describe("validateProduct", () => {
    test("acepta un producto válido y normaliza sus datos", () => {
      const result = validateProduct({
        nombre: "  Alimento premium  ",
        descripcion: "  Bolsa de alimento  ",
        precio: "15990",
        stock: "10",
      });

      expect(result).toEqual({
        product: {
          nombre: "Alimento premium",
          descripcion: "Bolsa de alimento",
          precio: 15990,
          stock: 10,
        },
      });
    });

    test("rechaza un producto sin nombre", () => {
      const result = validateProduct({
        nombre: " ",
        descripcion: "Producto",
        precio: 1000,
        stock: 1,
      });

      expect(result.error).toBe("El nombre es obligatorio.");
    });

    test("rechaza precios negativos", () => {
      const result = validateProduct({
        nombre: "Producto",
        descripcion: null,
        precio: -1,
        stock: 1,
      });

      expect(result.error).toBe(
        "El precio debe ser un número mayor o igual a cero."
      );
    });

    test("rechaza stock negativo o decimal", () => {
      const negativeStock = validateProduct({
        nombre: "Producto",
        descripcion: null,
        precio: 1000,
        stock: -1,
      });

      const decimalStock = validateProduct({
        nombre: "Producto",
        descripcion: null,
        precio: 1000,
        stock: 1.5,
      });

      expect(negativeStock.error).toBe(
        "El stock debe ser un número entero mayor o igual a cero."
      );

      expect(decimalStock.error).toBe(
        "El stock debe ser un número entero mayor o igual a cero."
      );
    });
  });
});

describe("API del backend", () => {
  test("GET /api/health responde HTTP 200", async () => {
    const response = await request(app).get("/api/health");

    expect(response.statusCode).toBe(200);
    expect(response.body).toEqual({
      status: "ok",
      message: "Backend de tienda de perritos en ejecución.",
    });
  });

  test("GET /api/ready responde 503 si MySQL no está inicializado", async () => {
    const response = await request(app).get("/api/ready");

    expect(response.statusCode).toBe(503);
    expect(response.body).toEqual({
      status: "not ready",
      database: "not initialized",
    });
  });

  test("GET de una ruta inexistente responde 404", async () => {
    const response = await request(app).get("/api/ruta-inexistente");

    expect(response.statusCode).toBe(404);
  });

  test("GET /api/productos/:id rechaza un ID inválido", async () => {
    const response = await request(app).get("/api/productos/abc");

    expect(response.statusCode).toBe(400);
    expect(response.body.message).toBe(
      "El ID del producto debe ser un entero positivo."
    );
  });

  test("POST /api/productos rechaza datos inválidos", async () => {
    const response = await request(app)
      .post("/api/productos")
      .send({
        nombre: "",
        precio: 1000,
        stock: 2,
      });

    expect(response.statusCode).toBe(400);
    expect(response.body.message).toBe(
      "El nombre es obligatorio."
    );
  });
});