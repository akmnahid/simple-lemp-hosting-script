#!/bin/bash

# Load configuration from .config file
CONFIG_FILE=".config"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Configuration file '$CONFIG_FILE' not found! Please create it."
  exit 1
fi

source "$CONFIG_FILE"

# Generate a random password
generate_password() {
  tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

echo "What is the username?"
read USERNAME
PASSWORD=$(generate_password)  # Randomly generate the system user password

echo "What is the domain?"
read DOMAIN

# Collect additional domains one by one
SERVER_NAME="$DOMAIN"
while true; do
  read -p "Enter an additional domain (leave blank to finish): " ADDITIONAL_DOMAIN
  if [[ -z "$ADDITIONAL_DOMAIN" ]]; then
    break
  fi
  SERVER_NAME="$SERVER_NAME $ADDITIONAL_DOMAIN"
done

echo "Server names: $SERVER_NAME"

# Create root-owned directory for chroot
echo "Creating root-owned directory for SFTP chroot: /home/${USERNAME}_root"
mkdir -p /home/${USERNAME}_root/$USERNAME/$DOMAIN/public


# Create system user
echo "Creating user $USERNAME with home directory /home/${USERNAME}_root/$USERNAME"
useradd -m -d /home/${USERNAME}_root/$USERNAME $USERNAME
echo "Setting $USERNAME to nologin"
usermod -s /sbin/nologin $USERNAME
chpasswd <<<"$USERNAME:$PASSWORD"

chown root:root /home/${USERNAME}_root
chmod 755 /home/${USERNAME}_root
mkdir -p /home/${USERNAME}_root/$USERNAME
chown -R $USERNAME:$USERNAME /home/${USERNAME}_root/$USERNAME
chown -R $USERNAME:$USERNAME /home/${USERNAME}_root/$USERNAME/$DOMAIN/public

# SSH configuration for SFTP
echo "
   Match Group $USERNAME
   ChrootDirectory /home/${USERNAME}_root
   ForceCommand internal-sftp
   X11Forwarding no
   AllowTcpForwarding no" | tee -a /etc/ssh/sshd_config

echo "Restarting SSH service"
service sshd restart

# Nginx configuration
echo "Copying Nginx configuration"
cp resources/nginx-site.conf /etc/nginx/conf.d/${DOMAIN}.conf
sed -i "s/{DOMAIN_PUBLIC_ROOT}/\/home\/${USERNAME}_root\/$USERNAME\/$DOMAIN\/public/g" /etc/nginx/conf.d/${DOMAIN}.conf
sed -i "s/{SERVER_NAME}/$SERVER_NAME/g" /etc/nginx/conf.d/${DOMAIN}.conf


# PHP configuration
read -p "Do you want to enable PHP for this site? (yes/no): " ENABLE_PHP
if [[ "$ENABLE_PHP" == "yes" ]]; then
  echo "Listing installed PHP versions:"
  PHP_VERSIONS=$(ls /etc/php/ | grep -E '^[0-9]+\.[0-9]+$')

  if [ -z "$PHP_VERSIONS" ]; then
    echo "No PHP versions found."
    exit 1
  fi

  echo "Select a PHP version from the list below:"
  select PHP_VERSION in $PHP_VERSIONS; do
    if [[ -n "$PHP_VERSION" ]]; then
      echo "You selected PHP version: $PHP_VERSION"
      break
    else
      echo "Invalid selection. Please select a valid PHP version."
    fi
  done

  echo "Copying PHP-FPM pool configuration for PHP version $PHP_VERSION"
  cp resources/php-pool.conf /etc/php/${PHP_VERSION}/fpm/pool.d/${USERNAME}.conf
  sed -i "s/{USERNAME}/$USERNAME/g" /etc/php/${PHP_VERSION}/fpm/pool.d/${USERNAME}.conf
  sed -i "s/{SOCK_LISTEN}/\/run\/php\/php${PHP_VERSION}-${USERNAME}-fpm.sock/g" /etc/php/${PHP_VERSION}/fpm/pool.d/${USERNAME}.conf
  sed -i "s/{PHP_FPM_SOCK}/\/run\/php\/php${PHP_VERSION}-${USERNAME}-fpm.sock/g" /etc/nginx/conf.d/${DOMAIN}.conf
  # Enable PHP in Nginx
  sed -i'' '/^[[:blank:]]*#PHP BLOCK/,/^[[:blank:]]*#PHP BLOCK/ { /^[[:blank:]]*#PHP BLOCK/! s/^[[:blank:]]*#\s*// }' /etc/nginx/conf.d/${DOMAIN}.conf
  service php${PHP_VERSION}-fpm restart
fi

# Database creation
read -p "Do you want to create a database for this site? (yes/no): " CREATE_DB
if [[ "$CREATE_DB" == "yes" ]]; then
  # Database check and configuration
  if command -v mysql >/dev/null 2>&1; then
    DB_COMMAND="mysql"
    echo "MySQL detected."
  elif command -v mariadb >/dev/null 2>&1; then
    DB_COMMAND="mariadb"
    echo "MariaDB detected."
  else
    echo "Neither MySQL nor MariaDB is installed. Exiting..."
    exit 1
  fi

  read -p "Do you want to create a database for this site? (yes/no): " CREATE_DB
  if [[ "$CREATE_DB" == "yes" ]]; then
    DB_NAME="${USERNAME}_db"
    DB_PASSWORD=$(generate_password)

    echo "Creating database and user..."
$DB_COMMAND -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_ROOT_USER" -p"$MYSQL_ROOT_PASSWORD" <<EOF
  CREATE DATABASE $DB_NAME;
  CREATE USER '$USERNAME'@'$APP_SERVER_IP' IDENTIFIED BY '$DB_PASSWORD';
  GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$USERNAME'@'$APP_SERVER_IP';
  FLUSH PRIVILEGES;
EOF

    echo "Database $DB_NAME and user $USERNAME created successfully."
  fi
fi

# Deployment information
echo "----------- DEPLOYMENT INFORMATION -----------"
cat <<EOF
phpMyAdmin URL: $PHPMYADMIN_URL

MySQL:
  Host: $MYSQL_HOST
  Port: $MYSQL_PORT
  Database: ${DB_NAME:-Not created}
  User: $USERNAME
  Password: ${DB_PASSWORD:-Not created}

SFTP:
  Host: $APP_SERVER_IP
  User: $USERNAME
  Password: $PASSWORD
  Deployment Path: /home/${USERNAME}_root/$USERNAME/$DOMAIN/public


Post-setup Commands :
  #check if configuration are ok:
  nginx -t
  #if it is successful then fun following command
  service nginx restart
EOF

exec bash
