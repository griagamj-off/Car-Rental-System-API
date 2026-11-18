-- Car Rental System database setup for PostgreSQL.
-- Run this file once in an empty database named car_rental_db.

CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE,
    driver_license VARCHAR(60) NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE cars (
    car_id SERIAL PRIMARY KEY,
    make VARCHAR(80) NOT NULL,
    model VARCHAR(80) NOT NULL,
    model_year SMALLINT NOT NULL CHECK (model_year BETWEEN 1980 AND 2100),
    license_plate VARCHAR(20) NOT NULL UNIQUE,
    daily_rate NUMERIC(10, 2) NOT NULL CHECK (daily_rate > 0),
    status VARCHAR(20) NOT NULL DEFAULT 'available'
        CHECK (status IN ('available', 'maintenance'))
);

CREATE TABLE rentals (
    rental_id SERIAL PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
    car_id INTEGER NOT NULL REFERENCES cars(car_id),
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,
    actual_return_date DATE,
    total_cost NUMERIC(10, 2) NOT NULL CHECK (total_cost > 0),
    status VARCHAR(20) NOT NULL DEFAULT 'booked'
        CHECK (status IN ('booked', 'completed', 'cancelled')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (end_date >= start_date),
    CHECK (actual_return_date IS NULL OR actual_return_date >= start_date)
);

CREATE INDEX rentals_car_dates_idx ON rentals (car_id, start_date, end_date);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    rental_id INTEGER NOT NULL UNIQUE REFERENCES rentals(rental_id),
    amount NUMERIC(10, 2) NOT NULL CHECK (amount > 0),
    payment_method VARCHAR(20) NOT NULL
        CHECK (payment_method IN ('cash', 'card', 'bank_transfer')),
    paid_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE FUNCTION rental_day_count(p_start_date DATE, p_end_date DATE)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_start_date IS NULL OR p_end_date IS NULL OR p_end_date < p_start_date THEN
        RAISE EXCEPTION 'End date must be on or after start date'
            USING ERRCODE = '22023';
    END IF;

    RETURN p_end_date - p_start_date + 1;
END;
$$;

CREATE FUNCTION calculate_rental_cost(
    p_daily_rate NUMERIC,
    p_start_date DATE,
    p_end_date DATE
)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_daily_rate IS NULL OR p_daily_rate <= 0 THEN
        RAISE EXCEPTION 'Daily rate must be greater than zero'
            USING ERRCODE = '22023';
    END IF;

    RETURN ROUND(p_daily_rate * rental_day_count(p_start_date, p_end_date), 2);
END;
$$;

CREATE FUNCTION customer_total_spent(p_customer_id INTEGER)
RETURNS NUMERIC(12, 2)
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(SUM(p.amount), 0)::NUMERIC(12, 2)
    FROM payments AS p
    JOIN rentals AS r ON r.rental_id = p.rental_id
    WHERE r.customer_id = p_customer_id;
$$;

CREATE PROCEDURE book_rental(
    IN p_customer_id INTEGER,
    IN p_car_id INTEGER,
    IN p_start_date DATE,
    IN p_end_date DATE,
    INOUT p_rental_id INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_daily_rate NUMERIC(10, 2);
    v_car_status VARCHAR(20);
    v_total_cost NUMERIC(10, 2);
BEGIN
    IF p_start_date IS NULL OR p_end_date IS NULL OR p_end_date < p_start_date THEN
        RAISE EXCEPTION 'End date must be on or after start date'
            USING ERRCODE = '22023';
    END IF;

    PERFORM 1 FROM customers WHERE customer_id = p_customer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Customer % does not exist', p_customer_id
            USING ERRCODE = '23503';
    END IF;

    SELECT daily_rate, status
    INTO v_daily_rate, v_car_status
    FROM cars
    WHERE car_id = p_car_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Car % does not exist', p_car_id
            USING ERRCODE = '23503';
    END IF;
    IF v_car_status <> 'available' THEN
        RAISE EXCEPTION 'Car % is not available for rental', p_car_id
            USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM rentals
        WHERE car_id = p_car_id
          AND status IN ('booked', 'completed')
          AND start_date <= p_end_date
          AND end_date >= p_start_date
    ) THEN
        RAISE EXCEPTION 'Car % already has a rental during those dates', p_car_id
            USING ERRCODE = 'P0001';
    END IF;

    v_total_cost := calculate_rental_cost(v_daily_rate, p_start_date, p_end_date);

    INSERT INTO rentals (customer_id, car_id, start_date, end_date, total_cost)
    VALUES (p_customer_id, p_car_id, p_start_date, p_end_date, v_total_cost)
    RETURNING rental_id INTO p_rental_id;
END;
$$;

CREATE PROCEDURE return_rental(
    IN p_rental_id INTEGER,
    IN p_return_date DATE,
    IN p_payment_method VARCHAR(20)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rental rentals%ROWTYPE;
BEGIN
    IF p_return_date IS NULL THEN
        RAISE EXCEPTION 'Return date is required' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_rental
    FROM rentals
    WHERE rental_id = p_rental_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Rental % does not exist', p_rental_id
            USING ERRCODE = '23503';
    END IF;
    IF v_rental.status <> 'booked' THEN
        RAISE EXCEPTION 'Only a booked rental can be returned'
            USING ERRCODE = 'P0001';
    END IF;
    IF p_return_date < v_rental.start_date THEN
        RAISE EXCEPTION 'Return date cannot be before the rental start date'
            USING ERRCODE = '22023';
    END IF;

    UPDATE rentals
    SET status = 'completed', actual_return_date = p_return_date
    WHERE rental_id = p_rental_id;

    IF p_payment_method IS NULL
       OR p_payment_method NOT IN ('cash', 'card', 'bank_transfer') THEN
        RAISE EXCEPTION 'Payment method must be cash, card, or bank_transfer'
            USING ERRCODE = '22023';
    END IF;

    INSERT INTO payments (rental_id, amount, payment_method)
    VALUES (p_rental_id, v_rental.total_cost, p_payment_method);
END;
$$;

CREATE PROCEDURE cancel_rental(IN p_rental_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rental rentals%ROWTYPE;
BEGIN
    SELECT * INTO v_rental
    FROM rentals
    WHERE rental_id = p_rental_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Rental % does not exist', p_rental_id
            USING ERRCODE = '23503';
    END IF;
    IF v_rental.status <> 'booked' THEN
        RAISE EXCEPTION 'Only a booked rental can be cancelled'
            USING ERRCODE = 'P0001';
    END IF;
    IF v_rental.start_date <= CURRENT_DATE THEN
        RAISE EXCEPTION 'A rental can only be cancelled before its start date'
            USING ERRCODE = 'P0001';
    END IF;

    UPDATE rentals SET status = 'cancelled' WHERE rental_id = p_rental_id;
END;
$$;

INSERT INTO customers (full_name, email, driver_license) VALUES
    ('Jordan Lee', 'jordan.lee@example.com', 'DL-CA-10001'),
    ('Taylor Morgan', 'taylor.morgan@example.com', 'DL-CA-10002');

INSERT INTO cars (make, model, model_year, license_plate, daily_rate, status) VALUES
    ('Toyota', 'Corolla', 2024, 'CRS-1001', 55.00, 'available'),
    ('Honda', 'Civic', 2023, 'CRS-1002', 62.50, 'available'),
    ('Ford', 'Escape', 2022, 'CRS-1003', 78.00, 'maintenance');
