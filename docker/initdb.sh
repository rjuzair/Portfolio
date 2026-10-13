#!/usr/bin/env bash
# Runs once, when the MySQL container initialises an empty data volume.
# The official image sources this file, so its docker_process_sql helper
# (root, connected to $MYSQL_DATABASE) is available here.

for module in /flight-sql/0[1-7]_*.sql; do
  echo "flight-reservations: loading ${module##*/}"
  docker_process_sql < "$module"
done

if [ "${SEED_DEMO_DATA:-true}" = "true" ]; then
  echo "flight-reservations: seeding demo data (about half a minute)"
  docker_process_sql < /flight-sql/seed_demo_data.sql
fi

# shellcheck source=../scripts/create-api-user.sh
. /flight-scripts/create-api-user.sh
create_api_user docker_process_sql
