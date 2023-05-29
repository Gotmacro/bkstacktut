#!/bin/bash

echo "This script installs a new BookStack instance on a fresh Ubuntu 22.04 server."
echo "This script does not ensure system security."
echo ""

LOGPATH=$(realpath "bookstack_install_$(date +%s).log")

# Get the current user running the script
SCRIPT_USER="${SUDO_USER:-$USER}"

# Get the current machine IP address
CURRENT_IP=$(ip addr | grep 'state UP' -A4 | grep 'inet ' | awk '{print $2}' | cut -f1  -d'/')

DB_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13)"

BOOKSTACK_DIR="/var/www/bookstack"

DOMAIN="wiki2.sdshmlb.com"


function error_out() {
  echo "ERROR: $1" | tee -a "$LOGPATH" 1>&2
  exit 1
}

function info_msg() {
  echo "$1" | tee -a "$LOGPATH"
}

function run_package_installs() {
  apt update
  apt install -y git unzip apache2 php8.1 curl php8.1-curl php8.1-mbstring php8.1-ldap \
  php8.1-xml php8.1-zip php8.1-gd php8.1-mysql libapache2-mod-php8.1
}

# Download BookStack
function run_bookstack_download() {
  cd /var/www || exit
  git clone https://github.com/BookStackApp/BookStack.git --branch release --single-branch bookstack
}

# Install composer
function run_install_composer() {
  EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

  if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]
  then
      >&2 echo 'ERROR: Invalid composer installer checksum'
      rm composer-setup.php
      exit 1
  fi

  php composer-setup.php --quiet
  rm composer-setup.php

  # Move composer to global installation
  mv composer.phar /usr/local/bin/composer
}

# Install BookStack composer dependencies
function run_install_bookstack_composer_deps() {
  cd "$BOOKSTACK_DIR" || exit
  export COMPOSER_ALLOW_SUPERUSER=1
  php /usr/local/bin/composer install --no-dev --no-plugins
}

$MYSQLS = 10.2.0.5

# Copy and update BookStack environment variables
function run_update_bookstack_env() {
  cd "$BOOKSTACK_DIR" || exit
  cp .env.example .env
  sed -i.bak "s@APP_URL=.*\$@APP_URL=http://$DOMAIN@" .env
  sed -i.bak "s/DB_DATABASE=.*$/DB_DATABASE=$MYSQLS/" .env
  sed -i.bak 's/DB_USERNAME=.*$/DB_USERNAME=bookstack/' .env
  sed -i.bak "s/DB_PASSWORD=.*\$/DB_PASSWORD=$DB_PASS/" .env
  # Generate the application key
  php artisan key:generate --no-interaction --force
}

# Run the BookStack database migrations for the first time
function run_bookstack_database_migrations() {
  cd "$BOOKSTACK_DIR" || exit
  php artisan migrate --no-interaction --force
}

function run_set_application_file_permissions() {
  cd "$BOOKSTACK_DIR" || exit
  chown -R "$SCRIPT_USER":www-data ./
  chmod -R 755 ./
  chmod -R 775 bootstrap/cache public/uploads storage
  chmod 740 .env

  # Tell git to ignore permission changes
  git config core.fileMode false
}

# Setup apache with the needed modules and config
function run_configure_apache() {
  # Enable required apache modules
  a2enmod rewrite
  a2enmod php8.1

  # Set-up the required BookStack apache config
  cat /etc/apache2/sites-available/bookstack.conf <<EOL
<VirtualHost *:80>
  ServerName ${DOMAIN}

  ServerAdmin webmaster@localhost
  DocumentRoot /var/www/bookstack/public/

  <Directory /var/www/bookstack/public/>
      Options -Indexes +FollowSymLinks
      AllowOverride None
      Require all granted
      <IfModule mod_rewrite.c>
          <IfModule mod_negotiation.c>
              Options -MultiViews -Indexes
          </IfModule>

          RewriteEngine On

          # Handle Authorization Header
          RewriteCond %{HTTP:Authorization} .
          RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]

          # Redirect Trailing Slashes If Not A Folder...
          RewriteCond %{REQUEST_FILENAME} !-d
          RewriteCond %{REQUEST_URI} (.+)/$
          RewriteRule ^ %1 [L,R=301]

          # Handle Front Controller...
          RewriteCond %{REQUEST_FILENAME} !-d
          RewriteCond %{REQUEST_FILENAME} !-f
          RewriteRule ^ index.php [L]
      </IfModule>
  </Directory>

  ErrorLog \${APACHE_LOG_DIR}/error.log
  CustomLog \${APACHE_LOG_DIR}/access.log combined

</VirtualHost>
EOL

  # Disable the default apache site and enable BookStack
  a2dissite 000-default.conf
  a2ensite bookstack.conf

  # Restart apache to load new config
  systemctl restart apache2
}
