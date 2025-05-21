#!/bin/bash

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "错误：请以 root 权限运行此脚本（使用 sudo）"
  exit 1
fi

# 提示用户输入自定义域名和邮箱
echo "请输入您的域名（例如 matrix.example.com）："
read -p "域名: " CUSTOM_DOMAIN
echo "请输入您的邮箱（用于 SSL 证书申请，例如 user@example.com）："
read -p "邮箱: " CUSTOM_EMAIL

# 验证输入是否为空
if [ -z "$CUSTOM_DOMAIN" ]; then
  echo "错误：域名不能为空！"
  exit 1
fi
if [ -z "$CUSTOM_EMAIL" ]; then
  echo "错误：邮箱不能为空！"
  exit 1
fi

# 遇到错误时退出
set -e

# 步骤 1: 安装 Docker
echo "正在安装 Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
rm get-docker.sh

# 步骤 2: 安装 Docker Compose
echo "正在安装 Docker Compose..."
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# 步骤 3: 搭建 Matrix Synapse
echo "正在设置 Matrix Synapse..."
# 创建 Docker 网络
docker network create matrix_network

# 创建 Matrix 目录并生成 docker-compose.yml
mkdir -p matrix
cd matrix
cat << EOF > docker-compose.yml
services:
  synapse:
    image: matrixdotorg/synapse:latest
    container_name: synapse
    environment:
      - VIRTUAL_HOST=$CUSTOM_DOMAIN
      - VIRTUAL_PORT=8008
      - LETSENCRYPT_HOST=$CUSTOM_DOMAIN
      - SYNAPSE_SERVER_NAME=$CUSTOM_DOMAIN
      - SYNAPSE_REPORT_STATS=no
    volumes:
      - ./synapse_data:/data
    ports:
      - "8008:8008"
    networks:
      - matrix_network
    restart: unless-stopped
volumes:
  synapse_data:
networks:
  matrix_network:
    external: true
    name: matrix_network
EOF

# 生成 Synapse 配置文件
docker compose run --rm -e SYNAPSE_SERVER_NAME=$CUSTOM_DOMAIN -e SYNAPSE_REPORT_STATS=no synapse generate

# 编辑 homeserver.yaml，启用注册并设置日志
echo "正在配置 homeserver.yaml..."
sed -i 's/enable_registration: false/enable_registration: true/' synapse_data/homeserver.yaml
cat << EOF >> synapse_data/homeserver.yaml
logging:
  handlers:
    console:
      level: DEBUG
EOF

# 启动 Synapse
docker compose up -d
cd ..

# 步骤 4: 部署 Nginx 和 acme-companion
echo "正在部署 Nginx 和 acme-companion..."
mkdir -p nginx
cd nginx
cat << EOF > docker-compose.yml
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
      - DEFAULT_EMAIL=$CUSTOM_EMAIL
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

# 启动 Nginx 和 acme-companion
docker compose up -d

# 步骤 5: 创建自定义 Nginx 配置
echo "正在创建自定义 Nginx 配置..."
mkdir -p /var/lib/docker/volumes/nginx_vhost/_data
cat << EOF > /var/lib/docker/volumes/nginx_vhost/_data/$CUSTOM_DOMAIN
client_max_body_size 50m;
location /.well-known/matrix/server {
    return 200 '{"m.server": "$CUSTOM_DOMAIN:443"}';
}
EOF

# 步骤 6: 重启 Nginx 容器
echo "正在重启 Nginx 容器..."
docker compose down
docker compose up -d

echo "设置完成！Matrix 服务器已部署在 https://$CUSTOM_DOMAIN"
