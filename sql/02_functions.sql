-- =============================================================================
-- 02_functions.sql — calendar, inventory, pricing, payments and refunds
-- =============================================================================

SET NAMES utf8mb4;

DROP FUNCTION IF EXISTS flightDate;
DROP FUNCTION IF EXISTS flightDeparture;
DROP FUNCTION IF EXISTS flightCapacity;
DROP FUNCTION IF EXISTS bookedSeats;
DROP FUNCTION IF EXISTS calculateFreeSeats;
DROP FUNCTION IF EXISTS calculatePrice;
DROP FUNCTION IF EXISTS isValidCardNumber;
DROP FUNCTION IF EXISTS cardBrand;
DROP FUNCTION IF EXISTS generateBookingRef;
DROP FUNCTION IF EXISTS refundPercentage;
DROP FUNCTION IF EXISTS calculateRefund;

DELIMITER //

-- Date of a weekday in an ISO-8601 week: ISO week 1 is the week with 4 January.
CREATE FUNCTION flightDate(p_year INT, p_week INT, p_weekday VARCHAR(10))
RETURNS DATE
DETERMINISTIC NO SQL
BEGIN
    DECLARE jan4 DATE DEFAULT MAKEDATE(p_year, 4);
    RETURN jan4 - INTERVAL WEEKDAY(jan4) DAY
                + INTERVAL ((p_week - 1) * 7
                            + FIELD(p_weekday, 'Monday', 'Tuesday', 'Wednesday', 'Thursday',
                                               'Friday', 'Saturday', 'Sunday') - 1) DAY;
END //

-- Scheduled departure (date and time) of a flight
CREATE FUNCTION flightDeparture(p_flight_id INT)
RETURNS DATETIME
READS SQL DATA
BEGIN
    DECLARE v_departure DATETIME;
    SELECT TIMESTAMP(fi.departure_date, ws.dept) INTO v_departure
    FROM flights_info fi
    JOIN weekly_schedule ws ON ws.w_id = fi.flight_ws_id
    WHERE fi.flight_id = p_flight_id;
    RETURN v_departure;
END //

-- Seats on the flight (copied from its aircraft when the flight is created)
CREATE FUNCTION flightCapacity(p_flight_id INT)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_capacity INT;
    SELECT capacity INTO v_capacity FROM flights_info WHERE flight_id = p_flight_id;
    RETURN v_capacity;
END //

-- Seats sold: passengers on CONFIRMED (paid) reservations. Pending,
-- cancelled and expired reservations do not hold seats.
CREATE FUNCTION bookedSeats(p_flight_id INT)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_booked INT;
    SELECT seats_booked INTO v_booked FROM flights_info WHERE flight_id = p_flight_id;
    RETURN v_booked;
END //

CREATE FUNCTION calculateFreeSeats(flightnum INT)
RETURNS INT
READS SQL DATA
BEGIN
    RETURN flightCapacity(flightnum) - bookedSeats(flightnum);
END //

-- Demand-based fare per seat:
--   base fare x weekday factor x profit factor x (1 + seats sold / capacity)
-- An empty flight sells at the base price; the last seat costs twice as much.
-- v_flight_availability (05_views.sql) applies the same formula to every
-- flight at once; the test suite asserts the two always agree.
CREATE FUNCTION calculatePrice(flightnum INT)
RETURNS DECIMAL(10,2)
READS SQL DATA
BEGIN
    DECLARE v_price DECIMAL(10,2);

    SELECT ROUND(r.price * wd.price_factor * y.profitfactor
                 * (fi.capacity + fi.seats_booked) / fi.capacity, 2)
    INTO v_price
    FROM flights_info fi
    JOIN weekly_schedule ws ON ws.w_id = fi.flight_ws_id
    JOIN route r            ON r.route_id = ws.w_route_id
    JOIN week_day wd        ON wd.weekday = ws.weekday AND wd.year = ws.w_year
    JOIN year y             ON y.year = ws.w_year
    WHERE fi.flight_id = flightnum;

    RETURN v_price;
END //

-- Luhn (mod 10) check for a 12–19 digit card number; spaces and dashes allowed
CREATE FUNCTION isValidCardNumber(p_card VARCHAR(32))
RETURNS BOOLEAN
DETERMINISTIC NO SQL
BEGIN
    DECLARE v_digits VARCHAR(32) DEFAULT REPLACE(REPLACE(p_card, ' ', ''), '-', '');
    DECLARE v_len INT DEFAULT CHAR_LENGTH(v_digits);
    DECLARE v_sum INT DEFAULT 0;
    DECLARE v_pos INT DEFAULT 0;
    DECLARE v_digit INT;

    IF v_digits IS NULL OR v_len NOT BETWEEN 12 AND 19 OR v_digits NOT REGEXP '^[0-9]+$' THEN
        RETURN FALSE;
    END IF;

    -- Walk from the rightmost digit, doubling every second one
    WHILE v_pos < v_len DO
        SET v_digit = CAST(SUBSTRING(v_digits, v_len - v_pos, 1) AS UNSIGNED);
        IF v_pos % 2 = 1 THEN
            SET v_digit = v_digit * 2;
            IF v_digit > 9 THEN SET v_digit = v_digit - 9; END IF;
        END IF;
        SET v_sum = v_sum + v_digit;
        SET v_pos = v_pos + 1;
    END WHILE;

    RETURN v_sum % 10 = 0;
END //

-- Card network from the issuer identification number (first digits)
CREATE FUNCTION cardBrand(p_card VARCHAR(32))
RETURNS VARCHAR(12)
DETERMINISTIC NO SQL
BEGIN
    DECLARE v_digits VARCHAR(32) DEFAULT REPLACE(REPLACE(p_card, ' ', ''), '-', '');
    DECLARE v_iin2 INT DEFAULT CAST(LEFT(v_digits, 2) AS UNSIGNED);
    DECLARE v_iin4 INT DEFAULT CAST(LEFT(v_digits, 4) AS UNSIGNED);

    RETURN CASE
        WHEN v_digits LIKE '4%'                             THEN 'VISA'
        WHEN v_iin2 BETWEEN 51 AND 55
          OR v_iin4 BETWEEN 2221 AND 2720                   THEN 'MASTERCARD'
        WHEN v_iin2 IN (34, 37)                             THEN 'AMEX'
        WHEN v_digits LIKE '6011%' OR v_digits LIKE '65%'   THEN 'DISCOVER'
        ELSE 'OTHER'
    END;
END //

-- Six-character booking reference (PNR). The alphabet leaves out 0/O and 1/I
-- so references can be read out over the phone. Uniqueness is guaranteed by
-- uq_booking_ref; createReservation retries on the rare collision.
CREATE FUNCTION generateBookingRef()
RETURNS CHAR(6)
NOT DETERMINISTIC NO SQL
BEGIN
    DECLARE v_alphabet CHAR(32) DEFAULT 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    DECLARE v_ref VARCHAR(6) DEFAULT '';
    WHILE CHAR_LENGTH(v_ref) < 6 DO
        SET v_ref = CONCAT(v_ref, SUBSTRING(v_alphabet, 1 + FLOOR(RAND() * 32), 1));
    END WHILE;
    RETURN v_ref;
END //

-- Refund policy, by time left until departure:
--   30 days or more → 100 %,  7–29 days → 50 %,  less than 7 days → 0 %
CREATE FUNCTION refundPercentage(p_departure DATETIME, p_as_of DATETIME)
RETURNS INT
DETERMINISTIC NO SQL
BEGIN
    DECLARE v_days INT DEFAULT TIMESTAMPDIFF(DAY, p_as_of, p_departure);
    RETURN CASE
        WHEN p_as_of >= p_departure THEN 0
        WHEN v_days >= 30           THEN 100
        WHEN v_days >= 7            THEN 50
        ELSE 0
    END;
END //

-- Amount refunded if a reservation were cancelled at p_as_of
CREATE FUNCTION calculateRefund(p_res_no INT, p_as_of DATETIME)
RETURNS DECIMAL(10,2)
READS SQL DATA
BEGIN
    DECLARE v_amount DECIMAL(10,2);
    DECLARE v_departure DATETIME;

    SELECT p.amount, flightDeparture(r.flight_id) INTO v_amount, v_departure
    FROM reservation r
    JOIN payment p ON p.res_no = r.res_no
    WHERE r.res_no = p_res_no AND r.status = 'CONFIRMED';

    IF v_amount IS NULL THEN
        RETURN 0;
    END IF;
    RETURN ROUND(v_amount * refundPercentage(v_departure, p_as_of) / 100, 2);
END //

DELIMITER ;
