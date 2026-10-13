-- =============================================================================
-- 07_security.sql — roles for least-privilege access
--
--   flight_app      booking workflow: EXECUTE on the booking procedures and
--                   SELECT on the operational views. No base-table access.
--   flight_analyst  SELECT on the analytics views only.
--   flight_ops      maintains reference data and reads the audit log.
--   flight_api      what the API's account gets: flight_app + flight_analyst.
--
-- Procedures and views run with their definer's rights (SQL SECURITY
-- DEFINER), so a role can use them without seeing the tables underneath.
-- Accounts are created outside this file (scripts/create-api-user.sh), so no
-- password is ever committed.
-- =============================================================================

CREATE ROLE IF NOT EXISTS flight_app, flight_analyst, flight_ops, flight_api;

GRANT EXECUTE ON PROCEDURE createReservation TO flight_app;
GRANT EXECUTE ON PROCEDURE addReservation    TO flight_app;
GRANT EXECUTE ON PROCEDURE addPassenger      TO flight_app;
GRANT EXECUTE ON PROCEDURE addContact        TO flight_app;
GRANT EXECUTE ON PROCEDURE addPayment        TO flight_app;
GRANT EXECUTE ON PROCEDURE cancelReservation TO flight_app;
GRANT EXECUTE ON PROCEDURE assignSeat        TO flight_app;
GRANT EXECUTE ON PROCEDURE getSeatMap        TO flight_app;
GRANT EXECUTE ON FUNCTION  calculateRefund   TO flight_app;
GRANT SELECT ON airport               TO flight_app;
GRANT SELECT ON v_flight_availability TO flight_app;
GRANT SELECT ON allFlights            TO flight_app;
GRANT SELECT ON v_booking             TO flight_app;
GRANT SELECT ON v_booking_passengers  TO flight_app;

GRANT SELECT ON v_flight_load       TO flight_analyst;
GRANT SELECT ON v_route_performance TO flight_analyst;
GRANT SELECT ON v_monthly_revenue   TO flight_analyst;
GRANT SELECT ON v_booking_funnel    TO flight_analyst;

GRANT EXECUTE ON PROCEDURE addYear                   TO flight_ops;
GRANT EXECUTE ON PROCEDURE addDay                    TO flight_ops;
GRANT EXECUTE ON PROCEDURE addDestination            TO flight_ops;
GRANT EXECUTE ON PROCEDURE addAircraft               TO flight_ops;
GRANT EXECUTE ON PROCEDURE addRoute                  TO flight_ops;
GRANT EXECUTE ON PROCEDURE addFlight                 TO flight_ops;
GRANT EXECUTE ON PROCEDURE addFlightWithAircraft     TO flight_ops;
GRANT EXECUTE ON PROCEDURE expirePendingReservations TO flight_ops;
GRANT SELECT ON audit_log         TO flight_ops;
GRANT SELECT ON v_inventory_drift TO flight_ops;

-- one role per statement: MariaDB does not accept a list here
GRANT flight_app     TO flight_api;
GRANT flight_analyst TO flight_api;
