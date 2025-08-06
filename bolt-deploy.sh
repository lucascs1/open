#!/bin/bash
# ------------------------------------------------------------------------------
# bolt-deploy.sh
#
# Script de deploy automatizado para projetos exportados do Bolt.new
# Utiliza Docker Swarm + Traefik + validação de domínio com SSL Let's Encrypt.
#
# 🔗 Este script é um complemento (addon) para o instalador oficial SetupOrion:
# https://oriondesign.art.br/setup
#
# Desenvolvido para uso com a estrutura de rede e stack definida pelo SetupOrion.
# ------------------------------------------------------------------------------

set -e

PORTAINER_VARS="/root/dados_vps/dados_portainer"
if [[ -f "$PORTAINER_VARS" ]]; then
  PORTAINER_URL=$(grep -oP '(?<=Dominio do portainer: ).*' "$PORTAINER_VARS")
  TOKEN=$(grep -oP '(?<=Token: ).*' "$PORTAINER_VARS")

  response_endpoints=$(curl -k -s -X GET -H "Authorization: Bearer $TOKEN" "https://$PORTAINER_URL/api/endpoints")
  if ! echo "$response_endpoints" | jq empty 2>/dev/null; then
    echo "❌ Erro ao buscar endpoints. Verifique o TOKEN ou a URL do Portainer."
    echo "Resposta da API: $response_endpoints"
    exit 1
  fi

  ENDPOINT_ID=$(echo "$response_endpoints" | jq -r '.[] | select(.Name == "primary") | .Id')
  if [[ -z "$ENDPOINT_ID" ]]; then
    echo "❌ ENDPOINT_ID não encontrado. Verifique o nome do endpoint no Portainer (esperado: 'primary')."
    exit 1
  fi

  response_swarm=$(curl -k -s -X GET -H "Authorization: Bearer $TOKEN" "https://$PORTAINER_URL/api/endpoints/$ENDPOINT_ID/docker/swarm")
  if ! echo "$response_swarm" | jq empty 2>/dev/null; then
    echo "❌ Erro ao buscar informações do Swarm. Verifique o ENDPOINT_ID e as permissões da API."
    echo "Resposta da API: $response_swarm"
    exit 1
  fi

  SWARM_ID=$(echo "$response_swarm" | jq -r .ID)
else
  echo "❌ Arquivo de variáveis do Portainer não encontrado: $PORTAINER_VARS"
  exit 1
fi

# 🚀 Identificação do script
echo "🚀 Iniciando deploy de projeto Bolt..."

# 🔎 Buscar nome da rede Traefik no arquivo de configuração
CONFIG_VPS_FILE="/root/dados_vps/dados_vps"
if [[ -f "$CONFIG_VPS_FILE" ]]; then
  TRAEFIK_NETWORK=$(grep -i 'Rede interna:' "$CONFIG_VPS_FILE" | cut -d':' -f2 | xargs)
  echo "🌐 Rede Traefik detectada: $TRAEFIK_NETWORK"
else
  echo "❌ Arquivo de dados da VPS não encontrado em $CONFIG_VPS_FILE"
  echo "   Não foi possível identificar a rede do Traefik automaticamente."
  exit 1
fi

# 🧱 Nome do projeto
read -p "📛 Nome do projeto (ex: seeds-site): " PROJECT_NAME
PROJECT_SLUG=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

# 📦 Caminho do ZIP exportado do Bolt
read -p "📁 Caminho completo do .zip exportado do Bolt: " ZIP_PATH

# 🌐 Deseja configurar domínio?
read -p "🌍 Deseja apontar um domínio para o projeto? (S/N): " USE_DOMAIN
USE_DOMAIN=$(echo "$USE_DOMAIN" | tr '[:upper:]' '[:lower:]')

DOMAIN=""
if [[ "$USE_DOMAIN" == "s" || "$USE_DOMAIN" == "y" ]]; then
  read -p "🔗 Informe o domínio completo (ex: exemplo.com): " DOMAIN
  echo "🌐 Verificando apontamento do domínio..."

  # Obter IPs da VPS (IPv4 e IPv6)
  VPS_IPV4=$(curl -s https://ipv4.icanhazip.com)
  VPS_IPV6=$(curl -s https://ipv6.icanhazip.com)

  # Obter todos os IPs do domínio
  DOMAIN_IPS=$(dig +short "$DOMAIN")

  MATCHED=false
  for ip in $DOMAIN_IPS; do
    if [[ "$ip" == "$VPS_IPV4" || "$ip" == "$VPS_IPV6" ]]; then
      MATCHED=true
      break
    fi
  done

  if [[ "$MATCHED" == false ]]; then
    echo "❌ O domínio $DOMAIN não está apontado para esta VPS."
    echo "   IPs do domínio: $DOMAIN_IPS"
    echo "   IP da VPS (IPv4): $VPS_IPV4"
    echo "   IP da VPS (IPv6): $VPS_IPV6"
    exit 1
  fi

  echo "✅ Domínio validado com sucesso."
fi

# 📁 Estrutura de diretórios
BASE_DIR="/root/bolt-sites/$PROJECT_SLUG"
PROJECT_DIR="$BASE_DIR/project"
BACKUP_DIR="$BASE_DIR/backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

IS_FIRST_DEPLOY=false
if [[ ! -d "$PROJECT_DIR" ]]; then
  IS_FIRST_DEPLOY=true
  echo "🆕 Primeiro deploy detectado."
else
  echo "♻️ Atualização detectada para $PROJECT_SLUG."
fi

mkdir -p "$PROJECT_DIR"
mkdir -p "$BACKUP_DIR"

# 🔐 Backup
if [[ -f "$PROJECT_DIR/package.json" ]]; then
  echo "🧰 Backup do projeto atual..."
  mv "$PROJECT_DIR" "$BACKUP_DIR/project-$TIMESTAMP"
  mkdir -p "$PROJECT_DIR"
fi

# 📦 Extração
echo "📦 Extraindo novo projeto..."
unzip -o "$ZIP_PATH" -d "$PROJECT_DIR"

# ⚙️ Corrigir estrutura duplicada (caso o ZIP tenha uma pasta interna 'project/')
if [[ -d "$PROJECT_DIR/project" ]]; then
  echo "🔄 Corrigindo estrutura de pastas..."
  mv "$PROJECT_DIR/project/"* "$PROJECT_DIR/"
  rm -rf "$PROJECT_DIR/project"
fi

# 🔧 Correções
PKG_JSON="$PROJECT_DIR/package.json"
if [[ ! -f "$PKG_JSON" ]]; then
  echo "❌ package.json não encontrado. Abortando."
  exit 1
fi

echo "🔧 Corrigindo script preview..."
if grep -q '"preview":' "$PKG_JSON"; then
  sed -i 's|"preview": *".*"|"preview": "vite preview --port 4173 --host 0.0.0.0"|' "$PKG_JSON"
else
  sed -i '/"scripts": {/a \    "preview": "vite preview --port 4173 --host 0.0.0.0",' "$PKG_JSON"
fi

VITE_CONFIG="$PROJECT_DIR/vite.config.ts"
if [[ -f "$VITE_CONFIG" ]] && ! grep -q 'preview:' "$VITE_CONFIG"; then
  echo "🛠️ Adicionando bloco preview em vite.config.ts..."
  sed -i "/defineConfig({/a \  preview: {\n    port: 4173,\n    host: true,\n    allowedHosts: ['$DOMAIN']\n  }," "$VITE_CONFIG"
fi

# 📄 Dockerfile
DOCKERFILE="$PROJECT_DIR/Dockerfile"
if [[ ! -f "$DOCKERFILE" ]]; then
  echo "📄 Criando Dockerfile..."
  cat > "$DOCKERFILE" <<'EOF'
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
RUN npm run build

FROM node:20-alpine AS runner
WORKDIR /app
COPY --from=builder /app ./
RUN npm install -g vite
EXPOSE 4173
CMD ["vite", "preview", "--host", "0.0.0.0", "--port", "4173"]
EOF
fi

# 📄 docker-compose.yaml
DOCKER_COMPOSE="$PROJECT_DIR/docker-compose.yaml"
if [[ ! -f "$DOCKER_COMPOSE" ]]; then
  echo "📄 Criando docker-compose.yaml..."
  cat > "$DOCKER_COMPOSE" <<EOF
version: "3.8"

services:
  $PROJECT_SLUG:
    build:
      context: .
    image: $PROJECT_SLUG:latest
    networks:
      - $TRAEFIK_NETWORK
    deploy:
      labels:
        - traefik.enable=1
        - traefik.http.routers.$PROJECT_SLUG.rule=Host(\`$DOMAIN\`)
        - traefik.http.routers.$PROJECT_SLUG.entrypoints=websecure
        - traefik.http.routers.$PROJECT_SLUG.priority=1
        - traefik.http.routers.$PROJECT_SLUG.tls.certresolver=letsencryptresolver
        - traefik.http.routers.$PROJECT_SLUG.service=$PROJECT_SLUG
        - traefik.http.services.$PROJECT_SLUG.loadbalancer.server.port=4173
        - traefik.http.services.$PROJECT_SLUG.loadbalancer.passHostHeader=true

networks:
  $TRAEFIK_NETWORK:
    external: true
EOF
fi

# ▶️ Deploy
cd "$PROJECT_DIR"

if [[ "$IS_FIRST_DEPLOY" = false ]]; then
  echo "🗑️ Removendo serviço antigo: $PROJECT_SLUG"
  docker stack rm "$PROJECT_SLUG" || true
  echo "⏳ Aguardando..."
  sleep 10
fi

echo "🐳 Buildando imagem..."
docker build --no-cache -t $PROJECT_SLUG:latest .

if [[ "$IS_FIRST_DEPLOY" = true ]]; then
  echo "♻️ Reiniciando Traefik..."
  docker service update --force traefik_traefik
  sleep 10
fi

echo "🚀 Preparando envio da stack para o Portainer..."

STACK_NAME="$PROJECT_SLUG"
STACK_FILE_PATH="$PROJECT_DIR/docker-compose.yaml"

# Pasta temporária para armazenar respostas
TMP_DIR="/tmp/deploy_$STACK_NAME"
mkdir -p "$TMP_DIR"
trap "rm -rf $TMP_DIR" EXIT
response_output="$TMP_DIR/response.json"
erro_output="$TMP_DIR/erro.log"

# Validar variáveis essenciais
if [[ -z "$PORTAINER_URL" || -z "$TOKEN" || -z "$ENDPOINT_ID" || -z "$SWARM_ID" ]]; then
  echo "❌ Variáveis do Portainer não definidas corretamente. Abortando."
  exit 1
fi

# Verificar se a stack já existe
echo "🔍 Verificando existência da stack '$STACK_NAME'..."
EXISTING_STACK_ID=$(curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://$PORTAINER_URL/api/stacks" | jq -r ".[] | select(.Name==\"$STACK_NAME\") | .Id")

if [[ -n "$EXISTING_STACK_ID" ]]; then
  echo "🗑️ Stack existente encontrada (ID: $EXISTING_STACK_ID). Removendo..."
  curl -sk -X DELETE -H "Authorization: Bearer $TOKEN" \
    "https://$PORTAINER_URL/api/stacks/$EXISTING_STACK_ID?endpointId=$ENDPOINT_ID"
  sleep 3
fi

# Criar nova stack
echo "📦 Criando nova stack via Portainer API..."
http_code=$(curl -s -o "$response_output" -w "%{http_code}" -k -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -F "Name=$STACK_NAME" \
  -F "file=@$STACK_FILE_PATH" \
  -F "SwarmID=$SWARM_ID" \
  -F "endpointId=$ENDPOINT_ID" \
  "https://$PORTAINER_URL/api/stacks/create/swarm/file" 2> "$erro_output")

response_body=$(cat "$response_output")

if [ "$http_code" -eq 200 ]; then
  echo -e "✅ Stack '$STACK_NAME' criada com sucesso via Portainer!"
  [[ -n "$DOMAIN" ]] && echo "🌐 Acesse: https://$DOMAIN"
else
  echo "❌ Erro HTTP $http_code durante envio da stack '$STACK_NAME'"
  echo "Mensagem de erro: $(cat "$erro_output")"
  echo "Detalhes: $(echo "$response_body" | jq .)"
  exit 1
fi

# ✅ Verificação
echo "⏳ Verificando status da stack no Docker Swarm..."
sleep 5
for i in {1..10}; do
  STATUS=$(docker service ls | grep "${PROJECT_SLUG}_${PROJECT_SLUG}" | awk '{print $4}')
  if [[ "$STATUS" == "1/1" ]]; then
    echo "✅ Projeto $PROJECT_SLUG rodando com sucesso!"
    [[ "$DOMAIN" != "" ]] && echo "🌐 https://$DOMAIN"
    exit 0
  fi
  echo "⏳ Tentando novamente ($i/10)..."
  sleep 3
done

echo "❌ O projeto não subiu corretamente. Verifique logs com:"
echo "   docker service logs ${PROJECT_SLUG}_${PROJECT_SLUG}"
exit 1
