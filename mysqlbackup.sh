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
GDRIVE_CLIENT_ID=""
GDRIVE_CLIENT_SECRET=""
GDRIVE_REFRESH_TOKEN=""
GDRIVE_FOLDER_ID=""
GDRIVE_MAX_SIZE_MB=0
GDRIVE_KEEP_FILES=0             # Numero di file da mantenere su Drive per ogni db (0 = nessun pruning)
LOCK_TIMEOUT_MINUTES=120        # Timeout del lock file in minuti (default 2 ore), dopo il quale viene eliminato con warning

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

#
# Lock file: impedisce esecuzioni concorrenti dello script
# Se il lock esiste ed e' piu' vecchio di LOCK_TIMEOUT_MINUTES, viene eliminato con warning
#
LOCK_FILE="$CONFIG_DIR/mysqlbackup.lock"

# Restituisce mtime epoch di un file in modo cross-platform (GNU stat -> BSD stat)
get_file_mtime_epoch() {
    local file="$1"
    local mtime=""

    mtime=$(stat -c %Y "$file" 2>/dev/null) || mtime=""
    if [[ -z "$mtime" ]]; then
        mtime=$(stat -f %m "$file" 2>/dev/null) || mtime=""
    fi

    if [[ "$mtime" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$mtime"
        return 0
    fi

    return 1
}

# Acquisizione atomica del lock file (noclobber impedisce race condition tra istanze concorrenti)
acquire_lock() {
    ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2>/dev/null
}

if ! acquire_lock; then
    if [ -f "$LOCK_FILE" ]; then
        # Calcola l'eta' del lock file in minuti
        lock_mtime=$(get_file_mtime_epoch "$LOCK_FILE")
        if [[ ! "$lock_mtime" =~ ^[0-9]+$ ]]; then
            echo "Errore: impossibile determinare l'eta' del lock file in modo portabile (lock file: $LOCK_FILE)"
            exit 1
        fi

        lock_age_seconds=$(( $(date +%s) - lock_mtime ))
        lock_age_minutes=$(( lock_age_seconds / 60 ))

        if [ "$lock_age_minutes" -ge "$LOCK_TIMEOUT_MINUTES" ]; then
            echo "Warning: lock file presente da $lock_age_minutes minuti (timeout: $LOCK_TIMEOUT_MINUTES min), eliminazione forzata"
            rm -f "$LOCK_FILE"

            if ! acquire_lock; then
                echo "Errore: impossibile acquisire il lock dopo la rimozione del lock stale (lock file: $LOCK_FILE)"
                exit 1
            fi
        else
            echo "Errore: un'altra istanza di mysqlbackup.sh e' gia' in esecuzione (lock file: $LOCK_FILE, eta': $lock_age_minutes min)"
            exit 1
        fi
    else
        echo "Errore: impossibile acquisire il lock file $LOCK_FILE"
        exit 1
    fi
fi

# Registra la rimozione automatica del lock all'uscita (anche in caso di errore)
trap 'rm -f "$LOCK_FILE"' EXIT

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
# Funzioni per upload su Google Drive via OAuth2 refresh token
#

# Ottiene un access token OAuth2 dal refresh token
get_gdrive_token() {
    local response=$(curl -s -X POST "https://oauth2.googleapis.com/token" \
        --data-urlencode "client_id=$GDRIVE_CLIENT_ID" \
        --data-urlencode "client_secret=$GDRIVE_CLIENT_SECRET" \
        --data-urlencode "refresh_token=$GDRIVE_REFRESH_TOKEN" \
        --data-urlencode "grant_type=refresh_token")

    echo "$response" | grep -o '"access_token" *: *"[^"]*"' | sed 's/.*: *"\(.*\)"/\1/'
}

# Carica un file su Google Drive con controllo dimensione massima (resumable upload)
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

    local token=$(get_gdrive_token)
    if [ -z "$token" ]; then
        echo "Errore: impossibile ottenere access token per Google Drive"
        return 1
    fi

    echo "Uploading $file_name to Google Drive..."

    # Inizia upload resumable (robusto per file grandi)
    local upload_url=$(curl -s -i -X POST \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$file_name\",\"parents\":[\"$GDRIVE_FOLDER_ID\"]}" \
        "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable" | grep -i "^location:" | tr -d '\r' | sed 's/location: //i')

    if [ -z "$upload_url" ]; then
        echo "Errore: impossibile iniziare upload su Google Drive"
        return 1
    fi

    # Upload del contenuto e richiesta dei campi size per verifica
    local file_size=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path")
    local response=$(curl -s -X PUT \
        -H "Content-Length: $file_size" \
        -H "Content-Type: application/gzip" \
        --data-binary "@$file_path" \
        "${upload_url}&fields=id,name,size")

    if ! echo "$response" | grep -q '"id"'; then
        echo "Errore upload Google Drive: $response"
        return 1
    fi

    # Verifica che il file caricato non sia vuoto
    local remote_size=$(echo "$response" | grep -o '"size" *: *"[^"]*"' | sed 's/.*: *"\(.*\)"/\1/')
    if [ -n "$remote_size" ] && [ "$remote_size" = "0" ]; then
        echo "Errore: il file caricato su Google Drive risulta vuoto (0 bytes)"
        return 1
    fi
    echo "Upload completed: $file_name ($remote_size bytes)"
}

# Rimuove i file piu' vecchi su Google Drive, mantenendo solo gli ultimi N per ogni database
# Il matching e' basato sul prefisso del nome db (es. "gescat_gianni_") escludendo la data
# Parametri: $1 = prefisso del nome file (es. "gescat_gianni_"), $2 = numero di file da mantenere
prune_gdrive_files() {
    local file_prefix="$1"
    local keep_count="$2"

    local token=$(get_gdrive_token)
    if [ -z "$token" ]; then
        echo "Errore: impossibile ottenere access token per pruning Google Drive"
        return 1
    fi

    # Cerca tutti i file nella cartella che matchano il prefisso, ordinati per data creazione decrescente
    local response=$(curl -s -H "Authorization: Bearer $token" \
        "https://www.googleapis.com/drive/v3/files?q='$GDRIVE_FOLDER_ID'+in+parents+and+name+contains+'${file_prefix}'+and+trashed=false&orderBy=createdTime+desc&fields=files(id,name,createdTime)&pageSize=100")

    # Parsing dei risultati: estrae coppie id/name e salta i primi N (da mantenere)
    # Usa process substitution per evitare subshell (le variabili devono persistere tra iterazioni)
    local i=0
    local current_id=""

    while read -r value; do
        if [ -z "$current_id" ]; then
            # Primo valore della coppia: id
            current_id="$value"
        else
            # Secondo valore della coppia: name
            i=$((i + 1))
            if [ $i -gt $keep_count ]; then
                echo "Pruning: eliminazione $value da Google Drive..."
                curl -s -X DELETE -H "Authorization: Bearer $token" \
                    "https://www.googleapis.com/drive/v3/files/$current_id" > /dev/null
            fi
            current_id=""
        fi
    done < <(echo "$response" | grep -o '"id": *"[^"]*"\|"name": *"[^"]*"' | sed 's/.*: *"\(.*\)"/\1/')
}

echo "retrieve databases..."
echo $MYSQLCOMMAND
DBNAMES=`echo "show databases" |$MYSQLCOMMAND | egrep -v "Database|information_schema"`
#Se sono stati specificati i database da linea di comando elaboro solo quelli specificati
if [[ ${#INCLUDE_DATABASES[@]} -gt 0 ]]; then
    DBNAMES="${INCLUDE_DATABASES[@]}"
    echo "$DBNAMES"
fi


# Skip del backup standard se si sta creando il database di test
if [ "$CREATE_DATABASE_TEST" != true ]; then
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
fi

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

    #
    # Step 1: Dump del database di produzione in un file temporaneo
    # Se gzip e' disponibile comprime il dump per risparmiare spazio su disco
    #
    if command -v gzip &> /dev/null; then
        TEMP_SQL_FILE="$DEFPATH/data/$database/${database}_export_db-$DATA-dump.sql.gz"
        TEMP_USE_GZIP=true
        echo "gzip disponibile, il dump intermedio sara' compresso"
    else
        TEMP_SQL_FILE="$DEFPATH/data/$database/${database}_export_db-$DATA-dump.sql"
        TEMP_USE_GZIP=false
        echo "gzip non disponibile, il dump intermedio sara' in chiaro"
    fi

    echo "Dumping production database $database to temp file..."
    if [ "$TEMP_USE_GZIP" = true ]; then
        # Dump compresso: pipe diretta a gzip
        {
            for table in "${EXCLUDE_TABLES[@]}"; do
                $MYSQLDUMPBIN $MYSQLCONFIG --no-data $database $table
            done
            $MYSQLDUMPBIN $MYSQLCONFIG $DBOPTION $EXCLUDE_PARAMS $database
        } | gzip > "$TEMP_SQL_FILE"
    else
        # Dump non compresso
        {
            for table in "${EXCLUDE_TABLES[@]}"; do
                $MYSQLDUMPBIN $MYSQLCONFIG --no-data $database $table
            done
            $MYSQLDUMPBIN $MYSQLCONFIG $DBOPTION $EXCLUDE_PARAMS $database
        } > "$TEMP_SQL_FILE"
    fi

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

    VIEWS=$($MYSQLCOMMAND $TEST_DATABASE_NAME -e "SHOW FULL TABLES WHERE Table_type='VIEW'" -N | awk '{print $1}')
    for view in $VIEWS; do
        $MYSQLCOMMAND $TEST_DATABASE_NAME -e "DROP VIEW IF EXISTS \`$view\`"
    done

    TABLES=$($MYSQLCOMMAND $TEST_DATABASE_NAME -e "SHOW FULL TABLES WHERE Table_type='BASE TABLE'" -N | awk '{print $1}')
    for table in $TABLES; do
        $MYSQLCOMMAND $TEST_DATABASE_NAME -e "DROP TABLE IF EXISTS \`$table\`"
    done

    $MYSQLCOMMAND $TEST_DATABASE_NAME -e "SET FOREIGN_KEY_CHECKS=1"

    # Step 3: Import del dump nel database di test
    # Se il dump e' compresso, decomprime al volo con gunzip durante l'import
    echo "Importing dump into test database $TEST_DATABASE_NAME..."
    if [ "$TEMP_USE_GZIP" = true ]; then
        gunzip -c "$TEMP_SQL_FILE" | $MYSQLBIN $MYSQLCONFIG $TEST_DATABASE_NAME
    else
        $MYSQLBIN $MYSQLCONFIG $TEST_DATABASE_NAME < "$TEMP_SQL_FILE"
    fi

    # Step 4: Esecuzione degli script SQL di trasformazione (in ordine alfabetico/numerico)
    if [ -d "$SQL_SCRIPTS_DIR" ]; then
        find "$SQL_SCRIPTS_DIR" -maxdepth 1 -type f -name "*.sql" -print0 | sort -z | while IFS= read -r -d '' script; do
            echo "Executing SQL script: $script"
            $MYSQLBIN $MYSQLCONFIG $TEST_DATABASE_NAME < "$script"
        done
    fi

    # Step 5: Export finale del database di test (compresso con gzip)
    BACKUP_FILE_TEST="$DEFPATH/data/$database/${database}_test_db-$DATA-dump.sql.gz"
    echo "Exporting test database $TEST_DATABASE_NAME..."
    if ! command -v gzip > /dev/null 2>&1; then
        echo "Errore: gzip non installato. --create-database-test richiede gzip per l'export finale compresso."
        rm -f "$TEMP_SQL_FILE"
        exit 1
    fi
    $MYSQLDUMPBIN $MYSQLCONFIG $DBOPTION $TEST_DATABASE_NAME | gzip > "$BACKUP_FILE_TEST"

    if [ -s "$BACKUP_FILE_TEST" ]; then
        echo "Test database export completed: $BACKUP_FILE_TEST"
    else
        echo "Errore: export del database di test fallito o vuoto"
        rm -f "$BACKUP_FILE_TEST"
    fi

    # Step 6: Upload su Google Drive (se configurato)
    # Il file su Drive si chiama nomedbprod_YYYY-MM-DD.sql.gz
    if [ -n "$GDRIVE_REFRESH_TOKEN" ] && [ -n "$GDRIVE_FOLDER_ID" ]; then
        if [ -s "$BACKUP_FILE_TEST" ]; then
            GDRIVE_FILE_NAME="${database}_$(date +%Y-%m-%d).sql.gz"
            upload_to_gdrive "$BACKUP_FILE_TEST" "$GDRIVE_FILE_NAME"

            # Step 7: Pruning dei file vecchi su Drive (se configurato)
            # Mantiene solo gli ultimi N file per questo database, basandosi sul prefisso "nomedb_"
            if [ "$GDRIVE_KEEP_FILES" -gt 0 ] 2>/dev/null; then
                prune_gdrive_files "${database}_" "$GDRIVE_KEEP_FILES"
            fi
        fi
    fi

    # Cleanup: rimuove il file .sql temporaneo
    rm -f "$TEMP_SQL_FILE"

    echo "=== Create test database finish at $(date +%Y-%m-%d.%H.%M.%S) ==="
fi

_now=$(date +%Y-%m-%d.%H.%M.%S)
echo "Finish at $_now"
