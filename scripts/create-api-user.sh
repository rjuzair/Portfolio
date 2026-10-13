#!/usr/bin/env bash
# Creates (or updates) the API's database account. It gets the flight_api
# role and nothing else: no access to the base tables at all.
#
#   API_DB_PASSWORD=secret scripts/create-api-user.sh mysql -h127.0.0.1 -uroot -proot flight_reservations
#
# Everything after the script name is the client command to pipe SQL into.
# docker/initdb.sh sources this file and calls create_api_user itself.

create_api_user() {
  local user="${API_DB_USER:-booking_api}"
  local password="${API_DB_PASSWORD:?API_DB_PASSWORD must be set}"
  password="${password//\'/\'\'}"
  # MySQL: SET DEFAULT ROLE r TO u    MariaDB: SET DEFAULT ROLE r FOR u
  local default_role="SET DEFAULT ROLE flight_api TO '${user}'@'%'"
  if "$@" -N -e "SELECT VERSION()" | grep -qi mariadb; then
    default_role="SET DEFAULT ROLE flight_api FOR '${user}'@'%'"
  fi
  "$@" <<SQL
CREATE USER IF NOT EXISTS '${user}'@'%' IDENTIFIED BY '${password}';
ALTER USER '${user}'@'%' IDENTIFIED BY '${password}';
GRANT flight_api TO '${user}'@'%';
${default_role};
SQL
  echo "API account '${user}' has the flight_api role"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  [ "$#" -gt 0 ] || { echo "usage: API_DB_PASSWORD=... $0 <mysql client command...>" >&2; exit 2; }
  create_api_user "$@"
fi
