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

CLOUDWATCH_ENABLED="${CLOUDWATCH_ENABLED:-true}"
CLOUDWATCH_ROLE_NAME="${CLOUDWATCH_ROLE_NAME:-${CLUSTER_NAME}-cloudwatch-role}"
CLOUDWATCH_ROLE_ARN="${CLOUDWATCH_ROLE_ARN:-}"

ECR_REPOSITORIES=(
  "tienda-frontend"
  "tienda-backend"
  "tienda-db"
)

CONTROL_PLANE_LOG_TYPES=(
  "api"
  "audit"
  "authenticator"
  "controllerManager"
  "scheduler"
)

echo "========================================"
echo "CREACIÓN DE AMAZON ECR Y AMAZON EKS"
echo "========================================"
echo "Región:             $REGION"
echo "Clúster:            $CLUSTER_NAME"
echo "Versión Kubernetes: $KUBERNETES_VERSION"
echo "Node Group:         $NODEGROUP_NAME"
echo "Instancias:         $NODE_INSTANCE_TYPE"
echo "CloudWatch:         $CLOUDWATCH_ENABLED"
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

warning() {
  echo ""
  echo "ADVERTENCIA: $1" >&2
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

get_addon_status() {
  local addon_name="$1"

  aws eks describe-addon \
    --region "$REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name "$addon_name" \
    --query "addon.status" \
    --output text \
    --no-cli-pager \
    2>/dev/null || true
}

wait_for_cluster_active() {
  local attempts=90
  local current_attempt=1
  local status

  echo "Esperando que el clúster $CLUSTER_NAME quede ACTIVE..."

  while [ "$current_attempt" -le "$attempts" ]; do
    status=$(get_cluster_status)

    case "$status" in
      ACTIVE)
        echo "Clúster activo."
        return 0
        ;;

      CREATING | UPDATING)
        echo "Estado del clúster: $status. Reintento ${current_attempt}/${attempts}..."
        ;;

      FAILED)
        fail "El clúster quedó en estado FAILED."
        ;;

      DELETING)
        fail "El clúster está siendo eliminado."
        ;;

      "")
        echo "El clúster todavía no es visible. Reintento ${current_attempt}/${attempts}..."
        ;;

      None | null)
        echo "El clúster todavía no es visible. Reintento ${current_attempt}/${attempts}..."
        ;;

      *)
        echo "Estado temporal o desconocido: $status. Reintento ${current_attempt}/${attempts}..."
        ;;
    esac

    sleep 10
    current_attempt=$((current_attempt + 1))
  done

  fail "El clúster no quedó ACTIVE después de 15 minutos."
}

wait_for_addon() {
  local addon_name="$1"
  local attempts=60
  local current_attempt=1
  local status

  echo "Esperando que el add-on $addon_name quede ACTIVE..."

  while [ "$current_attempt" -le "$attempts" ]; do
    status=$(get_addon_status "$addon_name")

    case "$status" in
      ACTIVE)
        echo "Add-on activo: $addon_name"
        return 0
        ;;

      CREATE_FAILED | UPDATE_FAILED | DELETE_FAILED | DEGRADED)
        fail "El add-on $addon_name quedó en estado $status."
        ;;

      *)
        echo "Add-on $addon_name en estado ${status:-no-visible}. Reintento ${current_attempt}/${attempts}..."
        sleep 10
        ;;
    esac

    current_attempt=$((current_attempt + 1))
  done

  fail "El add-on $addon_name no quedó ACTIVE."
}

create_or_update_addon() {
  local addon_name="$1"
  local configuration_values="${2:-}"
  local status

  status=$(get_addon_status "$addon_name")

  if resource_not_found "$status"; then
    echo "Instalando add-on: $addon_name"

    if [ -n "$configuration_values" ]; then
      aws eks create-addon \
        --region "$REGION" \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name "$addon_name" \
        --configuration-values "$configuration_values" \
        --resolve-conflicts OVERWRITE \
        --no-cli-pager \
        >/dev/null
    else
      aws eks create-addon \
        --region "$REGION" \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name "$addon_name" \
        --resolve-conflicts OVERWRITE \
        --no-cli-pager \
        >/dev/null
    fi
  else
    echo "Actualizando add-on existente: $addon_name"

    if [ -n "$configuration_values" ]; then
      aws eks update-addon \
        --region "$REGION" \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name "$addon_name" \
        --configuration-values "$configuration_values" \
        --resolve-conflicts OVERWRITE \
        --no-cli-pager \
        >/dev/null
    else
      aws eks update-addon \
        --region "$REGION" \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name "$addon_name" \
        --resolve-conflicts OVERWRITE \
        --no-cli-pager \
        >/dev/null
    fi
  fi

  wait_for_addon "$addon_name"
}

#####################################
# 0. VALIDACIONES
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
  fail "La VPC $VPC_ID no está disponible. Estado: $VPC_STATE"
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
  fail "No se encontró ${NETWORK_PROJECT_NAME}-app-a."
fi

if resource_not_found "$APP_SUBNET_B"; then
  fail "No se encontró ${NETWORK_PROJECT_NAME}-app-b."
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
# 3. VALIDAR RUTAS PRIVADAS
#####################################
echo ""
echo "3. Validando salida mediante NAT Gateway..."

for subnet_id in "$APP_SUBNET_A" "$APP_SUBNET_B"; do
  ROUTE_TARGET=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --filters "Name=association.subnet-id,Values=$subnet_id" \
    --query \
      "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId | [0]" \
    --output text \
    --no-cli-pager)

  if resource_not_found "$ROUTE_TARGET"; then
    fail "La subred $subnet_id no tiene una ruta hacia un NAT Gateway."
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
# 4. DESCUBRIR ROLES IAM DE EKS
#####################################
echo ""
echo "4. Buscando roles IAM de Amazon EKS..."

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
  fail "No se encontró un rol LabEksClusterRole."
fi

if resource_not_found "$NODE_ROLE_ARN"; then
  fail "No se encontró un rol LabEksNodeRole."
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
# 5. REPOSITORIOS ECR
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
    --kubernetes-network-config "ipFamily=ipv4" \
    --logging \
      '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}' \
    --tags \
      Project=tienda \
      Environment=academic \
      ManagedBy=crear-eks.sh \
    --no-cli-pager \
    >/dev/null

  echo "Solicitud de creación enviada."

  wait_for_cluster_visibility
  CLUSTER_STATUS=$(get_cluster_status)
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

   wait_for_cluster_active

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
  fail "El clúster no quedó activo. Estado: $CLUSTER_STATUS"
fi

ACTUAL_KUBERNETES_VERSION=$(aws eks describe-cluster \
  --region "$REGION" \
  --name "$CLUSTER_NAME" \
  --query "cluster.version" \
  --output text \
  --no-cli-pager)

#####################################
# 7. LOGS DEL CONTROL PLANE
#####################################
echo ""
echo "7. Configurando logs del plano de control..."

LOGGING_ENABLED=$(aws eks describe-cluster \
  --region "$REGION" \
  --name "$CLUSTER_NAME" \
  --query \
    "cluster.logging.clusterLogging[?enabled==\`true\`].types[]" \
  --output text \
  --no-cli-pager)

MISSING_CONTROL_PLANE_LOGS=false

for log_type in "${CONTROL_PLANE_LOG_TYPES[@]}"; do
  if [[ " $LOGGING_ENABLED " != *" $log_type "* ]]; then
    MISSING_CONTROL_PLANE_LOGS=true
    break
  fi
done

if [ "$MISSING_CONTROL_PLANE_LOGS" = "true" ]; then
  aws eks update-cluster-config \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --logging \
      '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}' \
    --no-cli-pager \
    >/dev/null

  echo "Actualización de logging enviada."

  wait_for_cluster_active 

else
  echo "Los logs del plano de control ya están habilitados."
fi

#####################################
# 8. CONFIGURAR KUBECONFIG
#####################################
echo ""
echo "8. Configurando kubeconfig..."

aws eks update-kubeconfig \
  --region "$REGION" \
  --name "$CLUSTER_NAME" \
  --alias "$CLUSTER_NAME" \
  --no-cli-pager

echo "Kubeconfig actualizado."

#####################################
# 9. CREAR MANAGED NODE GROUP
#####################################
echo ""
echo "9. Managed Node Group..."

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
    --update-config "maxUnavailable=1" \
    --labels \
      "workload=tienda,environment=academic" \
    --tags \
      Project=tienda \
      Environment=academic \
      ManagedBy=crear-eks.sh \
    --no-cli-pager \
    >/dev/null

  echo "Solicitud de creación enviada."

  wait_for_nodegroup_visibility
  NODEGROUP_STATUS=$(get_nodegroup_status)
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
  fail "El Node Group no quedó activo. Estado: $NODEGROUP_STATUS"
fi

#####################################
# 10. EKS POD IDENTITY AGENT
#####################################
if [ "$CLOUDWATCH_ENABLED" = "true" ]; then
  echo ""
  echo "10. Instalando EKS Pod Identity Agent..."

  create_or_update_addon "eks-pod-identity-agent"

  if command_exists kubectl; then
    kubectl rollout status \
      daemonset/eks-pod-identity-agent \
      --namespace kube-system \
      --timeout=300s
  fi
else
  echo ""
  echo "10. CloudWatch deshabilitado."
fi

#####################################
# 11. ROL IAM PARA CLOUDWATCH
#####################################
if [ "$CLOUDWATCH_ENABLED" = "true" ]; then
  echo ""
  echo "11. Configurando rol IAM para CloudWatch..."

  if resource_not_found "$CLOUDWATCH_ROLE_ARN"; then
    EXISTING_CLOUDWATCH_ROLE_ARN=$(aws iam get-role \
      --role-name "$CLOUDWATCH_ROLE_NAME" \
      --query "Role.Arn" \
      --output text \
      --no-cli-pager \
      2>/dev/null || true)

    if resource_not_found "$EXISTING_CLOUDWATCH_ROLE_ARN"; then
      TRUST_POLICY_FILE=$(mktemp)

      cat > "$TRUST_POLICY_FILE" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
EOF

      if ! CLOUDWATCH_ROLE_ARN=$(aws iam create-role \
        --role-name "$CLOUDWATCH_ROLE_NAME" \
        --assume-role-policy-document "file://${TRUST_POLICY_FILE}" \
        --description "Rol Pod Identity para CloudWatch Observability en ${CLUSTER_NAME}" \
        --tags \
          Key=Project,Value=tienda \
          Key=Environment,Value=academic \
          Key=ManagedBy,Value=crear-eks.sh \
        --query "Role.Arn" \
        --output text \
        --no-cli-pager); then

        rm -f "$TRUST_POLICY_FILE"

        fail "AWS Academy no permitió crear $CLOUDWATCH_ROLE_NAME. Proporciona CLOUDWATCH_ROLE_ARN."
      fi

      rm -f "$TRUST_POLICY_FILE"
      echo "Rol CloudWatch creado: $CLOUDWATCH_ROLE_ARN"
    else
      CLOUDWATCH_ROLE_ARN="$EXISTING_CLOUDWATCH_ROLE_ARN"
      echo "Rol CloudWatch existente: $CLOUDWATCH_ROLE_ARN"
    fi
  else
    echo "Usando rol CloudWatch proporcionado: $CLOUDWATCH_ROLE_ARN"
  fi

  CLOUDWATCH_ROLE_NAME="${CLOUDWATCH_ROLE_ARN##*/}"

  CLOUDWATCH_TRUST=$(aws iam get-role \
    --role-name "$CLOUDWATCH_ROLE_NAME" \
    --query \
      "Role.AssumeRolePolicyDocument.Statement[?Principal.Service=='pods.eks.amazonaws.com'] | length(@)" \
    --output text \
    --no-cli-pager)

  if [ "$CLOUDWATCH_TRUST" = "0" ]; then
    fail "El rol $CLOUDWATCH_ROLE_NAME no confía en pods.eks.amazonaws.com."
  fi

  aws iam attach-role-policy \
    --role-name "$CLOUDWATCH_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy" \
    --no-cli-pager

  echo "Política CloudWatchAgentServerPolicy asociada."
fi

#####################################
# 12. POD IDENTITY ASSOCIATION
#####################################
if [ "$CLOUDWATCH_ENABLED" = "true" ]; then
  echo ""
  echo "12. Configurando Pod Identity para CloudWatch..."

  POD_IDENTITY_ASSOCIATION_ID=$(aws eks list-pod-identity-associations \
    --region "$REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --query \
      "associations[?namespace=='amazon-cloudwatch' && serviceAccount=='cloudwatch-agent'].associationId | [0]" \
    --output text \
    --no-cli-pager)

  if resource_not_found "$POD_IDENTITY_ASSOCIATION_ID"; then
    POD_IDENTITY_ASSOCIATION_ID=$(aws eks create-pod-identity-association \
      --region "$REGION" \
      --cluster-name "$CLUSTER_NAME" \
      --namespace "amazon-cloudwatch" \
      --service-account "cloudwatch-agent" \
      --role-arn "$CLOUDWATCH_ROLE_ARN" \
      --tags \
        Project=tienda \
        Environment=academic \
        ManagedBy=crear-eks.sh \
      --query "association.associationId" \
      --output text \
      --no-cli-pager)

    echo "Pod Identity Association creada: $POD_IDENTITY_ASSOCIATION_ID"
  else
    CURRENT_CLOUDWATCH_ROLE_ARN=$(aws eks describe-pod-identity-association \
      --region "$REGION" \
      --cluster-name "$CLUSTER_NAME" \
      --association-id "$POD_IDENTITY_ASSOCIATION_ID" \
      --query "association.roleArn" \
      --output text \
      --no-cli-pager)

    if [ "$CURRENT_CLOUDWATCH_ROLE_ARN" != "$CLOUDWATCH_ROLE_ARN" ]; then
      aws eks update-pod-identity-association \
        --region "$REGION" \
        --cluster-name "$CLUSTER_NAME" \
        --association-id "$POD_IDENTITY_ASSOCIATION_ID" \
        --role-arn "$CLOUDWATCH_ROLE_ARN" \
        --no-cli-pager \
        >/dev/null

      echo "Pod Identity Association actualizada."
    else
      echo "Pod Identity Association ya configurada."
    fi
  fi
fi

#####################################
# 13. CLOUDWATCH OBSERVABILITY ADD-ON
#####################################
if [ "$CLOUDWATCH_ENABLED" = "true" ]; then
  echo ""
  echo "13. Instalando CloudWatch Observability..."

  CLOUDWATCH_CONFIGURATION='{"otelContainerInsights":{"enabled":true}}'

  create_or_update_addon \
    "amazon-cloudwatch-observability" \
    "$CLOUDWATCH_CONFIGURATION"

  echo "CloudWatch Container Insights habilitado."
fi

#####################################
# 14. VERIFICAR KUBERNETES
#####################################
echo ""
echo "14. Verificando Kubernetes..."

if command_exists kubectl; then
  kubectl config use-context "$CLUSTER_NAME" >/dev/null

  echo ""
  kubectl get nodes -o wide

  READY_NODE_COUNT=$(kubectl get nodes \
    --no-headers \
    2>/dev/null |
    awk '$2 == "Ready" {count++} END {print count+0}')

  echo ""
  echo "Nodos Ready: $READY_NODE_COUNT"

  if [ "$CLOUDWATCH_ENABLED" = "true" ]; then
    echo ""
    echo "Pods de EKS Pod Identity:"
    kubectl get pods \
      --namespace kube-system \
      -l app.kubernetes.io/name=eks-pod-identity-agent \
      -o wide || true

    echo ""
    echo "Pods de CloudWatch:"
    kubectl get pods \
      --namespace amazon-cloudwatch \
      -o wide
  fi
else
  warning "kubectl no está instalado. El kubeconfig quedó preparado."
fi

#####################################
# 15. INFORMACIÓN FINAL
#####################################
echo ""
echo "15. Obteniendo información final..."

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

if [ "$CLOUDWATCH_ENABLED" = "true" ]; then
  POD_IDENTITY_STATUS=$(get_addon_status "eks-pod-identity-agent")
  CLOUDWATCH_STATUS=$(get_addon_status "amazon-cloudwatch-observability")
else
  POD_IDENTITY_STATUS="DISABLED"
  CLOUDWATCH_STATUS="DISABLED"
fi

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
echo "Observabilidad:"
echo "  Control Plane Logs:   ENABLED"
echo "  Pod Identity Agent:   $POD_IDENTITY_STATUS"
echo "  CloudWatch Add-on:    $CLOUDWATCH_STATUS"

if [ "$CLOUDWATCH_ENABLED" = "true" ]; then
  echo "  CloudWatch Role:      $CLOUDWATCH_ROLE_ARN"
fi

echo ""
echo "Repositorios ECR:"
for repository in "${ECR_REPOSITORIES[@]}"; do
  echo "  ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${repository}"
done

echo ""
echo "Comandos de verificación:"
echo "  aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME"
echo "  kubectl get nodes"
echo "  kubectl get pods --all-namespaces"
echo "  kubectl get pods -n amazon-cloudwatch"
echo ""
echo "CloudWatch:"
echo "  AWS Console → CloudWatch → Container Insights"
echo "  AWS Console → CloudWatch → Log groups"
echo "========================================"