#!/bin/bash
set -euo pipefail

#####################################
# CONFIGURACIÓN
#####################################
NETWORK_PROJECT_NAME="${NETWORK_PROJECT_NAME:-red-lab}"

CLUSTER_NAME="${CLUSTER_NAME:-tienda-eks}"
NODEGROUP_NAME="${NODEGROUP_NAME:-tienda-nodegroup}"

REGION="${AWS_REGION:-us-east-1}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.35}"

NODE_INSTANCE_TYPE="${NODE_INSTANCE_TYPE:-t3.medium}"
NODE_DISK_SIZE="${NODE_DISK_SIZE:-20}"

NODE_MIN_SIZE="${NODE_MIN_SIZE:-2}"
NODE_DESIRED_SIZE="${NODE_DESIRED_SIZE:-2}"
NODE_MAX_SIZE="${NODE_MAX_SIZE:-3}"

ECR_REPOSITORIES=(
  "tienda-frontend"
  "tienda-backend"
  "tienda-db"
)

echo "========================================"
echo "CREACIÓN DE AMAZON ECR Y AMAZON EKS"
echo "========================================"
echo "Región:             $REGION"
echo "Clúster:            $CLUSTER_NAME"
echo "Versión Kubernetes: $KUBERNETES_VERSION"
echo "Node Group:         $NODEGROUP_NAME"
echo "Instancias:         $NODE_INSTANCE_TYPE"
echo ""

#####################################
# FUNCIONES AUXILIARES
#####################################
resource_not_found() {
  local value="${1:-}"

  [ -z "$value" ] ||
    [ "$value" = "None" ] ||
    [ "$value" = "null" ]
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

fail() {
  echo ""
  echo "ERROR: $1" >&2
  exit 1
}

validate_integer() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    fail "$name debe ser un número entero. Valor recibido: $value"
  fi
}

get_cluster_status() {
  aws eks describe-cluster \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --query "cluster.status" \
    --output text \
    --no-cli-pager \
    2>/dev/null || true
}

get_nodegroup_status() {
  aws eks describe-nodegroup \
    --region "$REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --query "nodegroup.status" \
    --output text \
    --no-cli-pager \
    2>/dev/null || true
}

#####################################
# 0. VALIDACIONES LOCALES
#####################################
echo "0. Validando herramientas y configuración..."

command_exists aws ||
  fail "AWS CLI no está instalado o no está disponible en el PATH."

validate_integer "NODE_MIN_SIZE" "$NODE_MIN_SIZE"
validate_integer "NODE_DESIRED_SIZE" "$NODE_DESIRED_SIZE"
validate_integer "NODE_MAX_SIZE" "$NODE_MAX_SIZE"
validate_integer "NODE_DISK_SIZE" "$NODE_DISK_SIZE"

if [ "$NODE_MIN_SIZE" -gt "$NODE_DESIRED_SIZE" ]; then
  fail "NODE_MIN_SIZE no puede ser mayor que NODE_DESIRED_SIZE."
fi

if [ "$NODE_DESIRED_SIZE" -gt "$NODE_MAX_SIZE" ]; then
  fail "NODE_DESIRED_SIZE no puede ser mayor que NODE_MAX_SIZE."
fi

IDENTITY_ARN=$(aws sts get-caller-identity \
  --region "$REGION" \
  --query "Arn" \
  --output text \
  --no-cli-pager)

ACCOUNT_ID=$(aws sts get-caller-identity \
  --region "$REGION" \
  --query "Account" \
  --output text \
  --no-cli-pager)

if resource_not_found "$ACCOUNT_ID"; then
  fail "No fue posible obtener la cuenta AWS. Revisa las credenciales."
fi

echo "Credenciales AWS válidas."
echo "Cuenta AWS: $ACCOUNT_ID"
echo "Identidad:  $IDENTITY_ARN"

#####################################
# 1. DESCUBRIR LA VPC
#####################################
echo ""
echo "1. Buscando la VPC del proyecto..."

VPC_ID=$(aws ec2 describe-vpcs \
  --region "$REGION" \
  --filters \
    "Name=tag:Name,Values=${NETWORK_PROJECT_NAME}-vpc" \
    "Name=tag:Project,Values=${NETWORK_PROJECT_NAME}" \
  --query "Vpcs[0].VpcId" \
  --output text \
  --no-cli-pager)

if resource_not_found "$VPC_ID"; then
  # Compatibilidad con redes creadas antes de agregar el tag Project.
  VPC_ID=$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters \
      "Name=tag:Name,Values=${NETWORK_PROJECT_NAME}-vpc" \
    --query "Vpcs[0].VpcId" \
    --output text \
    --no-cli-pager)
fi

if resource_not_found "$VPC_ID"; then
  fail "No se encontró ${NETWORK_PROJECT_NAME}-vpc. Ejecuta primero crear-red-lab.sh."
fi

VPC_STATE=$(aws ec2 describe-vpcs \
  --region "$REGION" \
  --vpc-ids "$VPC_ID" \
  --query "Vpcs[0].State" \
  --output text \
  --no-cli-pager)

if [ "$VPC_STATE" != "available" ]; then
  fail "La VPC $VPC_ID no está disponible. Estado actual: $VPC_STATE"
fi

echo "VPC encontrada: $VPC_ID"

#####################################
# 2. DESCUBRIR SUBREDES APP
#####################################
echo ""
echo "2. Buscando subredes privadas APP..."

APP_SUBNET_A=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=tag:Name,Values=${NETWORK_PROJECT_NAME}-app-a" \
  --query "Subnets[0].SubnetId" \
  --output text \
  --no-cli-pager)

APP_SUBNET_B=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=tag:Name,Values=${NETWORK_PROJECT_NAME}-app-b" \
  --query "Subnets[0].SubnetId" \
  --output text \
  --no-cli-pager)

if resource_not_found "$APP_SUBNET_A"; then
  fail "No se encontró la subred ${NETWORK_PROJECT_NAME}-app-a."
fi

if resource_not_found "$APP_SUBNET_B"; then
  fail "No se encontró la subred ${NETWORK_PROJECT_NAME}-app-b."
fi

APP_A_AZ=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --subnet-ids "$APP_SUBNET_A" \
  --query "Subnets[0].AvailabilityZone" \
  --output text \
  --no-cli-pager)

APP_B_AZ=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --subnet-ids "$APP_SUBNET_B" \
  --query "Subnets[0].AvailabilityZone" \
  --output text \
  --no-cli-pager)

if [ "$APP_A_AZ" = "$APP_B_AZ" ]; then
  fail "Las subredes APP deben estar en zonas de disponibilidad diferentes."
fi

APP_A_PUBLIC_IP=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --subnet-ids "$APP_SUBNET_A" \
  --query "Subnets[0].MapPublicIpOnLaunch" \
  --output text \
  --no-cli-pager)

APP_B_PUBLIC_IP=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --subnet-ids "$APP_SUBNET_B" \
  --query "Subnets[0].MapPublicIpOnLaunch" \
  --output text \
  --no-cli-pager)

if [ "$APP_A_PUBLIC_IP" != "False" ] ||
  [ "$APP_B_PUBLIC_IP" != "False" ]; then
  fail "Las subredes APP deben tener deshabilitada la asignación automática de IP pública."
fi

echo "Subred APP A: $APP_SUBNET_A ($APP_A_AZ)"
echo "Subred APP B: $APP_SUBNET_B ($APP_B_AZ)"

#####################################
# 3. VALIDAR SALIDA A INTERNET
#####################################
echo ""
echo "3. Validando rutas privadas..."

for subnet_id in "$APP_SUBNET_A" "$APP_SUBNET_B"; do
  ROUTE_TARGET=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --filters "Name=association.subnet-id,Values=$subnet_id" \
    --query \
      "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId | [0]" \
    --output text \
    --no-cli-pager)

  if resource_not_found "$ROUTE_TARGET"; then
    fail "La subred $subnet_id no tiene una ruta 0.0.0.0/0 hacia un NAT Gateway."
  fi

  NAT_STATE=$(aws ec2 describe-nat-gateways \
    --region "$REGION" \
    --nat-gateway-ids "$ROUTE_TARGET" \
    --query "NatGateways[0].State" \
    --output text \
    --no-cli-pager)

  if [ "$NAT_STATE" != "available" ]; then
    fail "El NAT Gateway $ROUTE_TARGET no está disponible. Estado: $NAT_STATE"
  fi

  echo "Subred $subnet_id → NAT Gateway $ROUTE_TARGET"
done

#####################################
# 4. DESCUBRIR ROLES IAM DE ACADEMY
#####################################
echo ""
echo "4. Buscando roles IAM para Amazon EKS..."

CLUSTER_ROLE_ARN="${EKS_CLUSTER_ROLE_ARN:-}"
NODE_ROLE_ARN="${EKS_NODE_ROLE_ARN:-}"

if resource_not_found "$CLUSTER_ROLE_ARN"; then
  CLUSTER_ROLE_ARN=$(aws iam list-roles \
    --query \
      "Roles[?contains(RoleName, 'LabEksClusterRole')].Arn | [0]" \
    --output text \
    --no-cli-pager)
fi

if resource_not_found "$NODE_ROLE_ARN"; then
  NODE_ROLE_ARN=$(aws iam list-roles \
    --query \
      "Roles[?contains(RoleName, 'LabEksNodeRole')].Arn | [0]" \
    --output text \
    --no-cli-pager)
fi

if resource_not_found "$CLUSTER_ROLE_ARN"; then
  fail "No se encontró un rol que contenga LabEksClusterRole."
fi

if resource_not_found "$NODE_ROLE_ARN"; then
  fail "No se encontró un rol que contenga LabEksNodeRole."
fi

CLUSTER_ROLE_NAME="${CLUSTER_ROLE_ARN##*/}"
NODE_ROLE_NAME="${NODE_ROLE_ARN##*/}"

CLUSTER_TRUST=$(aws iam get-role \
  --role-name "$CLUSTER_ROLE_NAME" \
  --query \
    "Role.AssumeRolePolicyDocument.Statement[?Principal.Service=='eks.amazonaws.com'] | length(@)" \
  --output text \
  --no-cli-pager)

NODE_TRUST=$(aws iam get-role \
  --role-name "$NODE_ROLE_NAME" \
  --query \
    "Role.AssumeRolePolicyDocument.Statement[?Principal.Service=='ec2.amazonaws.com'] | length(@)" \
  --output text \
  --no-cli-pager)

if [ "$CLUSTER_TRUST" = "0" ]; then
  fail "El rol $CLUSTER_ROLE_NAME no confía en eks.amazonaws.com."
fi

if [ "$NODE_TRUST" = "0" ]; then
  fail "El rol $NODE_ROLE_NAME no confía en ec2.amazonaws.com."
fi

echo "Rol del clúster: $CLUSTER_ROLE_ARN"
echo "Rol de los nodos: $NODE_ROLE_ARN"

#####################################
# 5. CREAR REPOSITORIOS ECR
#####################################
echo ""
echo "5. Repositorios Amazon ECR..."

for repository in "${ECR_REPOSITORIES[@]}"; do
  if aws ecr describe-repositories \
    --region "$REGION" \
    --repository-names "$repository" \
    --no-cli-pager \
    >/dev/null 2>&1; then

    echo "Repositorio existente: $repository"
  else
    aws ecr create-repository \
      --region "$REGION" \
      --repository-name "$repository" \
      --image-tag-mutability MUTABLE \
      --image-scanning-configuration scanOnPush=true \
      --tags \
        Key=Project,Value=tienda \
        Key=Environment,Value=academic \
      --no-cli-pager \
      >/dev/null

    echo "Repositorio creado: $repository"
  fi
done

#####################################
# 6. CREAR CLÚSTER EKS
#####################################
echo ""
echo "6. Clúster Amazon EKS..."

CLUSTER_STATUS=$(get_cluster_status)

if resource_not_found "$CLUSTER_STATUS"; then
  echo "Creando clúster $CLUSTER_NAME..."

  aws eks create-cluster \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --version "$KUBERNETES_VERSION" \
    --role-arn "$CLUSTER_ROLE_ARN" \
    --resources-vpc-config \
      "subnetIds=${APP_SUBNET_A},${APP_SUBNET_B},endpointPublicAccess=true,endpointPrivateAccess=true" \
    --kubernetes-network-config \
      "ipFamily=ipv4" \
    --tags \
      Project=tienda \
      Environment=academic \
      ManagedBy=crear-eks.sh \
    --no-cli-pager \
    >/dev/null

  CLUSTER_STATUS="CREATING"
  echo "Solicitud de creación enviada."
else
  echo "El clúster ya existe."
  echo "Estado actual: $CLUSTER_STATUS"
fi

case "$CLUSTER_STATUS" in
  ACTIVE)
    echo "El clúster ya está activo."
    ;;

  CREATING | UPDATING)
    echo "Esperando que el clúster quede ACTIVE..."

    aws eks wait cluster-active \
      --region "$REGION" \
      --name "$CLUSTER_NAME"

    echo "Clúster activo."
    ;;

  FAILED | DELETING)
    fail "El clúster está en estado $CLUSTER_STATUS."
    ;;

  *)
    fail "Estado inesperado del clúster: $CLUSTER_STATUS"
    ;;
esac

CLUSTER_STATUS=$(get_cluster_status)

if [ "$CLUSTER_STATUS" != "ACTIVE" ]; then
  fail "El clúster no quedó activo. Estado actual: $CLUSTER_STATUS"
fi

ACTUAL_KUBERNETES_VERSION=$(aws eks describe-cluster \
  --region "$REGION" \
  --name "$CLUSTER_NAME" \
  --query "cluster.version" \
  --output text \
  --no-cli-pager)

if [ "$ACTUAL_KUBERNETES_VERSION" != "$KUBERNETES_VERSION" ]; then
  echo "Aviso: el clúster existente usa Kubernetes $ACTUAL_KUBERNETES_VERSION."
  echo "La variable solicitada era $KUBERNETES_VERSION."
  echo "El script no modifica automáticamente la versión de un clúster existente."
fi

#####################################
# 7. CONFIGURAR KUBECONFIG
#####################################
echo ""
echo "7. Configurando kubeconfig..."

aws eks update-kubeconfig \
  --region "$REGION" \
  --name "$CLUSTER_NAME" \
  --alias "$CLUSTER_NAME" \
  --no-cli-pager

echo "Kubeconfig actualizado."

#####################################
# 8. CREAR MANAGED NODE GROUP
#####################################
echo ""
echo "8. Managed Node Group..."

NODEGROUP_STATUS=$(get_nodegroup_status)

if resource_not_found "$NODEGROUP_STATUS"; then
  echo "Creando Node Group $NODEGROUP_NAME..."

  aws eks create-nodegroup \
    --region "$REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --node-role "$NODE_ROLE_ARN" \
    --subnets "$APP_SUBNET_A" "$APP_SUBNET_B" \
    --instance-types "$NODE_INSTANCE_TYPE" \
    --capacity-type ON_DEMAND \
    --disk-size "$NODE_DISK_SIZE" \
    --scaling-config \
      "minSize=${NODE_MIN_SIZE},maxSize=${NODE_MAX_SIZE},desiredSize=${NODE_DESIRED_SIZE}" \
    --update-config \
      "maxUnavailable=1" \
    --labels \
      "workload=tienda,environment=academic" \
    --tags \
      Project=tienda \
      Environment=academic \
      ManagedBy=crear-eks.sh \
    --no-cli-pager \
    >/dev/null

  NODEGROUP_STATUS="CREATING"
  echo "Solicitud de creación enviada."
else
  echo "El Node Group ya existe."
  echo "Estado actual: $NODEGROUP_STATUS"
fi

case "$NODEGROUP_STATUS" in
  ACTIVE)
    echo "El Node Group ya está activo."
    ;;

  CREATING | UPDATING)
    echo "Esperando que el Node Group quede ACTIVE..."

    aws eks wait nodegroup-active \
      --region "$REGION" \
      --cluster-name "$CLUSTER_NAME" \
      --nodegroup-name "$NODEGROUP_NAME"

    echo "Node Group activo."
    ;;

  CREATE_FAILED | DELETE_FAILED | DEGRADED | DELETING)
    fail "El Node Group está en estado $NODEGROUP_STATUS."
    ;;

  *)
    fail "Estado inesperado del Node Group: $NODEGROUP_STATUS"
    ;;
esac

NODEGROUP_STATUS=$(get_nodegroup_status)

if [ "$NODEGROUP_STATUS" != "ACTIVE" ]; then
  fail "El Node Group no quedó activo. Estado actual: $NODEGROUP_STATUS"
fi

#####################################
# 9. VERIFICAR KUBERNETES
#####################################
echo ""
echo "9. Verificando conexión con Kubernetes..."

if command_exists kubectl; then
  kubectl config use-context "$CLUSTER_NAME" >/dev/null

  echo ""
  kubectl get nodes -o wide

  READY_NODE_COUNT=$(kubectl get nodes \
    --no-headers \
    2>/dev/null |
    awk '$2 == "Ready" {count++} END {print count+0}')

  if [ "$READY_NODE_COUNT" -lt "$NODE_MIN_SIZE" ]; then
    echo ""
    echo "ADVERTENCIA:"
    echo "El Node Group está activo, pero solo hay $READY_NODE_COUNT nodos Ready."
    echo "Revisa nuevamente con: kubectl get nodes"
  else
    echo ""
    echo "Nodos Ready: $READY_NODE_COUNT"
  fi
else
  echo "kubectl no está instalado en este entorno."
  echo "El kubeconfig quedó preparado."
  echo ""
  echo "Cuando kubectl esté disponible, ejecuta:"
  echo "aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME"
  echo "kubectl get nodes"
fi

#####################################
# 10. OBTENER INFORMACIÓN FINAL
#####################################
echo ""
echo "10. Obteniendo información final..."

CLUSTER_ENDPOINT=$(aws eks describe-cluster \
  --region "$REGION" \
  --name "$CLUSTER_NAME" \
  --query "cluster.endpoint" \
  --output text \
  --no-cli-pager)

CLUSTER_SECURITY_GROUP=$(aws eks describe-cluster \
  --region "$REGION" \
  --name "$CLUSTER_NAME" \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" \
  --output text \
  --no-cli-pager)

NODEGROUP_ASG=$(aws eks describe-nodegroup \
  --region "$REGION" \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODEGROUP_NAME" \
  --query "nodegroup.resources.autoScalingGroups[0].name" \
  --output text \
  --no-cli-pager)

#####################################
# RESUMEN
#####################################
echo ""
echo "========================================"
echo "AMAZON EKS LISTO"
echo "========================================"
echo "Cuenta AWS:             $ACCOUNT_ID"
echo "Región:                 $REGION"
echo ""
echo "VPC:                    $VPC_ID"
echo "Subred APP A:           $APP_SUBNET_A"
echo "Subred APP B:           $APP_SUBNET_B"
echo ""
echo "Clúster EKS:            $CLUSTER_NAME"
echo "Estado clúster:         $CLUSTER_STATUS"
echo "Versión Kubernetes:     $ACTUAL_KUBERNETES_VERSION"
echo "Endpoint:               $CLUSTER_ENDPOINT"
echo "Security Group:         $CLUSTER_SECURITY_GROUP"
echo ""
echo "Node Group:             $NODEGROUP_NAME"
echo "Estado Node Group:      $NODEGROUP_STATUS"
echo "Tipo de instancia:      $NODE_INSTANCE_TYPE"
echo "Escalamiento:           $NODE_MIN_SIZE/$NODE_DESIRED_SIZE/$NODE_MAX_SIZE"
echo "Auto Scaling Group:     $NODEGROUP_ASG"
echo ""
echo "Repositorios ECR:"
for repository in "${ECR_REPOSITORIES[@]}"; do
  echo "  ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${repository}"
done
echo ""
echo "Comandos siguientes:"
echo "  aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME"
echo "  kubectl get nodes"
echo "  kubectl get pods --all-namespaces"
echo "========================================"