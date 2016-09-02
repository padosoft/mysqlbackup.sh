#!/bin/bash
##########################################################################
# Backup Database MySQL                                                  #
# versione 0.1                                                           #
# Copyright (c) 2008 Daniele Vona <danielev@seeweb.it>                   #
#                                                                        #
# This program is free software; you can redistribute it and/or modify   #
# it under the terms of the GNU General Public License as published by   #
# the Free Software Foundation; either version 2 of the License, or      #
# (at your option) any later version.                                    #
#                                                                        #
##########################################################################

DBUSER="admin"
DBPASS=`cat /etc/psa/.psa.shadow`
DBOPTION="-f"
DEFPATH="/home/backup/"
DATA=`/bin/date +"%a"`
MYSQLBIN="/usr/bin/mysql"
MYSQLDUMPBIN="/usr/bin/mysqldump"

###############################################################################
#
echo "Setting database list ..."
if [ -z $DBPASS ] && [ -z $DBUSER ]; then
        MYSQLCOMMAND="$MYSQLBIN";
elif [ -z $DBPASS ] && [ ! -z $DBUSER ]; then
        MYSQLCOMMAND="$MYSQLBIN -u$DBUSER";
else
        MYSQLCOMMAND="$MYSQLBIN -u$DBUSER -p$DBPASS";
fi
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
        $MYSQLDUMPCOMMAND $DBOPTION $database > $DEFPATH/data/$database/$database-$DATA-dump.sql
	/bin/gzip -f $DEFPATH/data/$database/$database-$DATA-dump.sql
done
