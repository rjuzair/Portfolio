-- =============================================================================
-- 01_schema.sql — tables, keys, constraints and indexes
--
-- Load the modules in order (01 → 07). Every module is idempotent, so the
-- whole set can be re-applied to rebuild the database from scratch.
-- =============================================================================

SET NAMES utf8mb4;
-- Routine variables take the database default charset; keep it equal to the tables'
ALTER DATABASE CHARACTER SET utf8mb4;

SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS audit_log,
                     seat_assignment,
                     payment,
                     creditcard_info,          -- v1 table, replaced by payment
                     contact_info,
                     passenger,
                     reservation,
                     flights_info,
                     weekly_schedule,
                     route,
                     week_day,
                     year,
                     aircraft,
                     airport;
SET FOREIGN_KEY_CHECKS = 1;

-- ---------------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------------

-- IATA airports
CREATE TABLE airport (
  airport_id   CHAR(3)      NOT NULL,
  airport_name VARCHAR(80)  NOT NULL,
  country      VARCHAR(60)  NOT NULL,
  PRIMARY KEY (airport_id),
  CONSTRAINT chk_airport_code CHECK (airport_id COLLATE utf8mb4_bin REGEXP '^[A-Z]{3}$')
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- Aircraft types; the cabin is a grid of seat_rows x seats_per_row (seat 12C)
CREATE TABLE aircraft (
  aircraft_code VARCHAR(10)       NOT NULL,
  model         VARCHAR(60)       NOT NULL,
  seat_rows     TINYINT UNSIGNED  NOT NULL,
  seats_per_row TINYINT UNSIGNED  NOT NULL,
  capacity      SMALLINT UNSIGNED AS (seat_rows * seats_per_row) STORED,
  PRIMARY KEY (aircraft_code),
  CONSTRAINT chk_aircraft_rows  CHECK (seat_rows BETWEEN 1 AND 99),
  CONSTRAINT chk_aircraft_width CHECK (seats_per_row BETWEEN 1 AND 10)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- The original 40-seat cabin is the default for schedules that name no aircraft
INSERT INTO aircraft (aircraft_code, model, seat_rows, seats_per_row)
VALUES ('STD40', 'Standard 40-seat cabin', 10, 4);

-- Yearly profit factor applied to every fare
CREATE TABLE year (
  year         SMALLINT     NOT NULL,
  profitfactor DECIMAL(6,3) NOT NULL,
  PRIMARY KEY (year),
  CONSTRAINT chk_year_range    CHECK (year BETWEEN 2000 AND 2100),
  CONSTRAINT chk_profit_factor CHECK (profitfactor > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- Per-weekday price factor, set per year
CREATE TABLE week_day (
  weekday      VARCHAR(10)  NOT NULL,
  year         SMALLINT     NOT NULL,
  price_factor DECIMAL(6,3) NOT NULL,
  PRIMARY KEY (weekday, year),
  KEY idx_week_day_year (year),
  CONSTRAINT fk_week_day_year FOREIGN KEY (year) REFERENCES year (year),
  CONSTRAINT chk_weekday CHECK (weekday IN ('Monday', 'Tuesday', 'Wednesday', 'Thursday',
                                            'Friday', 'Saturday', 'Sunday')),
  CONSTRAINT chk_price_factor CHECK (price_factor > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- A route between two airports for one year, with its base fare
CREATE TABLE route (
  route_id     INT           NOT NULL AUTO_INCREMENT,
  departure_ap CHAR(3)       NOT NULL,
  arrival_ap   CHAR(3)       NOT NULL,
  year         SMALLINT      NOT NULL,
  price        DECIMAL(10,2) NOT NULL,           -- base fare per seat
  PRIMARY KEY (route_id),
  UNIQUE KEY uq_route (departure_ap, arrival_ap, year),
  KEY idx_route_arrival (arrival_ap),
  KEY idx_route_year (year),
  CONSTRAINT fk_route_departure FOREIGN KEY (departure_ap) REFERENCES airport (airport_id),
  CONSTRAINT fk_route_arrival   FOREIGN KEY (arrival_ap)   REFERENCES airport (airport_id),
  CONSTRAINT fk_route_year      FOREIGN KEY (year)         REFERENCES year (year),
  CONSTRAINT chk_route_distinct CHECK (departure_ap <> arrival_ap),
  CONSTRAINT chk_route_price    CHECK (price > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- A recurring weekly departure on a route
CREATE TABLE weekly_schedule (
  w_id          INT         NOT NULL AUTO_INCREMENT,
  w_route_id    INT         NOT NULL,
  w_year        SMALLINT    NOT NULL,
  weekday       VARCHAR(10) NOT NULL,
  dept          TIME        NOT NULL,
  aircraft_code VARCHAR(10) NOT NULL DEFAULT 'STD40',
  PRIMARY KEY (w_id),
  UNIQUE KEY uq_schedule (w_route_id, weekday, dept),
  KEY idx_schedule_day (weekday, w_year),
  KEY idx_schedule_aircraft (aircraft_code),
  CONSTRAINT fk_schedule_route    FOREIGN KEY (w_route_id)        REFERENCES route (route_id),
  CONSTRAINT fk_schedule_day      FOREIGN KEY (weekday, w_year)   REFERENCES week_day (weekday, year),
  CONSTRAINT fk_schedule_aircraft FOREIGN KEY (aircraft_code)     REFERENCES aircraft (aircraft_code)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- One concrete flight per schedule entry and ISO week.
-- seats_booked is the flight's seat inventory: passengers on CONFIRMED
-- reservations, maintained by trg_reservation_inventory (04_triggers.sql).
-- The CHECK constraint makes overselling impossible whatever code path
-- writes to it.
CREATE TABLE flights_info (
  flight_id      INT               NOT NULL AUTO_INCREMENT,
  flight_ws_id   INT               NOT NULL,
  week           TINYINT UNSIGNED  NOT NULL,
  departure_date DATE              NOT NULL,
  capacity       SMALLINT UNSIGNED NOT NULL,
  seats_booked   SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (flight_id),
  UNIQUE KEY uq_flight (flight_ws_id, week),
  KEY idx_flight_date (departure_date),
  CONSTRAINT fk_flight_schedule FOREIGN KEY (flight_ws_id) REFERENCES weekly_schedule (w_id),
  CONSTRAINT chk_flight_week      CHECK (week BETWEEN 1 AND 53),
  CONSTRAINT chk_flight_inventory CHECK (seats_booked <= capacity)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------------
-- Bookings
-- ---------------------------------------------------------------------------

-- A booking for n passengers on one flight.
-- Lifecycle: PENDING → CONFIRMED (paid) → CANCELLED, or PENDING → EXPIRED.
-- Only CONFIRMED reservations occupy seats.
CREATE TABLE reservation (
  res_no        INT              NOT NULL AUTO_INCREMENT,
  booking_ref   CHAR(6)          NOT NULL,           -- PNR-style public reference
  flight_id     INT              NOT NULL,
  no_passengers SMALLINT UNSIGNED NOT NULL,
  status        VARCHAR(10)      NOT NULL DEFAULT 'PENDING',
  created_at    DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (res_no),
  UNIQUE KEY uq_booking_ref (booking_ref),
  KEY idx_reservation_flight (flight_id, status),
  -- supports the expiry job
  KEY idx_reservation_status_created (status, created_at),
  CONSTRAINT fk_reservation_flight FOREIGN KEY (flight_id) REFERENCES flights_info (flight_id),
  CONSTRAINT chk_reservation_status CHECK (status IN ('PENDING', 'CONFIRMED', 'CANCELLED', 'EXPIRED')),
  CONSTRAINT chk_reservation_size   CHECK (no_passengers >= 1)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE passenger (
  res_no   INT          NOT NULL,
  passp_no VARCHAR(20)  NOT NULL,
  name     VARCHAR(100) NOT NULL,
  ticket   BIGINT       NULL,                      -- issued on payment
  PRIMARY KEY (res_no, passp_no),
  UNIQUE KEY uq_ticket (ticket),
  KEY idx_passenger_passport (passp_no),
  CONSTRAINT fk_passenger_reservation FOREIGN KEY (res_no) REFERENCES reservation (res_no),
  CONSTRAINT chk_passenger_name CHECK (CHAR_LENGTH(TRIM(name)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- Exactly one contact per reservation, who must be one of its passengers
CREATE TABLE contact_info (
  res_no   INT          NOT NULL,
  passp_no VARCHAR(20)  NOT NULL,
  phone    VARCHAR(20)  NOT NULL,
  email    VARCHAR(254) NOT NULL,
  PRIMARY KEY (res_no),
  CONSTRAINT fk_contact_passenger FOREIGN KEY (res_no, passp_no) REFERENCES passenger (res_no, passp_no),
  CONSTRAINT chk_contact_email CHECK (email REGEXP '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'),
  CONSTRAINT chk_contact_phone CHECK (phone REGEXP '^[+]?[0-9][0-9 ()-]{3,19}$')
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- One captured payment per reservation. The card number itself is never
-- stored: only the brand and the last four digits, as a payment provider
-- token would give you.
CREATE TABLE payment (
  payment_id      INT           NOT NULL AUTO_INCREMENT,
  res_no          INT           NOT NULL,
  cardholder_name VARCHAR(100)  NOT NULL,
  card_brand      VARCHAR(12)   NOT NULL,
  card_last4      CHAR(4)       NOT NULL,
  amount          DECIMAL(10,2) NOT NULL,
  refunded_amount DECIMAL(10,2) NOT NULL DEFAULT 0,
  paid_at         DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  refunded_at     DATETIME      NULL,
  PRIMARY KEY (payment_id),
  UNIQUE KEY uq_payment_reservation (res_no),
  CONSTRAINT fk_payment_reservation FOREIGN KEY (res_no) REFERENCES reservation (res_no),
  CONSTRAINT chk_payment_amount CHECK (amount > 0),
  CONSTRAINT chk_payment_refund CHECK (refunded_amount >= 0 AND refunded_amount <= amount),
  CONSTRAINT chk_card_last4     CHECK (card_last4 REGEXP '^[0-9]{4}$')
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- Seat selection. The primary key makes double-assigning a seat impossible,
-- even under concurrent requests.
CREATE TABLE seat_assignment (
  flight_id   INT         NOT NULL,
  seat_no     VARCHAR(4)  NOT NULL,                -- e.g. '12C'
  res_no      INT         NOT NULL,
  passp_no    VARCHAR(20) NOT NULL,
  assigned_at DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (flight_id, seat_no),
  UNIQUE KEY uq_seat_passenger (res_no, passp_no),
  CONSTRAINT fk_seat_flight    FOREIGN KEY (flight_id)        REFERENCES flights_info (flight_id),
  CONSTRAINT fk_seat_passenger FOREIGN KEY (res_no, passp_no) REFERENCES passenger (res_no, passp_no)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------------
-- Audit trail, written by triggers (04_triggers.sql)
-- ---------------------------------------------------------------------------
CREATE TABLE audit_log (
  audit_id   BIGINT      NOT NULL AUTO_INCREMENT,
  table_name VARCHAR(64) NOT NULL,
  record_id  VARCHAR(64) NOT NULL,
  action     VARCHAR(6)  NOT NULL,
  old_data   JSON        NULL,
  new_data   JSON        NULL,
  changed_by VARCHAR(288) NOT NULL,                -- connected account, not the routine definer
  changed_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (audit_id),
  KEY idx_audit_record (table_name, record_id),
  KEY idx_audit_changed_at (changed_at),
  CONSTRAINT chk_audit_action CHECK (action IN ('INSERT', 'UPDATE', 'DELETE'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;
