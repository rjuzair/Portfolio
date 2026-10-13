"""Analytics read from the reporting views (flight_analyst role)."""

from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, Query

from .. import repository
from ..deps import Cursor, require_insights_key
from ..models import Funnel, InsightsSummary, MonthlyRevenue, RouteLoad, RoutePerformance

router = APIRouter(
    prefix="/api/insights", tags=["insights"], dependencies=[Depends(require_insights_key)]
)


@router.get("/summary", response_model=InsightsSummary)
def summary(cur: Cursor, days: Annotated[int, Query(ge=1, le=365)] = 30) -> InsightsSummary:
    net_revenue, passengers = repository.revenue_totals(cur)
    upcoming = repository.upcoming_load(cur, days)
    capacity = sum(r["capacity"] for r in upcoming)
    booked = sum(r["seats_booked"] for r in upcoming)
    return InsightsSummary(
        funnel=Funnel(**repository.funnel(cur)),
        net_revenue=net_revenue,
        passengers_booked=passengers,
        upcoming_days=days,
        upcoming_load_factor_pct=round(100 * booked / capacity, 1) if capacity else None,
    )


@router.get("/routes", response_model=list[RoutePerformance])
def routes(cur: Cursor, year: int | None = None) -> list[RoutePerformance]:
    rows = repository.route_performance(cur, year or date.today().year)
    return [RoutePerformance(**r) for r in rows]


@router.get("/monthly-revenue", response_model=list[MonthlyRevenue])
def monthly_revenue(cur: Cursor) -> list[MonthlyRevenue]:
    return [MonthlyRevenue(**r) for r in repository.monthly_revenue(cur)]


@router.get("/upcoming-load", response_model=list[RouteLoad])
def upcoming_load(cur: Cursor, days: Annotated[int, Query(ge=1, le=365)] = 30) -> list[RouteLoad]:
    return [RouteLoad(**r) for r in repository.upcoming_load(cur, days)]
