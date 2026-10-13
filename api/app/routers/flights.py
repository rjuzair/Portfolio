from datetime import date, timedelta
from typing import Annotated

from fastapi import APIRouter, Query

from .. import repository
from ..deps import Cursor
from ..errors import ApiError
from ..models import Airport, Flight, SeatMap

router = APIRouter(prefix="/api", tags=["flights"])

AirportCode = Annotated[str | None, Query(pattern=r"^[A-Za-z]{3}$", examples=["ARN"])]


@router.get("/airports", response_model=list[Airport])
def list_airports(cur: Cursor) -> list[Airport]:
    return repository.list_airports(cur)


@router.get("/flights", response_model=list[Flight], summary="Search bookable flights")
def search_flights(
    cur: Cursor,
    origin: AirportCode = None,
    destination: AirportCode = None,
    date_from: date | None = None,
    date_to: date | None = None,
    passengers: Annotated[int, Query(ge=1, le=9)] = 1,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
) -> list[Flight]:
    """Future flights with at least `passengers` free seats, earliest first.

    Defaults to the next 14 days. `total_price` is the current fare for the
    whole party.
    """
    start = date_from or date.today()
    end = date_to or start + timedelta(days=14)
    if end < start:
        raise ApiError(422, "VALIDATION_FAILED", "date_to must not be before date_from")
    if (end - start).days > 92:
        raise ApiError(422, "VALIDATION_FAILED", "Search at most 92 days at a time")
    return repository.search_flights(
        cur,
        origin=origin,
        destination=destination,
        date_from=start,
        date_to=end,
        passengers=passengers,
        limit=limit,
    )


@router.get("/flights/{flight_id}", response_model=Flight)
def get_flight(flight_id: int, cur: Cursor) -> Flight:
    return repository.get_flight(cur, flight_id)


@router.get("/flights/{flight_id}/seats", response_model=SeatMap, summary="Seat map")
def get_seat_map(flight_id: int, cur: Cursor) -> SeatMap:
    return repository.seat_map(cur, flight_id)
