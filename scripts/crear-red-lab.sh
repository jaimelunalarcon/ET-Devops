#!/bin/bash
set -euo pipefail

#####################################
# CONFIGURACIÓN
#####################################
PROJECT_NAME="red-lab"
CLUSTER_NAME="tienda-eks"
REGION="us-east-1"

echo "====================================="
echo "Creando infraestructura de red AWS"
echo "====================================="
echo "Proyecto: $PROJECT_NAME"
echo "Región:   $REGION"
echo ""

#####################################
# FUNCIONES AUXILIARES
#####################################
resource_not_found() {
  local value="${1:-}"

  [ -z "$value" ] || [ "$value" = "None" ] || [ "$value" = "null" ]
}

create_or_replace_route() {
  local route_table_id="$1"
  local destination="$2"
  local target_type="$3"
  local target_id="$4"

  local current_state

  current_state=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --route-table-ids "$route_table_id" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='${destination}'].State | [0]" \
    --output text)

  if resource_not_found "$current_state"; then
    if [ "$target_type" = "gateway" ]; then
      aws ec2 create-route \
        --region "$REGION" \
        --route-table-id "$route_table_id" \
        --destination-cidr-block "$destination" \
        --gateway-id "$target_id" \
        >/dev/null
    else
      aws ec2 create-route \
        --region "$REGION" \
        --route-table-id "$route_table_id" \
        --destination-cidr-block "$destination" \
        --nat-gateway-id "$target_id" \
        >/dev/null
    fi
  else
    if [ "$target_type" = "gateway" ]; then
      aws ec2 replace-route \
        --region "$REGION" \
        --route-table-id "$route_table_id" \
        --destination-cidr-block "$destination" \
        --gateway-id "$target_id" \
        >/dev/null
    else
      aws ec2 replace-route \
        --region "$REGION" \
        --route-table-id "$route_table_id" \
        --destination-cidr-block "$destination" \
        --nat-gateway-id "$target_id" \
        >/dev/null
    fi
  fi
}

associate_route_table() {
  local subnet_id="$1"
  local expected_route_table_id="$2"

  local current_route_table_id
  local association_id

  current_route_table_id=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --filters "Name=association.subnet-id,Values=$subnet_id" \
    --query "RouteTables[0].RouteTableId" \
    --output text)

  if [ "$current_route_table_id" = "$expected_route_table_id" ]; then
    return
  fi

  association_id=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --filters "Name=association.subnet-id,Values=$subnet_id" \
    --query "RouteTables[0].Associations[?SubnetId=='${subnet_id}'].RouteTableAssociationId | [0]" \
    --output text)

  if resource_not_found "$association_id"; then
    aws ec2 associate-route-table \
      --region "$REGION" \
      --subnet-id "$subnet_id" \
      --route-table-id "$expected_route_table_id" \
      >/dev/null
  else
    aws ec2 replace-route-table-association \
      --region "$REGION" \
      --association-id "$association_id" \
      --route-table-id "$expected_route_table_id" \
      >/dev/null
  fi
}

create_subnet() {
  local name="$1"
  local cidr="$2"
  local az="$3"
  local tier="$4"
  local network_type="$5"
  local public_ip="$6"

  local subnet_id

  subnet_id=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters \
      "Name=vpc-id,Values=$VPC_ID" \
      "Name=tag:Name,Values=$name" \
    --query "Subnets[0].SubnetId" \
    --output text)

  if resource_not_found "$subnet_id"; then
    subnet_id=$(aws ec2 create-subnet \
      --region "$REGION" \
      --vpc-id "$VPC_ID" \
      --cidr-block "$cidr" \
      --availability-zone "$az" \
      --query "Subnet.SubnetId" \
      --output text)

    echo "Creada subred $name: $subnet_id" >&2
  else
    echo "Subred existente $name: $subnet_id" >&2
  fi

  aws ec2 create-tags \
    --region "$REGION" \
    --resources "$subnet_id" \
    --tags \
      Key=Name,Value="$name" \
      Key=Project,Value="$PROJECT_NAME" \
      Key=Tier,Value="$tier" \
      Key=Network,Value="$network_type" \
    >/dev/null

  if [ "$public_ip" = "true" ]; then
    aws ec2 modify-subnet-attribute \
      --region "$REGION" \
      --subnet-id "$subnet_id" \
      --map-public-ip-on-launch '{"Value":true}'
  else
    aws ec2 modify-subnet-attribute \
      --region "$REGION" \
      --subnet-id "$subnet_id" \
      --no-map-public-ip-on-launch
  fi

  echo "$subnet_id"
}

#####################################
# 0. VALIDACIONES
#####################################
echo "0. Validando credenciales AWS..."

aws sts get-caller-identity \
  --region "$REGION" \
  --no-cli-pager \
  >/dev/null

echo "Credenciales AWS válidas."

#####################################
# 1. VPC
#####################################
echo ""
echo "1. VPC..."

VPC_ID=$(aws ec2 describe-vpcs \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" \
  --query "Vpcs[0].VpcId" \
  --output text)

if resource_not_found "$VPC_ID"; then
  VPC_ID=$(aws ec2 create-vpc \
    --region "$REGION" \
    --cidr-block "10.0.0.0/20" \
    --query "Vpc.VpcId" \
    --output text)

  echo "VPC creada: $VPC_ID"
else
  echo "VPC existente: $VPC_ID"
fi

aws ec2 create-tags \
  --region "$REGION" \
  --resources "$VPC_ID" \
  --tags \
    Key=Name,Value="${PROJECT_NAME}-vpc" \
    Key=Project,Value="$PROJECT_NAME" \
    Key=Environment,Value=academic \
  >/dev/null

aws ec2 modify-vpc-attribute \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --enable-dns-hostnames '{"Value":true}'

aws ec2 modify-vpc-attribute \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --enable-dns-support '{"Value":true}'

#####################################
# 2. INTERNET GATEWAY
#####################################
echo ""
echo "2. Internet Gateway..."

IGW_ID=$(aws ec2 describe-internet-gateways \
  --region "$REGION" \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query "InternetGateways[0].InternetGatewayId" \
  --output text)

if resource_not_found "$IGW_ID"; then
  IGW_ID=$(aws ec2 create-internet-gateway \
    --region "$REGION" \
    --query "InternetGateway.InternetGatewayId" \
    --output text)

  aws ec2 attach-internet-gateway \
    --region "$REGION" \
    --vpc-id "$VPC_ID" \
    --internet-gateway-id "$IGW_ID"

  echo "Internet Gateway creado: $IGW_ID"
else
  echo "Internet Gateway existente: $IGW_ID"
fi

aws ec2 create-tags \
  --region "$REGION" \
  --resources "$IGW_ID" \
  --tags \
    Key=Name,Value="${PROJECT_NAME}-igw" \
    Key=Project,Value="$PROJECT_NAME" \
  >/dev/null

#####################################
# 3. SUBREDES
#####################################
echo ""
echo "3. Subredes..."

PUB_A=$(create_subnet \
  "${PROJECT_NAME}-public-a" \
  "10.0.0.0/24" \
  "${REGION}a" \
  "public" \
  "public" \
  "true")

PUB_B=$(create_subnet \
  "${PROJECT_NAME}-public-b" \
  "10.0.1.0/24" \
  "${REGION}b" \
  "public" \
  "public" \
  "true")

APP_A=$(create_subnet \
  "${PROJECT_NAME}-app-a" \
  "10.0.2.0/24" \
  "${REGION}a" \
  "app" \
  "private" \
  "false")

APP_B=$(create_subnet \
  "${PROJECT_NAME}-app-b" \
  "10.0.3.0/24" \
  "${REGION}b" \
  "app" \
  "private" \
  "false")

DATA_A=$(create_subnet \
  "${PROJECT_NAME}-data-a" \
  "10.0.4.0/24" \
  "${REGION}a" \
  "data" \
  "private" \
  "false")

DATA_B=$(create_subnet \
  "${PROJECT_NAME}-data-b" \
  "10.0.5.0/24" \
  "${REGION}b" \
  "data" \
  "private" \
  "false")

#####################################
# 3.1. TAGS PARA EKS
#####################################
echo ""
echo "3.1. Agregando tags para Amazon EKS..."

aws ec2 create-tags \
  --region "$REGION" \
  --resources "$PUB_A" "$PUB_B" \
  --tags \
    Key=kubernetes.io/role/elb,Value=1 \
    Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared \
  >/dev/null

aws ec2 create-tags \
  --region "$REGION" \
  --resources "$APP_A" "$APP_B" \
  --tags \
    Key=kubernetes.io/role/internal-elb,Value=1 \
    Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared \
  >/dev/null

# Las subredes DATA no reciben el tag del clúster.
# Se reservan para servicios de datos y una posible evolución hacia Amazon RDS.

aws ec2 delete-tags \
  --region "$REGION" \
  --resources "$DATA_A" "$DATA_B" \
  --tags "Key=kubernetes.io/cluster/${CLUSTER_NAME}" \
  >/dev/null 2>&1 || true

#####################################
# 4. ELASTIC IP Y NAT GATEWAY
#####################################
echo ""
echo "4. NAT Gateway..."

EIP_ALLOC=$(aws ec2 describe-addresses \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-nat-eip" \
  --query "Addresses[0].AllocationId" \
  --output text)

if resource_not_found "$EIP_ALLOC"; then
  EIP_ALLOC=$(aws ec2 allocate-address \
    --region "$REGION" \
    --domain vpc \
    --query "AllocationId" \
    --output text)

  echo "Elastic IP creada: $EIP_ALLOC"
else
  echo "Elastic IP existente: $EIP_ALLOC"
fi

aws ec2 create-tags \
  --region "$REGION" \
  --resources "$EIP_ALLOC" \
  --tags \
    Key=Name,Value="${PROJECT_NAME}-nat-eip" \
    Key=Project,Value="$PROJECT_NAME" \
  >/dev/null

NAT_ID=$(aws ec2 describe-nat-gateways \
  --region "$REGION" \
  --filter \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=tag:Name,Values=${PROJECT_NAME}-nat" \
    "Name=state,Values=pending,available" \
  --query "NatGateways[0].NatGatewayId" \
  --output text)

if resource_not_found "$NAT_ID"; then
  NAT_ID=$(aws ec2 create-nat-gateway \
    --region "$REGION" \
    --subnet-id "$PUB_A" \
    --allocation-id "$EIP_ALLOC" \
    --tag-specifications \
      "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-nat},{Key=Project,Value=${PROJECT_NAME}}]" \
    --query "NatGateway.NatGatewayId" \
    --output text)

  echo "NAT Gateway creado: $NAT_ID"
else
  echo "NAT Gateway existente: $NAT_ID"
fi

echo "Esperando que el NAT Gateway quede disponible..."

aws ec2 wait nat-gateway-available \
  --region "$REGION" \
  --nat-gateway-ids "$NAT_ID"

echo "NAT Gateway disponible."

#####################################
# 5. TABLA DE RUTAS PÚBLICA
#####################################
echo ""
echo "5. Tabla de rutas pública..."

RT_PUBLIC=$(aws ec2 describe-route-tables \
  --region "$REGION" \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=tag:Name,Values=${PROJECT_NAME}-rt-public" \
  --query "RouteTables[0].RouteTableId" \
  --output text)

if resource_not_found "$RT_PUBLIC"; then
  RT_PUBLIC=$(aws ec2 create-route-table \
    --region "$REGION" \
    --vpc-id "$VPC_ID" \
    --query "RouteTable.RouteTableId" \
    --output text)

  echo "Tabla de rutas pública creada: $RT_PUBLIC"
else
  echo "Tabla de rutas pública existente: $RT_PUBLIC"
fi

aws ec2 create-tags \
  --region "$REGION" \
  --resources "$RT_PUBLIC" \
  --tags \
    Key=Name,Value="${PROJECT_NAME}-rt-public" \
    Key=Project,Value="$PROJECT_NAME" \
    Key=Network,Value=public \
  >/dev/null

create_or_replace_route \
  "$RT_PUBLIC" \
  "0.0.0.0/0" \
  "gateway" \
  "$IGW_ID"

associate_route_table "$PUB_A" "$RT_PUBLIC"
associate_route_table "$PUB_B" "$RT_PUBLIC"

#####################################
# 6. TABLA DE RUTAS PRIVADA
#####################################
echo ""
echo "6. Tabla de rutas privada..."

RT_PRIVATE=$(aws ec2 describe-route-tables \
  --region "$REGION" \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=tag:Name,Values=${PROJECT_NAME}-rt-private" \
  --query "RouteTables[0].RouteTableId" \
  --output text)

if resource_not_found "$RT_PRIVATE"; then
  RT_PRIVATE=$(aws ec2 create-route-table \
    --region "$REGION" \
    --vpc-id "$VPC_ID" \
    --query "RouteTable.RouteTableId" \
    --output text)

  echo "Tabla de rutas privada creada: $RT_PRIVATE"
else
  echo "Tabla de rutas privada existente: $RT_PRIVATE"
fi

aws ec2 create-tags \
  --region "$REGION" \
  --resources "$RT_PRIVATE" \
  --tags \
    Key=Name,Value="${PROJECT_NAME}-rt-private" \
    Key=Project,Value="$PROJECT_NAME" \
    Key=Network,Value=private \
  >/dev/null

create_or_replace_route \
  "$RT_PRIVATE" \
  "0.0.0.0/0" \
  "nat" \
  "$NAT_ID"

associate_route_table "$APP_A" "$RT_PRIVATE"
associate_route_table "$APP_B" "$RT_PRIVATE"
associate_route_table "$DATA_A" "$RT_PRIVATE"
associate_route_table "$DATA_B" "$RT_PRIVATE"

#####################################
# 7. VPC ENDPOINT PARA S3
#####################################
echo ""
echo "7. Endpoint S3..."

S3_ENDPOINT_ID=$(aws ec2 describe-vpc-endpoints \
  --region "$REGION" \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=service-name,Values=com.amazonaws.${REGION}.s3" \
    "Name=vpc-endpoint-state,Values=pending,available" \
  --query "VpcEndpoints[0].VpcEndpointId" \
  --output text)

if resource_not_found "$S3_ENDPOINT_ID"; then
  S3_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
    --region "$REGION" \
    --vpc-id "$VPC_ID" \
    --service-name "com.amazonaws.${REGION}.s3" \
    --vpc-endpoint-type Gateway \
    --route-table-ids "$RT_PRIVATE" \
    --query "VpcEndpoint.VpcEndpointId" \
    --output text)

  echo "Endpoint S3 creado: $S3_ENDPOINT_ID"
else
  echo "Endpoint S3 existente: $S3_ENDPOINT_ID"

  aws ec2 modify-vpc-endpoint \
    --region "$REGION" \
    --vpc-endpoint-id "$S3_ENDPOINT_ID" \
    --add-route-table-ids "$RT_PRIVATE" \
    >/dev/null 2>&1 || true
fi

aws ec2 create-tags \
  --region "$REGION" \
  --resources "$S3_ENDPOINT_ID" \
  --tags \
    Key=Name,Value="${PROJECT_NAME}-s3-endpoint" \
    Key=Project,Value="$PROJECT_NAME" \
  >/dev/null

#####################################
# RESUMEN
#####################################
echo ""
echo "====================================="
echo "INFRAESTRUCTURA DE RED LISTA"
echo "====================================="
echo "Proyecto:             $PROJECT_NAME"
echo "Región:               $REGION"
echo "Clúster objetivo:     $CLUSTER_NAME"
echo ""
echo "VPC:                  $VPC_ID"
echo "Internet Gateway:     $IGW_ID"
echo "Elastic IP NAT:       $EIP_ALLOC"
echo "NAT Gateway:          $NAT_ID"
echo ""
echo "Subredes públicas:"
echo "  Public A:            $PUB_A"
echo "  Public B:            $PUB_B"
echo ""
echo "Subredes privadas APP:"
echo "  App A:               $APP_A"
echo "  App B:               $APP_B"
echo ""
echo "Subredes privadas DATA:"
echo "  Data A:              $DATA_A"
echo "  Data B:              $DATA_B"
echo ""
echo "Tabla pública:         $RT_PUBLIC"
echo "Tabla privada:         $RT_PRIVATE"
echo "Endpoint S3:           $S3_ENDPOINT_ID"
echo "====================================="