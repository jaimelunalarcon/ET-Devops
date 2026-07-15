#!/usr/bin/env bash
set -Eeuo pipefail

#######################################
# CONFIGURACIÓN
#######################################

readonly NETWORK_PROJECT_NAME="${NETWORK_PROJECT_NAME:-red-lab}"
readonly PROJECT_NAME="${PROJECT_NAME:-tienda}"
readonly ENVIRONMENT="${ENVIRONMENT:-academic}"

readonly REGION="${AWS_REGION:-us-east-1}"
readonly CLUSTER_NAME="${CLUSTER_NAME:-tienda-eks}"
readonly KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.35}"

readonly NODEGROUP_NAME="${NODEGROUP_NAME:-tienda-nodegroup}"
readonly NODE_INSTANCE_TYPE="${NODE_INSTANCE_TYPE:-t3.medium}"
readonly NODE_DISK_SIZE="${NODE_DISK_SIZE:-20}"
readonly NODE_MIN_SIZE="${NODE_MIN_SIZE:-2}"
readonly NODE_DESIRED_SIZE="${NODE_DESIRED_SIZE:-2}"
readonly NODE_MAX_SIZE="${NODE_MAX_SIZE:-3}"

readonly EKS_CLUSTER_ROLE_PATTERN="${EKS_CLUSTER_ROLE_PATTERN:-LabEksClusterRole}"
readonly EKS_NODE_ROLE_PATTERN="${EKS_NODE_ROLE_PATTERN:-LabEksNodeRole}"
readonly EKS_CLUSTER_ROLE_ARN="${EKS_CLUSTER_ROLE_ARN:-}"
readonly EKS_NODE_ROLE_ARN="${EKS_NODE_ROLE_ARN:-}"

readonly CLOUDWATCH_ENABLED="${CLOUDWATCH_ENABLED:-true}"
readonly CLOUDWATCH_ROLE_ARN="${CLOUDWATCH_ROLE_ARN:-}"

readonly POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"
readonly CLUSTER_WAIT_ATTEMPTS="${CLUSTER_WAIT_ATTEMPTS:-120}"
readonly NODEGROUP_WAIT_ATTEMPTS="${NODEGROUP_WAIT_ATTEMPTS:-120}"
readonly ADDON_WAIT_ATTEMPTS="${ADDON_WAIT_ATTEMPTS:-60}"

readonly SCRIPT_VERSION="2026-07-15-clean-v1"

readonly ECR_REPOSITORIES=(
  "tienda-frontend"
  "tienda-backend"
  "tienda-db"
)

TEMP_FILES=()

#######################################
# LOGS Y ERRORES
#######################################

log_info() {
  printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"
}

log_ok() {
  printf '\033[1;32m[OK]\033[0m %s\n' "$*"
}

log_warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

fail() {
  printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local file
  for file in "${TEMP_FILES[@]:-}"; do
    [[ -n "$file" ]] && rm -f "$file"
  done
}

on_error() {
  local exit_code=$?
  local line_number="${BASH_LINENO[0]:-unknown}"
  local command="${BASH_COMMAND:-unknown}"

  printf '\n\033[1;31m[ERROR]\033[0m Falló el script.\n' >&2
  printf '\033[1;31m[ERROR]\033[0m Línea: %s\n' "$line_number" >&2
  printf '\033[1;31m[ERROR]\033[0m Comando: %s\n' "$command" >&2
  printf '\033[1;31m[ERROR]\033[0m Código de salida: %s\n' "$exit_code" >&2
  exit "$exit_code"
}

trap cleanup EXIT
trap on_error ERR

#######################################
# FUNCIONES GENERALES
#######################################

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_command() {
  command_exists "$1" || fail "La herramienta '$1' no está instalada o no está disponible en PATH."
}

validate_integer() {
  local name="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9]+$ ]] ||
    fail "$name debe ser un número entero. Valor recibido: $value"
}

is_empty_aws_value() {
  local value="${1:-}"
  [[ -z "$value" || "$value" == "None" || "$value" == "null" ]]
}

make_temp_file() {
  local file
  file="$(mktemp)"
  TEMP_FILES+=("$file")
  printf '%s\n' "$file"
}

print_header() {
  cat <<EOF

========================================
CREACIÓN DE AMAZON ECR Y AMAZON EKS
========================================
Versión script:      ${SCRIPT_VERSION}
Región:              ${REGION}
Clúster:             ${CLUSTER_NAME}
Versión Kubernetes:  ${KUBERNETES_VERSION}
Node Group:          ${NODEGROUP_NAME}
Instancia:           ${NODE_INSTANCE_TYPE}
Escalamiento:        ${NODE_MIN_SIZE}/${NODE_DESIRED_SIZE}/${NODE_MAX_SIZE}
CloudWatch:          ${CLOUDWATCH_ENABLED}

EOF
}

#######################################
# CONSULTAS SEGURAS A EKS
#
# Retorno:
#   0: recurso encontrado
#   4: ResourceNotFoundException
#   otro: error real de AWS
#######################################

describe_cluster_status() {
  local error_file
  local status
  local exit_code

  error_file="$(make_temp_file)"

  set +e
  status="$(aws eks describe-cluster \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --query 'cluster.status' \
    --output text \
    --no-cli-pager \
    2>"$error_file")"
  exit_code=$?
  set -e

  if [[ "$exit_code" -eq 0 ]]; then
    printf '%s\n' "$status"
    return 0
  fi

  if grep -q 'ResourceNotFoundException' "$error_file"; then
    return 4
  fi

  cat "$error_file" >&2
  return "$exit_code"
}

describe_nodegroup_status() {
  local error_file
  local status
  local exit_code

  error_file="$(make_temp_file)"

  set +e
  status="$(aws eks describe-nodegroup \
    --region "$REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --query 'nodegroup.status' \
    --output text \
    --no-cli-pager \
    2>"$error_file")"
  exit_code=$?
  set -e

  if [[ "$exit_code" -eq 0 ]]; then
    printf '%s\n' "$status"
    return 0
  fi

  if grep -q 'ResourceNotFoundException' "$error_file"; then
    return 4
  fi

  cat "$error_file" >&2
  return "$exit_code"
}

describe_addon_status() {
  local addon_name="$1"
  local error_file
  local status
  local exit_code

  error_file="$(make_temp_file)"

  set +e
  status="$(aws eks describe-addon \
    --region "$REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name "$addon_name" \
    --query 'addon.status' \
    --output text \
    --no-cli-pager \
    2>"$error_file")"
  exit_code=$?
  set -e

  if [[ "$exit_code" -eq 0 ]]; then
    printf '%s\n' "$status"
    return 0
  fi

  if grep -q 'ResourceNotFoundException' "$error_file"; then
    return 4
  fi

  cat "$error_file" >&2
  return "$exit_code"
}

#######################################
# ESPERAS
#######################################

wait_for_cluster_active() {
  local attempt
  local status
  local exit_code

  log_info "Esperando que el clúster quede ACTIVE..."

  for ((attempt = 1; attempt <= CLUSTER_WAIT_ATTEMPTS; attempt++)); do
    set +e
    status="$(describe_cluster_status)"
    exit_code=$?
    set -e

    case "$exit_code" in
      0)
        case "$status" in
          ACTIVE)
            log_ok "Clúster activo."
            return 0
            ;;
          CREATING | UPDATING)
            printf '[INFO] Estado del clúster: %s (%d/%d).\n' \
              "$status" "$attempt" "$CLUSTER_WAIT_ATTEMPTS"
            ;;
          FAILED)
            print_cluster_health
            fail "El clúster quedó en estado FAILED."
            ;;
          DELETING)
            fail "El clúster está siendo eliminado."
            ;;
          *)
            log_warn "Estado inesperado del clúster: ${status:-vacío} (${attempt}/${CLUSTER_WAIT_ATTEMPTS})."
            ;;
        esac
        ;;
      4)
        printf '[INFO] El clúster aún no es visible (%d/%d).\n' \
          "$attempt" "$CLUSTER_WAIT_ATTEMPTS"
        ;;
      *)
        fail "No fue posible consultar el estado del clúster."
        ;;
    esac

    sleep "$POLL_INTERVAL_SECONDS"
  done

  fail "El clúster no quedó ACTIVE tras $((CLUSTER_WAIT_ATTEMPTS * POLL_INTERVAL_SECONDS)) segundos."
}

wait_for_nodegroup_active() {
  local attempt
  local status
  local exit_code

  log_info "Esperando que el Node Group quede ACTIVE..."

  for ((attempt = 1; attempt <= NODEGROUP_WAIT_ATTEMPTS; attempt++)); do
    set +e
    status="$(describe_nodegroup_status)"
    exit_code=$?
    set -e

    case "$exit_code" in
      0)
        case "$status" in
          ACTIVE)
            log_ok "Node Group activo."
            return 0
            ;;
          CREATING | UPDATING)
            printf '[INFO] Estado del Node Group: %s (%d/%d).\n' \
              "$status" "$attempt" "$NODEGROUP_WAIT_ATTEMPTS"
            ;;
          CREATE_FAILED | DELETE_FAILED | DEGRADED)
            print_nodegroup_health
            fail "El Node Group quedó en estado $status."
            ;;
          DELETING)
            fail "El Node Group está siendo eliminado."
            ;;
          *)
            log_warn "Estado inesperado del Node Group: ${status:-vacío} (${attempt}/${NODEGROUP_WAIT_ATTEMPTS})."
            ;;
        esac
        ;;
      4)
        printf '[INFO] El Node Group aún no es visible (%d/%d).\n' \
          "$attempt" "$NODEGROUP_WAIT_ATTEMPTS"
        ;;
      *)
        fail "No fue posible consultar el estado del Node Group."
        ;;
    esac

    sleep "$POLL_INTERVAL_SECONDS"
  done

  print_nodegroup_health
  fail "El Node Group no quedó ACTIVE tras $((NODEGROUP_WAIT_ATTEMPTS * POLL_INTERVAL_SECONDS)) segundos."
}

wait_for_addon_active() {
  local addon_name="$1"
  local attempt
  local status
  local exit_code

  for ((attempt = 1; attempt <= ADDON_WAIT_ATTEMPTS; attempt++)); do
    set +e
    status="$(describe_addon_status "$addon_name")"
    exit_code=$?
    set -e

    case "$exit_code" in
      0)
        case "$status" in
          ACTIVE)
            log_ok "Add-on activo: $addon_name"
            return 0
            ;;
          CREATING | UPDATING)
            printf '[INFO] Add-on %s: %s (%d/%d).\n' \
              "$addon_name" "$status" "$attempt" "$ADDON_WAIT_ATTEMPTS"
            ;;
          CREATE_FAILED | UPDATE_FAILED | DELETE_FAILED | DEGRADED)
            print_addon_health "$addon_name"
            return 1
            ;;
          *)
            log_warn "Estado inesperado del add-on $addon_name: ${status:-vacío}."
            ;;
        esac
        ;;
      4)
        printf '[INFO] Add-on %s aún no visible (%d/%d).\n' \
          "$addon_name" "$attempt" "$ADDON_WAIT_ATTEMPTS"
        ;;
      *)
        return "$exit_code"
        ;;
    esac

    sleep "$POLL_INTERVAL_SECONDS"
  done

  print_addon_health "$addon_name"
  return 1
}

#######################################
# DIAGNÓSTICO
#######################################

print_cluster_health() {
  aws eks describe-cluster \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --query 'cluster.health.issues' \
    --output json \
    --no-cli-pager \
    2>/dev/null || true
}

print_nodegroup_health() {
  aws eks describe-nodegroup \
    --region "$REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --query 'nodegroup.health.issues' \
    --output json \
    --no-cli-pager \
    2>/dev/null || true
}

print_addon_health() {
  local addon_name="$1"

  aws eks describe-addon \
    --region "$REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name "$addon_name" \
    --query 'addon.health.issues' \
    --output json \
    --no-cli-pager \
    2>/dev/null || true
}

#######################################
# RED
#######################################

find_vpc_id() {
  local vpc_id

  vpc_id="$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters \
      "Name=tag:Name,Values=${NETWORK_PROJECT_NAME}-vpc" \
      "Name=tag:Project,Values=${NETWORK_PROJECT_NAME}" \
    --query 'Vpcs[0].VpcId' \
    --output text \
    --no-cli-pager)"

  if is_empty_aws_value "$vpc_id"; then
    vpc_id="$(aws ec2 describe-vpcs \
      --region "$REGION" \
      --filters "Name=tag:Name,Values=${NETWORK_PROJECT_NAME}-vpc" \
      --query 'Vpcs[0].VpcId' \
      --output text \
      --no-cli-pager)"
  fi

  is_empty_aws_value "$vpc_id" &&
    fail "No se encontró ${NETWORK_PROJECT_NAME}-vpc. Ejecuta primero crear-red-lab.sh."

  printf '%s\n' "$vpc_id"
}

find_subnet_id() {
  local vpc_id="$1"
  local subnet_name="$2"
  local subnet_id

  subnet_id="$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters \
      "Name=vpc-id,Values=$vpc_id" \
      "Name=tag:Name,Values=$subnet_name" \
    --query 'Subnets[0].SubnetId' \
    --output text \
    --no-cli-pager)"

  is_empty_aws_value "$subnet_id" &&
    fail "No se encontró la subred $subnet_name."

  printf '%s\n' "$subnet_id"
}

validate_private_subnet() {
  local subnet_id="$1"
  local map_public_ip

  map_public_ip="$(aws ec2 describe-subnets \
    --region "$REGION" \
    --subnet-ids "$subnet_id" \
    --query 'Subnets[0].MapPublicIpOnLaunch' \
    --output text \
    --no-cli-pager)"

  [[ "$map_public_ip" == "False" ]] ||
    fail "La subred $subnet_id tiene asignación automática de IP pública habilitada."
}

find_effective_route_table_id() {
  local vpc_id="$1"
  local subnet_id="$2"
  local route_table_id

  route_table_id="$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --filters "Name=association.subnet-id,Values=$subnet_id" \
    --query 'RouteTables[0].RouteTableId' \
    --output text \
    --no-cli-pager)"

  if is_empty_aws_value "$route_table_id"; then
    route_table_id="$(aws ec2 describe-route-tables \
      --region "$REGION" \
      --filters "Name=vpc-id,Values=$vpc_id" \
      --query 'RouteTables[?Associations[?Main==`true`]].RouteTableId | [0]' \
      --output text \
      --no-cli-pager)"
  fi

  is_empty_aws_value "$route_table_id" &&
    fail "No fue posible determinar la Route Table efectiva de $subnet_id."

  printf '%s\n' "$route_table_id"
}

validate_nat_route() {
  local vpc_id="$1"
  local subnet_id="$2"
  local route_table_id
  local nat_gateway_id
  local nat_state

  route_table_id="$(find_effective_route_table_id "$vpc_id" "$subnet_id")"

  nat_gateway_id="$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --route-table-ids "$route_table_id" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId | [0]" \
    --output text \
    --no-cli-pager)"

  is_empty_aws_value "$nat_gateway_id" &&
    fail "La Route Table $route_table_id de $subnet_id no tiene una ruta 0.0.0.0/0 hacia NAT Gateway."

  nat_state="$(aws ec2 describe-nat-gateways \
    --region "$REGION" \
    --nat-gateway-ids "$nat_gateway_id" \
    --query 'NatGateways[0].State' \
    --output text \
    --no-cli-pager)"

  [[ "$nat_state" == "available" ]] ||
    fail "El NAT Gateway $nat_gateway_id está en estado $nat_state."

  log_ok "Subred $subnet_id → Route Table $route_table_id → NAT $nat_gateway_id"
}

#######################################
# IAM AWS ACADEMY
#######################################

resolve_role_arn() {
  local provided_arn="$1"
  local role_pattern="$2"
  local matches
  local count

  if ! is_empty_aws_value "$provided_arn"; then
    printf '%s\n' "$provided_arn"
    return 0
  fi

  matches="$(aws iam list-roles \
    --query "Roles[?contains(RoleName, '${role_pattern}')].Arn" \
    --output text \
    --no-cli-pager)"

  if is_empty_aws_value "$matches"; then
    fail "No se encontró ningún rol IAM que contenga '$role_pattern'."
  fi

  count="$(wc -w <<<"$matches" | tr -d ' ')"

  [[ "$count" -eq 1 ]] ||
    fail "Se encontraron $count roles que contienen '$role_pattern'. Proporciona el ARN explícitamente."

  printf '%s\n' "$matches"
}

validate_role_trust() {
  local role_arn="$1"
  local expected_service="$2"
  local role_name
  local trust_count

  role_name="${role_arn##*/}"

  [[ -n "$role_name" ]] ||
    fail "No fue posible extraer el nombre desde el ARN $role_arn."

  trust_count="$(aws iam get-role \
    --role-name "$role_name" \
    --query "length(Role.AssumeRolePolicyDocument.Statement[?Principal.Service=='${expected_service}'])" \
    --output text \
    --no-cli-pager)"

  [[ "$trust_count" != "0" ]] ||
    fail "El rol $role_name no confía en $expected_service."
}

#######################################
# ECR
#######################################

ensure_ecr_repository() {
  local repository="$1"
  local error_file
  local exit_code

  error_file="$(make_temp_file)"

  set +e
  aws ecr describe-repositories \
    --region "$REGION" \
    --repository-names "$repository" \
    --no-cli-pager \
    >/dev/null 2>"$error_file"
  exit_code=$?
  set -e

  if [[ "$exit_code" -eq 0 ]]; then
    log_ok "Repositorio existente: $repository"
    return 0
  fi

  if ! grep -q 'RepositoryNotFoundException' "$error_file"; then
    cat "$error_file" >&2
    fail "No fue posible consultar el repositorio ECR $repository."
  fi

  aws ecr create-repository \
    --region "$REGION" \
    --repository-name "$repository" \
    --image-tag-mutability MUTABLE \
    --image-scanning-configuration scanOnPush=true \
    --tags \
      Key=Project,Value="$PROJECT_NAME" \
      Key=Environment,Value="$ENVIRONMENT" \
    --no-cli-pager \
    >/dev/null

  log_ok "Repositorio creado: $repository"
}

#######################################
# EKS
#######################################

ensure_cluster() {
  local cluster_role_arn="$1"
  local subnet_a="$2"
  local subnet_b="$3"
  local status
  local exit_code

  set +e
  status="$(describe_cluster_status)"
  exit_code=$?
  set -e

  case "$exit_code" in
    0)
      log_ok "El clúster ya existe. Estado: $status"
      ;;
    4)
      log_info "Creando clúster $CLUSTER_NAME..."

      aws eks create-cluster \
        --region "$REGION" \
        --name "$CLUSTER_NAME" \
        --kubernetes-version "$KUBERNETES_VERSION" \
        --role-arn "$cluster_role_arn" \
        --resources-vpc-config \
          "subnetIds=${subnet_a},${subnet_b},endpointPublicAccess=true,endpointPrivateAccess=true" \
        --kubernetes-network-config 'ipFamily=ipv4' \
        --logging \
          '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}' \
        --tags \
          "Project=${PROJECT_NAME},Environment=${ENVIRONMENT},ManagedBy=crear-eks.sh" \
        --output json \
        --no-cli-pager

      log_ok "Solicitud create-cluster enviada."
      ;;
    *)
      fail "No fue posible determinar si el clúster existe."
      ;;
  esac

  wait_for_cluster_active
}

ensure_nodegroup() {
  local node_role_arn="$1"
  local subnet_a="$2"
  local subnet_b="$3"
  local status
  local exit_code

  set +e
  status="$(describe_nodegroup_status)"
  exit_code=$?
  set -e

  case "$exit_code" in
    0)
      log_ok "El Node Group ya existe. Estado: $status"
      ;;
    4)
      log_info "Creando Node Group $NODEGROUP_NAME..."

      aws eks create-nodegroup \
        --region "$REGION" \
        --cluster-name "$CLUSTER_NAME" \
        --nodegroup-name "$NODEGROUP_NAME" \
        --node-role "$node_role_arn" \
        --subnets "$subnet_a" "$subnet_b" \
        --instance-types "$NODE_INSTANCE_TYPE" \
        --capacity-type ON_DEMAND \
        --disk-size "$NODE_DISK_SIZE" \
        --scaling-config \
          "minSize=${NODE_MIN_SIZE},maxSize=${NODE_MAX_SIZE},desiredSize=${NODE_DESIRED_SIZE}" \
        --update-config 'maxUnavailable=1' \
        --labels \
          "workload=${PROJECT_NAME},environment=${ENVIRONMENT}" \
        --tags \
          "Project=${PROJECT_NAME},Environment=${ENVIRONMENT},ManagedBy=crear-eks.sh" \
        --output json \
        --no-cli-pager

      log_ok "Solicitud create-nodegroup enviada."
      ;;
    *)
      fail "No fue posible determinar si el Node Group existe."
      ;;
  esac

  wait_for_nodegroup_active
}

ensure_addon() {
  local addon_name="$1"
  local role_arn="${2:-}"
  local status
  local exit_code

  set +e
  status="$(describe_addon_status "$addon_name")"
  exit_code=$?
  set -e

  case "$exit_code" in
    0)
      if [[ "$status" == "ACTIVE" ]]; then
        log_ok "Add-on existente y activo: $addon_name"
        return 0
      fi

      log_info "Actualizando add-on existente: $addon_name"

      if [[ -n "$role_arn" ]]; then
        aws eks update-addon \
          --region "$REGION" \
          --cluster-name "$CLUSTER_NAME" \
          --addon-name "$addon_name" \
          --service-account-role-arn "$role_arn" \
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
      ;;
    4)
      log_info "Instalando add-on: $addon_name"

      if [[ -n "$role_arn" ]]; then
        aws eks create-addon \
          --region "$REGION" \
          --cluster-name "$CLUSTER_NAME" \
          --addon-name "$addon_name" \
          --service-account-role-arn "$role_arn" \
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
      ;;
    *)
      fail "No fue posible consultar el add-on $addon_name."
      ;;
  esac

  wait_for_addon_active "$addon_name"
}

#######################################
# MAIN
#######################################

main() {
  local account_id
  local identity_arn
  local vpc_id
  local subnet_a
  local subnet_b
  local subnet_a_az
  local subnet_b_az
  local cluster_role_arn
  local node_role_arn
  local actual_version
  local cluster_status
  local nodegroup_status
  local repository

  print_header

  log_info "0. Validando herramientas, variables y credenciales..."

  require_command aws
  require_command kubectl

  validate_integer NODE_DISK_SIZE "$NODE_DISK_SIZE"
  validate_integer NODE_MIN_SIZE "$NODE_MIN_SIZE"
  validate_integer NODE_DESIRED_SIZE "$NODE_DESIRED_SIZE"
  validate_integer NODE_MAX_SIZE "$NODE_MAX_SIZE"
  validate_integer POLL_INTERVAL_SECONDS "$POLL_INTERVAL_SECONDS"
  validate_integer CLUSTER_WAIT_ATTEMPTS "$CLUSTER_WAIT_ATTEMPTS"
  validate_integer NODEGROUP_WAIT_ATTEMPTS "$NODEGROUP_WAIT_ATTEMPTS"
  validate_integer ADDON_WAIT_ATTEMPTS "$ADDON_WAIT_ATTEMPTS"

  (( NODE_MIN_SIZE <= NODE_DESIRED_SIZE )) ||
    fail "NODE_MIN_SIZE no puede ser mayor que NODE_DESIRED_SIZE."

  (( NODE_DESIRED_SIZE <= NODE_MAX_SIZE )) ||
    fail "NODE_DESIRED_SIZE no puede ser mayor que NODE_MAX_SIZE."

  account_id="$(aws sts get-caller-identity \
    --query Account \
    --output text \
    --no-cli-pager)"

  identity_arn="$(aws sts get-caller-identity \
    --query Arn \
    --output text \
    --no-cli-pager)"

  log_ok "Credenciales válidas. Cuenta: $account_id"
  log_ok "Identidad: $identity_arn"

  # Falla rápido si la sesión de AWS Academy está cancelada.
  aws eks list-clusters \
    --region "$REGION" \
    --max-results 1 \
    --no-cli-pager \
    >/dev/null

  log_info "1. Descubriendo VPC y subredes privadas APP..."

  vpc_id="$(find_vpc_id)"
  subnet_a="$(find_subnet_id "$vpc_id" "${NETWORK_PROJECT_NAME}-app-a")"
  subnet_b="$(find_subnet_id "$vpc_id" "${NETWORK_PROJECT_NAME}-app-b")"

  validate_private_subnet "$subnet_a"
  validate_private_subnet "$subnet_b"

  subnet_a_az="$(aws ec2 describe-subnets \
    --region "$REGION" \
    --subnet-ids "$subnet_a" \
    --query 'Subnets[0].AvailabilityZone' \
    --output text \
    --no-cli-pager)"

  subnet_b_az="$(aws ec2 describe-subnets \
    --region "$REGION" \
    --subnet-ids "$subnet_b" \
    --query 'Subnets[0].AvailabilityZone' \
    --output text \
    --no-cli-pager)"

  [[ "$subnet_a_az" != "$subnet_b_az" ]] ||
    fail "Las subredes APP deben estar en zonas de disponibilidad distintas."

  log_ok "VPC: $vpc_id"
  log_ok "Subred APP A: $subnet_a ($subnet_a_az)"
  log_ok "Subred APP B: $subnet_b ($subnet_b_az)"

  log_info "2. Validando rutas privadas y NAT Gateway..."

  validate_nat_route "$vpc_id" "$subnet_a"
  validate_nat_route "$vpc_id" "$subnet_b"

  log_info "3. Descubriendo roles IAM existentes de AWS Academy..."

  cluster_role_arn="$(resolve_role_arn "$EKS_CLUSTER_ROLE_ARN" "$EKS_CLUSTER_ROLE_PATTERN")"
  node_role_arn="$(resolve_role_arn "$EKS_NODE_ROLE_ARN" "$EKS_NODE_ROLE_PATTERN")"

  validate_role_trust "$cluster_role_arn" 'eks.amazonaws.com'
  validate_role_trust "$node_role_arn" 'ec2.amazonaws.com'

  log_ok "Rol del clúster: $cluster_role_arn"
  log_ok "Rol de los nodos: $node_role_arn"

  log_info "4. Asegurando repositorios Amazon ECR..."

  for repository in "${ECR_REPOSITORIES[@]}"; do
    ensure_ecr_repository "$repository"
  done

  log_info "5. Asegurando clúster Amazon EKS..."

  ensure_cluster "$cluster_role_arn" "$subnet_a" "$subnet_b"

  log_info "6. Configurando kubeconfig..."

  aws eks update-kubeconfig \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --alias "$CLUSTER_NAME" \
    --no-cli-pager

  log_ok "Kubeconfig actualizado."

  log_info "7. Asegurando Managed Node Group..."

  ensure_nodegroup "$node_role_arn" "$subnet_a" "$subnet_b"

  log_info "8. Instalando EKS Pod Identity Agent..."

  ensure_addon 'eks-pod-identity-agent' ||
    fail "No fue posible instalar eks-pod-identity-agent."

  log_info "9. Configurando CloudWatch Observability..."

  if [[ "$CLOUDWATCH_ENABLED" != "true" ]]; then
    log_warn "CloudWatch deshabilitado mediante CLOUDWATCH_ENABLED=$CLOUDWATCH_ENABLED."
  elif [[ -n "$CLOUDWATCH_ROLE_ARN" ]]; then
    if ensure_addon 'amazon-cloudwatch-observability' "$CLOUDWATCH_ROLE_ARN"; then
      log_ok "CloudWatch Observability instalado usando el rol proporcionado."
    else
      log_warn "CloudWatch Observability no quedó activo. El resto de la infraestructura permanece disponible."
    fi
  else
    log_warn "CLOUDWATCH_ROLE_ARN no fue proporcionado."
    log_warn "AWS Academy no permite crear roles libremente; se omite amazon-cloudwatch-observability para no romper el despliegue."
  fi

  log_info "10. Verificando Kubernetes..."

  kubectl config use-context "$CLUSTER_NAME" >/dev/null
  kubectl get nodes -o wide

  cluster_status="$(describe_cluster_status)"
  nodegroup_status="$(describe_nodegroup_status)"

  actual_version="$(aws eks describe-cluster \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --query 'cluster.version' \
    --output text \
    --no-cli-pager)"

  echo
  echo "========================================"
  echo "AMAZON EKS LISTO"
  echo "========================================"
  echo "Cuenta AWS:           $account_id"
  echo "Región:               $REGION"
  echo "VPC:                  $vpc_id"
  echo "Subred APP A:         $subnet_a"
  echo "Subred APP B:         $subnet_b"
  echo "Clúster:              $CLUSTER_NAME"
  echo "Estado clúster:       $cluster_status"
  echo "Versión Kubernetes:   $actual_version"
  echo "Node Group:           $NODEGROUP_NAME"
  echo "Estado Node Group:    $nodegroup_status"
  echo "Pod Identity Agent:   instalado"
  echo
  echo "Repositorios ECR:"

  for repository in "${ECR_REPOSITORIES[@]}"; do
    echo "  ${account_id}.dkr.ecr.${REGION}.amazonaws.com/${repository}"
  done

  echo
  echo "Siguiente paso:"
  echo "  kubectl apply -f k8s/"
  echo "========================================"
}

main "$@"