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
EXCLUDE_TABLES_CUSTOM=()
EXCLUDE_TABLES=()

# Verifico le opzioni inserite da linea di comando
while [[ $# -gt 0 ]]; do
    case "$1" in
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

# Esporta solo le schema delle tabelle per le quali ho escluso i dati da linea di comando
create_empty_schema() {
    local database=$1
    local table=$2
    table_exists=$(echo "SHOW TABLES LIKE '$table'" | $MYSQLCOMMAND $database | grep -w "$table")

    if [ -n "$table_exists" ]; then
        echo "Dumping empty schema for table $table in database $database ..."
        $MYSQLDUMPCOMMAND --no-data $database $table >> "$DEFPATH/data/$database/$database-schema-$DATA.sql"
    else
        echo "Skipping table $table in database $database because it does not exist."
    fi
}

for database in $DBNAMES; do
    if [ ! -d $DEFPATH/data/$database ]; then
            echo "Making directory structure ..."
            mkdir -p $DEFPATH/data/$database;
    fi

    echo "Removing old empty schema files for the same backup.."
    #Dal momento che scrivo in append gli schemi delle tabelle rimuovo il file prima di scrivere
    rm -f "$DEFPATH/data/$database/$database-schema-$DATA.sql"
    echo "Dumping structure and data of $database ..."
    MYSQLDUMPCOMMAND="$MYSQLDUMPBIN $MYSQLCONFIG"
    echo "Configurazione DB per export: $MYSQLDUMPCOMMAND"

    for table in "${EXCLUDE_TABLES[@]}"; do
        create_empty_schema "$database" "$table"
    done

    EXCLUDE_PARAMS=""
    for table in "${EXCLUDE_TABLES[@]}"; do
        EXCLUDE_PARAMS+=" --ignore-table=$database.$table"
    done

		
		_now=$(date +%Y-%m-%d.%H.%M.%S)
		echo "Backup db name $database starts at $_now"
		echo "Executing: $MYSQLDUMPCOMMAND $DBOPTION $database > $DEFPATH/data/$database/$database-$DATA-dump.sql"
    $MYSQLDUMPCOMMAND $DBOPTION $EXCLUDE_PARAMS $database >  $DEFPATH/data/$database/$database-$DATA-dump.sql
		
		echo "Checking sql file..."
		if [ -s $DEFPATH/data/$database/$database-$DATA-dump.sql ] ; then

  	  #Se esiste il file schema lo aggiungo al dump e lo elimino
		  if [[ -f $DEFPATH/data/$database/$database-schema-$DATA.sql ]]; then
		      echo "Adding tables with only schema to dump file"
          cat "$DEFPATH/data/$database/$database-schema-$DATA.sql" >> "$DEFPATH/data/$database/$database-$DATA-dump.sql"
          rm "$DEFPATH/data/$database/$database-schema-$DATA.sql"
      else
        echo "File non trovato $DEFPATH/data/$database/$database-schema-$DATA.sql"
      fi


			echo "sql file is ok, exec gzip.."
			/bin/gzip -f $DEFPATH/data/$database/$database-$DATA-dump.sql
			
			echo "Checking gz file..."
			if [ -s $DEFPATH/data/$database/$database-$DATA-dump.sql.gz ] ; then
				echo ".gz file is ok"
			else
				echo ".gz file doesn't exists or has zero bytes, remove it"
				rm -f $DEFPATH/data/$database/$database-$DATA-dump.sql.gz
			fi	
		else
			echo "sql file doesn't exists or has zero bytes, remove it"
			rm -f $DEFPATH/data/$database/$database-$DATA-dump.sql
		fi	
		
		_now=$(date +%Y-%m-%d.%H.%M.%S)
		echo "Backup db name $database finish at $_now"
done

_now=$(date +%Y-%m-%d.%H.%M.%S)
echo "Finish at $_now"
