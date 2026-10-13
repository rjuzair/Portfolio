-- =============================================================================
-- 05_views.sql — read models
--
-- Applications read through views and write through procedures; the API's
-- database account has no privileges on the base tables (07_security.sql).
-- =============================================================================

SET NAMES utf8mb4;

DROP VIEW IF EXISTS allFlights;
DROP VIEW IF EXISTS v_flight_availability;
DROP VIEW IF EXISTS v_booking;
DROP VIEW IF EXISTS v_booking_passengers;
DROP VIEW IF EXISTS v_flight_load;
DROP VIEW IF EXISTS v_route_performance;
DROP VIEW IF EXISTS v_monthly_revenue;
DROP VIEW IF EXISTS v_booking_funnel;
DROP VIEW IF EXISTS v_inventory_drift;

-- ---------------------------------------------------------------------------
-- Operational read models
-- ---------------------------------------------------------------------------

-- Every flight with its route, schedule, free seats and current fare.
-- Joins only (no aggregation), so the optimizer merges it into the caller's
-- query and filters such as departure_date use their indexes.
CREATE VIEW v_flight_availability AS
SELECT fi.flight_id,
       r.departure_ap                                   AS departure_airport,
       dep.airport_name                                 AS departure_airport_name,
       dep.country                                      AS departure_country,
       r.arrival_ap                                     AS arrival_airport,
       arr.airport_name                                 AS arrival_airport_name,
       arr.country                                      AS arrival_country,
       fi.departure_date,
       ws.dept                                          AS departure_time,
       TIMESTAMP(fi.departure_date, ws.dept)            AS departs_at,
       ws.weekday,
       fi.week,
       ws.w_year                                        AS year,
       ws.aircraft_code,
       a.model                                          AS aircraft_model,
       fi.capacity,
       fi.seats_booked,
       fi.capacity - fi.seats_booked                    AS free_seats,
       ROUND(r.price * wd.price_factor * y.profitfactor
             * (fi.capacity + fi.seats_booked) / fi.capacity, 2) AS price_per_seat
FROM flights_info fi
JOIN weekly_schedule ws ON ws.w_id = fi.flight_ws_id
JOIN route r            ON r.route_id = ws.w_route_id
JOIN airport dep        ON dep.airport_id = r.departure_ap
JOIN airport arr        ON arr.airport_id = r.arrival_ap
JOIN week_day wd        ON wd.weekday = ws.weekday AND wd.year = ws.w_year
JOIN year y             ON y.year = ws.w_year
JOIN aircraft a         ON a.aircraft_code = ws.aircraft_code;

-- The original v1 view, kept with its column names for compatibility
CREATE VIEW allFlights AS
SELECT departure_airport_name AS departure_city_name,
       arrival_airport_name   AS destination_city_name,
       departure_time,
       weekday                AS departure_day,
       week                   AS departure_week,
       year                   AS departure_year,
       free_seats             AS nr_of_free_seats,
       price_per_seat         AS current_price_per_seat,
       flight_id,
       departure_date
FROM v_flight_availability;

-- One row per reservation, looked up by its public booking reference
CREATE VIEW v_booking AS
SELECT r.res_no,
       r.booking_ref,
       r.status,
       r.no_passengers,
       r.flight_id,
       rt.departure_ap                       AS departure_airport,
       dep.airport_name                      AS departure_airport_name,
       rt.arrival_ap                         AS arrival_airport,
       arr.airport_name                      AS arrival_airport_name,
       fi.departure_date,
       ws.dept                               AS departure_time,
       TIMESTAMP(fi.departure_date, ws.dept) AS departs_at,
       ws.aircraft_code,
       c.passp_no                            AS contact_passport,
       c.email                               AS contact_email,
       c.phone                               AS contact_phone,
       pay.amount                            AS amount_paid,
       pay.refunded_amount,
       pay.card_brand,
       pay.card_last4,
       pay.paid_at,
       pay.refunded_at,
       r.created_at,
       r.updated_at
FROM reservation r
JOIN flights_info fi    ON fi.flight_id = r.flight_id
JOIN weekly_schedule ws ON ws.w_id = fi.flight_ws_id
JOIN route rt           ON rt.route_id = ws.w_route_id
JOIN airport dep        ON dep.airport_id = rt.departure_ap
JOIN airport arr        ON arr.airport_id = rt.arrival_ap
LEFT JOIN contact_info c ON c.res_no = r.res_no
LEFT JOIN payment pay    ON pay.res_no = r.res_no;

CREATE VIEW v_booking_passengers AS
SELECT r.booking_ref,
       p.res_no,
       p.passp_no,
       p.name,
       p.ticket,
       sa.seat_no,
       c.passp_no IS NOT NULL AS is_contact
FROM passenger p
JOIN reservation r            ON r.res_no = p.res_no
LEFT JOIN seat_assignment sa  ON sa.res_no = p.res_no AND sa.passp_no = p.passp_no
LEFT JOIN contact_info c      ON c.res_no = p.res_no AND c.passp_no = p.passp_no;

-- ---------------------------------------------------------------------------
-- Analytics
-- ---------------------------------------------------------------------------

-- Load factor and revenue per flight
CREATE VIEW v_flight_load AS
WITH flight_revenue AS (
    SELECT res.flight_id,
           SUM(p.amount)          AS gross_revenue,
           SUM(p.refunded_amount) AS refunds
    FROM payment p
    JOIN reservation res ON res.res_no = p.res_no
    GROUP BY res.flight_id
)
SELECT fi.flight_id,
       r.departure_ap                                        AS departure_airport,
       r.arrival_ap                                          AS arrival_airport,
       fi.departure_date,
       fi.capacity,
       fi.seats_booked,
       ROUND(100 * fi.seats_booked / fi.capacity, 1)         AS load_factor_pct,
       COALESCE(fr.gross_revenue, 0) - COALESCE(fr.refunds, 0) AS net_revenue
FROM flights_info fi
JOIN weekly_schedule ws ON ws.w_id = fi.flight_ws_id
JOIN route r            ON r.route_id = ws.w_route_id
LEFT JOIN flight_revenue fr ON fr.flight_id = fi.flight_id;

-- Route league table per year: capacity, sales, load factor, revenue and rank
CREATE VIEW v_route_performance AS
WITH flight_revenue AS (
    SELECT res.flight_id,
           SUM(p.amount)          AS gross_revenue,
           SUM(p.refunded_amount) AS refunds
    FROM payment p
    JOIN reservation res ON res.res_no = p.res_no
    GROUP BY res.flight_id
),
route_totals AS (
    SELECT rt.route_id,
           rt.departure_ap,
           rt.arrival_ap,
           rt.year,
           COUNT(*)                            AS flights,
           SUM(fi.capacity)                    AS seats_offered,
           SUM(fi.seats_booked)                AS seats_sold,
           COALESCE(SUM(fr.gross_revenue), 0)  AS gross_revenue,
           COALESCE(SUM(fr.refunds), 0)        AS refunds
    FROM route rt
    JOIN weekly_schedule ws ON ws.w_route_id = rt.route_id
    JOIN flights_info fi    ON fi.flight_ws_id = ws.w_id
    LEFT JOIN flight_revenue fr ON fr.flight_id = fi.flight_id
    GROUP BY rt.route_id, rt.departure_ap, rt.arrival_ap, rt.year
)
SELECT route_id,
       departure_ap                                           AS departure_airport,
       arrival_ap                                             AS arrival_airport,
       year,
       flights,
       seats_offered,
       seats_sold,
       ROUND(100 * seats_sold / seats_offered, 1)             AS load_factor_pct,
       gross_revenue,
       refunds,
       gross_revenue - refunds                                AS net_revenue,
       ROUND((gross_revenue - refunds) / NULLIF(seats_sold, 0), 2) AS revenue_per_seat,
       RANK() OVER (PARTITION BY year ORDER BY gross_revenue - refunds DESC) AS revenue_rank
FROM route_totals;

-- Net revenue by month of travel, with running total and month-on-month change
CREATE VIEW v_monthly_revenue AS
WITH monthly AS (
    SELECT DATE_FORMAT(fi.departure_date, '%Y-%m')                 AS travel_month,
           COUNT(*)                                                AS paid_bookings,
           SUM(res.status = 'CANCELLED')                           AS cancelled_bookings,
           SUM(CASE WHEN res.status = 'CONFIRMED' THEN res.no_passengers ELSE 0 END) AS passengers,
           SUM(p.amount - p.refunded_amount)                       AS net_revenue
    FROM payment p
    JOIN reservation res ON res.res_no = p.res_no
    JOIN flights_info fi ON fi.flight_id = res.flight_id
    GROUP BY DATE_FORMAT(fi.departure_date, '%Y-%m')
)
SELECT travel_month,
       paid_bookings,
       cancelled_bookings,
       passengers,
       net_revenue,
       SUM(net_revenue) OVER (ORDER BY travel_month)          AS cumulative_revenue,
       net_revenue - LAG(net_revenue) OVER (ORDER BY travel_month) AS change_vs_previous_month
FROM monthly;

-- Checkout funnel: how many reservations reach payment
CREATE VIEW v_booking_funnel AS
SELECT COUNT(*)                                            AS reservations,
       SUM(r.status = 'PENDING')                           AS pending,
       SUM(r.status = 'CONFIRMED')                         AS confirmed,
       SUM(r.status = 'CANCELLED')                         AS cancelled,
       SUM(r.status = 'EXPIRED')                           AS expired,
       COUNT(p.res_no)                                     AS paid,
       ROUND(100 * COUNT(p.res_no) / NULLIF(COUNT(*), 0), 1) AS conversion_pct
FROM reservation r
LEFT JOIN payment p ON p.res_no = r.res_no;

-- Operations check: flights whose inventory counter disagrees with the
-- reservations it summarises. Expected to be empty.
CREATE VIEW v_inventory_drift AS
SELECT fi.flight_id,
       fi.seats_booked,
       COALESCE(SUM(CASE WHEN r.status = 'CONFIRMED' THEN r.no_passengers END), 0) AS confirmed_passengers
FROM flights_info fi
LEFT JOIN reservation r ON r.flight_id = fi.flight_id
GROUP BY fi.flight_id, fi.seats_booked
HAVING fi.seats_booked <> COALESCE(SUM(CASE WHEN r.status = 'CONFIRMED' THEN r.no_passengers END), 0);
