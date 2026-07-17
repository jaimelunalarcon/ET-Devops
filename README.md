# ET-Devops

Proyecto de automatización DevOps desarrollado para la Evaluación Final Transversal.

La solución implementa una arquitectura basada en contenedores utilizando **Docker**, **Kubernetes**, **Amazon EKS**, **Amazon ECR** y **GitHub Actions**, permitiendo automatizar el ciclo completo desde el desarrollo hasta el despliegue continuo en la nube.

---

# Arquitectura

```text
                     GitHub
                        │
                        ▼
                GitHub Actions
                        │
        ┌───────────────┼────────────────┐
        │               │                │
        ▼               ▼                ▼
     Tests         Docker Build      Amazon ECR
                        │
                        ▼
                  Amazon EKS
                        │
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
     Frontend       Backend         MySQL
```

---

# Tecnologías

- Node.js
- Express
- MySQL 8
- Docker
- Kubernetes
- Amazon EKS
- Amazon ECR
- GitHub Actions
- Amazon CloudWatch
- Jest
- Supertest

---

# Estructura del proyecto

```text
ET-Devops/
│
├── .github/
│   └── workflows/
│
├── backend/
├── frontend/
├── db/
├── k8s/
├── scripts/
│
├── docker-compose.yml
├── README.md
└── .gitignore
```

---

# Arquitectura Kubernetes

La aplicación se despliega sobre un clúster de **Amazon EKS** utilizando los siguientes recursos:

| Recurso | Función |
|----------|---------|
| Namespace | Aísla todos los recursos de la aplicación (`tienda`). |
| Deployment | Administra los Pods del Frontend, Backend y MySQL. |
| Service | Permite la comunicación interna y externa de la aplicación. |
| ConfigMap | Almacena la configuración no sensible. |
| Secret | Almacena las credenciales de la base de datos. |
| PVC | Proporciona almacenamiento persistente para MySQL mediante Amazon EBS. |
| HPA | Escala automáticamente el Backend según el uso de CPU (70%, mínimo 2 y máximo 8 réplicas). |

---

# Pipeline CI/CD

El proyecto implementa un pipeline completamente automatizado mediante **GitHub Actions**.

## Flujo

```text
Push
   │
   ▼
Tests (Jest)
   │
   ▼
Docker Build
   │
   ▼
Push Amazon ECR
   │
   ▼
Deploy Amazon EKS
   │
   ▼
Rolling Update
```

## Etapas

- **Push:** inicia automáticamente el pipeline.
- **Tests:** ejecuta 11 pruebas automatizadas utilizando Jest y Supertest.
- **Docker Build:** construye una nueva imagen del Backend.
- **Push ECR:** publica la imagen en Amazon Elastic Container Registry.
- **Deploy EKS:** actualiza el Deployment utilizando la nueva imagen.
- **Rolling Update:** Kubernetes reemplaza los Pods sin interrumpir el servicio.

---

# Despliegue

## 1. Crear la infraestructura de red

```bash
./scripts/crear-red-lab.sh
```

Crea la VPC, subredes, NAT Gateway y recursos de red necesarios.

## 2. Crear EKS y ECR

```bash
./scripts/crear-eks.sh
```

Crea el clúster Amazon EKS, el Node Group y los repositorios Amazon ECR.

## 3. Desplegar Kubernetes

```bash
kubectl apply -f k8s/
```

Despliega todos los recursos de la aplicación dentro del namespace `tienda`.

---

# Verificaciones

Comprobar el estado de la aplicación:

```bash
kubectl get pods -n tienda

kubectl get deployments -n tienda

kubectl get svc -n tienda

kubectl get hpa -n tienda

kubectl rollout status deployment/tienda-backend -n tienda
```

---

# API

Comprobar el estado del Backend:

```bash
curl http://<LOAD_BALANCER_URL>/api/health
```

Verificar la conexión con la base de datos:

```bash
curl http://<LOAD_BALANCER_URL>/api/ready
```

Obtener el listado de productos:

```bash
curl http://<LOAD_BALANCER_URL>/api/productos
```

---

# Tests

El Backend incorpora pruebas automatizadas utilizando:

- Jest
- Supertest

Actualmente el proyecto cuenta con **11 pruebas automatizadas**, las cuales son ejecutadas automáticamente antes de construir la imagen Docker dentro del pipeline CI/CD.

---

# Acceso a la aplicación

```
http://a70aa376952eb41c2af33223df8991a7-1632640155.us-east-1.elb.amazonaws.com/
```

---

# Autores

**KArla Blanco - Katherine Cuestas - Jaime Luna**

Ingeniería en Informática — Duoc UC

Proyecto desarrollado para la Evaluación Final Transversal de Introducción a Herramientas devops_803V.