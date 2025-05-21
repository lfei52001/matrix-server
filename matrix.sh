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

# 交互式输入变量（无默认值）
echo "请输入 Matrix 域名（例如：matrix.example.com）："
read -r -p "" MATRIX_DOMAIN
if [ -z "$MATRIX_DOMAIN" ]; then
  echo "错误：Matrix 域名不能为空"
  exit 1
fi
if ! echo "$MATRIX_DOMAIN" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
  echo "错误：无效的 Matrix 域名格式"
  exit 1
fi

echo "请输入 Element 域名（例如：element.example.com）："
read -r -p "" ELEMENT_DOMAIN
if [ -z "$ELEMENT_DOMAIN" ]; then
  echo "错误：Element 域名不能为空"
  exit 1
fi
if ! echo "$ELEMENT_DOMAIN" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
  echo "错误：无效的 Element 域名格式"
  exit 1
fi

echo "请输入用于 Let's Encrypt 和通知的邮箱（例如：user@example.com）："
read -r -p "" EMAIL
if [ -z "$EMAIL" ]; then
  echo "错误：邮箱不能为空"
  exit 1
fi
if ! echo "$EMAIL" | grep -qE '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
  echo "错误：无效的邮箱格式"
  exit 1
fi

echo "请输入 PostgreSQL 密码："
read -r -s -p "" POSTGRES_PASSWORD
echo
if [ -z "$POSTGRES_PASSWORD" ]; then
  echo "错误：PostgreSQL 密码不能为空"
  exit 1
fi

echo "请输入 SMTP 用户邮箱（例如：user@gmail.com）："
read -r -p "" SMTP_USER
if [ -z "$SMTP_USER" ]; then
  echo "错误：SMTP 用户邮箱不能为空"
  exit 1
fi
if ! echo "$SMTP_USER" | grep -qE '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
  echo "错误：无效的 SMTP 邮箱格式"
  exit 1
fi

echo "请输入 SMTP 密码（Google 应用专用密码）："
read -r -s -p "" SMTP_PASS
echo
if [ -z "$SMTP_PASS" ]; then
  echo "错误：SMTP 密码不能为空"
  exit 1
fi

echo "请输入 Google OAuth 客户端 ID（按 Enter 禁用 Google OIDC）："
read -r -p "" GOOGLE_CLIENT_ID

echo "请输入 Google OAuth 客户端密钥（按 Enter 禁用 Google OIDC）："
read -r -s -p "" GOOGLE_CLIENT_SECRET
echo

echo "请输入 GitHub OAuth 客户端 ID（按 Enter 禁用 GitHub OIDC）："
read -r -p "" GITHUB_CLIENT_ID

echo "请输入 GitHub OAuth 客户端密钥（按 Enter 禁用 GitHub OIDC）："
read -r -s -p "" GITHUB_CLIENT_SECRET
echo

# 如果 Google 或 GitHub OIDC 为空，禁用 OIDC 配置
if [ -z "$GOOGLE_CLIENT_ID" ] || [ -z "$GOOGLE_CLIENT_SECRET" ] || [ -z "$GITHUB_CLIENT_ID" ] || [ -z "$GITHUB_CLIENT_SECRET" ]; then
  OIDC_CONFIG=""
else
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
fi

# 1. 安装 Docker
echo "安装 Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
if ! sudo sh get-docker.sh; then
  echo "Docker 安装失败"
  exit 1
fi
rm get-docker.sh

# 安装 Docker Compose
echo "安装 Docker Compose..."
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
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
      POSTGRES_PASSWORD: $POSTGRES_PASSWORD
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
    password: $POSTGRES_PASSWORD
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
registrations_require_3pid:
  - email
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

# 4. 部署 Nginx
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

# 5. 创建 Nginx 自定义配置
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

# 6. 部署 Element
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

echo "Matrix、Nginx 和 Element 部署完成！"
echo "访问 Matrix: https://$MATRIX_DOMAIN"
echo "访问 Element: https://$ELEMENT_DOMAIN"