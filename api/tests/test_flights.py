from datetime import date


def test_health_reports_the_database_version(client):
    response = client.get("/api/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    assert response.json()["database"]


def test_airports(client):
    codes = {a["code"] for a in client.get("/api/airports").json()}
    assert codes == {"ARN", "LHR"}


def test_search_returns_future_flights_in_departure_order(client, reference):
    response = client.get(
        "/api/flights",
        params={
            "origin": "arn",
            "destination": "LHR",
            "passengers": 2,
            "date_from": f"{reference.year}-03-01",
            "date_to": f"{reference.year}-03-31",
        },
    )
    assert response.status_code == 200
    flights = response.json()
    assert flights, "expected flights in March"
    assert [f["departs_at"] for f in flights] == sorted(f["departs_at"] for f in flights)
    for flight in flights:
        assert flight["origin"]["code"] == "ARN" and flight["destination"]["code"] == "LHR"
        assert f"{reference.year}-03-01" <= flight["departure_date"] <= f"{reference.year}-03-31"
        assert float(flight["total_price"]) == float(flight["price_per_seat"]) * 2


def test_search_hides_flights_without_enough_seats(client, reference):
    params = {
        "origin": "ARN",
        "date_from": f"{reference.year}-06-01",
        "date_to": f"{reference.year}-06-30",
    }
    aircraft = {f["aircraft_code"] for f in client.get("/api/flights", params=params).json()}
    assert aircraft == {"STD40", "MINI4"}
    params["passengers"] = 5
    aircraft = {f["aircraft_code"] for f in client.get("/api/flights", params=params).json()}
    assert aircraft == {"STD40"}, "a 4-seat aircraft cannot take 5 passengers"


def test_search_validates_its_input(client):
    response = client.get("/api/flights", params={"origin": "ARLANDA"})
    assert response.status_code == 422
    assert response.headers["content-type"].startswith("application/problem+json")
    assert response.json()["error"] == "VALIDATION_FAILED"

    response = client.get(
        "/api/flights", params={"date_from": "2030-02-01", "date_to": "2030-01-01"}
    )
    assert response.status_code == 422


def test_search_defaults_to_the_next_two_weeks(client):
    for flight in client.get("/api/flights").json():
        assert (date.fromisoformat(flight["departure_date"]) - date.today()).days <= 14


def test_flight_details_and_problem_for_unknown_flight(client, reference):
    flight = client.get(f"/api/flights/{reference.first_flight}").json()
    assert flight["capacity"] == 40 and flight["free_seats"] <= 40

    response = client.get("/api/flights/999999")
    assert response.status_code == 404
    assert response.json() == {
        "type": "about:blank",
        "title": "Not Found",
        "status": 404,
        "error": "FLIGHT_NOT_FOUND",
        "detail": "The flight does not exist",
    }


def test_seat_map_covers_the_whole_cabin(client, flights):
    seat_map = client.get(f"/api/flights/{flights.fresh('MINI4')}/seats").json()
    assert (seat_map["rows"], seat_map["seats_per_row"]) == (2, 2)
    assert [s["seat_no"] for s in seat_map["seats"]] == ["1A", "1B", "2A", "2B"]
    assert not any(s["taken"] for s in seat_map["seats"])


def test_openapi_document_is_served(client):
    spec = client.get("/openapi.json").json()
    assert "/api/bookings/{booking_ref}/payment" in spec["paths"]
