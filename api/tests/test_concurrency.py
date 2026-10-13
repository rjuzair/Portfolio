"""Races that the database must win, run through the API's own pool and account."""

import threading

import pymysql
import pytest

from app import repository
from app.db import errno_of

from .conftest import book


def _race(api_db, jobs) -> list[int | None]:
    """Runs every job at the same instant; returns None or the error number per job."""
    barrier = threading.Barrier(len(jobs))
    outcomes: list[int | None] = [None] * len(jobs)

    def run(i, job):
        with api_db.cursor() as cur:
            barrier.wait()
            try:
                job(cur)
            except pymysql.MySQLError as exc:
                outcomes[i] = errno_of(exc)

    threads = [threading.Thread(target=run, args=(i, job)) for i, job in enumerate(jobs)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return outcomes


@pytest.mark.parametrize("round_", range(3))
def test_concurrent_payments_never_oversell(client, api_db, flights, admin, round_):
    """Eight single-seat bookings race to pay for a four-seat aircraft.

    v1 of the schema sold every one of them; now exactly four succeed and
    the rest are declined with 7101 (INSUFFICIENT_SEATS).
    """
    flight_id = flights.fresh("MINI4")
    refs = [book(client, flight_id, [f"Racer {i}"], pay=False)["booking_ref"] for i in range(8)]

    outcomes = _race(
        api_db,
        [
            (lambda cur, ref=ref: repository.pay(cur, ref, "Racer", "4111111111111111"))
            for ref in refs
        ],
    )

    assert outcomes.count(None) == 4, outcomes
    assert outcomes.count(7101) == 4, outcomes
    admin.execute(
        "SELECT capacity, seats_booked FROM flights_info WHERE flight_id = %s", (flight_id,)
    )
    assert admin.fetchone() == {"capacity": 4, "seats_booked": 4}
    admin.execute("SELECT COUNT(*) AS n FROM v_inventory_drift")
    assert admin.fetchone()["n"] == 0


def test_concurrent_requests_for_the_same_seat(client, api_db, flights):
    booking = book(client, flights.fresh(), [f"Passenger {i}" for i in range(6)])
    ref = booking["booking_ref"]
    passports = [p["passport"] for p in booking["passengers"]]

    outcomes = _race(
        api_db,
        [
            (lambda cur, passport=passport: repository.assign_seat(cur, ref, passport, "7C"))
            for passport in passports
        ],
    )

    assert outcomes.count(None) == 1
    assert outcomes.count(7104) == 5, "everyone else is told the seat is taken"
    seats = [p["seat"] for p in client.get(f"/api/bookings/{ref}").json()["passengers"]]
    assert seats.count("7C") == 1
