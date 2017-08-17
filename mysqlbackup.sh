#!/bin/bash

_now=$(date +%Y-%m-%d.%H.%M.%S)
echo "starts at $_now"

DBUSER="admin"
DBPASS=`cat /etc/psa/.psa.shadow`
DBOPTION="-f"
DEFPATH="/home/backup/"
DATA=`/bin/date +"%a"`
MYSQLBIN="/usr/bin/mysql"
MYSQLDUMPBIN="/usr/bin/mysqldump"


#
# Load config file if exists
#
CONFIG_DIR=$( dirname "$(readlink -f "$0")" )
CONFIG_FILE="$CONFIG_DIR/mysqlbackup.config"

if [[ -f $CONFIG_FILE ]]; then
   echo "Loading settings from $CONFIG_FILE."
   source $CONFIG_FILE
else
   echo "Could not load settings from $CONFIG_FILE (file does not exist), kill process use default settings."
fi


if [ -z $DBPASS ] && [ -z $DBUSER ]; then
        MYSQLCOMMAND="$MYSQLBIN";
elif [ -z $DBPASS ] && [ ! -z $DBUSER ]; then
        MYSQLCOMMAND="$MYSQLBIN -u$DBUSER";
else
        MYSQLCOMMAND="$MYSQLBIN -u$DBUSER -p$DBPASS";
fi

echo "retrive databases..."
DBNAMES=`echo "show databases" |$MYSQLCOMMAND | egrep -v "Database|information_schema"`

for database in $DBNAMES; do
        if [ ! -d $DEFPATH/data/$database ]; then
                echo "Making directory structure ..."
                mkdir -p $DEFPATH/data/$database;
        fi
        
		echo "Dumping structure and data of $database ..."
        if [ -z $DBPASS ] && [ -z $DBUSER ]; then
                MYSQLDUMPCOMMAND="$MYSQLDUMPBIN";
        elif [ -z $DBPASS ] && [ ! -z $DBUSER ]; then
                MYSQLDUMPCOMMAND="$MYSQLDUMPBIN -u$DBUSER";
        else
                MYSQLDUMPCOMMAND="$MYSQLDUMPBIN -u$DBUSER -p$DBPASS";
        fi

		
		_now=$(date +%Y-%m-%d.%H.%M.%S)
		echo "Backup db name $database starts at $_now"
        $MYSQLDUMPCOMMAND $DBOPTION $database > $DEFPATH/data/$database/$database-$DATA-dump.sql
		
		echo "Checking sql file..."
		if [ -s $DEFPATH/data/$database/$database-$DATA-dump.sql ] ; then

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
