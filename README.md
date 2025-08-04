# FusionPBX IP Migration Script

> ⚠️ **Notice**: This script was primarily built with GitHub Copilot assistance but includes extensive human adjustments and testing. While thoroughly reviewed, there may be edge cases or issues that haven't been identified. **Always test in a non-production environment first** and ensure you have complete backups before running on production systems.

A comprehensive bash script for safely migrating FusionPBX installations to a new IP address. This script automatically updates configuration files, database entries, and manages service restarts with full backup and rollback capabilities.

## 🚀 Features

- **IP Address Validation** - Validates IPv4 addresses before processing
- **Comprehensive Backup** - Backs up all configuration files and PostgreSQL database
- **Safe Configuration Updates** - Uses word boundaries to prevent partial IP matches
- **Complete Database Migration** - Updates ALL text/varchar columns containing the old IP
- **Service Management** - Properly stops/starts FreeSWITCH, PHP-FPM, and Nginx
- **Automatic Rollback** - Rolls back changes if anything goes wrong
- **Full Transparency** - Shows exactly what will be changed before executing
- **Network Configuration** - Handles `/etc/network/interfaces` updates
- **Post-Migration Verification** - Comprehensive checklist for testing

## 📋 Prerequisites

- FusionPBX installation with PostgreSQL database
- Root or sudo access to the server
- PostgreSQL client tools (`psql`, `pg_dump`)
- FreeSWITCH CLI access (`fs_cli`)

## 🛠️ What Gets Updated

### Configuration Files
- `/etc/fusionpbx/config.conf` - FusionPBX main configuration
- `/etc/freeswitch/vars.xml` - FreeSWITCH variables
- `/etc/freeswitch/autoload_configs/event_socket.conf.xml` - Event Socket configuration
- `/etc/network/interfaces` - Network interface configuration
- `/etc/hosts` - System hosts file

### Database
- **ALL** text and varchar columns in all user schemas
- Automatically discovers and updates any column containing the old IP address
- Excludes system schemas (`information_schema`, `pg_catalog`)

### Services
- FreeSWITCH (with profile reloads)
- PHP-FPM (supports versions 8.1, 8.2)
- Nginx
- PostgreSQL (ensures it's running)

## 📖 Usage

### Basic Usage
```bash
sudo ./fusionpbx_ip_migration.sh <OLD_IP> <NEW_IP>
```

### Example
```bash
sudo ./fusionpbx_ip_migration.sh 192.168.1.100 192.168.1.200
```

## 🔧 How It Works

1. **Validation Phase**
   - Validates IP address formats
   - Checks FusionPBX configuration file exists
   - Extracts database credentials
   - Tests database connectivity

2. **Backup Phase**
   - Creates timestamped backup directory
   - Backs up all configuration files
   - Creates full PostgreSQL database dump

3. **Migration Phase**
   - Updates configuration files with safe regex patterns
   - Generates comprehensive SQL script for database updates
   - Shows complete preview of all database changes
   - Applies database updates

4. **Service Restart Phase**
   - Clears FusionPBX cache
   - Optionally restarts network configuration
   - Starts services in proper order
   - Reloads FreeSWITCH profiles

## 🛡️ Safety Features

### Automatic Backups
All backups are stored in `/var/backups/fusionpbx_ip_migration_YYYY-MM-DD_HH-MM-SS/`:
```
├── configs/          # Configuration file backups
└── db/              # Database backup (.sql)
```

### Rollback Protection
- **Error Trap**: Automatically rolls back on any script failure
- **Manual Rollback**: Instructions provided if issues occur
- **Service Recovery**: Guidance for restarting services manually

### Safe Pattern Matching
- Uses word boundaries (`\b`) in regex to prevent partial IP matches
- Only updates rows that actually contain the old IP address
- Schema-qualified database updates

## 📋 Interactive Confirmations

The script asks for confirmation at each major step:
1. Stop services (FreeSWITCH, PHP-FPM, Nginx)
2. Proceed with backup
3. Proceed with migration
4. Review database changes (shows complete SQL script)
5. Restart network configuration
6. Clear cache and restart services

## 🔍 Post-Migration Checklist

After successful migration, test these components:

1. **Web Interface**: `http://NEW_IP`
2. **SIP Registration**: Check phone registrations
3. **Call Testing**: Test internal and external calls
4. **FreeSWITCH Status**: `fs_cli -x 'sofia status'`
5. **Service Status**: Verify all services are running

## 📊 Example Output

```bash
IP Migration: 192.168.1.100 -> 192.168.1.200
Stopping services...
Creating backup directory at /var/backups/fusionpbx_ip_migration_2025-08-05_14-30-22...
Backing up config files...
 - /etc/fusionpbx/config.conf backed up.
 - /etc/freeswitch/vars.xml backed up.
...
Generated SQL script with 47 lines
Preview of all database updates:
================================
-- Comprehensive IP replacement in all text/varchar columns
UPDATE public.v_domains SET domain_name = REPLACE(domain_name, '192.168.1.100', '192.168.1.200') WHERE domain_name LIKE '%192.168.1.100%';
UPDATE public.v_gateways SET gateway = REPLACE(gateway, '192.168.1.100', '192.168.1.200') WHERE gateway LIKE '%192.168.1.100%';
...
================================
```

## 🚨 Troubleshooting

### Database Connection Issues
```bash
Error: Cannot connect to PostgreSQL database.
```
**Solution**: Ensure PostgreSQL is running and credentials in `/etc/fusionpbx/config.conf` are correct.

### Service Start Failures
```bash
Warning: FreeSWITCH failed to start
```
**Solution**: Check logs with `journalctl -u freeswitch -f` and verify configuration syntax.

### Rollback Required
If something goes wrong, restore from backup:
```bash
# Restore database
export PGPASSWORD="your_db_password"
psql -h localhost -U fusionpbx -d fusionpbx < /var/backups/fusionpbx_ip_migration_*/db/fusionpbx_backup.sql

# Restore config files
cp /var/backups/fusionpbx_ip_migration_*/configs/* /etc/fusionpbx/
```

## ⚠️ Important Notes

- **Test First**: Always test on a development/staging environment
- **Remote Access**: If running remotely, network restart may disconnect you
- **Backup Verification**: Verify backups are complete before proceeding
- **Service Dependencies**: Some services may take time to fully start
- **SSL Certificates**: May need updating if using domain names with HTTPS

## 📝 Advanced Configuration

### Custom FusionPBX Configuration Path
Edit the script to change the configuration file location:
```bash
FUSIONPBX_CONF="/custom/path/to/config.conf"
```

### Additional Configuration Files
Add more files to the `CONFIG_FILES` array:
```bash
CONFIG_FILES=(
  "/etc/fusionpbx/config.conf"
  "/etc/freeswitch/vars.xml"
  "/etc/freeswitch/autoload_configs/event_socket.conf.xml"
  "/etc/network/interfaces"
  "/etc/hosts"
  "/custom/config/file.conf"  # Add your custom files here
)
```

## 📄 License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## ⚡ Quick Start

1. Download the script:
   ```bash
   wget https://raw.githubusercontent.com/your-repo/fusionpbx-ip-migration/main/fusionpbx_ip_migration.sh
   chmod +x fusionpbx_ip_migration.sh
   ```

2. Run with your IP addresses:
   ```bash
   sudo ./fusionpbx_ip_migration.sh 192.168.1.100 192.168.1.200
   ```

3. Follow the interactive prompts and test thoroughly!

---

**⚠️ Always backup your system before making changes to production environments!**
