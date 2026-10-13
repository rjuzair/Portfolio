# Common workflows. `make` lists them.
COMPOSE    ?= docker compose
DB_EXEC     = $(COMPOSE) exec -T db sh -c 'mysql -uroot -p"$$MYSQL_ROOT_PASSWORD" $(1)'
SQL_MODULES = $(sort $(wildcard sql/0[1-7]_*.sql))

.DEFAULT_GOAL := help
.PHONY: help up down reset logs db-shell test test-sql test-api lint format

help:  ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

up:  ## Build and start MySQL + API; the web UI is on http://localhost:8000
	$(COMPOSE) up --build --detach --wait

down:  ## Stop the stack (keeps the database volume)
	$(COMPOSE) down

reset:  ## Stop the stack and delete the database volume
	$(COMPOSE) down --volumes

logs:  ## Follow the logs
	$(COMPOSE) logs --follow

db-shell:  ## Open a MySQL shell on the database
	$(COMPOSE) exec db sh -c 'mysql -uroot -p"$$MYSQL_ROOT_PASSWORD" flight_reservations'

test: test-sql test-api  ## Run every test suite against the running stack

test-sql:  ## SQL assertions in a scratch database inside the db container
	$(call DB_EXEC,-e "DROP DATABASE IF EXISTS flight_tests; CREATE DATABASE flight_tests")
	@for module in $(SQL_MODULES) sql/tests.sql; do \
	  echo "→ $$module"; $(call DB_EXEC,flight_tests) < $$module || exit 1; done

test-api:  ## API integration tests (needs `pip install -r api/requirements-dev.txt`)
	cd api && TEST_DB_PORT=$${DB_PORT:-3306} TEST_DB_ADMIN_PASSWORD=$${MYSQL_ROOT_PASSWORD:-root} python -m pytest

lint:  ## Lint and format-check the API
	cd api && ruff check . && ruff format --check .

format:  ## Format the API code
	cd api && ruff check --fix . && ruff format .
