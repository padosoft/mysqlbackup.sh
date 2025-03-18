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

_now=$(date +%Y-%m-%d.%H.%M.%S)
echo "Finish at $_now"
