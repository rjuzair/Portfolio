"""The API's account can use the views and procedures, and nothing else."""

import pymysql
import pytest

from app.db import errno_of

TABLE_ACCESS_DENIED = 1142
ROUTINE_ACCESS_DENIED = 1370


@pytest.mark.parametrize(
    "sql",
    [
        "SELECT * FROM payment",
        "SELECT * FROM passenger",
        "SELECT * FROM reservation",
        "SELECT * FROM audit_log",
        "UPDATE flights_info SET seats_booked = 0",
        "DELETE FROM reservation",
        "INSERT INTO airport VALUES ('XXX', 'Nowhere', 'Nowhere')",
    ],
)
def test_base_tables_are_off_limits(api_db, sql):
    with pytest.raises(pymysql.MySQLError) as failure, api_db.cursor() as cur:
        cur.execute(sql)
    assert errno_of(failure.value) == TABLE_ACCESS_DENIED


@pytest.mark.parametrize(
    "sql",
    [
        "CALL addYear(2099, 1)",
        "CALL addFlight('ARN', 'LHR', 2099, 'Monday', '09:00:00')",
        "CALL expirePendingReservations(0, @n)",
    ],
)
def test_admin_procedures_are_off_limits(api_db, sql):
    with pytest.raises(pymysql.MySQLError) as failure, api_db.cursor() as cur:
        cur.execute(sql)
    assert errno_of(failure.value) == ROUTINE_ACCESS_DENIED


def test_the_audit_log_names_the_api_account(client, flights, admin):
    ref = client.post("/api/bookings", json={"flight_id": flights.fresh(), "passengers": 1}).json()[
        "booking_ref"
    ]
    admin.execute(
        "SELECT a.changed_by FROM audit_log a JOIN reservation r "
        "ON a.table_name = 'reservation' AND a.record_id = r.res_no "
        "WHERE r.booking_ref = %s",
        (ref,),
    )
    assert admin.fetchone()["changed_by"].startswith("booking_api_test@")


def test_responses_carry_a_request_id(client):
    response = client.get("/api/health", headers={"X-Request-ID": "trace-123"})
    assert response.headers["X-Request-ID"] == "trace-123"
    assert client.get("/api/health").headers["X-Request-ID"]
