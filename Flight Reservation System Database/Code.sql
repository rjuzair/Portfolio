-- Disable foreign key checks for safe dropping of tables
SET FOREIGN_KEY_CHECKS = 0;

-- Drop existing tables to avoid conflicts when creating new ones
DROP TABLE IF EXISTS flights_info, 
             contact_info, 
             passenger, 
             creditcard_info, 
             reservation, 
             weekly_schedule, 
             week_day, 
             route, 
             airport, 
             year;

-- Drop existing procedures if they exist
DROP PROCEDURE IF EXISTS addReservation;
DROP PROCEDURE IF EXISTS addPassenger;
DROP PROCEDURE IF EXISTS addContact;
DROP PROCEDURE IF EXISTS addPayment;
DROP PROCEDURE IF EXISTS addYear;
DROP PROCEDURE IF EXISTS addDay;
DROP PROCEDURE IF EXISTS addDestination;
DROP PROCEDURE IF EXISTS addRoute;
DROP PROCEDURE IF EXISTS addFlight;

-- Drop existing functions
DROP FUNCTION IF EXISTS calculateFreeSeats;
DROP FUNCTION IF EXISTS calculatePrice;

-- Drop existing views
DROP VIEW IF EXISTS allFlights;

-- Re-enable foreign key checks
SET FOREIGN_KEY_CHECKS = 1;

############# TABLES ##############################################

-- Table to store airport information
CREATE TABLE airport (
  airport_id VARCHAR(3),            -- Unique identifier for the airport
  country VARCHAR(30),              -- Country where the airport is located
  airport_name VARCHAR(30),         -- Name of the airport
  PRIMARY KEY (airport_id)          -- Setting airport_id as the primary key
);

-- Table to store route information
CREATE TABLE route (
  route_id INTEGER AUTO_INCREMENT,  -- Unique route identifier
  departure_ap VARCHAR(3),          -- Departure airport code
  arrival_ap VARCHAR(3),            -- Arrival airport code
  year INTEGER,                     -- Year of operation
  price DOUBLE,                     -- Price for the route
  PRIMARY KEY (route_id)            -- Setting route_id as the primary key
  -- Foreign keys will be added after all table creations
);

-- Table to store weekly schedule information
CREATE TABLE weekly_schedule (
  w_id INTEGER AUTO_INCREMENT,       -- Unique identifier for weekly schedule
  w_route_id INTEGER,                -- Route identifier
  w_year INTEGER,                    -- Year of the flight
  weekday VARCHAR(10),               -- Day of the week
  dept TIME,                         -- Departure time
  PRIMARY KEY (w_id)                 -- Setting w_id as the primary key
);

-- Table to store profit factors by year
CREATE TABLE year (
  year INTEGER,                      -- Year
  profitfactor DOUBLE,               -- Profit factor for the year
  PRIMARY KEY (year)                 -- Setting year as the primary key
);

-- Table to store weekday pricing factors
CREATE TABLE week_day (
  weekday VARCHAR(10),               -- Day of the week
  price_factor DOUBLE,               -- Price factor for that day
  year INTEGER,                      -- Year for the price factor
  PRIMARY KEY (weekday, year)        -- Composite primary key
);

-- Table to store flight information
CREATE TABLE flights_info (
  flight_id INTEGER AUTO_INCREMENT,  -- Unique flight identifier
  flight_ws_id INTEGER,              -- Weekly schedule ID
  week INTEGER,                      -- Week number of the flight
  PRIMARY KEY (flight_id)            -- Setting flight_id as the primary key
);

-- Table to store reservation information
CREATE TABLE reservation (
  res_no INTEGER AUTO_INCREMENT,     -- Unique reservation number
  flight_id INTEGER,                 -- Flight identifier associated with the reservation
  no_passengers INTEGER,             -- Number of passengers in the reservation
  PRIMARY KEY (res_no)               -- Setting res_no as the primary key
);

-- Table to store passenger information
CREATE TABLE passenger (
  passp_no INTEGER,                  -- Unique passenger number
  name VARCHAR(30),                  -- Passenger's name
  res_no INTEGER,                    -- Reservation number
  ticket INTEGER,                    -- Ticket number
  PRIMARY KEY (passp_no, res_no)     -- Composite primary key
);

-- Table to store contact information
CREATE TABLE contact_info ( 
  res_no INTEGER,                    -- Reservation number
  passp_no INTEGER,                  -- Passenger number
  phone BIGINT,                      -- Phone number of the passenger
  email VARCHAR(30),                 -- Email address of the passenger
  PRIMARY KEY (passp_no, res_no)     -- Composite primary key
);

-- Table to store credit card information
CREATE TABLE creditcard_info (
  card_no BIGINT,                   -- Credit card number
  name VARCHAR(40),                 -- Name on the credit card
  amount INTEGER,                   -- Amount charged to the credit card
  res_no INTEGER,                   -- Reservation number
  PRIMARY KEY (res_no)               -- Setting res_no as the primary key
);

-- Adding foreign key constraints for data integrity
ALTER TABLE route
  ADD CONSTRAINT fk_departure_ap FOREIGN KEY (departure_ap) REFERENCES airport(airport_id),
  ADD CONSTRAINT fk_arrival_ap FOREIGN KEY (arrival_ap) REFERENCES airport(airport_id);

ALTER TABLE weekly_schedule
  ADD CONSTRAINT fk_weekd_ay FOREIGN KEY (weekday, w_year) REFERENCES week_day(weekday, year),
  ADD CONSTRAINT fk_route_id1 FOREIGN KEY (w_route_id) REFERENCES route(route_id);

ALTER TABLE flights_info
  ADD CONSTRAINT fk_flight_ws_id FOREIGN KEY (flight_ws_id) REFERENCES weekly_schedule(w_id);

ALTER TABLE reservation
  ADD CONSTRAINT fk_flight_id FOREIGN KEY (flight_id) REFERENCES flights_info(flight_id);

ALTER TABLE passenger
  ADD CONSTRAINT fk_res_no FOREIGN KEY (res_no) REFERENCES reservation(res_no);

ALTER TABLE contact_info
  ADD CONSTRAINT fk_passp_no FOREIGN KEY (passp_no) REFERENCES passenger(passp_no),
  ADD CONSTRAINT fk_res_no1 FOREIGN KEY (res_no) REFERENCES reservation(res_no);

ALTER TABLE creditcard_info
  ADD CONSTRAINT fk_res_no2 FOREIGN KEY (res_no) REFERENCES reservation(res_no);

################ Procedures #############

-- Change delimiter to allow for procedure creation
DELIMITER //

-- Procedure to add a new year to the year table
CREATE PROCEDURE addYear(
    IN p_year INT, 
    IN p_factor DOUBLE
)
BEGIN
    INSERT INTO year(year, profitfactor)
    VALUES (p_year, p_factor);
END //

-- Procedure to add a new day to the week_day table
CREATE PROCEDURE addDay(
    IN p_year INT, 
    IN p_day VARCHAR(10), 
    IN p_factor DOUBLE
)
BEGIN
    INSERT INTO week_day(year, weekday, price_factor)
    VALUES (p_year, p_day, p_factor);
END //

-- Procedure to add a new destination (airport) to the airport table
CREATE PROCEDURE addDestination(
    IN p_airport_code VARCHAR(3), 
    IN p_name VARCHAR(30), 
    IN p_country VARCHAR(30)
)
BEGIN
    INSERT INTO airport(airport_id, airport_name, country)
    VALUES (p_airport_code, p_name, p_country);
END //

-- Procedure to add a new route to the route table
CREATE PROCEDURE addRoute(
    IN p_airport_code_dept VARCHAR(3),
    IN p_airport_code_dest VARCHAR(3),
    IN p_year INT,
    IN p_routeprice DOUBLE
)
BEGIN
    INSERT INTO route(departure_ap, arrival_ap, year, price)
    VALUES (p_airport_code_dept, p_airport_code_dest, p_year, p_routeprice);
END //

-- Procedure to add a new flight to the flights_info and weekly_schedule tables
CREATE PROCEDURE addFlight(
    IN dep VARCHAR(3),
    IN arr VARCHAR(3),
    IN yr INT,
    IN wday VARCHAR(10),
    IN time TIME
)
BEGIN
    DECLARE rid INT;  -- Route ID
    DECLARE wid INT;  -- Weekly Schedule ID
    DECLARE i INT DEFAULT 1;  -- Week counter

    -- Find the route ID based on departure and arrival airports
    SELECT route_id INTO rid 
    FROM route 
    WHERE departure_ap = dep AND arrival_ap = arr AND year = yr;

    -- Insert new entry into the weekly schedule
    INSERT INTO weekly_schedule(dept, w_route_id, w_year, weekday)
    VALUES (time, rid, yr, wday);

    -- Retrieve the ID of the newly inserted weekly schedule entry
    SELECT w_id INTO wid 
    FROM weekly_schedule 
    WHERE dept = time AND w_route_id = rid AND w_year = yr AND weekday = wday
    ORDER BY w_id DESC
    LIMIT 1;

    -- Insert weekly flights for the year
    REPEAT
        INSERT INTO flights_info(flight_ws_id, week)
        VALUES (wid, i);
        SET i = i + 1;  -- Increment week counter
    UNTIL i > 52  -- Repeat for all weeks of the year
    END REPEAT;
END //
DELIMITER ;

##################### FUNCTIONS ############################

-- Change delimiter to allow for function creation
DELIMITER //

-- Function to calculate the number of free seats for a given flight
CREATE FUNCTION calculateFreeSeats(flightnum INT)
RETURNS INT
BEGIN
    DECLARE totalCapacity INT DEFAULT 40;  -- Total capacity of the flight
    DECLARE bookedSeats INT;                -- Variable to hold booked seats count

    -- Calculate total booked seats for the flight
    SELECT SUM(r.no_passengers) INTO bookedSeats 
    FROM reservation r
    WHERE r.flight_id = flightnum;

    -- Handle case where no seats are booked
    IF bookedSeats IS NULL THEN
        SET bookedSeats = 0;  -- No seats booked
    END IF;

    -- Return the number of free seats
    RETURN totalCapacity - bookedSeats;
END //

-- Function to calculate the current price of a flight based on various factors
CREATE FUNCTION calculatePrice(flightnum INT)
RETURNS DOUBLE
BEGIN
    DECLARE finalPrice DOUBLE;  -- Variable to hold the final price

    -- Calculate final price based on various parameters
    SELECT r.price * wd.price_factor * y.profitfactor * ((IFNULL(SUM(p.ticket IS NOT NULL), 0) + 1) / 40)
    INTO finalPrice
    FROM flights_info fi
    JOIN weekly_schedule ws ON fi.flight_ws_id = ws.w_id
    JOIN route r ON ws.w_route_id = r.route_id
    JOIN week_day wd ON ws.weekday = wd.weekday
    JOIN year y ON ws.w_year = y.year
    LEFT JOIN reservation res ON fi.flight_id = res.flight_id
    LEFT JOIN passenger p ON res.res_no = p.res_no
    WHERE fi.flight_id = flightnum
    GROUP BY r.route_id, wd.weekday, y.year;

    -- Return the final calculated price
    RETURN finalPrice;
END //
DELIMITER ;

##################### TRIGGER ####################
-- Change delimiter to allow for trigger creation
DELIMITER //

-- Trigger to generate a ticket number after inserting credit card info
CREATE TRIGGER ticketgenerator
AFTER INSERT ON creditcard_info
FOR EACH ROW
BEGIN 
    UPDATE passenger p
    SET p.ticket = FLOOR(RAND() * 100000)  -- Generate a random ticket number
    WHERE p.res_no = NEW.res_no;           -- Update the relevant passenger
END //
DELIMITER ;

############ Procedures ##################

-- Change delimiter to allow for procedure creation
DELIMITER //

-- Procedure to add a reservation
CREATE PROCEDURE addreservation(
    IN deptcode VARCHAR(3),  -- Departure airport code
    IN arrcode VARCHAR(3),   -- Arrival airport code
    IN yr INT,               -- Year of flight
    IN wk INT,               -- Week number of flight
    IN day VARCHAR(10),      -- Day of the week
    IN depttime TIME,        -- Departure time
    IN numpass INT,          -- Number of passengers
    OUT resnum INT)          -- Output variable for reservation number
BEGIN
    DECLARE flightid INT;    -- Variable to hold flight ID
    DECLARE newresno INT;    -- Variable to hold new reservation number
    SET flightid = NULL;     -- Initialize flight ID

    -- Find the flight ID based on provided parameters
    SELECT fi.flight_id INTO flightid 
    FROM flights_info fi
    JOIN weekly_schedule ws ON fi.flight_ws_id = ws.w_id
    JOIN route r ON ws.w_route_id = r.route_id
    WHERE ws.w_year = yr AND ws.weekday = day 
      AND ws.dept = depttime AND r.departure_ap = deptcode
      AND r.arrival_ap = arrcode AND fi.week = wk;

    -- Check if there are enough free seats
    IF numpass > calculateFreeSeats(flightid) THEN
        SELECT 'There are not enough seats available on the chosen flight' AS message;
    ELSEIF flightid IS NULL THEN
        SELECT 'There exist no flight for the given route, date and time' AS message;
    ELSE
        -- Insert new reservation
        INSERT INTO reservation(flight_id, no_passengers)
        VALUES (flightid, numpass);
        SELECT LAST_INSERT_ID() INTO newresno;  -- Get the new reservation number
        SET resnum = newresno;                  -- Set the output parameter
    END IF;
END //

-- Procedure to add a passenger to a reservation
CREATE PROCEDURE addpassenger(
    IN resnr INT,            -- Reservation number
    IN passportnr INT,       -- Passport number of the passenger
    IN name VARCHAR(30)      -- Name of the passenger
)
BEGIN
    DECLARE maxpass INT;     -- Maximum number of passengers for the reservation
    DECLARE bookedpass INT;  -- Count of booked passengers
    DECLARE paid INT;        -- Count of paid reservations
    SET paid = NULL;         -- Initialize paid count
    SET maxpass = NULL;      -- Initialize maximum passengers count

    -- Get the maximum number of passengers for the reservation
    SELECT no_passengers INTO maxpass FROM reservation WHERE res_no = resnr;
    -- Count the number of booked passengers
    SELECT COUNT(res_no) INTO bookedpass FROM passenger WHERE res_no = resnr;
    -- Count the number of paid reservations
    SELECT COUNT(res_no) INTO paid FROM creditcard_info WHERE res_no = resnr;

    -- Validate reservation and booking conditions
    IF maxpass IS NULL THEN
        SELECT 'The reservation number does not exist';
    ELSEIF maxpass <= bookedpass THEN
        SELECT 'There are not enough seats available on the flight anymore, deleting reservation"' AS message;
    ELSEIF paid = 1 THEN
        SELECT 'The booking has already paid, no further passengers can be added' AS message;
    ELSE
        -- Insert new passenger
        INSERT INTO passenger(res_no, passp_no, name)
        VALUES (resnr, passportnr, name);
    END IF;
END //

-- Procedure to add contact information for a passenger
CREATE PROCEDURE addcontact(
    IN resnr INT,               -- Reservation number
    IN passportnr INT,          -- Passport number of the passenger
    IN email VARCHAR(30),       -- Email of the passenger
    IN phone BIGINT)            -- Phone number of the passenger
BEGIN
    DECLARE resvalid INT;       -- Validity check for reservation number
    DECLARE passvalid INT;      -- Validity check for passenger number

    -- Validate reservation number
    SELECT COUNT(*) INTO resvalid 
    FROM reservation 
    WHERE res_no = resnr;

    -- Validate passenger number
    SELECT COUNT(*) INTO passvalid 
    FROM passenger 
    WHERE passp_no = passportnr AND res_no = resnr;

    -- Check for validity and insert contact information
    IF resvalid = 0 THEN
        SELECT 'The given reservation number does not exist' AS message;
    ELSEIF passvalid = 0  THEN
        SELECT 'The person is not a passenger of the reservation' AS message;
    ELSE
        -- Insert contact information
        INSERT INTO contact_info(res_no, passp_no, phone, email)
        VALUES (resnr, passportnr, phone, email);
    END IF;
END //

-- Procedure to process payment for a reservation
CREATE PROCEDURE addpayment(
    IN resnr INT,              -- Reservation number
    IN cardname VARCHAR(30),   -- Name on the credit card
    IN cardnum BIGINT)         -- Credit card number
BEGIN
    DECLARE cost DOUBLE;       -- Cost of the flight
    DECLARE flightid INT;      -- Flight ID associated with the reservation
    DECLARE contactcount INT;  -- Count of contact info entries
    DECLARE numpass INT;       -- Number of passengers in the reservation

    -- Get flight ID and number of passengers for the reservation
    SELECT flight_id, no_passengers INTO flightid, numpass 
    FROM reservation 
    WHERE res_no = resnr;

    -- Calculate cost if flight ID is valid
    IF flightid IS NOT NULL THEN
        SET cost = calculatePrice(flightid);
    END IF;

    -- Count the number of contact information entries
    SELECT COUNT(*) INTO contactcount 
    FROM contact_info 
    WHERE res_no = resnr;

    -- Validate conditions before processing payment
    IF flightid IS NULL THEN
        SELECT 'The given reservation number does not exist' AS message;
    ELSEIF numpass > calculateFreeSeats(flightid) THEN
        SELECT 'The flight is fully booked, payment declined.' AS message;
    ELSEIF contactcount = 0 THEN
        SELECT 'The reservation has no contact yet' AS message;
    ELSE
        -- Insert payment information
        INSERT INTO creditcard_info(card_no, name, amount, res_no)
        VALUES(cardnum, cardname, cost, resnr);
    END IF;
END //

-- Change delimiter to allow for view creation
DELIMITER ;

-- Create a view to display all flights with relevant details
CREATE VIEW allFlights AS
SELECT 
    departure_airport.airport_name AS departure_city_name,   -- Departure city name
    arrival_airport.airport_name AS destination_city_name,    -- Destination city name
    weekly_schedule.dept AS departure_time,                   -- Departure time
    weekly_schedule.weekday AS departure_day,                 -- Day of the week
    flights_info.week AS departure_week,                      -- Week number
    weekly_schedule.w_year AS departure_year,                 -- Year of flight
    calculateFreeSeats(flights_info.flight_id) AS nr_of_free_seats, -- Number of free seats
    calculatePrice(flights_info.flight_id) AS current_price_per_seat -- Current price per seat
FROM 
    flights_info
    JOIN weekly_schedule ON flights_info.flight_ws_id = weekly_schedule.w_id
    JOIN route ON weekly_schedule.w_route_id = route.route_id
    JOIN airport AS departure_airport ON route.departure_ap = departure_airport.airport_id
    JOIN airport AS arrival_airport ON route.arrival_ap = arrival_airport.airport_id
ORDER BY 
    weekly_schedule.w_year,      -- Sort by year
    flights_info.week;           -- Then by week
