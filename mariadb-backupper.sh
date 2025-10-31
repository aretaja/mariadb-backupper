#!/bin/bash
set -euo pipefail
#
# mariadb-backupper.sh
# Copyright 2025 by Marko Punnar <marko[AT]aretaja.org>
# Version: 1.0.1
#
# Script to make MariaDB backups of your data to remote target.
# Must be executed as root.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>
#
# Changelog:
# 1.0.0 Initial release
# 1.0.1 Fix error if target dir exists

# show help if requested
if [[ "$1" = '-h' ]] || [[ "$1" = '--help' ]]
then
    echo "Make daily, weekly, monthly MariaDB backups."
    echo "Creates local or remeote backup:"
    echo "  monthly on every 1 day of month in'mariadb_monthly' directory,"
    echo "  weekly on every 1 day of week in 'mariadb_weekly' directory,"
    echo "  every other day in 'mariadb_daily' directory."
    echo "Only latest backup will preserved in every directory."
    echo "Requires config file. Default: /usr/local/etc/mariadb-backupper.conf"
    echo "Script must be executed by root."
    echo ""
    echo "Usage:"
    echo "       mariadb-backupper.sh mariadb-backupper.conf"
    exit 1
fi

### Functions ###############################################################
# Cleanup lockfile
cleanup()
{
    # shellcheck disable=SC2317
    rm -f "$lock_f"
}

# Output formater. Takes severity (ERROR, WARNING, INEO) as first
# and output message as second arg.
write_log()
{
    tstamp=$(date -Is)
    if [[ "$1" = 'INFO'  ]]
    then
        echo "$tstamp [$1] $2"
    else
       echo "$tstamp [$1] $2" 1>&2
    fi
}
#############################################################################

write_log INFO "mariadb backup start"

# Make sure we are root
if [[ "$EUID" -ne 0 ]]
then
   write_log ERROR "$0 must be executed as root - interrupting"
   exit 1
fi

# Define default values
cfile="$1" || "/usr/local/etc/mariadb-backupper.conf"
lock_f="/var/run/mariadb-backupper.lock"

# Check for running backup (lockfile)
# Open a file descriptor and try to lock it
exec 9>"$lock_f"
if ! flock -n 9
then
    write_log ERROR "previous backup is running (lockfile set) - interrupting"
    exit 1
fi

# Ensure lockfile is removed at exit (unlocking happens automatically when FD 9 closes)
trap cleanup EXIT INT TERM HUP

# Load config
if [[ -r "$cfile" ]]
then
    # shellcheck source=./mariadb-backupper.conf_example
    . "$cfile"
else
     write_log ERROR "config file missing - interrupting"
     exit 1
fi

# Check config
if [[ ! "$m_ignore_db" =~ ^[[:alnum:]_\ |]+$ ]]
then
    write_log ERROR "only alnum, _ and space characters allowed in db exclude list - interrupting"
    exit 1
fi

if [[ -z "${bdir-}" ]] || [[ ! "$bdir" =~ ^[[:alnum:]_\ \.\/-]+$ ]]
then
    write_log ERROR "destination basedir for backups missing or incorrect - interrupting"
    exit 1
else
    # Change working dir
    cd "$bdir"
    if [ "$PWD" != "$bdir" ]
    then
        write_log ERROR "wrong working dir: ${PWD}, expected ${bdir} - interrupting"
        exit 1
    fi
fi

# Set remote directory name
target="daily"
day_of_month=$(date +%-d)
day_of_week=$(date +%u)

if [[ "$day_of_month" -eq 1 ]]
then
    target="monthly"
elif [[ "$day_of_week" -eq 1 ]]
then
    target="weekly"
fi

mkdir -p "$target"

# Make backup
if result=$(mariadb -N -B -e 'SHOW DATABASES;' |grep -Pv "^(information_schema|performance_schema|sys|${m_ignore_db})$")
then
    while IFS= read -r d
    do
        write_log INFO "making compressed $d backup"
        # shellcheck disable=SC2029
        if mysqldump --single-transaction --events --triggers --add-drop-database --flush-logs "$d" | gzip > "./${target}/${d}.sql.gz"
        then
            write_log INFO "$d backup done"
        else
            write_log ERROR "something went wrong with $d backup"
        fi
    done <<< "$result"
else
    write_log ERROR "mariadb backup error - db connection failed"
fi

write_log INFO "all backups done"
exit 0
