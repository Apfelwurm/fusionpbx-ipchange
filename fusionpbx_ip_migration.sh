#!/bin/bash

# --- Parameter Check ---
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <OLD_IP> <NEW_IP>"
    exit 1
fi

OLD_IP="$1"
NEW_IP="$2"

# --- Configuration ---
FUSIONPBX_CONF="/etc/fusionpbx/config.conf"

# --- Parse DB credentials from FusionPBX config ---
if [[ ! -f "$FUSIONPBX_CONF" ]]; then
    echo "Error: Cannot find FusionPBX config at $FUSIONPBX_CONF"
    exit 1
fi

DB_HOST=$(grep -E '^database\.0\.host' "$FUSIONPBX_CONF" | cut -d'=' -f2 | xargs)
DB_PORT=$(grep -E '^database\.0\.port' "$FUSIONPBX_CONF" | cut -d'=' -f2 | xargs)
DB_NAME=$(grep -E '^database\.0\.name' "$FUSIONPBX_CONF" | cut -d'=' -f2 | xargs)
DB_USER=$(grep -E '^database\.0\.username' "$FUSIONPBX_CONF" | cut -d'=' -f2 | xargs)
DB_PASS=$(grep -E '^database\.0\.password' "$FUSIONPBX_CONF" | cut -d'=' -f2 | xargs)

# Validate DB values
if [[ -z "$DB_HOST" || -z "$DB_PORT" || -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASS" ]]; then
    echo "Error: One or more database config values are missing or malformed in $FUSIONPBX_CONF"
    exit 1
fi

# --- Config files to be updated ---
CONFIG_FILES=(
  "/etc/fusionpbx/config.conf"
  "/etc/freeswitch/vars.xml"
  "/etc/network/interfaces"
  "/etc/hosts"
  "/var/cache/fusionpbx/configuration.sofia.conf.ams-pbx1"
  "/var/cache/fusionpbx/configuration.acl.conf"
)

BACKUP_DIR="/var/backups/fusionpbx_ip_migration_$(date +%F_%H-%M-%S)"
SQL_SCRIPT="/tmp/update_ip.sql"

# --- Confirmation Prompt Function ---
confirm() {
    read -r -p "$1 [y/N]: " response
    [[ "$response" =~ ^[Yy]$ ]] || { echo "Aborting."; exit 1; }
}

# --- Stop Services ---
echo "To ensure safe migration, it's recommended to stop FreeSWITCH, PHP-FPM, and Nginx during the process."
confirm "Do you want to stop services now (freeswitch, php-fpm, nginx)?"

echo "Stopping services..."
systemctl stop freeswitch
systemctl stop php-fpm || systemctl stop php8.1-fpm || echo "Warning: php-fpm not found"
systemctl stop nginx
echo "Services stopped."

# --- Step 1: Confirm and Backup ---
confirm "Proceed to backup configuration files and PostgreSQL database?"

echo "Creating backup directory at $BACKUP_DIR..."
mkdir -p "$BACKUP_DIR/configs"
mkdir -p "$BACKUP_DIR/db"

echo "Backing up config files..."
for file in "${CONFIG_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        cp "$file" "$BACKUP_DIR/configs/"
        echo " - $file backed up."
    else
        echo " - $file not found, skipping."
    fi
done

echo "Backing up PostgreSQL database..."
export PGPASSWORD="$DB_PASS"
pg_dump -h "$DB_HOST" -U "$DB_USER" -p "$DB_PORT" "$DB_NAME" > "$BACKUP_DIR/db/${DB_NAME}_backup.sql"

if [[ $? -ne 0 ]]; then
    echo "Error: Database backup failed."
    exit 1
fi

echo "Backup completed successfully at $BACKUP_DIR"

# --- Step 2: Confirm and Execute Migration ---
confirm "Proceed with replacing IP in config files and database?"

# --- Update Config Files ---
echo "Updating config files..."
for file in "${CONFIG_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        sed -i.bak "s/$OLD_IP/$NEW_IP/g" "$file"
        echo " - Updated $file (backup: $file.bak)"
    fi
done

# --- Generate Dynamic SQL for DB IP Replacement ---
echo "Generating SQL update script for database..."

psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -p "$DB_PORT" -Atc "
SELECT 'UPDATE ' || table_schema || '.' || table_name || ' SET ' || column_name ||
       ' = REPLACE(' || column_name || ', ''$OLD_IP'', ''$NEW_IP'') WHERE ' || column_name || ' LIKE ''%$OLD_IP%'';'
FROM information_schema.columns
WHERE data_type IN ('character varying', 'text')
  AND table_schema NOT IN ('information_schema', 'pg_catalog');
" > "$SQL_SCRIPT"

if [[ ! -s "$SQL_SCRIPT" ]]; then
    echo "No matching entries found in database. Skipping DB update."
else
    echo "Applying database updates from $SQL_SCRIPT..."
    psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -p "$DB_PORT" -f "$SQL_SCRIPT"
fi

# --- Post-migration cleanup and restart ---
confirm "Migration completed. Do you want to clear FusionPBX cache and restart services now?"

echo "Clearing FusionPBX cache..."
rm -rf /var/cache/fusionpbx/*

echo "Starting services..."
systemctl start nginx
systemctl start php-fpm || systemctl start php8.1-fpm || echo "Warning: php-fpm not found"
sleep 45
systemctl start freeswitch

echo "Triggering FreeSWITCH reload..."
fs_cli -x "reloadxml"

echo "All services restarted. Migration fully complete."
