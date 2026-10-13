from decimal import Decimal

from fastapi.testclient import TestClient

from app.main import create_app

from .conftest import book


def test_insights_reflect_bookings(client, flights, reference):
    book(client, flights.fresh(origin="LHR"), ["Alan Turing", "Joan Clarke"])

    summary = client.get("/api/insights/summary").json()
    assert summary["funnel"]["paid"] >= 1
    assert summary["funnel"]["reservations"] >= summary["funnel"]["paid"]
    assert Decimal(summary["net_revenue"]) > 0

    routes = client.get("/api/insights/routes", params={"year": reference.year}).json()
    assert {(r["departure_airport"], r["arrival_airport"]) for r in routes} == {
        ("ARN", "LHR"),
        ("LHR", "ARN"),
    }
    assert sorted(r["revenue_rank"] for r in routes) == [1, 2]

    months = client.get("/api/insights/monthly-revenue").json()
    assert Decimal(months[-1]["cumulative_revenue"]) == Decimal(summary["net_revenue"])


def test_insights_can_require_an_api_key(settings):
    secured = settings.model_copy(update={"insights_api_key": "s3cret"})
    with TestClient(create_app(secured)) as client:
        assert client.get("/api/insights/summary").status_code == 401
        assert (
            client.get("/api/insights/summary", headers={"X-API-Key": "wrong"}).status_code == 401
        )
        assert (
            client.get("/api/insights/summary", headers={"X-API-Key": "s3cret"}).status_code == 200
        )
        assert client.get("/api/flights").status_code == 200, "only insights are protected"
