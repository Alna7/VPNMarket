#!/bin/bash
set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
PROJECT_PATH="/var/www/vpnmarket"
GITHUB_REPO="https://github.com/arvinvahed/VPNMarket.git"
PHP_VERSION="8.3"

echo -e "${CYAN}--- نصب VPNMarket روی Ubuntu 22.04 ---${NC}\n"

# --- ورودی‌ها ---
read -p "🌐 دامنه (market.example.com): " DOMAIN
DOMAIN=$(echo $DOMAIN | sed 's|http[s]*://||g' | sed 's|/.*||g')
read -p "🗃 نام دیتابیس: " DB_NAME
read -p "👤 کاربر دیتابیس: " DB_USER
while true; do
  read -s -p "🔑 رمز دیتابیس: " DB_PASS; echo
  [ -n "$DB_PASS" ] && break || echo -e "${RED}خالی نباشد.${NC}"
done
read -p "✉️ ایمیل برای SSL/Certbot: " ADMIN_EMAIL
echo

export DEBIAN_FRONTEND=noninteractive

# --- 1) پیش‌نیازهای سیستم ---
echo -e "${YELLOW}📦 1/10: به‌روزرسانی و نصب پیش‌نیازها...${NC}"
sudo apt-get update -y
sudo apt-get install -y git curl unzip software-properties-common gpg \
  nginx certbot python3-certbot-nginx mysql-server redis-server supervisor ufw \
  composer build-essential python3 make g++

# --- 2) نصب Node.js (LTS) فقط یک‌بار و بدون npm اوبونتو ---
echo -e "${YELLOW}📦 2/10: نصب Node.js LTS از NodeSource...${NC}"
if ! command -v node >/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs   # npm همراه این پکیج هست
else
  # اگر نسخه نصب است ولی قدیمی‌تر از 18 است، ارتقا بده
  MAJOR=$(node -v | sed 's/v//' | cut -d. -f1)
  if [ "$MAJOR" -lt 18 ]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y --reinstall nodejs
  fi
fi
echo -e "${GREEN}Node $(node -v), npm $(npm -v)${NC}"

# --- 3) نصب PHP 8.3 ---
echo -e "${YELLOW}☕ 3/10: نصب PHP ${PHP_VERSION}...${NC}"
sudo add-apt-repository -y ppa:ondrej/php
sudo apt-get update -y
sudo apt-get install -y php${PHP_VERSION}-fpm php${PHP_VERSION}-mysql php${PHP_VERSION}-mbstring \
  php${PHP_VERSION}-xml php${PHP_VERSION}-curl php${PHP_VERSION}-zip php${PHP_VERSION}-bcmath \
  php${PHP_VERSION}-intl php${PHP_VERSION}-gd php${PHP_VERSION}-dom php${PHP_VERSION}-redis
sudo update-alternatives --set php /usr/bin/php${PHP_VERSION}

# --- 4) فعال‌سازی سرویس‌ها ---
echo -e "${YELLOW}🚀 4/10: فعال‌سازی سرویس‌ها...${NC}"
sudo systemctl enable --now php${PHP_VERSION}-fpm nginx mysql redis-server supervisor

# --- 5) فایروال ---
echo -e "${YELLOW}🛡️ 5/10: تنظیم UFW...${NC}"
sudo ufw allow 'OpenSSH'
sudo ufw allow 'Nginx Full'
echo "y" | sudo ufw enable
sudo ufw status

# --- 6) دریافت پروژه ---
echo -e "${YELLOW}⬇️ 6/10: کلون و آماده‌سازی پروژه...${NC}"
sudo rm -rf "$PROJECT_PATH" || true
sudo git clone "$GITHUB_REPO" "$PROJECT_PATH"
sudo chown -R www-data:www-data "$PROJECT_PATH"

# --- 7) دیتابیس و .env ---
echo -e "${YELLOW}🧩 7/10: ساخت دیتابیس و تنظیم .env...${NC}"
sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"
sudo mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
sudo mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;"

sudo -u www-data cp "$PROJECT_PATH/.env.example" "$PROJECT_PATH/.env"
sudo sed -i "s|^DB_DATABASE=.*|DB_DATABASE=$DB_NAME|" "$PROJECT_PATH/.env"
sudo sed -i "s|^DB_USERNAME=.*|DB_USERNAME=$DB_USER|" "$PROJECT_PATH/.env"
sudo sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" "$PROJECT_PATH/.env"
sudo sed -i "s|^APP_URL=.*|APP_URL=https://$DOMAIN|" "$PROJECT_PATH/.env"
sudo sed -i "s|^APP_ENV=.*|APP_ENV=production|" "$PROJECT_PATH/.env"
sudo sed -i "s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" "$PROJECT_PATH/.env"

# دسترسی‌ها برای لاراول
sudo -u www-data mkdir -p "$PROJECT_PATH/storage" "$PROJECT_PATH/bootstrap/cache"
sudo chmod -R ug+rwX "$PROJECT_PATH/storage" "$PROJECT_PATH/bootstrap/cache"

# --- 8) نصب وابستگی‌ها ---
echo -e "${YELLOW}🧰 8/10: Composer و npm...${NC}"
# Composer (با HOME مشخص برای www-data)
sudo -u www-data env COMPOSER_HOME=/var/www/.composer composer install --no-dev --optimize-autoloader -d "$PROJECT_PATH"

# npm (بدون نصب npm اوبونتویی؛ از npm همراه NodeSource استفاده می‌شود)
sudo -u www-data npm --prefix "$PROJECT_PATH" ci || sudo -u www-data npm --prefix "$PROJECT_PATH" install
sudo -u www-data npm --prefix "$PROJECT_PATH" run build

# --- 9) Artisan ---
echo -e "${YELLOW}⚙️ 9/10: Artisan...${NC}"
cd "$PROJECT_PATH"
sudo -u www-data php artisan key:generate
sudo -u www-data php artisan migrate --seed --force
sudo -u www-data php artisan storage:link
sudo -u www-data php artisan config:cache
sudo -u www-data php artisan route:cache
sudo -u www-data php artisan view:cache

# --- 10) Nginx و Supervisor ---
echo -e "${YELLOW}🌍 10/10: پیکربندی Nginx و Queue...${NC}"
PHP_FPM_SOCK_PATH=$(grep -oP 'listen\s*=\s*\K.*' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf | head -n1 | sed 's/;//g' | xargs)

sudo tee /etc/nginx/sites-available/vpnmarket >/dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root $PROJECT_PATH/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";

    index index.php;
    charset utf-8;

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    error_page 404 /index.php;

    location ~ \.php$ {
        fastcgi_pass unix:$PHP_FPM_SOCK_PATH;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
    }

    location ~ /\.(?!well-known).* { deny all; }
}
EOF

sudo ln -sf /etc/nginx/sites-available/vpnmarket /etc/nginx/sites-enabled/vpnmarket
[ -f /etc/nginx/sites-enabled/default ] && sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl restart nginx

sudo tee /etc/supervisor/conf.d/vpnmarket-worker.conf >/dev/null <<EOF
[program:vpnmarket-worker]
process_name=%(program_name)s_%(process_num)02d
command=php $PROJECT_PATH/artisan queue:work redis --sleep=3 --tries=3
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=www-data
numprocs=2
redirect_stderr=true
stdout_logfile=/var/log/supervisor/vpnmarket-worker.log
stopwaitsecs=3600
EOF

sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl start vpnmarket-worker:*

# --- SSL اختیاری ---
read -p "🔒 HTTPS با Certbot فعال شود؟ (y/n): " ENABLE_SSL
if [[ "$ENABLE_SSL" =~ ^[yY]$ ]]; then
  sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL"
fi

echo -e "${GREEN}\n✅ نصب با موفقیت انجام شد!${NC}"
echo -e "🌐 https://$DOMAIN"
echo -e "🔑 https://$DOMAIN/admin"
echo -e "${RED}⚠️ پسورد ادمین را فوراً عوض کنید.${NC}"
