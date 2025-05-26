#!/bin/bash
# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "错误：请以 root 权限运行此脚本（使用 sudo 或 root 用户）"
  exit 1
fi
set -e
echo "请输入 Matrix 服务器域名（例如 matrix.example.com）："
read -r MATRIX_DOMAIN
if [ -z "$MATRIX_DOMAIN" ]; then
  echo "错误：Matrix 服务器域名不能为空！"
  exit 1
fi
echo "请输入用于申请SSL证书的邮箱地址："
read -r EMAIL_ADDRESS
if [ -z "$EMAIL_ADDRESS" ]; then
  echo "错误：邮箱地址不能为空！"
  exit 1
fi
# 邮箱验证为必须开启，直接要求输入 SMTP 信息
echo "请输入 SMTP 邮箱地址（用于邮箱验证，例如 your-email@gmail.com）："
read -r SMTP_USER
if [ -z "$SMTP_USER" ]; then
  echo "错误：SMTP 邮箱地址不能为空！"
  exit 1
fi
echo "请输入 SMTP 邮箱的应用专用密码（Google App Password）："
read -r SMTP_PASS
if [ -z "$SMTP_PASS" ]; then
  echo "错误：SMTP 应用专用密码不能为空！"
  exit 1
fi
echo "是否开启单点登录（Google/GitHub）？(y/n，默认 y)"
read -r ENABLE_OIDC
ENABLE_OIDC=$(echo "${ENABLE_OIDC:-y}" | tr '[:upper:]' '[:lower:]')
if [ "$ENABLE_OIDC" = "y" ]; then
  echo "请输入 Google SSO client_id："
  read -r GOOGLE_CLIENT_ID
  if [ -z "$GOOGLE_CLIENT_ID" ]; then
    echo "错误：Google client_id 不能为空！"
    exit 1
  fi
  echo "请输入 Google SSO client_secret："
  read -r GOOGLE_CLIENT_SECRET
  if [ -z "$GOOGLE_CLIENT_SECRET" ]; then
    echo "错误：Google client_secret 不能为空！"
    exit 1
  fi
  echo "请输入 GitHub SSO client_id："
  read -r GITHUB_CLIENT_ID
  if [ -z "$GITHUB_CLIENT_ID" ]; then
    echo "错误：GitHub client_id 不能为空！"
    exit 1
  fi
  echo "请输入 GitHub SSO client_secret："
  read -r GITHUB_CLIENT_SECRET
  if [ -z "$GITHUB_CLIENT_SECRET" ]; then
    echo "错误：GitHub client_secret 不能为空！"
    exit 1
  fi
fi
echo "是否部署Element-Web客户端？(y/n，默认 y)"
read -r ENABLE_ELEMENT
ENABLE_ELEMENT=$(echo "${ENABLE_ELEMENT:-y}" | tr '[:upper:]' '[:lower:]')
# 如果部署 Element Web 客户端，输入 Element 域名
if [ "$ENABLE_ELEMENT" = "y" ]; then
  echo "请输入Element-Web客户端域名（例如 element.example.com）："
  read -r ELEMENT_DOMAIN
  if [ -z "$ELEMENT_DOMAIN" ]; then
    echo "错误：Element Web 客户端域名不能为空！"
    exit 1
  fi
fi
echo "是否部署Synapse-Admin管理界面？(y/n，默认 n)"
read -r ENABLE_SYNAPSE_ADMIN
ENABLE_SYNAPSE_ADMIN=$(echo "${ENABLE_SYNAPSE_ADMIN:-n}" | tr '[:upper:]' '[:lower:]')
# 如果部署 Synapse-Admin，输入管理员账号和密码
if [ "$ENABLE_SYNAPSE_ADMIN" = "y" ]; then
  echo "请输入 Synapse-Admin 域名（例如 admin.example.com）："
  read -r ADMIN_DOMAIN
  if [ -z "$ADMIN_DOMAIN" ]; then
    echo "错误：Synapse-Admin 域名不能为空！"
    exit 1
  fi
  echo "请输入管理员账号（例如 admin）："
  read -r ADMIN_USERNAME
  if [ -z "$ADMIN_USERNAME" ]; then
    echo "错误：管理员账号不能为空！"
    exit 1
  fi
  echo "请输入管理员密码："
  read -r ADMIN_PASSWORD
  if [ -z "$ADMIN_PASSWORD" ]; then
    echo "错误：管理员密码不能为空！"
    exit 1
  fi
fi
# 生成安全的 PostgreSQL 密码，并确保其不包含会导致 YAML 解析失败的特殊字符
POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
echo "开始部署Matrix Synapse服务器..."
echo "安装 Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
rm get-docker.sh
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
docker network create matrix_network
mkdir -p /root/matrix
cd /root/matrix
cat > docker-compose.yml << EOF
services:
  postgres:
    image: postgres:17
    container_name: postgres
    environment:
      POSTGRES_USER: synapse_user
      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
      POSTGRES_DB: synapse
      POSTGRES_INITDB_ARGS: "--encoding=UTF-8 --lc-collate=C --lc-ctype=C"
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    networks:
      - matrix_network
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U synapse_user -d synapse"]
      interval: 5s
      timeout: 5s
      retries: 5
  synapse:
    image: matrixdotorg/synapse:latest
    container_name: synapse
    environment:
      VIRTUAL_HOST: "${MATRIX_DOMAIN}"
      VIRTUAL_PORT: 8008
      LETSENCRYPT_HOST: "${MATRIX_DOMAIN}"
      SYNAPSE_SERVER_NAME: "${MATRIX_DOMAIN}"
      SYNAPSE_REPORT_STATS: "no"
    volumes:
      - ./synapse_data:/data
    ports:
      - "8008:8008"
    depends_on:
      postgres:
        condition: service_healthy
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
echo "启动 PostgreSQL 并验证其状态..."
docker compose up -d postgres
# 等待 PostgreSQL 就绪（最多 60 秒）
for i in {1..60}; do
  if docker exec postgres pg_isready -U synapse_user -d synapse > /dev/null 2>&1; then
    echo "PostgreSQL 服务已就绪！"
    break
  fi
  echo "PostgreSQL 服务尚未就绪，等待 $i/60..."
  sleep 1
done
# 检查 PostgreSQL 是否成功启动
if ! docker exec postgres pg_isready -U synapse_user -d synapse > /dev/null 2>&1; then
  echo "错误：无法连接到 PostgreSQL 服务，请检查日志！"
  docker compose logs postgres
  exit 1
fi
docker compose run --rm -e SYNAPSE_SERVER_NAME=${MATRIX_DOMAIN} -e SYNAPSE_REPORT_STATS=no synapse generate
if [ ! -f "synapse_data/homeserver.yaml" ]; then
  echo "错误：homeserver.yaml 文件未找到，请检查 Synapse 配置生成步骤！"
  exit 1
fi
sed -i '/# vim:ft=yaml/d' synapse_data/homeserver.yaml
if grep -q "# vim:ft=yaml" synapse_data/homeserver.yaml; then
  echo "错误：无法删除 homeserver.yaml 中的 # vim:ft=yaml！"
  exit 1
fi
# 使用 printf 对密码进行转义，确保特殊字符不会破坏 YAML 格式
POSTGRES_PASSWORD_ESCAPED=$(printf '%s' "$POSTGRES_PASSWORD" | sed 's/[\\"]/\\&/g')
sed -i "/database:/,/database:/ s|name: sqlite3|name: psycopg2|" synapse_data/homeserver.yaml
sed -i "/database:/,/database:/ s|database: /data/homeserver.db|user: synapse_user\n    password: \"${POSTGRES_PASSWORD_ESCAPED}\"\n    database: synapse\n    host: postgres\n    cp_min: 5\n    cp_max: 10|" synapse_data/homeserver.yaml
cat >> synapse_data/homeserver.yaml << EOF
enable_registration: true
max_upload_size: 1024M
logging:
  handlers:
    console:
      level: DEBUG
registrations_require_3pid:
  - email
email:
  smtp_host: smtp.gmail.com
  smtp_port: 587
  smtp_user: "${SMTP_USER}"
  smtp_pass: "${SMTP_PASS}"
  require_transport_security: true
  enable_notifs: true
  notif_from: "Matrix Server <${SMTP_USER}>"
  app_name: Matrix
EOF
if [ "$ENABLE_OIDC" = "y" ]; then  
    cat >> synapse_data/homeserver.yaml << EOF
oidc_providers:
  - idp_id: google
    idp_name: Google
    idp_brand: "google"
    issuer: "https://accounts.google.com/"
    client_id: "${GOOGLE_CLIENT_ID}"
    client_secret: "${GOOGLE_CLIENT_SECRET}"
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
    client_id: "${GITHUB_CLIENT_ID}"
    client_secret: "${GITHUB_CLIENT_SECRET}"
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
fi
if [ "$ENABLE_SYNAPSE_ADMIN" = "y" ]; then
  echo "启动 Synapse 服务并等待其完全可用..."
  docker compose up -d synapse
  # 等待 Synapse 服务就绪（最多 60 秒）
  for i in {1..60}; do
    if docker exec synapse curl -s http://localhost:8008/_matrix/client/versions > /dev/null; then
      echo "Synapse 服务已就绪！"
      break
    fi
    echo "Synapse 服务尚未就绪，等待 $i/60..."
    sleep 1
  done
  # 检查是否成功连接到 Synapse
  if ! docker exec synapse curl -s http://localhost:8008/_matrix/client/versions > /dev/null; then
    echo "错误：无法连接到 Synapse 服务（http://localhost:8008），请检查日志！"
    docker compose logs synapse
    exit 1
  fi
  # 注册管理员用户
  echo "注册管理员用户 ${ADMIN_USERNAME}..."
  if ! docker exec -i synapse register_new_matrix_user -u "${ADMIN_USERNAME}" -p "${ADMIN_PASSWORD}" -a -c /data/homeserver.yaml http://localhost:8008; then
    echo "错误：管理员用户注册失败，请检查 Synapse 日志！"
    docker compose logs synapse
    exit 1
  fi
# 部署 Synapse-Admin
echo "部署 Synapse-Admin..."
mkdir -p /root/synapse-admin
cd /root/synapse-admin
touch config.json
cat > config.json << EOF
{
  "restrictBaseUrl": "https://${MATRIX_DOMAIN}"
}
EOF
touch docker-compose.yml
cat > docker-compose.yml << EOF
services:
  synapse-admin:
    image: awesometechnologies/synapse-admin:0.10.4
    container_name: synapse-admin
    environment:
      - VIRTUAL_HOST=${ADMIN_DOMAIN}
      - VIRTUAL_PORT=80
      - LETSENCRYPT_HOST=${ADMIN_DOMAIN}
      - LETSENCRYPT_EMAIL=${EMAIL_ADDRESS}
      - REACT_APP_SERVER=https://${MATRIX_DOMAIN}
    volumes:
      - ./config.json:/app/config.json
    networks:
      - matrix_network
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "https://${MATRIX_DOMAIN}/_matrix/client/versions"]
      interval: 10s
      timeout: 5s
      retries: 5
networks:
  matrix_network:
    name: matrix_network
    external: true
EOF
docker compose up -d
fi
echo "部署 Nginx..."
mkdir -p /root/nginx
cd /root/nginx
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
      - DEFAULT_EMAIL=${EMAIL_ADDRESS}
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
mkdir -p /var/lib/docker/volumes/nginx_vhost/_data
cat > /var/lib/docker/volumes/nginx_vhost/_data/${MATRIX_DOMAIN} << EOF
client_max_body_size 1024M;
location /.well-known/matrix/server {
    return 200 '{"m.server": "${MATRIX_DOMAIN}:443"}';
}
EOF
if [ "$ENABLE_SYNAPSE_ADMIN" = "y" ]; then
  cat > /var/lib/docker/volumes/nginx_vhost/_data/${ADMIN_DOMAIN} << EOF
client_max_body_size 10M;
EOF
fi
docker compose up -d
if [ "$ENABLE_ELEMENT" = "y" ]; then
    echo "部署Element-Web客户端..."
    mkdir -p /root/element
    cd /root/element
    cat > docker-compose.yml << EOF
services:
  element:
    image: vectorim/element-web:v1.10.0
    container_name: element
    volumes:
      - ./config.${ELEMENT_DOMAIN}.json:/app/config.${ELEMENT_DOMAIN}.json
    environment:
      - VIRTUAL_HOST=${ELEMENT_DOMAIN}
      - VIRTUAL_PORT=80
      - VIRTUAL_PROTO=http
      - LETSENCRYPT_HOST=${ELEMENT_DOMAIN}
      - LETSENCRYPT_EMAIL=${EMAIL_ADDRESS}
    networks:
      - matrix_network
    restart: unless-stopped
networks:
  matrix_network:
    name: matrix_network
    external: true
EOF
    cat > config.${ELEMENT_DOMAIN}.json << EOF
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://${MATRIX_DOMAIN}",
      "server_name": "${MATRIX_DOMAIN}"
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
  "permalink_prefix": "https://${ELEMENT_DOMAIN}"
}
EOF
    docker compose up -d
fi
echo "Matrix Synapse服务器安装完成！"
echo "访问Matrix: https://${MATRIX_DOMAIN}"
if [ "$ENABLE_ELEMENT" = "y" ]; then
    echo "访问Element: https://${ELEMENT_DOMAIN}"
fi
if [ "$ENABLE_SYNAPSE_ADMIN" = "y" ]; then
    echo "访问Synapse-Admin: https://${ADMIN_DOMAIN}"
    echo "管理员账号: ${ADMIN_USERNAME}"
    echo "管理员密码: ${ADMIN_PASSWORD}"
fi
