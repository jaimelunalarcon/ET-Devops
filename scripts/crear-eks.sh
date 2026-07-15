#!/usr/bin/env bash
set -Eeuo pipefail

#######################################
# CONFIGURACIÓN
#######################################
readonly NETWORK_PROJECT_NAME="${NETWORK_PROJECT_NAME:-red-lab}"
readonly PROJECT_NAME="${PROJECT_NAME:-tienda}"
readonly ENVIRONMENT="${ENVIRONMENT:-academic}"

readonly CLUSTER_NAME="${CLUSTER_NAME:-tienda-eks}"
readonly NODEGROUP_NAME="${NODEGROUP_NAME:-tienda-nodegroup}"
readonly REGION="${AWS_REGION:-us-east-1}"
readonly KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.35}"

readonly NODE_INSTANCE_TYPE="${NODE_INSTANCE_TYPE:-t3.medium}"
readonly NODE_DISK_SIZE="${NODE_DISK_SIZE:-20}"
readonly NODE_MIN_SIZE="${NODE_MIN_SIZE:-2}"
readonly NODE_DESIRED_SIZE="${NODE_DESIRED_SIZE:-2}"
readonly NODE_MAX_SIZE="${NODE_MAX_SIZE:-3}"

readonly EKS_CLUSTER_ROLE_NAME="${EKS_CLUSTER_ROLE_NAME:-LabEksClusterRole}"
readonly EKS_NODE_ROLE_NAME="${EKS_NODE_ROLE_NAME:-LabEksNodeRole}"
readonly EKS_CLUSTER_ROLE_ARN="${EKS_CLUSTER_ROLE_ARN:-}"
readonly EKS_NODE_ROLE_ARN="${EKS_NODE_ROLE_ARN:-}"

readonly CLOUDWATCH_ENABLED="${CLOUDWATCH_ENABLED:-true}"
readonly CLOUDWATCH_ROLE_NAME="${CLOUDWATCH_ROLE_NAME:-${CLUSTER_NAME}-cloudwatch-role}"
readonly CLOUDWATCH_ROLE_ARN_INPUT="${CLOUDWATCH_ROLE_ARN:-}"

readonly CLUSTER_WAIT_ATTEMPTS="${CLUSTER_WAIT_ATTEMPTS:-120}"
readonly NODEGROUP_WAIT_ATTEMPTS="${NODEGROUP_WAIT_ATTEMPTS:-120}"
readonly ADDON_WAIT_ATTEMPTS="${ADDON_WAIT_ATTEMPTS:-60}"
readonly POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"

readonly -a ECR_REPOSITORIES=(
  "${PROJECT_NAME}-frontend"
  "${PROJECT_NAME}-backend"
  "${PROJECT_NAME}-db"
)

readonly -a CONTROL_PLANE_LOG_TYPES=(
  api
  audit
  authenticator
  controllerManager
  scheduler
)

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

log_error() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
}

fail() {
  log_error "$*"
  exit 1
}

on_error() {
  local exit_code=$?
  local line_number="${BASH_LINENO[0]:-desconocida}"
  local failed_command="${BASH_COMMAND:-desconocido}"

  log_error "El script terminó inesperadamente."
  log_error "Línea: ${line_number}"
  log_error "Comando: ${failed_command}"
  log_error "Código de salida: ${exit_code}"
  exit "$exit_code"
}

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

validate_boolean() {
  local name="$1"
  local value="$2"

  case "$value" in
    true | false) ;;
    *) fail "$name debe ser 'true' o 'false'. Valor recibido: $value" ;;
  esac
}

is_empty_aws_value() {
  local value="${1:-}"
  [[ -z "$value" || "$value" == "None" || "$value" == "null" ]]
}

make_temp_file() {
  mktemp "${TMPDIR:-/tmp}/crear-eks.XXXXXX"
}

print_header() {
  cat <<EOF_HEADER

========================================
CREACIÓN DE AMAZON ECR Y AMAZON EKS
========================================
Región:             ${REGION}
Clúster:            ${CLUSTER_NAME}
Versión Kubernetes: ${KUBERNETES_VERSION}
Node Group:         ${NODEGROUP_NAME}
Instancia:          ${NODE_INSTANCE_TYPE}
Escalamiento:       ${NODE_MIN_SIZE}/${NODE_DESIRED_SIZE}/${NODE_MAX_SIZE}
CloudWatch:         ${CLOUDWATCH_ENABLED}

EOF_HEADER
}

#######################################
# CONSULTAS AWS SIN OCULTAR ERRORES
# Retorno 0: recurso encontrado
# Retorno 4: recurso no encontrado
# Otros errores: el script termina mostrando AWS
#######################################
get_cluster_status() {
  local error_file output exit_code
  error_file=$(make_temp_file)

  if output=$(aws eks describe-cluster \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --query 'cluster.status' \
    --output text \
    --no-cli-pager \
    2>"$error_file"); then
    rm -f "$error_file"
    printf '%s\n' "$output"
    return 0
  fi

  exit_code=$?
  if grep -q 'ResourceNotFoundException' "$error_file"; then
    rm -f "$error_file"
    return 4
  fi

  cat "$error_file" >&2
  rm -f "$error_file"
  fail "No fue posible consultar el clúster EKS (código AWS CLI: $exit_code)."
}

get_nodegroup_status() {
  local error_file output exit_code
  error_file=$(make_temp_file)

  if output=$(aws eks describe-nodegroup \
    --region "$REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --query 'nodegroup.status' \
    --output text \
    --no-cli-pager \
    2>"$error_file"); then
    rm -f "$error_file"
    printf '%s\n' "$output"
    return 0
  fi

  exit_code=$?
  if grep -q 'ResourceNotFoundException' "$error_file"; then
    rm -f "$error_file"
    return 4
  fi

  cat "$error_file" >&2
  rm -f "$error_file"
  fail "No fue posible consultar el Managed Node Group (código AWS CLI: $exit_code)."
}

get_addon_status() {
  local addon_name="$1"
  local error_file output exit_code
  error_file=$(make_temp_file)

  if output=$(aws eks describe-addon \
    --region "$REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name "$addon_name" \
    --query 'addon.status' \
    --output text \
    --no-cli-pager \
    2>"$error_file"); then
    rm -f "$error_file"
    printf '%s\n' "$output"
    return 0
  fi

  exit_code=$?
  if grep -q 'ResourceNotFoundException' "$error_file"; then
    rm -f "$error_file"
    return 4
  fi

  cat "$error_file" >&2
  rm -f "$error_file"
  fail "No fue posible consultar el add-on '$addon_name' (código AWS CLI: $exit_code)."
}

get_role_arn() {
  local role_name="$1"
  local error_file output exit_code
  error_file=$(make_temp_file)

  if output=$(aws iam get-role \
    --role-name "$role_name" \
    --query 'Role.Arn' \
    --output text \
    --no-cli-pager \
    2>"$error_file"); then
    rm -f "$error_file"
    printf '%s\n' "$output"
    return 0
  fi

  exit_code=$?
  if grep -qE 'NoSuchEntity|cannot be found' "$error_file"; then
    rm -f "$error_file"
    return 4
  fi

  cat "$error_file" >&2
  rm -f "$error_file"
  fail "No fue posible consultar el rol IAM '$role_name' (código AWS CLI: $exit_code)."
}

repository_exists() {
  local repository_name="$1"
  local error_file exit_code
  error_file=$(make_temp_file)

  if aws ecr describe-repositories \
    --region "$REGION" \
    --repository-names "$repository_name" \
    --no-cli-pager \
    >/dev/null 2>"$error_file"; then
    rm -f "$error_file"
    return 0
  fi

  exit_code=$?
  if grep -q 'RepositoryNotFoundException' "$error_file"; then
    rm -f "$error_file"
    return 4
  fi

  cat "$error_file" >&2
  rm -f "$error_file"
  fail "No fue posible consultar ECR '$repository_name' (código AWS CLI: $exit_code)."
}

#######################################
# ESPERAS CONTROLADAS
#######################################
wait_for_cluster_active() {
  local attempt status rc

  log_info "Esperando que el clúster quede ACTIVE..."

  for ((attempt = 1; attempt <= CLUSTER_WAIT_ATTEMPTS; attempt++)); do
    if status=$(get_cluster_status); then
      case "$status" in
        ACTIVE)
          log_ok "Clúster activo."
          return 0
          ;;
        FAILED)
          show_cluster_health_issues
          fail "El clúster quedó en estado FAILED."
          ;;
        DELETING)
          fail "El clúster está siendo eliminado."
          ;;
        CREATING | UPDATING | PENDING)
          log_info "Estado del clúster: $status (${attempt}/${CLUSTER_WAIT_ATTEMPTS})."
          ;;
        *)
          log_warn "Estado inesperado del clúster: $status (${attempt}/${CLUSTER_WAIT_ATTEMPTS})."
          ;;
      esac
    else
      rc=$?
      if [[ "$rc" -eq 4 ]]; then
        log_info "El clúster aún no es visible (${attempt}/${CLUSTER_WAIT_ATTEMPTS})."

        if (( attempt == 12 )); then
          log_warn "El clúster continúa sin aparecer después de $((attempt * POLL_INTERVAL_SECONDS)) segundos. Se mantendrá el polling hasta agotar el tiempo configurado."
        fi
      else
        return "$rc"
      fi
    fi

    sleep "$POLL_INTERVAL_SECONDS"
  done

  show_cluster_health_issues
  fail "El clúster no quedó ACTIVE tras $((CLUSTER_WAIT_ATTEMPTS * POLL_INTERVAL_SECONDS)) segundos."
}

wait_for_nodegroup_active() {
  local attempt status rc

  log_info "Esperando que el Managed Node Group quede ACTIVE..."

  for ((attempt = 1; attempt <= NODEGROUP_WAIT_ATTEMPTS; attempt++)); do
    if status=$(get_nodegroup_status); then
      case "$status" in
        ACTIVE)
          log_ok "Managed Node Group activo."
          return 0
          ;;
        CREATE_FAILED | DELETE_FAILED | DEGRADED)
          show_nodegroup_health_issues
          fail "El Managed Node Group quedó en estado $status."
          ;;
        DELETING)
          fail "El Managed Node Group está siendo eliminado."
          ;;
        CREATING | UPDATING)
          log_info "Estado del Node Group: $status (${attempt}/${NODEGROUP_WAIT_ATTEMPTS})."
          ;;
        *)
          log_warn "Estado inesperado del Node Group: $status (${attempt}/${NODEGROUP_WAIT_ATTEMPTS})."
          ;;
      esac
    else
      rc=$?
      if [[ "$rc" -eq 4 ]]; then
        log_info "El Node Group aún no es visible (${attempt}/${NODEGROUP_WAIT_ATTEMPTS})."
      else
        return "$rc"
      fi
    fi

    sleep "$POLL_INTERVAL_SECONDS"
  done

  show_nodegroup_health_issues
  fail "El Node Group no quedó ACTIVE tras $((NODEGROUP_WAIT_ATTEMPTS * POLL_INTERVAL_SECONDS)) segundos."
}

wait_for_addon_active() {
  local addon_name="$1"
  local attempt status rc

  log_info "Esperando que el add-on '$addon_name' quede ACTIVE..."

  for ((attempt = 1; attempt <= ADDON_WAIT_ATTEMPTS; attempt++)); do
    if status=$(get_addon_status "$addon_name"); then
      case "$status" in
        ACTIVE)
          log_ok "Add-on activo: $addon_name"
          return 0
          ;;
        CREATE_FAILED | UPDATE_FAILED | DELETE_FAILED | DEGRADED)
          show_addon_health_issues "$addon_name"
          fail "El add-on '$addon_name' quedó en estado $status."
          ;;
        CREATING | UPDATING)
          log_info "Add-on $addon_name: $status (${attempt}/${ADDON_WAIT_ATTEMPTS})."
          ;;
        *)
          log_warn "Estado inesperado de $addon_name: $status (${attempt}/${ADDON_WAIT_ATTEMPTS})."
          ;;
      esac
    else
      rc=$?
      if [[ "$rc" -eq 4 ]]; then
        log_info "El add-on '$addon_name' aún no es visible (${attempt}/${ADDON_WAIT_ATTEMPTS})."
      else
        return "$rc"
      fi
    fi

    sleep "$POLL_INTERVAL_SECONDS"
  done

  show_addon_health_issues "$addon_name"
  fail "El add-on '$addon_name' no quedó ACTIVE."
}

wait_for_cluster_update() {
  local update_id="$1"
  local attempt status

  log_info "Esperando actualización del clúster: $update_id"

  for ((attempt = 1; attempt <= CLUSTER_WAIT_ATTEMPTS; attempt++)); do
    status=$(aws eks describe-update \
      --region "$REGION" \
      --name "$CLUSTER_NAME" \
      --update-id "$update_id" \
      --query 'update.status' \
      --output text \
      --no-cli-pager)

    case "$status" in
      Successful)
        log_ok "Actualización del clúster completada."
        return 0
        ;;
      Failed | Cancelled)
        aws eks describe-update \
          --region "$REGION" \
          --name "$CLUSTER_NAME" \
          --update-id "$update_id" \
          --query 'update.errors' \
          --output json \
          --no-cli-pager >&2 || true
        fail "La actualización del clúster terminó en estado $status."
        ;;
      InProgress)
        log_info "Actualización en progreso (${attempt}/${CLUSTER_WAIT_ATTEMPTS})."
        ;;
      *)
        log_warn "Estado inesperado de la actualización: $status."
        ;;
    esac

    sleep "$POLL_INTERVAL_SECONDS"
  done

  fail "La actualización del clúster excedió el tiempo máximo de espera."
}

#######################################
# DIAGNÓSTICO
#######################################
show_cluster_health_issues() {
  aws eks describe-cluster \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --query 'cluster.health.issues' \
    --output json \
    --no-cli-pager >&2 || true
}

show_nodegroup_health_issues() {
  aws eks describe-nodegroup \
    --region "$REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --query 'nodegroup.health.issues' \
    --output json \
    --no-cli-pager >&2 || true
}

show_addon_health_issues() {
  local addon_name="$1"

  aws eks describe-addon \
    --region "$REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name "$addon_name" \
    --query 'addon.health.issues' \
    --output json \
    --no-cli-pager >&2 || true
}

#######################################
# RED
#######################################
find_vpc() {
  local vpc_id

  vpc_id=$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters \
      "Name=tag:Name,Values=${NETWORK_PROJECT_NAME}-vpc" \
      "Name=tag:Project,Values=${NETWORK_PROJECT_NAME}" \
    --query 'Vpcs[0].VpcId' \
    --output text \
    --no-cli-pager)

  if is_empty_aws_value "$vpc_id"; then
    vpc_id=$(aws ec2 describe-vpcs \
      --region "$REGION" \
      --filters "Name=tag:Name,Values=${NETWORK_PROJECT_NAME}-vpc" \
      --query 'Vpcs[0].VpcId' \
      --output text \
      --no-cli-pager)
  fi

  is_empty_aws_value "$vpc_id" &&
    fail "No se encontró ${NETWORK_PROJECT_NAME}-vpc. Ejecuta primero el workflow de red."

  printf '%s\n' "$vpc_id"
}

find_subnet() {
  local vpc_id="$1"
  local subnet_name="$2"
  local subnet_id

  subnet_id=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters \
      "Name=vpc-id,Values=$vpc_id" \
      "Name=tag:Name,Values=$subnet_name" \
    --query 'Subnets[0].SubnetId' \
    --output text \
    --no-cli-pager)

  is_empty_aws_value "$subnet_id" && fail "No se encontró la subred '$subnet_name'."
  printf '%s\n' "$subnet_id"
}

find_route_table_for_subnet() {
  local vpc_id="$1"
  local subnet_id="$2"
  local route_table_id

  route_table_id=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --filters "Name=association.subnet-id,Values=$subnet_id" \
    --query 'RouteTables[0].RouteTableId' \
    --output text \
    --no-cli-pager)

  if is_empty_aws_value "$route_table_id"; then
    route_table_id=$(aws ec2 describe-route-tables \
      --region "$REGION" \
      --filters \
        "Name=vpc-id,Values=$vpc_id" \
        'Name=association.main,Values=true' \
      --query 'RouteTables[0].RouteTableId' \
      --output text \
      --no-cli-pager)
  fi

  is_empty_aws_value "$route_table_id" &&
    fail "No se encontró una Route Table efectiva para la subred $subnet_id."

  printf '%s\n' "$route_table_id"
}

validate_private_subnet() {
  local subnet_id="$1"
  local expected_az_distinct_from="${2:-}"
  local map_public_ip az

  read -r map_public_ip az < <(aws ec2 describe-subnets \
    --region "$REGION" \
    --subnet-ids "$subnet_id" \
    --query 'Subnets[0].[MapPublicIpOnLaunch,AvailabilityZone]' \
    --output text \
    --no-cli-pager)

  [[ "$map_public_ip" == "False" ]] ||
    fail "La subred $subnet_id asigna IP pública automáticamente y no es privada."

  if [[ -n "$expected_az_distinct_from" && "$az" == "$expected_az_distinct_from" ]]; then
    fail "Las subredes APP deben estar en zonas de disponibilidad distintas."
  fi

  printf '%s\n' "$az"
}

validate_nat_route() {
  local vpc_id="$1"
  local subnet_id="$2"
  local route_table_id nat_gateway_id nat_state

  route_table_id=$(find_route_table_for_subnet "$vpc_id" "$subnet_id")

  nat_gateway_id=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --route-table-ids "$route_table_id" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId | [0]" \
    --output text \
    --no-cli-pager)

  is_empty_aws_value "$nat_gateway_id" &&
    fail "La subred $subnet_id no tiene una ruta 0.0.0.0/0 hacia un NAT Gateway."

  nat_state=$(aws ec2 describe-nat-gateways \
    --region "$REGION" \
    --nat-gateway-ids "$nat_gateway_id" \
    --query 'NatGateways[0].State' \
    --output text \
    --no-cli-pager)

  [[ "$nat_state" == "available" ]] ||
    fail "El NAT Gateway $nat_gateway_id está en estado $nat_state."

  log_ok "Subred $subnet_id → Route Table $route_table_id → NAT $nat_gateway_id"
}

#######################################
# IAM EXISTENTE DE AWS ACADEMY
#######################################
resolve_role_arn() {
  local supplied_arn="${1:-}"
  local role_pattern="$2"
  local role_count role_arn

  # Permite proporcionar el ARN explícitamente desde GitHub Actions.
  if [[ -n "$supplied_arn" && "$supplied_arn" != "None" && "$supplied_arn" != "null" ]]; then
    printf '%s\n' "$supplied_arn"
    return 0
  fi

  # AWS Academy agrega prefijos y sufijos dinámicos a los nombres de roles.
  # Por eso buscamos por coincidencia parcial, no por nombre exacto.
  role_count=$(aws iam list-roles \
    --query "length(Roles[?contains(RoleName, '${role_pattern}')])" \
    --output text \
    --no-cli-pager)

  case "$role_count" in
    0)
      fail "No se encontró ningún rol IAM cuyo nombre contenga '$role_pattern'."
      ;;
    1)
      ;;
    *)
      fail "Se encontraron $role_count roles IAM cuyo nombre contiene '$role_pattern'. Proporciona el ARN explícitamente mediante la variable correspondiente."
      ;;
  esac

  role_arn=$(aws iam list-roles \
    --query "Roles[?contains(RoleName, '${role_pattern}')].Arn | [0]" \
    --output text \
    --no-cli-pager)

  resource_not_found "$role_arn" &&
    fail "No fue posible resolver el ARN del rol IAM que contiene '$role_pattern'."

  printf '%s\n' "$role_arn"
}

validate_role_trust() {
  local role_arn="$1"
  local expected_service="$2"
  local role_name trust_count
  role_name="${role_arn##*/}"

  [[ -n "$role_arn" ]] || fail "Se recibió un ARN IAM vacío al validar la confianza del rol."
  [[ -n "$role_name" ]] || fail "No fue posible extraer el nombre del rol desde el ARN: '$role_arn'."

  trust_count=$(aws iam get-role \
    --role-name "$role_name" \
    --query "Role.AssumeRolePolicyDocument.Statement[?Principal.Service=='${expected_service}'] | length(@)" \
    --output text \
    --no-cli-pager)

  [[ "$trust_count" != "0" ]] ||
    fail "El rol $role_name no confía en $expected_service."
}

#######################################
# ECR
#######################################
ensure_ecr_repositories() {
  local repository rc

  for repository in "${ECR_REPOSITORIES[@]}"; do
    if repository_exists "$repository"; then
      log_ok "Repositorio existente: $repository"
      continue
    else
      rc=$?
    fi

    [[ "$rc" -eq 4 ]] || return "$rc"

    aws ecr create-repository \
      --region "$REGION" \
      --repository-name "$repository" \
      --image-tag-mutability MUTABLE \
      --image-scanning-configuration scanOnPush=true \
      --tags \
        "Key=Project,Value=$PROJECT_NAME" \
        "Key=Environment,Value=$ENVIRONMENT" \
        'Key=ManagedBy,Value=crear-eks.sh' \
      --no-cli-pager \
      >/dev/null

    log_ok "Repositorio creado: $repository"
  done
}

#######################################
# EKS
#######################################
ensure_cluster() {
  local cluster_role_arn="$1"
  local subnet_a="$2"
  local subnet_b="$3"
  local status rc actual_version

  if status=$(get_cluster_status); then
    log_ok "El clúster ya existe. Estado: $status"
  else
    rc=$?
    [[ "$rc" -eq 4 ]] || return "$rc"

    log_info "Creando clúster $CLUSTER_NAME..."

    local create_response create_name create_status request_token
    request_token="${CLUSTER_NAME}-${GITHUB_RUN_ID:-$(date +%s)}-${GITHUB_RUN_ATTEMPT:-1}"
    request_token="${request_token:0:64}"

    create_response=$(aws eks create-cluster \
      --region "$REGION" \
      --name "$CLUSTER_NAME" \
      --version "$KUBERNETES_VERSION" \
      --role-arn "$cluster_role_arn" \
      --resources-vpc-config \
        "subnetIds=${subnet_a},${subnet_b},endpointPublicAccess=true,endpointPrivateAccess=true" \
      --kubernetes-network-config 'ipFamily=ipv4' \
      --logging \
        '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}' \
      --tags \
        "Project=$PROJECT_NAME" \
        "Environment=$ENVIRONMENT" \
        'ManagedBy=crear-eks.sh' \
      --client-request-token "$request_token" \
      --output json \
      --no-cli-pager)

    create_name=$(printf '%s' "$create_response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("cluster",{}).get("name",""))')
    create_status=$(printf '%s' "$create_response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("cluster",{}).get("status",""))')

    if resource_not_found "$create_name" || [[ "$create_name" != "$CLUSTER_NAME" ]]; then
      printf '%s\n' "$create_response" >&2
      fail "create-cluster no devolvió un clúster válido llamado $CLUSTER_NAME."
    fi

    log_ok "AWS registró create-cluster. Estado inicial: ${create_status:-desconocido}."
    wait_for_cluster_active
    status="ACTIVE"
  fi

  case "$status" in
    ACTIVE) ;;
    CREATING | UPDATING | PENDING) wait_for_cluster_active ;;
    FAILED | DELETING)
      show_cluster_health_issues
      fail "El clúster está en estado $status."
      ;;
    *) fail "Estado inesperado del clúster: $status" ;;
  esac

  actual_version=$(aws eks describe-cluster \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --query 'cluster.version' \
    --output text \
    --no-cli-pager)

  if [[ "$actual_version" != "$KUBERNETES_VERSION" ]]; then
    log_warn "El clúster existente usa Kubernetes $actual_version; el script solicita $KUBERNETES_VERSION. No se hará upgrade automático."
  fi
}

ensure_control_plane_logs() {
  local enabled_logs missing=false log_type update_id

  enabled_logs=$(aws eks describe-cluster \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --query 'cluster.logging.clusterLogging[?enabled==`true`].types[]' \
    --output text \
    --no-cli-pager)

  for log_type in "${CONTROL_PLANE_LOG_TYPES[@]}"; do
    if [[ " $enabled_logs " != *" $log_type "* ]]; then
      missing=true
      break
    fi
  done

  if [[ "$missing" == "false" ]]; then
    log_ok "Los logs del plano de control ya están habilitados."
    return 0
  fi

  update_id=$(aws eks update-cluster-config \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --logging \
      '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}' \
    --query 'update.id' \
    --output text \
    --no-cli-pager)

  wait_for_cluster_update "$update_id"
}

ensure_nodegroup() {
  local node_role_arn="$1"
  local subnet_a="$2"
  local subnet_b="$3"
  local status rc

  if status=$(get_nodegroup_status); then
    log_ok "El Node Group ya existe. Estado: $status"
  else
    rc=$?
    [[ "$rc" -eq 4 ]] || return "$rc"

    log_info "Creando Managed Node Group $NODEGROUP_NAME..."

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
        "workload=$PROJECT_NAME,environment=$ENVIRONMENT" \
      --tags \
        "Project=$PROJECT_NAME" \
        "Environment=$ENVIRONMENT" \
        'ManagedBy=crear-eks.sh' \
      --client-request-token "${CLUSTER_NAME}-${NODEGROUP_NAME}-${GITHUB_RUN_ID:-$(date +%s)}-${GITHUB_RUN_ATTEMPT:-1}" \
      --no-cli-pager \
      >/dev/null

    log_ok "AWS aceptó la solicitud create-nodegroup."
    wait_for_nodegroup_active
    return 0
  fi

  case "$status" in
    ACTIVE) ;;
    CREATING | UPDATING) wait_for_nodegroup_active ;;
    CREATE_FAILED | DELETE_FAILED | DEGRADED | DELETING)
      show_nodegroup_health_issues
      fail "El Node Group está en estado $status."
      ;;
    *) fail "Estado inesperado del Node Group: $status" ;;
  esac
}

#######################################
# ADD-ONS
#######################################
ensure_addon() {
  local addon_name="$1"
  local status rc

  if status=$(get_addon_status "$addon_name"); then
    case "$status" in
      ACTIVE)
        log_ok "Add-on existente y activo: $addon_name"
        return 0
        ;;
      CREATING | UPDATING)
        wait_for_addon_active "$addon_name"
        return 0
        ;;
      CREATE_FAILED | UPDATE_FAILED | DELETE_FAILED | DEGRADED)
        show_addon_health_issues "$addon_name"
        fail "El add-on existente '$addon_name' está en estado $status."
        ;;
      *) fail "Estado inesperado del add-on '$addon_name': $status" ;;
    esac
  else
    rc=$?
  fi

  [[ "$rc" -eq 4 ]] || return "$rc"

  log_info "Instalando add-on: $addon_name"
  aws eks create-addon \
    --region "$REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name "$addon_name" \
    --resolve-conflicts OVERWRITE \
    --client-request-token "${CLUSTER_NAME}-${addon_name}-${GITHUB_RUN_ID:-$(date +%s)}-${GITHUB_RUN_ATTEMPT:-1}" \
    --no-cli-pager \
    >/dev/null

  wait_for_addon_active "$addon_name"
}

resolve_cloudwatch_role_arn() {
  local role_arn rc

  if [[ -n "$CLOUDWATCH_ROLE_ARN_INPUT" ]]; then
    printf '%s\n' "$CLOUDWATCH_ROLE_ARN_INPUT"
    return 0
  fi

  if role_arn=$(get_role_arn "$CLOUDWATCH_ROLE_NAME"); then
    printf '%s\n' "$role_arn"
    return 0
  else
    rc=$?
  fi

  [[ "$rc" -eq 4 ]] && return 4
  return "$rc"
}

ensure_cloudwatch_observability() {
  local cloudwatch_role_arn association_id current_role_arn rc

  if [[ "$CLOUDWATCH_ENABLED" != "true" ]]; then
    log_warn "CloudWatch Observability está deshabilitado."
    return 0
  fi

  ensure_addon 'eks-pod-identity-agent'

  if cloudwatch_role_arn=$(resolve_cloudwatch_role_arn); then
    :
  else
    rc=$?
    if [[ "$rc" -eq 4 ]]; then
      log_warn "AWS Academy no proporciona el rol '$CLOUDWATCH_ROLE_NAME' y este script no crea IAM Roles."
      log_warn "Se instaló eks-pod-identity-agent, pero se omitirá amazon-cloudwatch-observability."
      log_warn "Para habilitarlo, define el secret o variable CLOUDWATCH_ROLE_ARN con un rol autorizado que tenga CloudWatchAgentServerPolicy."
      return 0
    fi
    return "$rc"
  fi

  validate_role_trust "$cloudwatch_role_arn" 'pods.eks.amazonaws.com'

  association_id=$(aws eks list-pod-identity-associations \
    --region "$REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --query "associations[?namespace=='amazon-cloudwatch' && serviceAccount=='cloudwatch-agent'].associationId | [0]" \
    --output text \
    --no-cli-pager)

  if is_empty_aws_value "$association_id"; then
    association_id=$(aws eks create-pod-identity-association \
      --region "$REGION" \
      --cluster-name "$CLUSTER_NAME" \
      --namespace amazon-cloudwatch \
      --service-account cloudwatch-agent \
      --role-arn "$cloudwatch_role_arn" \
      --tags \
        "Project=$PROJECT_NAME" \
        "Environment=$ENVIRONMENT" \
        'ManagedBy=crear-eks.sh' \
      --query 'association.associationId' \
      --output text \
      --no-cli-pager)

    log_ok "Pod Identity Association creada: $association_id"
  else
    current_role_arn=$(aws eks describe-pod-identity-association \
      --region "$REGION" \
      --cluster-name "$CLUSTER_NAME" \
      --association-id "$association_id" \
      --query 'association.roleArn' \
      --output text \
      --no-cli-pager)

    if [[ "$current_role_arn" != "$cloudwatch_role_arn" ]]; then
      aws eks update-pod-identity-association \
        --region "$REGION" \
        --cluster-name "$CLUSTER_NAME" \
        --association-id "$association_id" \
        --role-arn "$cloudwatch_role_arn" \
        --no-cli-pager \
        >/dev/null
      log_ok "Pod Identity Association actualizada."
    else
      log_ok "Pod Identity Association ya configurada."
    fi
  fi

  ensure_addon 'amazon-cloudwatch-observability'
}

#######################################
# KUBECONFIG Y VERIFICACIÓN
#######################################
configure_kubeconfig() {
  require_command kubectl

  aws eks update-kubeconfig \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --alias "$CLUSTER_NAME" \
    --no-cli-pager

  kubectl config use-context "$CLUSTER_NAME" >/dev/null
  log_ok "Kubeconfig actualizado y contexto seleccionado."
}

verify_kubernetes() {
  local ready_node_count

  kubectl get nodes -o wide

  ready_node_count=$(kubectl get nodes \
    --no-headers | awk '$2 == "Ready" {count++} END {print count+0}')

  [[ "$ready_node_count" -ge "$NODE_MIN_SIZE" ]] ||
    fail "Solo hay $ready_node_count nodos Ready; se esperaban al menos $NODE_MIN_SIZE."

  log_ok "Nodos Ready: $ready_node_count"
}

#######################################
# VALIDACIONES INICIALES
#######################################
validate_inputs() {
  require_command aws
  require_command kubectl

  validate_integer NODE_DISK_SIZE "$NODE_DISK_SIZE"
  validate_integer NODE_MIN_SIZE "$NODE_MIN_SIZE"
  validate_integer NODE_DESIRED_SIZE "$NODE_DESIRED_SIZE"
  validate_integer NODE_MAX_SIZE "$NODE_MAX_SIZE"
  validate_integer CLUSTER_WAIT_ATTEMPTS "$CLUSTER_WAIT_ATTEMPTS"
  validate_integer NODEGROUP_WAIT_ATTEMPTS "$NODEGROUP_WAIT_ATTEMPTS"
  validate_integer ADDON_WAIT_ATTEMPTS "$ADDON_WAIT_ATTEMPTS"
  validate_integer POLL_INTERVAL_SECONDS "$POLL_INTERVAL_SECONDS"
  validate_boolean CLOUDWATCH_ENABLED "$CLOUDWATCH_ENABLED"

  ((NODE_MIN_SIZE <= NODE_DESIRED_SIZE)) ||
    fail "NODE_MIN_SIZE no puede ser mayor que NODE_DESIRED_SIZE."

  ((NODE_DESIRED_SIZE <= NODE_MAX_SIZE)) ||
    fail "NODE_DESIRED_SIZE no puede ser mayor que NODE_MAX_SIZE."
}

#######################################
# RESUMEN
#######################################
print_summary() {
  local account_id="$1"
  local vpc_id="$2"
  local subnet_a="$3"
  local subnet_b="$4"
  local cluster_status nodegroup_status actual_version endpoint cluster_sg nodegroup_asg
  local pod_identity_status='NOT_INSTALLED'
  local cloudwatch_status='NOT_INSTALLED'
  local repository

  cluster_status=$(get_cluster_status)
  nodegroup_status=$(get_nodegroup_status)

  read -r actual_version endpoint cluster_sg < <(aws eks describe-cluster \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --query 'cluster.[version,endpoint,resourcesVpcConfig.clusterSecurityGroupId]' \
    --output text \
    --no-cli-pager)

  nodegroup_asg=$(aws eks describe-nodegroup \
    --region "$REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --query 'nodegroup.resources.autoScalingGroups[0].name' \
    --output text \
    --no-cli-pager)

  if pod_identity_status=$(get_addon_status 'eks-pod-identity-agent'); then :; else pod_identity_status='NOT_INSTALLED'; fi
  if cloudwatch_status=$(get_addon_status 'amazon-cloudwatch-observability'); then :; else cloudwatch_status='NOT_INSTALLED'; fi

  cat <<EOF_SUMMARY

========================================
AMAZON EKS LISTO
========================================
Cuenta AWS:             $account_id
Región:                 $REGION

VPC:                    $vpc_id
Subred APP A:           $subnet_a
Subred APP B:           $subnet_b

Clúster EKS:            $CLUSTER_NAME
Estado clúster:         $cluster_status
Versión Kubernetes:     $actual_version
Endpoint:               $endpoint
Security Group:         $cluster_sg

Node Group:             $NODEGROUP_NAME
Estado Node Group:      $nodegroup_status
Tipo de instancia:      $NODE_INSTANCE_TYPE
Escalamiento:           $NODE_MIN_SIZE/$NODE_DESIRED_SIZE/$NODE_MAX_SIZE
Auto Scaling Group:     $nodegroup_asg

Observabilidad:
  Control Plane Logs:   ENABLED
  Pod Identity Agent:   $pod_identity_status
  CloudWatch Add-on:    $cloudwatch_status

Repositorios ECR:
EOF_SUMMARY

  for repository in "${ECR_REPOSITORIES[@]}"; do
    printf '  %s.dkr.ecr.%s.amazonaws.com/%s\n' "$account_id" "$REGION" "$repository"
  done

  cat <<EOF_COMMANDS

Comandos de verificación:
  aws eks describe-cluster --region $REGION --name $CLUSTER_NAME
  kubectl get nodes
  kubectl get pods --all-namespaces
  kubectl get addons 2>/dev/null || true
========================================
EOF_COMMANDS
}

#######################################
# MAIN
#######################################
main() {
  local account_id identity_arn
  local vpc_id subnet_a subnet_b subnet_a_az subnet_b_az
  local cluster_role_arn node_role_arn

  print_header

  log_info "0. Validando herramientas, variables y credenciales..."
  validate_inputs

  read -r account_id identity_arn < <(aws sts get-caller-identity \
    --query '[Account,Arn]' \
    --output text \
    --no-cli-pager)

  is_empty_aws_value "$account_id" && fail "No fue posible identificar la cuenta AWS."
  log_ok "Credenciales válidas. Cuenta: $account_id"
  log_ok "Identidad: $identity_arn"

  log_info "1. Descubriendo VPC y subredes privadas APP..."
  vpc_id=$(find_vpc)
  subnet_a=$(find_subnet "$vpc_id" "${NETWORK_PROJECT_NAME}-app-a")
  subnet_b=$(find_subnet "$vpc_id" "${NETWORK_PROJECT_NAME}-app-b")

  subnet_a_az=$(validate_private_subnet "$subnet_a")
  subnet_b_az=$(validate_private_subnet "$subnet_b" "$subnet_a_az")

  log_ok "VPC: $vpc_id"
  log_ok "Subred APP A: $subnet_a ($subnet_a_az)"
  log_ok "Subred APP B: $subnet_b ($subnet_b_az)"

  log_info "2. Validando rutas privadas y NAT Gateway..."
  validate_nat_route "$vpc_id" "$subnet_a"
  validate_nat_route "$vpc_id" "$subnet_b"

  log_info "3. Descubriendo roles IAM existentes de AWS Academy..."
  cluster_role_arn=$(resolve_role_arn "$EKS_CLUSTER_ROLE_ARN" "$EKS_CLUSTER_ROLE_NAME")
  node_role_arn=$(resolve_role_arn "$EKS_NODE_ROLE_ARN" "$EKS_NODE_ROLE_NAME")

  validate_role_trust "$cluster_role_arn" 'eks.amazonaws.com'
  validate_role_trust "$node_role_arn" 'ec2.amazonaws.com'
  log_ok "Rol del clúster: $cluster_role_arn"
  log_ok "Rol de los nodos: $node_role_arn"

  log_info "4. Asegurando repositorios Amazon ECR..."
  ensure_ecr_repositories

  log_info "5. Asegurando clúster Amazon EKS..."
  ensure_cluster "$cluster_role_arn" "$subnet_a" "$subnet_b"

  log_info "6. Asegurando logs del plano de control..."
  ensure_control_plane_logs

  log_info "7. Configurando kubeconfig..."
  configure_kubeconfig

  log_info "8. Asegurando Managed Node Group..."
  ensure_nodegroup "$node_role_arn" "$subnet_a" "$subnet_b"

  log_info "9. Verificando nodos Kubernetes..."
  verify_kubernetes

  log_info "10. Configurando add-ons y observabilidad..."
  ensure_cloudwatch_observability

  log_info "11. Resumen final..."
  print_summary "$account_id" "$vpc_id" "$subnet_a" "$subnet_b"
}

main "$@"