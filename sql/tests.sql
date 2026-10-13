-- =============================================================================
-- tests.sql — assertions for the whole database. Run on a freshly loaded schema:
--
--   scripts/load-schema.sh mysql flight_reservations_test
--   mysql flight_reservations_test < sql/tests.sql
--
-- The script builds its own fixtures, dated relative to today so it never goes
-- stale. A failed assertion raises SQLSTATE 45000 and stops the script.
-- =============================================================================

SET NAMES utf8mb4;

DROP PROCEDURE IF EXISTS assert_true;
DROP PROCEDURE IF EXISTS assert_error;

DELIMITER //

CREATE PROCEDURE assert_true(IN passed BOOLEAN, IN description VARCHAR(255))
BEGIN
    SET @assertions = IFNULL(@assertions, 0) + 1;
    IF passed IS NULL OR NOT passed THEN
        SET @failure = LEFT(CONCAT('FAILED: ', description), 128);
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = @failure;
    END IF;
END //

-- Runs a statement and asserts it fails with the given error number.
-- MariaDB reports a violated CHECK constraint as 4025, MySQL as 3819; both
-- are normalised to 3819.
CREATE PROCEDURE assert_error(IN stmt TEXT, IN expected INT, IN description VARCHAR(255))
BEGIN
    DECLARE v_errno INT DEFAULT 0;

    -- The handler lives in an inner block so it cannot swallow the failure
    -- that assert_true raises below
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
            GET DIAGNOSTICS CONDITION 1 v_errno = MYSQL_ERRNO;
        SET @assert_sql = stmt;
        PREPARE assert_stmt FROM @assert_sql;
        EXECUTE assert_stmt;
    END;
    DEALLOCATE PREPARE assert_stmt;

    IF v_errno = 4025 THEN
        SET v_errno = 3819;
    END IF;
    CALL assert_true(v_errno = expected,
                     CONCAT(description, ' [expected ', expected, ', got ', v_errno, ']'));
END //

DELIMITER ;

SET @assertions = 0;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
SET @y    = YEAR(CURDATE()) + 1;     -- every flight in @y is in the future
SET @past = YEAR(CURDATE()) - 1;     -- every flight in @past has departed

CALL addYear(@y, 2.3);
CALL addYear(@y + 1, 2.5);
CALL addYear(@past, 1);
CALL addDay(@y, 'Monday', 1);
CALL addDay(@y + 1, 'Monday', 1.1);
CALL addDay(@past, 'Monday', 1);
CALL addDestination('MIT', 'Minas Tirith', 'Gondor');
CALL addDestination('hob', 'Hobbiton', 'The Shire');      -- codes are upper-cased
CALL addAircraft('EGL4', 'Great Eagle', 2, 2);             -- a 4-seat cabin
CALL addRoute('MIT', 'HOB', @y, 50);
CALL addRoute('MIT', 'HOB', @y + 1, 50);
CALL addRoute('HOB', 'MIT', @y, 40);
CALL addRoute('MIT', 'HOB', @past, 50);
CALL addFlight('MIT', 'HOB', @y, 'Monday', '09:00:00');
CALL addFlight('MIT', 'HOB', @y + 1, 'Monday', '09:00:00');
CALL addFlightWithAircraft('HOB', 'MIT', @y, 'Monday', '18:00:00', 'EGL4');
CALL addFlight('MIT', 'HOB', @past, 'Monday', '09:00:00');

SET @f     = (SELECT flight_id FROM v_flight_availability
              WHERE departure_airport = 'MIT' AND year = @y AND week = 10);
SET @f_next= (SELECT flight_id FROM v_flight_availability
              WHERE departure_airport = 'MIT' AND year = @y + 1 AND week = 10);
SET @eagle = (SELECT flight_id FROM v_flight_availability
              WHERE departure_airport = 'HOB' AND year = @y AND week = 10);
SET @gone  = (SELECT flight_id FROM v_flight_availability
              WHERE departure_airport = 'MIT' AND year = @past AND week = 10);

-- ---------------------------------------------------------------------------
-- Reference data, schedules and the calendar
-- ---------------------------------------------------------------------------
CALL assert_true((SELECT COUNT(*) FROM airport WHERE airport_id = 'HOB') = 1,
                 'airport codes are stored upper-case');
CALL assert_true((SELECT COUNT(*) FROM flights_info) = 4 * 52,
                 'addFlight creates 52 weekly flights per schedule');
CALL assert_true((SELECT COUNT(*) FROM v_flight_availability WHERE DAYNAME(departure_date) <> weekday) = 0,
                 'every flight departs on its scheduled weekday');
CALL assert_true((SELECT COUNT(*) FROM v_flight_availability
                  WHERE YEARWEEK(departure_date, 3) <> year * 100 + week) = 0,
                 'flight dates follow ISO-8601 week numbering');
CALL assert_true(flightDate(2026, 1, 'Monday') = '2025-12-29' AND flightDate(2026, 53, 'Sunday') = '2027-01-03',
                 'flightDate handles ISO weeks that cross a calendar year');
CALL assert_true((SELECT MIN(capacity) = 4 AND MAX(capacity) = 4 FROM flights_info fi
                  JOIN weekly_schedule ws ON ws.w_id = fi.flight_ws_id WHERE ws.aircraft_code = 'EGL4'),
                 'flights take their capacity from the aircraft');
CALL assert_error("CALL addFlight('HOB', 'MIT', 2099, 'Monday', '10:00:00')", 7004,
                  'a flight needs an existing route');
CALL assert_error("CALL addFlightWithAircraft('MIT', 'HOB', @y, 'Monday', '11:00:00', 'B747')", 7005,
                  'a flight needs an existing aircraft type');
CALL assert_error("CALL addFlight('MIT', 'HOB', @y, 'Monday', '09:00:00')", 1062,
                  'a route cannot have two departures at the same weekday and time');
CALL assert_error("CALL addDestination('M1T', 'Bad', 'Code')", 3819,
                  'airport codes must be three letters');
CALL assert_error("CALL addRoute('MIT', 'MIT', @y, 10)", 3819,
                  'a route must connect two different airports');
CALL assert_error("CALL addRoute('HOB', 'MIT', @y + 1, -5)", 3819,
                  'a route price must be positive');
CALL assert_error("CALL addDay(@y, 'Funday', 1)", 3819,
                  'weekday names are validated');

-- ---------------------------------------------------------------------------
-- Pricing
-- ---------------------------------------------------------------------------
CALL assert_true(calculatePrice(@f) = 115.00,
                 'empty flight: base 50 x weekday 1 x profit 2.3 = 115.00');
CALL assert_true(calculatePrice(@f_next) = 137.50,
                 'next year uses its own weekday (1.1) and profit (2.5) factors');
CALL assert_true((SELECT COUNT(*) FROM v_flight_availability
                  WHERE price_per_seat <> calculatePrice(flight_id)) = 0,
                 'the availability view and calculatePrice agree on every flight');
CALL assert_true(calculateFreeSeats(@f) = 40 AND calculateFreeSeats(@eagle) = 4,
                 'free seats start at capacity');

-- ---------------------------------------------------------------------------
-- Reservations
-- ---------------------------------------------------------------------------
CALL createReservation(@f, 4, @r, @ref);
CALL assert_true(@r IS NOT NULL AND @ref COLLATE utf8mb4_bin REGEXP '^[A-HJ-NP-Z2-9]{6}$',
                 'a reservation gets a six-character booking reference');
CALL assert_true((SELECT status FROM reservation WHERE res_no = @r) = 'PENDING',
                 'new reservations are pending');
CALL addReservation('MIT', 'HOB', @y, 10, 'Monday', '09:00:00', 2, @r2);
CALL assert_true((SELECT flight_id FROM reservation WHERE res_no = @r2) = @f,
                 'addReservation finds the flight by route, week, weekday and time');
CALL assert_true(calculateFreeSeats(@f) = 40,
                 'pending reservations do not hold seats');
CALL assert_error("CALL addReservation('MIT', 'HOB', @y, 99, 'Monday', '09:00:00', 2, @x)", 7001,
                  'reserving a flight that does not exist is rejected');
CALL assert_error("CALL createReservation(-1, 1, @x, @xref)", 7001,
                  'reserving an unknown flight id is rejected');
CALL assert_error("CALL createReservation(@f, 41, @x, @xref)", 7101,
                  'reserving more seats than the aircraft has is rejected');
CALL assert_error("CALL createReservation(@f, 0, @x, @xref)", 7206,
                  'a reservation needs at least one passenger');
CALL assert_error("CALL createReservation(@gone, 1, @x, @xref)", 7108,
                  'a departed flight cannot be booked');

-- ---------------------------------------------------------------------------
-- Passengers and contact
-- ---------------------------------------------------------------------------
CALL addPassenger(@r, 'P-FRODO', 'Frodo Baggins');
CALL addPassenger(@r, 'P-SAM', 'Samwise Gamgee');
CALL addPassenger(@r, 'P-MERRY', 'Meriadoc Brandybuck');
CALL assert_error("CALL addPassenger(@r, 'P-SAM', 'Samwise again')", 7106,
                  'the same passport cannot be added twice');
CALL addPassenger(@r, 'P-PIPPIN', 'Peregrin Took');
CALL assert_error("CALL addPassenger(@r, 'P-GANDALF', 'Gandalf')", 7105,
                  'a reservation cannot get more passengers than it was made for');
CALL assert_error("CALL addPassenger(-1, 'P-X', 'Nobody')", 7002,
                  'adding a passenger to an unknown reservation is rejected');

CALL assert_error("CALL addContact(@r, 'P-GANDALF', 'g@istari.me', '12345')", 7003,
                  'the contact must be a passenger of the reservation');
CALL assert_error("CALL addContact(@r, 'P-FRODO', 'not-an-email', '12345')", 3819,
                  'contact e-mail addresses are validated');
CALL addContact(@r, 'P-SAM', 'sam@shire.me', '+46 70 000 0000');
CALL addContact(@r, 'P-FRODO', 'frodo@shire.me', '+46 70 123 4567');
CALL assert_true((SELECT COUNT(*) = 1 AND MAX(email) = 'frodo@shire.me' FROM contact_info WHERE res_no = @r),
                 'addContact replaces the existing contact');

-- ---------------------------------------------------------------------------
-- Payment
-- ---------------------------------------------------------------------------
CALL addPassenger(@r2, 'P-BILBO', 'Bilbo Baggins');
CALL assert_error("CALL addPayment(@r2, 'Bilbo Baggins', '4111111111111111')", 7202,
                  'all passengers must be added before paying');
CALL addPassenger(@r2, 'P-LOBELIA', 'Lobelia Sackville-Baggins');
CALL assert_error("CALL addPayment(@r2, 'Bilbo Baggins', '4111111111111111')", 7201,
                  'a reservation needs a contact before paying');
CALL assert_error("CALL addPayment(@r, 'Frodo Baggins', '4111111111111112')", 7203,
                  'card numbers failing the Luhn check are declined');
CALL assert_error("CALL addPayment(@r, 'Frodo Baggins', '4111')", 7203,
                  'too-short card numbers are declined');

CALL addPayment(@r, 'Frodo Baggins', '4111 1111 1111 1111');
CALL assert_true((SELECT status FROM reservation WHERE res_no = @r) = 'CONFIRMED',
                 'payment confirms the reservation');
CALL assert_true((SELECT amount FROM payment WHERE res_no = @r) = 460.00,
                 'payment charges the fare for every passenger (115.00 x 4)');
CALL assert_true((SELECT card_brand = 'VISA' AND card_last4 = '1111' FROM payment WHERE res_no = @r),
                 'the card brand and last four digits are kept');
CALL assert_true((SELECT COUNT(*) FROM payment
                  WHERE CONCAT_WS('|', cardholder_name, card_brand, card_last4) LIKE '%41111111%') = 0
                 AND (SELECT COUNT(*) FROM audit_log WHERE CAST(new_data AS CHAR) LIKE '%41111111%') = 0,
                 'the full card number is stored nowhere');
CALL assert_true((SELECT COUNT(DISTINCT ticket) FROM passenger WHERE res_no = @r AND ticket IS NOT NULL) = 4,
                 'every paid passenger gets a unique ticket');
CALL assert_true(bookedSeats(@f) = 4 AND calculateFreeSeats(@f) = 36,
                 'paid seats are taken from the inventory');
CALL assert_true(calculatePrice(@f) = 126.50,
                 'the fare rises with demand: 115.00 x (40 + 4) / 40 = 126.50');
CALL assert_error("CALL addPayment(@r, 'Frodo Baggins', '4111111111111111')", 7102,
                  'a reservation cannot be paid twice');
CALL assert_error("CALL addPassenger(@r, 'P-GANDALF', 'Gandalf')", 7102,
                  'passengers cannot be added after payment');
CALL addContact(@r2, 'P-BILBO', 'bilbo@shire.me', '555 0101');
CALL addPayment(@r2, 'Bilbo Baggins', '5555 5555 5555 4444');
CALL assert_true((SELECT card_brand FROM payment WHERE res_no = @r2) = 'MASTERCARD',
                 'card brands are detected from the card number');
CALL assert_true((SELECT amount FROM payment WHERE res_no = @r2) = 253.00,
                 'the second booking pays the higher fare (126.50 x 2)');

CALL createReservation(@f, 2, @r3, @ref3);
CALL assert_error("CALL addPassenger(@r3, 'P-FRODO', 'Frodo Baggins')", 7107,
                  'a passenger cannot hold two tickets on the same flight');

-- ---------------------------------------------------------------------------
-- Seat selection
-- ---------------------------------------------------------------------------
CALL addPassenger(@r3, 'P-GANDALF', 'Gandalf the Grey');
CALL assert_error("CALL assignSeat(@r3, 'P-GANDALF', '1A')", 7205,
                  'seats are selected after payment');
CALL assert_error("CALL assignSeat(@r, 'P-FRODO', '11A')", 7204,
                  'rows beyond the cabin are rejected (10 rows)');
CALL assert_error("CALL assignSeat(@r, 'P-FRODO', '1E')", 7204,
                  'seat letters beyond the cabin width are rejected (A-D)');
CALL assert_error("CALL assignSeat(@r, 'P-FRODO', 'XX')", 7204,
                  'malformed seat codes are rejected');
CALL assert_error("CALL assignSeat(@r, 'P-GANDALF', '1A')", 7003,
                  'only passengers of the reservation get seats');
CALL assignSeat(@r, 'P-FRODO', '1a');
CALL assert_error("CALL assignSeat(@r, 'P-SAM', '1A')", 7104,
                  'a seat cannot be given to two passengers');
CALL assignSeat(@r, 'P-SAM', '1B');
CALL assignSeat(@r, 'P-FRODO', '2C');
CALL assert_true((SELECT seat_no FROM seat_assignment WHERE res_no = @r AND passp_no = 'P-FRODO') = '2C'
                 AND (SELECT COUNT(*) FROM seat_assignment WHERE flight_id = @f AND seat_no = '1A') = 0,
                 'changing seat releases the old one');
CALL assert_true((SELECT GROUP_CONCAT(seat_no ORDER BY seat_no) FROM v_booking_passengers
                  WHERE booking_ref = @ref AND seat_no IS NOT NULL) = '1B,2C',
                 'v_booking_passengers shows assigned seats');

-- ---------------------------------------------------------------------------
-- Inventory integrity and state machine
-- ---------------------------------------------------------------------------
CALL createReservation(@eagle, 3, @e1, @eref1);
CALL createReservation(@eagle, 2, @e2, @eref2);
CALL addPassenger(@e1, 'E1', 'Frodo'); CALL addPassenger(@e1, 'E2', 'Sam'); CALL addPassenger(@e1, 'E3', 'Gollum');
CALL addPassenger(@e2, 'E4', 'Merry'); CALL addPassenger(@e2, 'E5', 'Pippin');
CALL addContact(@e1, 'E1', 'frodo@shire.me', '555 0001');
CALL addContact(@e2, 'E4', 'merry@shire.me', '555 0002');
CALL addPayment(@e1, 'Frodo Baggins', '4111111111111111');
CALL assert_error("CALL addPayment(@e2, 'Merry Brandybuck', '4111111111111111')", 7101,
                  'payment re-checks seats: 2 more do not fit on a 4-seat aircraft with 3 sold');
CALL assert_error("UPDATE flights_info SET seats_booked = capacity + 1 WHERE flight_id = @eagle", 3819,
                  'the inventory CHECK constraint blocks overselling outside the procedures');
CALL assert_error("UPDATE reservation SET status = 'CONFIRMED' WHERE res_no = @e2", 3819,
                  'confirming by hand still cannot oversell (trigger + CHECK)');
CALL assert_error("UPDATE reservation SET status = 'PENDING' WHERE res_no = @e1", 7109,
                  'illegal status transitions are rejected');
CALL assert_error("UPDATE reservation SET no_passengers = 1 WHERE res_no = @e1", 7110,
                  'a reservation cannot change size after creation');
CALL assert_error("UPDATE payment SET amount = 1 WHERE res_no = @e1", 7111,
                  'captured payment amounts are immutable');
CALL assert_true((SELECT COUNT(*) FROM v_inventory_drift) = 0,
                 'the inventory counters match the confirmed reservations');

-- ---------------------------------------------------------------------------
-- Cancellation and refunds
-- ---------------------------------------------------------------------------
SET @dep = flightDeparture(@f);
CALL assert_true(refundPercentage(@dep, @dep - INTERVAL 40 DAY) = 100
             AND refundPercentage(@dep, @dep - INTERVAL 30 DAY) = 100
             AND refundPercentage(@dep, @dep - INTERVAL 10 DAY) = 50
             AND refundPercentage(@dep, @dep - INTERVAL 7 DAY) = 50
             AND refundPercentage(@dep, @dep - INTERVAL 2 DAY) = 0
             AND refundPercentage(@dep, @dep + INTERVAL 1 HOUR) = 0,
                 'refund tiers: >=30 days 100 %, 7-29 days 50 %, <7 days 0 %');
CALL assert_true(calculateRefund(@r, @dep - INTERVAL 10 DAY) = 230.00,
                 'calculateRefund applies the tier to the amount paid (50 % of 460.00)');

CALL cancelReservation(@r, @refund);
CALL assert_true(@refund = 460.00, 'cancelling well before departure refunds in full');
CALL assert_true((SELECT status FROM reservation WHERE res_no = @r) = 'CANCELLED'
                 AND (SELECT refunded_amount FROM payment WHERE res_no = @r) = 460.00,
                 'the reservation is cancelled and the refund recorded');
CALL assert_true(bookedSeats(@f) = 2,
                 'cancelling releases the seats (only the 2 from the second booking remain)');
CALL assert_true((SELECT COUNT(*) FROM seat_assignment WHERE res_no = @r) = 0,
                 'cancelling releases seat assignments');
CALL assert_error("CALL cancelReservation(@r, @x)", 7103,
                  'a reservation cannot be cancelled twice');
CALL assert_error("CALL addContact(@r, 'P-FRODO', 'frodo@shire.me', '12345')", 7103,
                  'a cancelled reservation cannot be changed');
CALL addPassenger(@r3, 'P-FRODO', 'Frodo Baggins');
CALL assert_true((SELECT COUNT(*) FROM passenger WHERE res_no = @r3) = 2,
                 'after cancelling, the passenger can book the flight again');
CALL cancelReservation(@r3, @refund3);
CALL assert_true(@refund3 = 0 AND (SELECT status FROM reservation WHERE res_no = @r3) = 'CANCELLED',
                 'an unpaid reservation is cancelled without a refund');

INSERT INTO reservation (booking_ref, flight_id, no_passengers) VALUES ('PAST22', @gone, 1);
SET @r_gone = LAST_INSERT_ID();
CALL assert_error("CALL cancelReservation(@r_gone, @x)", 7108,
                  'a reservation cannot be cancelled after departure');

-- ---------------------------------------------------------------------------
-- Expiry of abandoned checkouts
-- ---------------------------------------------------------------------------
CALL createReservation(@f, 1, @stale, @stale_ref);
UPDATE reservation SET created_at = NOW() - INTERVAL 2 HOUR WHERE res_no = @stale;
CALL expirePendingReservations(30, @expired);
CALL assert_true(@expired >= 1 AND (SELECT status FROM reservation WHERE res_no = @stale) = 'EXPIRED',
                 'pending reservations older than the limit expire');
CALL assert_true((SELECT status FROM reservation WHERE res_no = @e2) = 'PENDING',
                 'recent pending reservations are left alone');
CALL assert_error("CALL addPassenger(@stale, 'P-X', 'Late')", 7103,
                  'an expired reservation cannot be changed');
CALL assert_true((SELECT COUNT(*) FROM information_schema.EVENTS
                  WHERE EVENT_SCHEMA = DATABASE() AND EVENT_NAME = 'ev_expire_pending_reservations') = 1,
                 'the expiry job is scheduled');

-- ---------------------------------------------------------------------------
-- Audit trail
-- ---------------------------------------------------------------------------
CALL assert_true((SELECT GROUP_CONCAT(JSON_UNQUOTE(JSON_EXTRACT(new_data, '$.status')) ORDER BY audit_id)
                  FROM audit_log WHERE table_name = 'reservation' AND record_id = @r) = 'PENDING,CONFIRMED,CANCELLED',
                 'the audit log records the reservation lifecycle');
CALL assert_true((SELECT COUNT(*) FROM audit_log WHERE table_name = 'payment' AND action = 'UPDATE'
                  AND JSON_EXTRACT(new_data, '$.refunded_amount') = 460) = 1,
                 'the audit log records refunds');
CALL assert_true((SELECT COUNT(*) FROM audit_log WHERE table_name = 'seat_assignment') = 6,
                 'the audit log records seat changes (3 assigned, 3 released)');
CALL assert_true((SELECT COUNT(*) FROM audit_log WHERE changed_by IS NULL OR changed_by = '') = 0,
                 'every audit row names the connected account');

-- ---------------------------------------------------------------------------
-- Analytics
-- ---------------------------------------------------------------------------
CALL assert_true((SELECT net_revenue FROM v_route_performance
                  WHERE departure_airport = 'MIT' AND arrival_airport = 'HOB' AND year = @y) = 253.00,
                 'route revenue nets out refunds (460 paid and refunded + 253 paid)');
CALL assert_true((SELECT net_revenue FROM v_route_performance
                  WHERE departure_airport = 'HOB' AND year = @y) = 276.00,
                 'the 4-seat route earned 3 x 92.00 (40 x 2.3 x (4 + 0) / 4)');
CALL assert_true((SELECT GROUP_CONCAT(departure_airport ORDER BY revenue_rank) FROM v_route_performance
                  WHERE year = @y) = 'HOB,MIT',
                 'routes are ranked by net revenue within their year');
CALL assert_true((SELECT seats_sold FROM v_route_performance
                  WHERE departure_airport = 'HOB' AND year = @y) = 3,
                 'route seat sales come from the inventory');
CALL assert_true((SELECT MAX(cumulative_revenue) FROM v_monthly_revenue)
                 = (SELECT SUM(amount - refunded_amount) FROM payment),
                 'the monthly running total ends at total net revenue');
CALL assert_true((SELECT reservations FROM v_booking_funnel) = (SELECT COUNT(*) FROM reservation)
                 AND (SELECT paid FROM v_booking_funnel) = (SELECT COUNT(*) FROM payment),
                 'the funnel counts every reservation and payment');
CALL assert_true((SELECT load_factor_pct FROM v_flight_load WHERE flight_id = @eagle) = 75.0,
                 'load factor = seats sold / capacity (3 / 4)');

-- ---------------------------------------------------------------------------
-- Least privilege
-- ---------------------------------------------------------------------------
CALL assert_true((SELECT COUNT(*) FROM mysql.procs_priv
                  WHERE User = 'flight_app' AND Db = DATABASE()) = 9,
                 'flight_app may execute exactly the 8 booking procedures and calculateRefund');
CALL assert_true((SELECT COUNT(*) FROM mysql.tables_priv
                  WHERE User = 'flight_app' AND Db = DATABASE()
                    AND Table_name NOT IN ('airport', 'v_flight_availability', 'allFlights',
                                           'v_booking', 'v_booking_passengers')) = 0,
                 'flight_app has no privileges on base tables other than airport');

DROP PROCEDURE assert_true;
DROP PROCEDURE assert_error;
SELECT CONCAT('All ', @assertions, ' flight reservation assertions passed') AS result;
