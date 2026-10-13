-- =============================================================================
-- 03_procedures.sql — reference data and the booking workflow
--
-- Writes go through these procedures, which enforce the business rules. Every
-- rejection raises SQLSTATE 45000 with an application error number:
--   70xx  something does not exist        (HTTP 404)
--   71xx  conflicts with current state    (HTTP 409)
--   72xx  request is not valid            (HTTP 422)
-- The full catalogue is in docs/architecture.md.
-- =============================================================================

SET NAMES utf8mb4;

DROP PROCEDURE IF EXISTS raiseError;
DROP PROCEDURE IF EXISTS addYear;
DROP PROCEDURE IF EXISTS addDay;
DROP PROCEDURE IF EXISTS addDestination;
DROP PROCEDURE IF EXISTS addAircraft;
DROP PROCEDURE IF EXISTS addRoute;
DROP PROCEDURE IF EXISTS addFlight;
DROP PROCEDURE IF EXISTS addFlightWithAircraft;
DROP PROCEDURE IF EXISTS createReservation;
DROP PROCEDURE IF EXISTS addReservation;
DROP PROCEDURE IF EXISTS addPassenger;
DROP PROCEDURE IF EXISTS addContact;
DROP PROCEDURE IF EXISTS addPayment;
DROP PROCEDURE IF EXISTS cancelReservation;
DROP PROCEDURE IF EXISTS assignSeat;
DROP PROCEDURE IF EXISTS getSeatMap;
DROP PROCEDURE IF EXISTS expirePendingReservations;

DELIMITER //

CREATE PROCEDURE raiseError(IN p_errno INT, IN p_message VARCHAR(255))
BEGIN
    SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO = p_errno, MESSAGE_TEXT = p_message;
END //

-- ---------------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------------

CREATE PROCEDURE addYear(IN p_year INT, IN p_factor DECIMAL(6,3))
BEGIN
    INSERT INTO year (year, profitfactor) VALUES (p_year, p_factor);
END //

CREATE PROCEDURE addDay(IN p_year INT, IN p_day VARCHAR(10), IN p_factor DECIMAL(6,3))
BEGIN
    INSERT INTO week_day (year, weekday, price_factor) VALUES (p_year, p_day, p_factor);
END //

CREATE PROCEDURE addDestination(IN p_airport_code VARCHAR(3), IN p_name VARCHAR(80),
                                IN p_country VARCHAR(60))
BEGIN
    INSERT INTO airport (airport_id, airport_name, country)
    VALUES (UPPER(p_airport_code), p_name, p_country);
END //

CREATE PROCEDURE addAircraft(IN p_code VARCHAR(10), IN p_model VARCHAR(60),
                             IN p_rows INT, IN p_seats_per_row INT)
BEGIN
    INSERT INTO aircraft (aircraft_code, model, seat_rows, seats_per_row)
    VALUES (p_code, p_model, p_rows, p_seats_per_row);
END //

CREATE PROCEDURE addRoute(IN p_airport_code_dept VARCHAR(3), IN p_airport_code_dest VARCHAR(3),
                          IN p_year INT, IN p_routeprice DECIMAL(10,2))
BEGIN
    INSERT INTO route (departure_ap, arrival_ap, year, price)
    VALUES (p_airport_code_dept, p_airport_code_dest, p_year, p_routeprice);
END //

-- A weekly departure on the default 40-seat aircraft
CREATE PROCEDURE addFlight(IN dep VARCHAR(3), IN arr VARCHAR(3), IN yr INT,
                           IN wday VARCHAR(10), IN time TIME)
BEGIN
    CALL addFlightWithAircraft(dep, arr, yr, wday, time, 'STD40');
END //

-- Creates a weekly schedule entry and its 52 dated flights in one transaction
CREATE PROCEDURE addFlightWithAircraft(IN dep VARCHAR(3), IN arr VARCHAR(3), IN yr INT,
                                       IN wday VARCHAR(10), IN p_time TIME,
                                       IN p_aircraft VARCHAR(10))
BEGIN
    DECLARE v_route_id INT;
    DECLARE v_schedule_id INT;
    DECLARE v_capacity INT;
    DECLARE v_week INT DEFAULT 1;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SELECT route_id INTO v_route_id
    FROM route
    WHERE departure_ap = dep AND arrival_ap = arr AND year = yr;

    IF v_route_id IS NULL THEN
        CALL raiseError(7004, 'No route exists for the given airports and year');
    END IF;

    SELECT capacity INTO v_capacity FROM aircraft WHERE aircraft_code = p_aircraft;
    IF v_capacity IS NULL THEN
        CALL raiseError(7005, 'The aircraft type does not exist');
    END IF;

    START TRANSACTION;

    INSERT INTO weekly_schedule (w_route_id, w_year, weekday, dept, aircraft_code)
    VALUES (v_route_id, yr, wday, p_time, p_aircraft);
    SET v_schedule_id = LAST_INSERT_ID();

    WHILE v_week <= 52 DO
        INSERT INTO flights_info (flight_ws_id, week, departure_date, capacity)
        VALUES (v_schedule_id, v_week, flightDate(yr, v_week, wday), v_capacity);
        SET v_week = v_week + 1;
    END WHILE;

    COMMIT;
END //

-- ---------------------------------------------------------------------------
-- Booking workflow: reserve → add passengers → add contact → pay → ticket
-- ---------------------------------------------------------------------------

-- Reserve seats on a flight. Pending reservations do not hold seats; seat
-- availability is checked again, under a lock, when the reservation is paid.
CREATE PROCEDURE createReservation(IN p_flight_id INT, IN p_passengers INT,
                                   OUT p_res_no INT, OUT p_booking_ref CHAR(6))
BEGIN
    DECLARE v_departure DATETIME DEFAULT flightDeparture(p_flight_id);
    DECLARE v_ref CHAR(6);

    SET p_res_no = NULL, p_booking_ref = NULL;

    IF v_departure IS NULL THEN
        CALL raiseError(7001, 'The flight does not exist');
    END IF;
    IF v_departure <= NOW() THEN
        CALL raiseError(7108, 'The flight has already departed');
    END IF;
    IF p_passengers IS NULL OR p_passengers < 1 THEN
        CALL raiseError(7206, 'A reservation needs at least one passenger');
    END IF;
    IF p_passengers > calculateFreeSeats(p_flight_id) THEN
        CALL raiseError(7101, 'There are not enough seats available on the chosen flight');
    END IF;

    REPEAT
        SET v_ref = generateBookingRef();
    UNTIL NOT EXISTS (SELECT 1 FROM reservation WHERE booking_ref = v_ref) END REPEAT;

    INSERT INTO reservation (booking_ref, flight_id, no_passengers)
    VALUES (v_ref, p_flight_id, p_passengers);

    SET p_res_no = LAST_INSERT_ID(), p_booking_ref = v_ref;
END //

-- Reserve by route, date and time (the original lookup-based interface)
CREATE PROCEDURE addReservation(IN deptcode VARCHAR(3), IN arrcode VARCHAR(3), IN yr INT,
                                IN wk INT, IN day VARCHAR(10), IN depttime TIME,
                                IN numpass INT, OUT resnum INT)
BEGIN
    DECLARE v_flight_id INT;
    DECLARE v_ref CHAR(6);

    SELECT fi.flight_id INTO v_flight_id
    FROM flights_info fi
    JOIN weekly_schedule ws ON ws.w_id = fi.flight_ws_id
    JOIN route r            ON r.route_id = ws.w_route_id
    WHERE ws.w_year = yr AND ws.weekday = day AND ws.dept = depttime
      AND r.departure_ap = deptcode AND r.arrival_ap = arrcode AND fi.week = wk;

    IF v_flight_id IS NULL THEN
        CALL raiseError(7001, 'There exist no flight for the given route, date and time');
    END IF;

    CALL createReservation(v_flight_id, numpass, resnum, v_ref);
END //

CREATE PROCEDURE addPassenger(IN resnr INT, IN passportnr VARCHAR(20), IN p_name VARCHAR(100))
BEGIN
    DECLARE v_status VARCHAR(10);
    DECLARE v_max INT;
    DECLARE v_flight_id INT;
    DECLARE v_added INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    -- Lock the reservation so concurrent calls cannot exceed its passenger count
    SELECT status, no_passengers, flight_id INTO v_status, v_max, v_flight_id
    FROM reservation
    WHERE res_no = resnr
    FOR UPDATE;

    IF v_status IS NULL THEN
        CALL raiseError(7002, 'The reservation number does not exist');
    ELSEIF v_status = 'CONFIRMED' THEN
        CALL raiseError(7102, 'The booking has already been paid, no further passengers can be added');
    ELSEIF v_status <> 'PENDING' THEN
        CALL raiseError(7103, 'The reservation is no longer active');
    END IF;

    IF EXISTS (SELECT 1 FROM passenger WHERE res_no = resnr AND passp_no = passportnr) THEN
        CALL raiseError(7106, 'The passenger is already on this reservation');
    END IF;

    SELECT COUNT(*) INTO v_added FROM passenger WHERE res_no = resnr;
    IF v_added >= v_max THEN
        CALL raiseError(7105, 'All passengers for this reservation have already been added');
    END IF;

    IF EXISTS (SELECT 1
               FROM passenger p
               JOIN reservation r ON r.res_no = p.res_no
               WHERE r.flight_id = v_flight_id AND r.status = 'CONFIRMED'
                 AND p.passp_no = passportnr) THEN
        CALL raiseError(7107, 'The passenger already holds a ticket on this flight');
    END IF;

    INSERT INTO passenger (res_no, passp_no, name) VALUES (resnr, passportnr, TRIM(p_name));

    COMMIT;
END //

-- Sets (or replaces) the reservation's contact person
CREATE PROCEDURE addContact(IN resnr INT, IN passportnr VARCHAR(20),
                            IN p_email VARCHAR(254), IN p_phone VARCHAR(20))
BEGIN
    DECLARE v_status VARCHAR(10);

    SELECT status INTO v_status FROM reservation WHERE res_no = resnr;

    IF v_status IS NULL THEN
        CALL raiseError(7002, 'The given reservation number does not exist');
    ELSEIF v_status NOT IN ('PENDING', 'CONFIRMED') THEN
        CALL raiseError(7103, 'The reservation is no longer active');
    ELSEIF NOT EXISTS (SELECT 1 FROM passenger WHERE res_no = resnr AND passp_no = passportnr) THEN
        CALL raiseError(7003, 'The person is not a passenger of the reservation');
    END IF;

    INSERT INTO contact_info (res_no, passp_no, phone, email)
    VALUES (resnr, passportnr, p_phone, p_email)
    ON DUPLICATE KEY UPDATE passp_no = passportnr, phone = p_phone, email = p_email;
END //

-- Pays for a reservation: charges the current fare for every passenger,
-- confirms the reservation and (via the ticketgenerator trigger) issues tickets.
CREATE PROCEDURE addPayment(IN resnr INT, IN cardname VARCHAR(100), IN cardnum VARCHAR(32))
BEGIN
    DECLARE v_flight_id INT;
    DECLARE v_status VARCHAR(10);
    DECLARE v_passengers INT;
    DECLARE v_added INT;
    DECLARE v_free INT;
    DECLARE v_price DECIMAL(10,2);
    DECLARE v_digits VARCHAR(32) DEFAULT REPLACE(REPLACE(cardnum, ' ', ''), '-', '');

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF NOT isValidCardNumber(v_digits) THEN
        CALL raiseError(7203, 'The card number is not valid');
    END IF;

    START TRANSACTION;

    -- Concurrency control: lock the reservation, then the flight, before any
    -- plain (non-locking) read. InnoDB fixes a transaction's REPEATABLE READ
    -- snapshot at its first plain read; reading first and locking second would
    -- let two payments both see the last free seats (v1 of this schema did).
    --   1. the reservation row: a reservation cannot be paid twice
    --   2. the flight row: payments for the same flight run one at a time,
    --      and the locking read returns the latest committed inventory
    SELECT flight_id, status, no_passengers INTO v_flight_id, v_status, v_passengers
    FROM reservation
    WHERE res_no = resnr
    FOR UPDATE;

    IF v_flight_id IS NULL THEN
        CALL raiseError(7002, 'The given reservation number does not exist');
    ELSEIF v_status = 'CONFIRMED' THEN
        CALL raiseError(7102, 'The reservation has already been paid');
    ELSEIF v_status <> 'PENDING' THEN
        CALL raiseError(7103, 'The reservation is no longer active');
    END IF;

    SELECT capacity - seats_booked INTO v_free
    FROM flights_info
    WHERE flight_id = v_flight_id
    FOR UPDATE;

    IF flightDeparture(v_flight_id) <= NOW() THEN
        CALL raiseError(7108, 'The flight has already departed');
    END IF;

    SELECT COUNT(*) INTO v_added FROM passenger WHERE res_no = resnr;
    IF v_added < v_passengers THEN
        CALL raiseError(7202, 'All passengers must be added before the reservation can be paid');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM contact_info WHERE res_no = resnr) THEN
        CALL raiseError(7201, 'The reservation has no contact yet');
    END IF;

    IF v_passengers > v_free THEN
        CALL raiseError(7101, 'The flight is fully booked, payment declined');
    END IF;

    -- Fare at the current load, before this booking's seats are added
    SET v_price = calculatePrice(v_flight_id);

    INSERT INTO payment (res_no, cardholder_name, card_brand, card_last4, amount)
    VALUES (resnr, cardname, cardBrand(v_digits), RIGHT(v_digits, 4), v_price * v_passengers);

    -- trg_reservation_inventory moves the seats into flights_info.seats_booked
    UPDATE reservation SET status = 'CONFIRMED' WHERE res_no = resnr;

    COMMIT;
END //

-- Cancels a reservation. A paid reservation is refunded according to
-- refundPercentage(); its seats (via trg_reservation_inventory) and seat
-- assignments are released.
CREATE PROCEDURE cancelReservation(IN resnr INT, OUT p_refund DECIMAL(10,2))
BEGIN
    DECLARE v_status VARCHAR(10);
    DECLARE v_flight_id INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET p_refund = NULL;
    START TRANSACTION;

    SELECT status, flight_id INTO v_status, v_flight_id
    FROM reservation
    WHERE res_no = resnr
    FOR UPDATE;

    IF v_status IS NULL THEN
        CALL raiseError(7002, 'The given reservation number does not exist');
    ELSEIF v_status NOT IN ('PENDING', 'CONFIRMED') THEN
        CALL raiseError(7103, 'The reservation is no longer active');
    ELSEIF flightDeparture(v_flight_id) <= NOW() THEN
        CALL raiseError(7108, 'The flight has already departed');
    END IF;

    SET p_refund = 0;
    IF v_status = 'CONFIRMED' THEN
        SET p_refund = calculateRefund(resnr, NOW());
        UPDATE payment SET refunded_amount = p_refund, refunded_at = NOW() WHERE res_no = resnr;
        DELETE FROM seat_assignment WHERE res_no = resnr;
    END IF;

    UPDATE reservation SET status = 'CANCELLED' WHERE res_no = resnr;

    COMMIT;
END //

-- Picks (or changes) a passenger's seat, e.g. '12C'. Rows are numbered from 1,
-- seat letters run A, B, C, ... skipping I, as on real aircraft.
CREATE PROCEDURE assignSeat(IN resnr INT, IN passportnr VARCHAR(20), IN p_seat VARCHAR(4))
BEGIN
    DECLARE v_status VARCHAR(10);
    DECLARE v_flight_id INT;
    DECLARE v_rows INT;
    DECLARE v_width INT;
    DECLARE v_seat VARCHAR(4) DEFAULT UPPER(TRIM(p_seat));

    -- The primary key (flight_id, seat_no) is the final guard against two
    -- passengers taking the same seat at the same time
    DECLARE EXIT HANDLER FOR 1062
    BEGIN
        ROLLBACK;
        CALL raiseError(7104, 'The seat is already taken');
    END;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT status, flight_id INTO v_status, v_flight_id
    FROM reservation
    WHERE res_no = resnr
    FOR UPDATE;

    IF v_status IS NULL THEN
        CALL raiseError(7002, 'The given reservation number does not exist');
    ELSEIF v_status = 'PENDING' THEN
        CALL raiseError(7205, 'Seats can be selected once the reservation is paid');
    ELSEIF v_status <> 'CONFIRMED' THEN
        CALL raiseError(7103, 'The reservation is no longer active');
    ELSEIF flightDeparture(v_flight_id) <= NOW() THEN
        CALL raiseError(7108, 'The flight has already departed');
    ELSEIF NOT EXISTS (SELECT 1 FROM passenger WHERE res_no = resnr AND passp_no = passportnr) THEN
        CALL raiseError(7003, 'The person is not a passenger of the reservation');
    END IF;

    SELECT a.seat_rows, a.seats_per_row INTO v_rows, v_width
    FROM flights_info fi
    JOIN weekly_schedule ws ON ws.w_id = fi.flight_ws_id
    JOIN aircraft a         ON a.aircraft_code = ws.aircraft_code
    WHERE fi.flight_id = v_flight_id;

    IF v_seat IS NULL
       OR v_seat NOT REGEXP '^[1-9][0-9]?[A-HJK]$'
       OR CAST(LEFT(v_seat, CHAR_LENGTH(v_seat) - 1) AS UNSIGNED) > v_rows
       OR LOCATE(RIGHT(v_seat, 1), LEFT('ABCDEFGHJK', v_width)) = 0 THEN
        CALL raiseError(7204, 'The seat does not exist on this aircraft');
    END IF;

    DELETE FROM seat_assignment WHERE res_no = resnr AND passp_no = passportnr;
    INSERT INTO seat_assignment (flight_id, seat_no, res_no, passp_no)
    VALUES (v_flight_id, v_seat, resnr, passportnr);

    COMMIT;
END //

-- Every seat on the flight's aircraft and whether it is taken
CREATE PROCEDURE getSeatMap(IN p_flight_id INT)
BEGIN
    DECLARE v_rows INT;
    DECLARE v_width INT;

    SELECT a.seat_rows, a.seats_per_row INTO v_rows, v_width
    FROM flights_info fi
    JOIN weekly_schedule ws ON ws.w_id = fi.flight_ws_id
    JOIN aircraft a         ON a.aircraft_code = ws.aircraft_code
    WHERE fi.flight_id = p_flight_id;

    IF v_rows IS NULL THEN
        CALL raiseError(7001, 'The flight does not exist');
    END IF;

    WITH RECURSIVE
        cabin_rows (seat_row) AS (
            SELECT 1 UNION ALL SELECT seat_row + 1 FROM cabin_rows WHERE seat_row < v_rows
        ),
        cabin_cols (col) AS (
            SELECT 1 UNION ALL SELECT col + 1 FROM cabin_cols WHERE col < v_width
        ),
        seats AS (
            SELECT seat_row, SUBSTRING('ABCDEFGHJK', col, 1) AS seat_letter, col
            FROM cabin_rows CROSS JOIN cabin_cols
        )
    SELECT CONCAT(s.seat_row, s.seat_letter) AS seat_no,
           s.seat_row,
           s.seat_letter,
           sa.seat_no IS NOT NULL AS is_taken
    FROM seats s
    LEFT JOIN seat_assignment sa
           ON sa.flight_id = p_flight_id AND sa.seat_no = CONCAT(s.seat_row, s.seat_letter)
    ORDER BY s.seat_row, s.col;
END //

-- Housekeeping: abandoned checkouts. Run by the ev_expire_pending_reservations
-- event (06_jobs.sql).
CREATE PROCEDURE expirePendingReservations(IN p_max_age_minutes INT, OUT p_expired INT)
BEGIN
    UPDATE reservation
    SET status = 'EXPIRED'
    WHERE status = 'PENDING'
      AND created_at < NOW() - INTERVAL p_max_age_minutes MINUTE;
    SET p_expired = ROW_COUNT();
END //

DELIMITER ;
