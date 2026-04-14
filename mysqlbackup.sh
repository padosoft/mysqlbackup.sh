#!/bin/bash

_now=$(date +%Y-%m-%d.%H.%M.%S)
echo "starts at $_now"

DBUSER="admin"
#Se non sono su plesk non esiste il file .psa.shadow, evito che schianti e setto password vuota
DBPASS=$( [ -f /etc/psa/.psa.shadow ] && cat /etc/psa/.psa.shadow || echo "" )
DBPORT=3306
DBHOST=""
DBOPTION="-f --routines"
DEFPATH="/home/backup/"
DATA=`/bin/date +"%a"`
MYSQLBIN="/usr/bin/mysql"
MYSQLDUMPBIN="/usr/bin/mysqldump"
INCLUDE_DATABASES=()
CREATE_DATABASE_TEST=false
TEST_DATABASE_NAME=""
SQL_SCRIPTS_DIR=""
GDRIVE_SERVICE_ACCOUNT_JSON=""
GDRIVE_FOLDER_ID=""
GDRIVE_MAX_SIZE_MB=0

EXCLUDE_TABLES_QUEUE=()
EXCLUDE_TABLES_LOG_CACHE_SERVIZIO=()
EXCLUDE_TABLES_STORICO=()
EXCLUDE_TABLES_STATISTICHE=()
EXCLUDE_TABLES_HOURLY=()
EXCLUDE_TABLES_CUSTOM=()
EXCLUDE_TABLES=()

#
# Load config file if exists
#
CONFIG_DIR=$( dirname "$(readlink -f "$0")" )
CONFIG_FILE="$CONFIG_DIR/mysqlbackup.config"

if [[ -f $CONFIG_FILE ]]; then
   echo "Loading settings from $CONFIG_FILE."
   source $CONFIG_FILE
else
   echo "Could not load settings from $CONFIG_FILE (file does not exist), script use default settings."
fi

# Verifico le opzioni inserite da linea di comando
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hourly)
            DATA="hourly$(date +%H)" # backup incrementale orario
            EXCLUDE_TABLES+=("${EXCLUDE_TABLES_HOURLY[@]}") # Mantiene la lista predefinita
            shift
            ;;
        --databases)
            IFS=',' read -ra INCLUDE_DATABASES <<< "$2" # Split lista di database
            shift 2
            ;;
        --escludi_tabelle_queue)
            EXCLUDE_TABLES+=("${EXCLUDE_TABLES_QUEUE[@]}") # Mantiene la lista predefinita
            shift
            ;;
        --escludi_tabelle_servizio)
            EXCLUDE_TABLES+=("${EXCLUDE_TABLES_LOG_CACHE_SERVIZIO[@]}") # Mantiene la lista predefinita
            shift
            ;;
        --escludi_tabelle_storico)
            EXCLUDE_TABLES+=("${EXCLUDE_TABLES_STORICO[@]}") # Mantiene la lista predefinita
            shift
            ;;
        --escludi_tabelle_statistiche)
            EXCLUDE_TABLES+=("${EXCLUDE_TABLES_STATISTICHE[@]}") # Mantiene la lista predefinita
            shift
            ;;
        --escludi_tabelle_custom)
            IFS=',' read -ra EXCLUDE_TABLES <<< "$2"
            shift 2
            ;;
        --create-database-test)
            CREATE_DATABASE_TEST=true
            shift
            ;;
        --escludi_tutte)
            EXCLUDE_TABLES=("${EXCLUDE_TABLES_QUEUE[@]}" "${EXCLUDE_TABLES_LOG_CACHE_SERVIZIO[@]}" "${EXCLUDE_TABLES_STORICO[@]}" "${EXCLUDE_TABLES_STATISTICHE[@]}")
            shift
            ;;
        *)
            echo "Opzione sconosciuta: $1"
            exit 1
            ;;
    esac
done


#
# Validazione --create-database-test
# Richiede: esattamente 1 database via --databases, TEST_DATABASE_NAME configurato e diverso dal db di produzione
#
if [ "$CREATE_DATABASE_TEST" = true ]; then
    if [ ${#INCLUDE_DATABASES[@]} -ne 1 ]; then
        echo "Errore: --create-database-test richiede --databases con esattamente 1 database"
        exit 1
    fi
    if [ -z "$TEST_DATABASE_NAME" ]; then
        echo "Errore: TEST_DATABASE_NAME non configurato in $CONFIG_FILE"
        exit 1
    fi
    # Evita di sovrascrivere il database di produzione
    if [ "$TEST_DATABASE_NAME" = "${INCLUDE_DATABASES[0]}" ]; then
        echo "Errore: TEST_DATABASE_NAME deve essere diverso dal database di produzione"
        exit 1
    fi
    # Default per la directory degli script SQL di trasformazione
    if [ -z "$SQL_SCRIPTS_DIR" ]; then
        SQL_SCRIPTS_DIR="$CONFIG_DIR/sql_script_for_test_db"
    fi
    if [ ! -d "$SQL_SCRIPTS_DIR" ]; then
        echo "Warning: directory $SQL_SCRIPTS_DIR non trovata, nessuno script SQL verra' eseguito"
    fi
fi

MYSQLCOMMAND="$MYSQLBIN"
MYSQLCONFIG=""
if [ ! -z $DBUSER ]; then
    MYSQLCONFIG+=" -u$DBUSER"
fi

if [ ! -z $DBPASS ]; then
    MYSQLCONFIG+=" -p$DBPASS"
fi

if [ "$DBPORT" != "3306" ]; then
    MYSQLCONFIG+=" --port=$DBPORT"
fi

if [ "$DBHOST" != "" ]; then
    MYSQLCONFIG+=" -h$DBHOST"
fi

MYSQLCOMMAND+="$MYSQLCONFIG"

#
# Funzioni per upload su Google Drive via Service Account
#

# Ottiene un access token OAuth2 dal Service Account JSON usando JWT firmato con openssl
get_gdrive_token() {
    # Estrae i campi dal JSON del service account
    local client_email=$(grep '"client_email"' "$GDRIVE_SERVICE_ACCOUNT_JSON" | sed 's/.*: *"\(.*\)".*/\1/')
    local token_uri=$(grep '"token_uri"' "$GDRIVE_SERVICE_ACCOUNT_JSON" | sed 's/.*: *"\(.*\)".*/\1/')

    # Estrae la private key (campo multilinea con \n)
    local private_key=$(sed -n '/private_key/,/-----END/p' "$GDRIVE_SERVICE_ACCOUNT_JSON" | sed 's/.*: *"//;s/",*$//' | sed 's/\\n/\n/g')

    # JWT header e claim
    local now=$(date +%s)
    local exp=$((now + 3600))
    local header='{"alg":"RS256","typ":"JWT"}'
    local claim="{\"iss\":\"$client_email\",\"scope\":\"https://www.googleapis.com/auth/drive.file\",\"aud\":\"$token_uri\",\"iat\":$now,\"exp\":$exp}"

    # Base64url encoding
    local b64_header=$(echo -n "$header" | openssl base64 -e | tr -d '=\n' | tr '+/' '-_')
    local b64_claim=$(echo -n "$claim" | openssl base64 -e | tr -d '=\n' | tr '+/' '-_')

    # Firma RSA-SHA256 con la private key del service account
    local signature=$(echo -n "$b64_header.$b64_claim" | openssl dgst -sha256 -sign <(echo "$private_key") | openssl base64 -e | tr -d '=\n' | tr '+/' '-_')

    local jwt="$b64_header.$b64_claim.$signature"

    # Scambia il JWT per un access token
    local response=$(curl -s -X POST "$token_uri" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=$jwt")

    echo "$response" | grep -o '"access_token" *: *"[^"]*"' | sed 's/.*: *"\(.*\)"/\1/'
}

# Carica un file su Google Drive con controllo dimensione massima
# Parametri: $1 = path del file, $2 = nome del file su Drive (opzionale, default = basename)
upload_to_gdrive() {
    local file_path="$1"
    local file_name="${2:-$(basename "$file_path")}"

    # Controllo dimensione massima
    if [ "$GDRIVE_MAX_SIZE_MB" -gt 0 ]; then
        local file_size_mb=$(( $(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path") / 1048576 ))
        if [ "$file_size_mb" -gt "$GDRIVE_MAX_SIZE_MB" ]; then
            echo "Warning: file $file_name ($file_size_mb MB) supera il limite di $GDRIVE_MAX_SIZE_MB MB, upload skippato"
            return 0
        fi
    fi

    # Ottieni access token dal service account
    local token=$(get_gdrive_token)
    if [ -z "$token" ]; then
        echo "Errore: impossibile ottenere access token per Google Drive"
        return 1
    fi

    # Upload via API Google Drive (multipart upload)
    echo "Uploading $file_name to Google Drive..."
    local response=$(curl -s -X POST \
        -H "Authorization: Bearer $token" \
        -F "metadata={\"name\":\"$file_name\",\"parents\":[\"$GDRIVE_FOLDER_ID\"]};type=application/json;charset=UTF-8" \
        -F "file=@$file_path;type=application/gzip" \
        "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")

    if echo "$response" | grep -q '"id"'; then
        echo "Upload completed: $file_name"
    else
        echo "Errore upload Google Drive: $response"
        return 1
    fi
}

echo "retrieve databases..."
echo $MYSQLCOMMAND
DBNAMES=`echo "show databases" |$MYSQLCOMMAND | egrep -v "Database|information_schema"`
#Se sono stati specificati i database da linea di comando elaboro solo quelli specificati
if [[ ${#INCLUDE_DATABASES[@]} -gt 0 ]]; then
    DBNAMES="${INCLUDE_DATABASES[@]}"
    echo "$DBNAMES"
fi


for database in $DBNAMES; do
    BACKUP_FILE="$DEFPATH/data/$database/$database-$DATA-dump.sql.gz"

    if [ ! -d "$DEFPATH/data/$database" ]; then
        echo "Making directory structure ..."
        mkdir -p "$DEFPATH/data/$database"
    fi

    echo "Backup db name $database starts at $(date +%Y-%m-%d.%H.%M.%S)"

    # Costruisce la lista di tabelle da escludere
    EXCLUDE_PARAMS=""
    for table in "${EXCLUDE_TABLES[@]}"; do
        EXCLUDE_PARAMS+=" --ignore-table=$database.$table"
    done

    # Dump completo con schema per le tabelle escluse
    {
        for table in "${EXCLUDE_TABLES[@]}"; do
            $MYSQLDUMPBIN $MYSQLCONFIG --no-data $database $table
        done
        $MYSQLDUMPBIN $MYSQLCONFIG $DBOPTION $EXCLUDE_PARAMS $database
    } | gzip > "$BACKUP_FILE"

    # Controllo se il backup è stato creato correttamente
    if [ -s "$BACKUP_FILE" ]; then
        echo "Backup completed successfully: $BACKUP_FILE"
    else
        echo "Backup failed: file does not exist or is empty, removing..."
        rm -f "$BACKUP_FILE"
    fi

    echo "Backup db name $database finish at $(date +%Y-%m-%d.%H.%M.%S)"
done

#
# Creazione database di test a partire dal database di produzione
# Flusso: dump prod -> import in test db -> esecuzione script SQL di trasformazione -> export test db
#
if [ "$CREATE_DATABASE_TEST" = true ]; then
    database="${INCLUDE_DATABASES[0]}"
    echo ""
    echo "=== Create test database starts at $(date +%Y-%m-%d.%H.%M.%S) ==="
    echo "Source database: $database"
    echo "Test database: $TEST_DATABASE_NAME"

    if [ ! -d "$DEFPATH/data/$database" ]; then
        mkdir -p "$DEFPATH/data/$database"
    fi

    # Costruisce la lista di tabelle da escludere (stessa logica del backup standard)
    EXCLUDE_PARAMS=""
    for table in "${EXCLUDE_TABLES[@]}"; do
        EXCLUDE_PARAMS+=" --ignore-table=$database.$table"
    done

    # Step 1: Dump del database di produzione in un file .sql temporaneo (non compresso per l'import diretto)
    TEMP_SQL_FILE="$DEFPATH/data/$database/${database}_export_db-$DATA-dump.sql"
    echo "Dumping production database $database to temp file..."
    {
        for table in "${EXCLUDE_TABLES[@]}"; do
            $MYSQLDUMPBIN $MYSQLCONFIG --no-data $database $table
        done
        $MYSQLDUMPBIN $MYSQLCONFIG $DBOPTION $EXCLUDE_PARAMS $database
    } > "$TEMP_SQL_FILE"

    if [ ! -s "$TEMP_SQL_FILE" ]; then
        echo "Errore: dump del database di produzione fallito o vuoto"
        rm -f "$TEMP_SQL_FILE"
        exit 1
    fi
    echo "Dump completed: $TEMP_SQL_FILE"

    # Step 2: Drop di tutte le tabelle e viste nel database di test
    # Disabilita FK per evitare errori di dipendenza tra tabelle
    echo "Cleaning test database $TEST_DATABASE_NAME..."
    $MYSQLCOMMAND $TEST_DATABASE_NAME -e "SET FOREIGN_KEY_CHECKS=0"

    TABLES=$($MYSQLCOMMAND $TEST_DATABASE_NAME -e "SHOW TABLES" -N)
    for table in $TABLES; do
        $MYSQLCOMMAND $TEST_DATABASE_NAME -e "DROP TABLE IF EXISTS \`$table\`"
    done

    VIEWS=$($MYSQLCOMMAND $TEST_DATABASE_NAME -e "SHOW FULL TABLES WHERE Table_type='VIEW'" -N | awk '{print $1}')
    for view in $VIEWS; do
        $MYSQLCOMMAND $TEST_DATABASE_NAME -e "DROP VIEW IF EXISTS \`$view\`"
    done

    $MYSQLCOMMAND $TEST_DATABASE_NAME -e "SET FOREIGN_KEY_CHECKS=1"

    # Step 3: Import del dump nel database di test
    echo "Importing dump into test database $TEST_DATABASE_NAME..."
    $MYSQLBIN $MYSQLCONFIG $TEST_DATABASE_NAME < "$TEMP_SQL_FILE"

    # Step 4: Esecuzione degli script SQL di trasformazione (in ordine alfabetico/numerico)
    if [ -d "$SQL_SCRIPTS_DIR" ]; then
        for script in $(ls "$SQL_SCRIPTS_DIR"/*.sql 2>/dev/null | sort); do
            echo "Executing SQL script: $script"
            $MYSQLBIN $MYSQLCONFIG $TEST_DATABASE_NAME < "$script"
        done
    fi

    # Step 5: Export finale del database di test (compresso con gzip)
    BACKUP_FILE_TEST="$DEFPATH/data/$database/${database}_test_db-$DATA-dump.sql.gz"
    echo "Exporting test database $TEST_DATABASE_NAME..."
    $MYSQLDUMPBIN $MYSQLCONFIG $DBOPTION $TEST_DATABASE_NAME | gzip > "$BACKUP_FILE_TEST"

    if [ -s "$BACKUP_FILE_TEST" ]; then
        echo "Test database export completed: $BACKUP_FILE_TEST"
    else
        echo "Errore: export del database di test fallito o vuoto"
        rm -f "$BACKUP_FILE_TEST"
    fi

    # Step 6: Upload su Google Drive (se configurato)
    # Il file su Drive si chiama nomedbprod_YYYY-MM-DD.sql.gz
    if [ -n "$GDRIVE_SERVICE_ACCOUNT_JSON" ] && [ -n "$GDRIVE_FOLDER_ID" ]; then
        if [ -s "$BACKUP_FILE_TEST" ]; then
            GDRIVE_FILE_NAME="${database}_$(date +%Y-%m-%d).sql.gz"
            upload_to_gdrive "$BACKUP_FILE_TEST" "$GDRIVE_FILE_NAME"
        fi
    fi

    # Cleanup: rimuove il file .sql temporaneo
    rm -f "$TEMP_SQL_FILE"

    echo "=== Create test database finish at $(date +%Y-%m-%d.%H.%M.%S) ==="
fi

_now=$(date +%Y-%m-%d.%H.%M.%S)
echo "Finish at $_now"
