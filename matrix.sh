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

# 交互式输入变量
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

# 询问是否启用 OIDC 配置
echo "是否启用 Google 或 GitHub OIDC 配置？（y/n，默认为 n）："
read -r -p "" ENABLE_OIDC
ENABLE_OIDC=${ENABLE_OIDC:-n}
if [[ "$ENABLE_OIDC" =~ ^[Yy]$ ]]; then
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

  # 如果 Google 或 GitHub OIDC 信息完整，生成 OIDC 配置
  if [ -n "$GOOGLE_CLIENT_ID" ] && [ -n "$GOOGLE_CLIENT_SECRET" ] && [ -n "$GITHUB_CLIENT_ID" ] && [ -n "$GITHUB_CLIENT_SECRET" ]; then
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
    echo "警告：OIDC 配置信息不完整，已禁用 OIDC。"
  fi
else
  OIDC_CONFIG=""
  echo "已禁用 OIDC 配置。"
fi

# 询问是否部署 Element
echo "是否部署 Element Web 客户端？（y/n，默认为 n）："
read -r -p "" DEPLOY_ELEMENT
DEPLOY_ELEMENT=${DEPLOY_ELEMENT:-n}
if [[ "$DEPLOY_ELEMENT" =~ ^[Yy]$ ]]; then
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

# 创建 Matrix 的 docker-compose.yml
cat > docker-compose.yml << EOF
services:
  postgres:
    image: postgres:17
    container_name: postgres
    environment:
      POSTGRES_USER: synapse_user
      POSTGRES_PASSWORD: $POSTGRES_PASSWORD
      POSTGRES_DB: synapse
      ernal: true
    name: matrix_network
EOF

# 启动 Element 容器
echo "启动 Element 容器..."
docker compose up -d
cd ..

# 6. 输出部署结果
echo "部署完成！"
echo "访问 Matrix: https://$MATRIX_DOMAIN"
if [[ "$DEPLOY_ELEMENT" =~ ^[Yy]$ ]]; then
  echo "访问 Element: https://$ELEMENT_DOMAIN"
fi
