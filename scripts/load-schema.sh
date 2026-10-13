#!/usr/bin/env bash
# Load (or rebuild) the database from the numbered SQL modules.
#
#   scripts/load-schema.sh mysql -h127.0.0.1 -uroot flight_reservations
#
# Everything after the script name is the client command to pipe SQL into.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$#" -gt 0 ] || { echo "usage: $0 <mysql client command...>" >&2; exit 2; }
for module in sql/0[1-7]_*.sql; do
  echo "→ ${module}"
  "$@" < "$module"
done
