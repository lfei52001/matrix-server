#!/bin/bash
# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 权限运行此脚本"
  exit 1
fi
# 自动生成安全的随机密钥
REGISTRATION_SECRET=$(openssl rand -base64 32)
MACAROON_SECRET=$(openssl rand -base64 32)
FORM_SECRET=$(openssl rand -base64 32)
POSTGRES_PASSWORD=$(openssl rand -base64 32)  # 自动生成 PostgreSQL 密码
# 交互式输入变量并验证
prompt_and_validate() {
  local prompt=$1
  local var_name=$2
  local validation_regex=$3
  local error_msg=$4
  local input
  read -r -p "$prompt" input
  if [ -z "$input" ]; then
    echo "错误：$error_msg 不能为空"
    exit 1
  fi
  if ! echo "$input" | grep -qE "$validation_regex"; then
    echo "错误：无效的 $error_msg 格式"
    exit 1
  fi
  eval "$var_name='$input'"
}
prompt_and_validate "请输入 Matrix 域名（例如：matrix.example.com）： " MATRIX_DOMAIN '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' "Matrix 域名"
prompt_and_validate "请输入用于 Let's Encrypt 和通知的邮箱（例如：user@example.com）： " EMAIL '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' "邮箱"
# 询问是否启用 SMTP 配置
echo "是否启用 SMTP 配置？（y/n，默认 n）： "
read -r ENABLE_SMTP
ENABLE_SMTP=${ENABLE_SMTP:-n}
if [[ "$ENABLE_SMTP" =~ ^[Yy]$ ]]; then
  prompt_and_validate "请输入 SMTP 用户邮箱（例如：user@gmail.com）： " SMTP_USER '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' "SMTP 用户邮箱"
  read -r -s -p "请输入 SMTP 密码（Google 应用专用密码）： " SMTP_PASS
  echo
  if [ -z "$SMTP_PASS" ]; then
    echo "错误：SMTP 密码不能为空"
    exit 1
  fi
else
  SMTP_USER=""
  SMTP_PASS=""
fi
# 询问是否启用 OIDC 配置
echo "是否启用 Google 和 GitHub OIDC 配置？（y/n，默认 n）： "
read -r ENABLE_OIDC
ENABLE_OIDC=${ENABLE_OIDC:-n}
if [[ "$ENABLE_OIDC" =~ ^[Yy]$ ]]; then
  prompt_and_validate "请输入 Google OAuth 客户端 ID： " GOOGLE_CLIENT_ID '^.+$' "Google OAuth 客户端 ID"
  read -r -s -p "请输入 Google OAuth 客户端密钥： " GOOGLE_CLIENT_SECRET
  echo
  if [ -z "$GOOGLE_CLIENT_SECRET" ]; then
    echo "错误：Google OAuth 客户端密钥不能为空"
    exit 1
  fi
  prompt_and_validate "请输入 GitHub OAuth 客户端 ID： " GITHUB_CLIENT_ID '^.+$' "GitHub OAuth 客户端 ID"
  read -r -s -p "请输入 GitHub OAuth 客户端密钥： " GITHUB_CLIENT_SECRET
  echo
  if [ -z "$GITHUB_CLIENT_SECRET" ]; then
    echo "错误：GitHub OAuth 客户端密钥不能为空"
    exit 1
  fi
  OIDC_CONFIG=$(cat << EOF
oidc_providers:
  - idp_id: google
    idp_name: Google
    idp_brand: "google"
    issuer: "https://accounts.google.com/"
    client_id: "$GOOGLE_CLIENT_ID"
    client_secret: "$GOOGLE_CLIENT_SECRET"
    scopes: ["openid", "profile", "email"]
    user_mapping_provider:
      config:
        localpart_template: "{{ user.given_name|lower }}"
        display_name_template: "{{ user.name }}"
        email_template: "{{ user.email }}"
  - idp_id: github
    idp_name: Github
    idp_brand: "github"
    discover: false
    issuer: "https://github.com/"
    client_id: "$GITHUB_CLIENT_ID"
    client_secret: "$GITHUB_CLIENT_SECRET"
    authorization_endpoint: "https://github.com/login/oauth/authorize"
    token_endpoint: "https://github.com/login/oauth/access_token"
    userinfo_endpoint: "https://api.github.com/user"
    scopes: ["read:user"]
    user_mapping_provider:
      config:
        subject_claim: "id"
        localpart_template: "{{ user.login }}"
        display_name_template: "{{ user.name }}"
EOF
)
else
  OIDC_CONFIG=""
fi
# 询问是否部署 Element
echo "是否部署 Element Web？（y/n，默认 n）： "
read -r DEPLOY_ELEMENT
DEPLOY_ELEMENT=${DEPLOY_ELEMENT:-n}
if [[ "$DEPLOY_ELEMENT" =~ ^[Yy]$ ]]; then
  prompt_and_validate "请输入 Element 域名（例如：element.example.com）： " ELEMENT_DOMAIN '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' "Element 域名"
fi
# 询问是否要求注册时需要邮箱
echo "是否要求注册时提供邮箱？（y/n，默认 n）： "
read -r REQUIRE_EMAIL
REQUIRE_EMAIL=${REQUIRE_EMAIL:-n}
if [[ "$REQUIRE_EMAIL" =~ ^[Yy]$ ]]; then
  EMAIL_REGISTRATION_CONFIG="registrations_require_3pid:
  - email"
else
  EMAIL_REGISTRATION_CONFIG=""
fi
# 1. 安装 Docker
echo "安装 Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
if ! sh get-docker.sh; then
  echo "Docker 安装失败"
  exit 1
fi
rm get-docker.sh
# 安装 Docker Compose
echo "安装 Docker Compose..."
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
if ! docker-compose --version; then
  echo "Docker Compose 安装失败"
  exit 1
fi
# 2. 创建 Docker 网络
echo "创建 Docker 网络 matrix_network..."
docker network create matrix_network || true
# 3. 部署 Matrix (Synapse + PostgreSQL)
echo "设置 Matrix 环境..."
mkdir -p matrix
cd matrix
# 创建 docker-compose.yml
cat > docker-compose.yml << EOF
services:
  postgres:
    image: postgres:17
    container_name: postgres
    environment:
      POSTGRES_USER: synapse_user
      POSTGRES_PASSWORD: "$POSTGRES_PASSWORD"
      POSTGRES_DB: synapse
      POSTGRES_INITDB_ARGS: "--encoding=UTF-8 --lc-collate=C --lc-ctype=C"
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    networks:
      - matrix_network
    restart: unless-stopped
  synapse:
    image: matrixdotorg/synapse:latest
    container_name: synapse
    environment:
      VIRTUAL_HOST: "$MATRIX_DOMAIN"
      VIRTUAL_PORT: 8008
      LETSENCRYPT_HOST: "$MATRIX_DOMAIN"
      SYNAPSE_SERVER_NAME: "$MATRIX_DOMAIN"
      SYNAPSE_REPORT_STATS: "no"
    volumes:
      - ./synapse_data:/data
    ports:
      - "8008:8008"
    depends_on:
      - postgres
    networks:
      - matrix_network
    restart: unless-stopped
volumes:
  postgres_data:
  synapse_data:
networks:
  matrix_network:
    external: true
    name: matrix_network
EOF
# 生成 Synapse 配置文件
echo "生成 Synapse 配置文件..."
docker compose run --rm -e SYNAPSE_SERVER_NAME="$MATRIX_DOMAIN" -e SYNAPSE_REPORT_STATS=no synapse generate
# 编辑 homeserver.yaml
cat > synapse_data/homeserver.yaml << EOF
server_name: "$MATRIX_DOMAIN"
pid_file: /data/homeserver.pid
listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    resources:
      - names: [client, federation]
        compress: false
database:
  name: psycopg2
  args:
    user: synapse_user
    password: "$POSTGRES_PASSWORD"
    database: synapse
    host: postgres
    cp_min: 5
    cp_max: 10
log_config: "/data/$MATRIX_DOMAIN.log.config"
media_store_path: /data/media_store
registration_shared_secret: "$REGISTRATION_SECRET"
report_stats: false
macaroon_secret_key: "$MACAROON_SECRET"
form_secret: "$FORM_SECRET"
signing_key_path: "/data/$MATRIX_DOMAIN.signing.key"
trusted_key_servers:
  - server_name: "matrix.org"
enable_registration: true
logging:
  handlers:
    console:
      level: DEBUG
$EMAIL_REGISTRATION_CONFIG
email:
  smtp_host: smtp.gmail.com
  smtp_port: 587
  smtp_user: "$SMTP_USER"
  smtp_pass: "$SMTP_PASS"
  require_transport_security: true
  enable_notifs: true
  notif_from: "Matrix Server <$SMTP_USER>"
  app_name: Matrix
$OIDC_CONFIG
EOF
# 启动 Matrix 容器
echo "启动 Matrix 容器..."
docker compose up -d
cd ..
# 4. 部署 Nginx（保持不变）
echo "设置 Nginx 环境..."
mkdir -p nginx
cd nginx
# 创建 Nginx docker-compose.yml
cat > docker-compose.yml << EOF
services:
  nginx-proxy:
    image: nginxproxy/nginx-proxy
    container_name: nginx-proxy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - vhost:/etc/nginx/vhost.d
      - conf:/etc/nginx/conf.d
      - html:/usr/share/nginx/html
      - certs:/etc/nginx/certs:ro
      - /var/run/docker.sock:/tmp/docker.sock:ro
    environment:
      - TRUST_DOWNSTREAM_PROXY=false
    networks:
      - matrix_network
    restart: unless-stopped
  acme-companion:
    image: nginxproxy/acme-companion
    container_name: nginx-proxy-acme
    environment:
      - DEFAULT_EMAIL=$EMAIL
    volumes_from:
      - nginx-proxy
    volumes:
      - certs:/etc/nginx/certs:rw
      - acme:/etc/acme.sh
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - matrix_network
    restart: unless-stopped
networks:
  matrix_network:
    name: matrix_network
    external: true
volumes:
  vhost:
  conf:
  html:
  certs:
  acme:
EOF
# 启动 Nginx 容器
echo "启动 Nginx 容器..."
docker compose up -d
# 创建 Nginx 自定义配置
echo "创建 Nginx 自定义配置..."
mkdir -p /var/lib/docker/volumes/nginx_vhost/_data
cat > /var/lib/docker/volumes/nginx_vhost/_data/$MATRIX_DOMAIN << EOF
client_max_body_size 50m;
location /.well-known/matrix/server {
    return 200 '{"m.server": "$MATRIX_DOMAIN:443"}';
}
EOF
# 重启 Nginx 容器
echo "重启 Nginx 容器..."
docker compose down
docker compose up -d
cd ..
# 5. 部署 Element（可选）
if [[ "$DEPLOY_ELEMENT" =~ ^[Yy]$ ]]; then
  echo "设置 Element 环境..."
  mkdir -p element
  cd element
  # 创建 Element docker-compose.yml
  cat > docker-compose.yml << EOF
services:
  element:
    image: vectorim/element-web:v1.8.0
    container_name: element
    volumes:
      - ./config.$ELEMENT_DOMAIN.json:/app/config.$ELEMENT_DOMAIN.json
    environment:
      - VIRTUAL_HOST=$ELEMENT_DOMAIN
      - VIRTUAL_PORT=80
      - VIRTUAL_PROTO=http
      - LETSENCRYPT_HOST=$ELEMENT_DOMAIN
      - LETSENCRYPT_EMAIL=$EMAIL
    networks:
      - matrix_network
    restart: unless-stopped
networks:
  matrix_network:
    name: matrix_network
    external: true
EOF
  # 创建 Element 配置文件
  cat > config.$ELEMENT_DOMAIN.json << EOF
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://$MATRIX_DOMAIN",
      "server_name": "$MATRIX_DOMAIN"
    },
    "m.identity_server": {
      "base_url": "https://vector.im"
    }
  },
  "brand": "Element",
  "default_country_code": "CN",
  "default_language": "EN",
  "show_labs_settings": true,
  "features": {
    "feature_pinning": true
  },
  "disable_custom_urls": false,
  "disable_guests": false,
  "disable_login_language_selector": false,
  "disable_3pid_login": false,
  "permalink_prefix": "https://$ELEMENT_DOMAIN"
}
EOF
  # 启动 Element 容器
  echo "启动 Element 容器..."
  docker compose up -d
  cd ..
fi
# 6. 输出部署结果
echo "Matrix 部署完成！"
echo "访问 Matrix: https://$MATRIX_DOMAIN"
if [[ "$DEPLOY_ELEMENT" =~ ^[Yy]$ ]]; then
  echo "访问 Element: https://$ELEMENT_DOMAIN"
fi
echo "PostgreSQL 密码（请保存）： $POSTGRES_PASSWORD"
