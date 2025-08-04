#!/bin/bash

# --- IP Validation Function ---
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [[ $i -gt 255 || $i -lt 0 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# --- Parameter Check ---
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <OLD_IP> <NEW_IP>"
    exit 1
fi

OLD_IP="$1"
NEW_IP="$2"

# Validate IP addresses
if ! validate_ip "$OLD_IP"; then
    echo "Error: Invalid OLD_IP address: $OLD_IP"
    exit 1
fi

if ! validate_ip "$NEW_IP"; then
    echo "Error: Invalid NEW_IP address: $NEW_IP"
    exit 1
fi

echo "IP Migration: $OLD_IP -> $NEW_IP"

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
  "/etc/freeswitch/autoload_configs/event_socket.conf.xml"
  "/etc/network/interfaces"
  "/etc/hosts"
)

BACKUP_DIR="/var/backups/fusionpbx_ip_migration_$(date +%F_%H-%M-%S)"
SQL_SCRIPT="/tmp/update_ip.sql"

# --- Confirmation Prompt Function ---
confirm() {
    read -r -p "$1 [y/N]: " response
    [[ "$response" =~ ^[Yy]$ ]] || { echo "Aborting."; exit 1; }
}

# --- Rollback Function ---
rollback() {
    echo "ERROR: Something went wrong. Rolling back changes..."
    
    if [[ -d "$BACKUP_DIR" ]]; then
        echo "Restoring configuration files..."
        for file in "${CONFIG_FILES[@]}"; do
            if [[ -f "$BACKUP_DIR/configs/$(basename "$file")" ]]; then
                cp "$BACKUP_DIR/configs/$(basename "$file")" "$file"
                echo " - Restored $file"
            fi
        done
        
        if [[ -f "$BACKUP_DIR/db/${DB_NAME}_backup.sql" ]]; then
            echo "Restoring database..."
            export PGPASSWORD="$DB_PASS"
            psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -p "$DB_PORT" < "$BACKUP_DIR/db/${DB_NAME}_backup.sql"
        fi
        
        echo "Rollback completed. Please restart services manually."
    else
        echo "Backup directory not found. Manual restoration required."
    fi
    exit 1
}

# --- Trap for cleanup on error ---
trap rollback ERR

# --- Stop Services ---
echo "To ensure safe migration, it's recommended to stop FreeSWITCH, PHP-FPM, and Nginx during the process."
confirm "Do you want to stop services now (freeswitch, php-fpm, nginx)?"

echo "Stopping services..."
systemctl stop freeswitch
if [[ $? -ne 0 ]]; then
    echo "Warning: FreeSWITCH stop failed or not running"
fi

systemctl stop php-fpm || systemctl stop php8.1-fpm || systemctl stop php8.2-fpm || echo "Warning: php-fpm not found"
systemctl stop nginx
if [[ $? -ne 0 ]]; then
    echo "Warning: Nginx stop failed or not running"
fi

echo "Services stopped."

# --- Check PostgreSQL Status ---
if ! systemctl is-active --quiet postgresql; then
    echo "Warning: PostgreSQL is not running. Starting it..."
    systemctl start postgresql
    sleep 5
    if ! systemctl is-active --quiet postgresql; then
        echo "Error: Cannot start PostgreSQL. Database operations will fail."
        exit 1
    fi
fi

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

# Test database connection first
if ! psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -p "$DB_PORT" -c "SELECT 1;" >/dev/null 2>&1; then
    echo "Error: Cannot connect to PostgreSQL database."
    echo "Please check database credentials and ensure PostgreSQL is running."
    exit 1
fi

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
        # Use word boundaries to prevent partial IP matches
        sed -i.bak "s/\b$OLD_IP\b/$NEW_IP/g" "$file"
        echo " - Updated $file (backup: $file.bak)"
    fi
done

# --- Generate Dynamic SQL for DB IP Replacement ---
echo "Generating SQL update script for database..."

# Create comprehensive SQL script that updates ALL text/varchar columns
cat > "$SQL_SCRIPT" << EOF
-- Comprehensive IP replacement in all text/varchar columns
EOF

# Generate SQL for ALL text and varchar columns in the database
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -p "$DB_PORT" -Atc "
SELECT 'UPDATE ' || table_schema || '.' || table_name || ' SET ' || column_name ||
       ' = REPLACE(' || column_name || ', ''' || '$OLD_IP' || ''', ''' || '$NEW_IP' || ''') WHERE ' || column_name || ' LIKE ''%' || '$OLD_IP' || '%'';'
FROM information_schema.columns
WHERE table_schema NOT IN ('information_schema', 'pg_catalog')
  AND data_type IN ('character varying', 'text', 'varchar')
ORDER BY table_name, column_name;
" >> "$SQL_SCRIPT"

# Check if we generated any SQL
if [[ ! -s "$SQL_SCRIPT" ]] || [[ $(wc -l < "$SQL_SCRIPT") -le 1 ]]; then
    echo "No text/varchar columns found in database or no SQL generated."
    echo "Skipping database updates."
else
    echo "Generated SQL script with $(wc -l < "$SQL_SCRIPT") lines"
    
    # Show the complete SQL script for review
    echo "Preview of all database updates:"
    echo "================================"
    cat "$SQL_SCRIPT"
    echo "================================"
    
    confirm "Proceed with these database updates?"
fi

if [[ ! -s "$SQL_SCRIPT" ]]; then
    echo "No matching entries found in database. Skipping DB update."
else
    echo "Applying database updates from $SQL_SCRIPT..."
    if psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -p "$DB_PORT" -f "$SQL_SCRIPT"; then
        echo "Database updates completed successfully."
    else
        echo "Error: Database update failed. Check $SQL_SCRIPT for issues."
        echo "You can manually run: psql -h $DB_HOST -U $DB_USER -d $DB_NAME -p $DB_PORT -f $SQL_SCRIPT"
    fi
fi

# --- Post-migration cleanup and restart ---
confirm "Migration completed. Do you want to clear FusionPBX cache and restart services now?"

echo "Clearing FusionPBX cache..."
rm -rf /var/cache/fusionpbx/*

# Check if network configuration was changed
if grep -q "$NEW_IP" /etc/network/interfaces 2>/dev/null; then
    echo "Network configuration updated. You may need to restart networking:"
    echo "  sudo systemctl restart networking"
    echo "  OR reboot the system"
    confirm "Do you want to restart networking now? (This may disconnect you if remote)"
    systemctl restart networking
    sleep 5
fi

echo "Starting services..."
systemctl start nginx
if systemctl is-active --quiet nginx; then
    echo " - Nginx started successfully"
else
    echo " - Warning: Nginx failed to start"
fi

systemctl start php-fpm || systemctl start php8.1-fpm || systemctl start php8.2-fpm || echo "Warning: php-fpm not found"
if systemctl is-active --quiet php-fpm || systemctl is-active --quiet php8.1-fpm || systemctl is-active --quiet php8.2-fpm; then
    echo " - PHP-FPM started successfully"
else
    echo " - Warning: PHP-FPM failed to start"
fi

echo "Waiting 10 seconds before starting FreeSWITCH..."
sleep 10

systemctl start freeswitch
if systemctl is-active --quiet freeswitch; then
    echo " - FreeSWITCH started successfully"
    
    echo "Waiting for FreeSWITCH to fully load..."
    sleep 30
    
    echo "Triggering FreeSWITCH reloads..."
    fs_cli -x "reloadxml" || echo "Warning: reloadxml failed"
    fs_cli -x "sofia profile internal restart" || echo "Warning: internal profile restart failed"
    fs_cli -x "sofia profile external restart" || echo "Warning: external profile restart failed"
    
else
    echo " - Warning: FreeSWITCH failed to start"
    echo "   Check logs: journalctl -u freeswitch -f"
fi

echo ""
echo "=== Migration Summary ==="
echo "Old IP: $OLD_IP"
echo "New IP: $NEW_IP"
echo "Backup location: $BACKUP_DIR"
echo "SQL script: $SQL_SCRIPT"
echo ""
echo "=== Post-Migration Checklist ==="
echo "1. Test web interface: http://$NEW_IP"
echo "2. Test SIP registration"
echo "3. Test calls (internal and external)"
echo "4. Check FreeSWITCH status: fs_cli -x 'sofia status'"
echo "5. If issues occur, restore from backup: $BACKUP_DIR"
echo ""
echo "Migration completed. Please test thoroughly!"
