
# mysqlbackup.sh
Bash script to daily backup all your mysql/mariadb database in gzip or Gdrive with weekly history.

[![Software License][ico-license]](LICENSE.md)

Table of Contents
=================

  * [Prerequisites](#prerequisites)
  * [Install](#install)
  * [Usage](#usage)
  * [Create test database](#create-test-database)
  * [Google Drive upload](#google-drive-upload)
  * [Lock file](#lock-file)
  * [Configuration reference](#configuration-reference)
  * [Contributing](#contributing)
  * [Credits](#credits)
  * [License](#license)

# Prerequisites

- bash
- mysql / mysqldump
- curl (required for Google Drive upload)
- gzip (required for `--create-database-test`; otherwise used for compressed intermediate dumps)

# Install

``` bash
cd /root/myscript
git clone https://github.com/padosoft/mysqlbackup.sh.git
cd mysqlbackup.sh
chmod +x mysqlbackup.sh
```

Create a config file from the template and set your variables:

``` bash
cp mysqlbackup.config.template mysqlbackup.config
nano mysqlbackup.config
```

`mysqlbackup.config` is excluded from git (contains credentials).

To run automatically every day at midnight, add a cronjob manually or run the install script:

``` bash
chmod +x install.sh
bash install.sh
```

# Usage

**Backup all databases (standard daily backup):**

``` bash
bash mysqlbackup.sh
```

**Backup specific databases only:**

``` bash
bash mysqlbackup.sh --databases mydb1,mydb2
```

**Hourly backup (uses hourlyHH suffix instead of day name):**

``` bash
bash mysqlbackup.sh --hourly
```

**Exclude tables from the backup:**

``` bash
# Exclude predefined table groups (configured in mysqlbackup.config)
bash mysqlbackup.sh --escludi_tabelle_queue
bash mysqlbackup.sh --escludi_tabelle_servizio
bash mysqlbackup.sh --escludi_tabelle_storico
bash mysqlbackup.sh --escludi_tabelle_statistiche
bash mysqlbackup.sh --escludi_tutte

# Exclude specific tables
bash mysqlbackup.sh --escludi_tabelle_custom table1,table2
```

Excluded tables still have their schema exported (structure only, no data).

## Output

Backups are saved in `<DEFPATH>/data/<database>/` with weekly rotation:

```
/home/backup/data/mydb/mydb-Mon-dump.sql.gz
/home/backup/data/mydb/mydb-Tue-dump.sql.gz
...
```

Each day's file overwrites the same day from the previous week.

# Create test database

Create a test database from production, useful for providing developers with a sanitized copy of production data.

**Flow:** dump production DB -> import into test DB -> run SQL transformation scripts -> export test DB

``` bash
bash mysqlbackup.sh --create-database-test --databases mydb_production
```

**Requirements:**

1. Set `TEST_DATABASE_NAME` in `mysqlbackup.config` (must be different from the production database name)
2. The test database must already exist on the MySQL server (`CREATE DATABASE mydb_test`)
3. Use `--databases` with exactly one database name

**SQL transformation scripts:**

Place `.sql` files in the `sql_script_for_test_db/` directory (or configure `SQL_SCRIPTS_DIR` in config). Scripts are executed in alphabetical/numeric order after the import. Use these to anonymize data, remove sensitive information, etc.

Example naming convention:
```
sql_script_for_test_db/
  001_anonymize_users.sql
  002_clear_logs.sql
  003_reset_passwords.sql
```

**Table exclusions** (`--escludi_tabelle_*`) are compatible with `--create-database-test` to exclude large or unnecessary tables from the test database.

When `--create-database-test` is used, the standard backup is skipped. Only the test database creation flow runs.

# Google Drive upload

Automatically upload the test database export to Google Drive after creation.

## Setup

1. Go to [Google Cloud Console](https://console.cloud.google.com)
2. Create a project (or use an existing one)
3. Enable the **Google Drive API**
4. Go to **APIs & Services** -> **Credentials** -> **Create Credentials** -> **OAuth client ID**
5. Application type: **Desktop app** (or Web, with `http://localhost` as redirect URI)
6. Add your Google account as a test user in **OAuth consent screen** -> **Audience**
7. Run the authorization flow to get a refresh token:

``` bash
# Open this URL in your browser (replace CLIENT_ID):
https://accounts.google.com/o/oauth2/auth?client_id=YOUR_CLIENT_ID&redirect_uri=http://localhost&response_type=code&scope=https://www.googleapis.com/auth/drive&access_type=offline&prompt=consent

# After authorization, the browser redirects to http://localhost/?code=XXXX
# Exchange the code for a refresh token:
curl -s -X POST "https://oauth2.googleapis.com/token" \
  -d "code=AUTHORIZATION_CODE" \
  -d "client_id=YOUR_CLIENT_ID" \
  -d "client_secret=YOUR_CLIENT_SECRET" \
  -d "redirect_uri=http://localhost" \
  -d "grant_type=authorization_code"
```

8. Copy the `refresh_token` from the response and configure `mysqlbackup.config`:

``` bash
GDRIVE_CLIENT_ID="your-client-id"
GDRIVE_CLIENT_SECRET="your-client-secret"
GDRIVE_REFRESH_TOKEN="your-refresh-token"
GDRIVE_FOLDER_ID="your-folder-id"        # from the Google Drive folder URL
GDRIVE_MAX_SIZE_MB=500                     # skip upload if file exceeds 500 MB (0 = no limit)
GDRIVE_KEEP_FILES=2                        # keep only the last 2 files per database on Drive (0 = no pruning)
```

The uploaded file is named `<database>_YYYY-MM-DD.sql.gz`.

## Pruning

When `GDRIVE_KEEP_FILES` is set to a value greater than 0, old files are automatically deleted from Google Drive after each upload. Files are matched by database name prefix and sorted by creation date. Only the most recent N files are kept.

# Lock file

The script creates a `mysqlbackup.lock` file to prevent concurrent executions. If the script is already running, a second instance will exit with an error.

If the lock file is older than `LOCK_TIMEOUT_MINUTES` (default: 120 minutes / 2 hours), it is considered stale and automatically removed with a warning. This handles cases where a previous run crashed without cleaning up.

The lock file is automatically removed on exit (including errors) via a `trap`.

# Configuration reference

| Variable | Default | Description |
|----------|---------|-------------|
| `DBUSER` | `admin` | MySQL username |
| `DBPASS` | Plesk shadow file or empty | MySQL password |
| `DBPORT` | `3306` | MySQL port |
| `DBHOST` | (empty = localhost) | MySQL host |
| `DBOPTION` | `-f --routines` | mysqldump options |
| `DEFPATH` | `/home/backup/` | Backup destination directory |
| `MYSQLBIN` | `/usr/bin/mysql` | Path to mysql binary |
| `MYSQLDUMPBIN` | `/usr/bin/mysqldump` | Path to mysqldump binary |
| `EXCLUDE_TABLES_QUEUE` | `()` | Tables to exclude with `--escludi_tabelle_queue` |
| `EXCLUDE_TABLES_LOG_CACHE_SERVIZIO` | `()` | Tables to exclude with `--escludi_tabelle_servizio` |
| `EXCLUDE_TABLES_STORICO` | `()` | Tables to exclude with `--escludi_tabelle_storico` |
| `EXCLUDE_TABLES_STATISTICHE` | `()` | Tables to exclude with `--escludi_tabelle_statistiche` |
| `EXCLUDE_TABLES_HOURLY` | `()` | Tables to exclude with `--hourly` |
| `TEST_DATABASE_NAME` | (empty) | Name of the test database |
| `SQL_SCRIPTS_DIR` | `sql_script_for_test_db/` | Directory containing SQL transformation scripts |
| `GDRIVE_CLIENT_ID` | (empty) | OAuth2 Client ID |
| `GDRIVE_CLIENT_SECRET` | (empty) | OAuth2 Client Secret |
| `GDRIVE_REFRESH_TOKEN` | (empty) | OAuth2 Refresh Token |
| `GDRIVE_FOLDER_ID` | (empty) | Google Drive destination folder ID |
| `GDRIVE_MAX_SIZE_MB` | `0` | Max file size in MB for upload (0 = no limit) |
| `GDRIVE_KEEP_FILES` | `0` | Files to keep per db on Drive (0 = no pruning) |
| `LOCK_TIMEOUT_MINUTES` | `120` | Lock file timeout in minutes before forced removal |

# Contributing

Please see [CONTRIBUTING](CONTRIBUTING.md) and [CONDUCT](CONDUCT.md) for details.

# Credits

- [Lorenzo Padovani](https://github.com/lopadova)
- [Padosoft](https://github.com/padosoft)
- [Daniele Vona](danielev@seeweb.it)
- [All Contributors](../../contributors)

# About Padosoft
Padosoft is a software house based in Florence, Italy. Specialized in E-commerce and web sites.

# License

The MIT License (MIT). Please see [License File](LICENSE.md) for more information.

[ico-license]: https://img.shields.io/badge/License-GPL%20v3-blue.svg?style=flat-square
