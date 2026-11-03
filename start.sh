#!/bin/bash
# Скрипт для автоматического развертывания серверной инфраструктуры (Traefik, Remnawave Panel/Node)
# Перед первым запуском необходимо выдать права на исполнение: chmod +x start.sh

# Останавливать выполнение при любой ошибке (fail-fast)
set -e

# Цвета для вывода
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Базовый путь к директории скрипта
BASE_DIR="$(dirname "$0")"
VAR_FILE="$BASE_DIR/.variables"

# Проверка наличия файла с переменными
if [ ! -f "$VAR_FILE" ]; then
    echo -e "${RED}Ошибка: Файл $VAR_FILE не найден! Пожалуйста, создайте его.${NC}"
    exit 1
fi

# Загружаем переменные из .variables
source "$VAR_FILE"

#---------------------ВЫБОР ТИПА УСТАНОВКИ---------------------

echo -e "${BLUE}Что вы хотите установить?${NC}"
echo "1) Remnawave Panel (Панель управления)"
echo "2) Remnawave Node (Узел проксирования)"
read -p "Ваш выбор [1/2]: " INSTALL_CHOICE

#---------------------ОБЩАЯ НАСТРОЙКА TRAEFIK---------------------

TRAEFIK_DIR="$BASE_DIR/traefik"
mkdir -p "$TRAEFIK_DIR"

# Установка apache2-utils для генерации хеша пароля, если отсутствует
if ! command -v htpasswd &> /dev/null; then
    echo -e "${ORANGE}Установка apache2-utils для генерации паролей...${NC}"
    sudo apt-get update && sudo apt-get install -y apache2-utils
fi

# Интерактивная настройка доступа к дашборду Traefik
echo -e "${BLUE}Настройка доступа к дашборду Traefik...${NC}"
read -p "Введите логин для дашборда Traefik: " TRAEFIK_USER
read -sp "Введите пароль для дашборда Traefik: " TRAEFIK_PASS
echo "" # Перенос строки после скрытого ввода

# Создание хеша пароля и экранирование символа $ для Docker Compose
HASHED_PASS=$(htpasswd -nb "$TRAEFIK_USER" "$TRAEFIK_PASS" | cut -d ':' -f2)
AUTH_DASHBOARD=$(echo "$TRAEFIK_USER:$HASHED_PASS" | sed 's/\$/$$/g')

if [ "$INSTALL_CHOICE" = "1" ]; then
    #=========================================================
    # УСТАНОВКА REMNAWAVE PANEL
    #=========================================================
    echo -e "${BLUE}Начинаем установку Remnawave Panel...${NC}"
    
    PANEL_DIR="$BASE_DIR/remnawave/panel"
    mkdir -p "$PANEL_DIR"

    # 1. Загрузка файлов
    echo -e "${BLUE}Загрузка файлов конфигурации Remnawave Panel...${NC}"
    curl -sSL -o "$PANEL_DIR/docker-compose.yml" https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml
    curl -sSL -o "$PANEL_DIR/.env" https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample
    
    # Исправляем сеть на external: true, но ТОЛЬКО для remnawave-network, чтобы не сломать volumes
    sed -i '/remnawave-network:/,/external: false/ s/external: false/external: true/' "$PANEL_DIR/docker-compose.yml"

    # 2. Настройка .env
    echo -e "${BLUE}Настройка .env файла...${NC}"
    cd "$PANEL_DIR"

    # Генерация пароля БД
    pw=$(openssl rand -hex 24)
    sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$pw/" .env
    sed -i "s|^\(DATABASE_URL=\"postgresql://postgres:\)[^\@]*\(@.*\)|\1$pw\2|" .env

    # Генерация секретов безопасности
    sed -i "s/^APP_SECRET=.*/APP_SECRET=$(openssl rand -hex 32)/" .env
    sed -i "s/^METRICS_PASS=.*/METRICS_PASS=$(openssl rand -hex 32)/" .env
    sed -i "s/^WEBHOOK_SECRET_HEADER=.*/WEBHOOK_SECRET_HEADER=$(openssl rand -hex 32)/" .env

    # Подстановка доменов
    sed -i "s|^FRONT_END_DOMAIN=.*|FRONT_END_DOMAIN=$FRONT_END_DOMAIN|" .env
    sed -i "s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=$SUB_PUBLIC_DOMAIN|" .env

    echo -e "${GREEN}Конфигурация панели успешно настроена.${NC}"

    # 3. Запуск панели
    echo -e "${BLUE}Запуск Remnawave Panel...${NC}"
    docker compose up -d
    echo -e "${GREEN}Remnawave Panel успешно запущена!${NC}"

    # 4. Создание конфига маршрутизации Traefik для Panel
    echo -e "${BLUE}Создание конфига маршрутизации Traefik для Panel...${NC}"
    mkdir -p "$TRAEFIK_DIR/config"
    cat <<EOF > "$TRAEFIK_DIR/config/remnawave-panel.yml"
http:
  routers:
    remnawave:
      rule: 'Host(\`{{ env "FRONT_END_DOMAIN" }}\`)'
      entrypoints:
        - https
      tls:
        certResolver: letsencrypt
      service: remnawave

  middlewares:
    remnawave-https-redirect:
      redirectScheme:
        scheme: https

  services:
    remnawave:
      loadBalancer:
        servers:
          - url: "http://remnawave:3000"
EOF

    # Переменная для динамического .env Traefik
    TRAEFIK_ENV_DOMAIN="FRONT_END_DOMAIN=$FRONT_END_DOMAIN"

elif [ "$INSTALL_CHOICE" = "2" ]; then
    #=========================================================
    # УСТАНОВКА REMNAWAVE NODE
    #=========================================================
    echo -e "${BLUE}Начинаем установку Remnawave Node...${NC}"

    NODE_DIR="$BASE_DIR/remnawave/node"
    mkdir -p "$NODE_DIR"
    cd "$NODE_DIR"

    # 1. Загрузка конфигурации Node
    echo -e "${BLUE}Загрузка файлов конфигурации Remnawave Node...${NC}"
    curl -sSL -o docker-compose.yml https://raw.githubusercontent.com/remnawave/node/main/docker-compose-prod.yml

    # 2. Модификация сети (убираем host mode, подключаем к remnawave-network)
    echo -e "${ORANGE}Настройка сети для работы за Traefik...${NC}"
    sed -i '/network_mode: host/d' docker-compose.yml
    printf "\nnetworks:\n  remnawave-network:\n    external: true\n" >> docker-compose.yml

    # 3. Запрос секретного ключа
    echo -e "${BLUE}Для подключения к панели необходим SECRET_KEY.${NC}"
    echo "Его можно получить в интерфейсе панели при добавлении узла."
    read -sp "Введите SECRET_KEY: " NODE_SECRET_KEY
    echo ""
    
    # Вставка ключа в конфиг
    sed -i "s|SECRET_KEY=\"\"|SECRET_KEY=\"$NODE_SECRET_KEY\"|" docker-compose.yml

    # 4. Запуск Node
    echo -e "${BLUE}Запуск Remnawave Node...${NC}"
    docker compose up -d
    echo -e "${GREEN}Remnawave Node успешно запущен!${NC}"

    # 5. Создание конфига маршрутизации для Node
    echo -e "${BLUE}Создание конфига маршрутизации Traefik для Node...${NC}"
    mkdir -p "$TRAEFIK_DIR/config"
    cat <<EOF > "$TRAEFIK_DIR/config/remnawave-node.yml"
http:
  routers:
    remnanode:
      rule: 'Host(\`{{ env "NODE_DOMAIN" }}\`)'
      entrypoints:
        - https
      service: remnanode
      tls:
        certResolver: letsencrypt

  services:
    remnanode:
      loadBalancer:
        servers:
          - url: "http://remnanode:2222"
EOF
    
    # Переменная для динамического .env Traefik
    TRAEFIK_ENV_DOMAIN="NODE_DOMAIN=$NODE_DOMAIN"

else
    echo -e "${RED}Ошибка: Неверный выбор. Запустите скрипт заново и введите 1 или 2.${NC}"
    exit 1
fi

#---------------------ФИНАЛЬНАЯ НАСТРОЙКА TRAEFIK---------------------

echo -e "${BLUE}Генерация .env для Traefik...${NC}"
cat <<EOF > "$TRAEFIK_DIR/.env"
EMAIL=$TRAEFIK_EMAIL
DASHBOARD_DOMAIN=$DASHBOARD_DOMAIN
AUTH_DASHBOARD=$AUTH_DASHBOARD
$TRAEFIK_ENV_DOMAIN
EOF

echo -e "${GREEN}Конфигурация Traefik успешно обновлена.${NC}"

#---------------------ЗАПУСК TRAEFIK---------------------

echo -e "${BLUE}Проверка портов в UFW...${NC}"
for port in 80 443; do
  if sudo ufw status | grep -q "$port"; then
    echo -e "${GREEN}Порт $port уже открыт.${NC}"
  else
    echo -e "${ORANGE}Открытие порта $port...${NC}"
    sudo ufw allow $port/tcp
  fi
done

# Запуск Traefik
echo -e "${BLUE}Запуск Traefik...${NC}"
cd "$TRAEFIK_DIR"
docker compose up -d

echo -e "${GREEN}Развертывание успешно завершено!${NC}"
