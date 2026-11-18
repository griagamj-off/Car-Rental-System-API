import logging
import os
from contextlib import contextmanager
from datetime import date
from typing import Iterator

import psycopg
from fastapi import FastAPI, HTTPException, Query
from psycopg.rows import dict_row
from pydantic import BaseModel, Field

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger(__name__)

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/car_rental_db",
)

app = FastAPI(
    title="Car Rental System API",
    description="A teaching demo that delegates business rules to PostgreSQL functions and procedures.",
    version="1.0.0",
)


@contextmanager
def database_connection() -> Iterator[psycopg.Connection]:
    with psycopg.connect(DATABASE_URL, row_factory=dict_row) as connection:
        yield connection


def raise_database_error(error: psycopg.Error) -> None:
    sqlstate = error.sqlstate
    message = (
        error.diag.message_primary
        if error.diag and error.diag.message_primary
        else "Database request failed"
    )
    if sqlstate == "22023":
        raise HTTPException(status_code=400, detail=message) from error
    if sqlstate == "23503":
        raise HTTPException(status_code=404, detail=message) from error
    if sqlstate == "23505":
        raise HTTPException(status_code=409, detail=message) from error
    if sqlstate == "P0001":
        raise HTTPException(status_code=409, detail=message) from error

    logger.exception("Unexpected database error", exc_info=error)
    raise HTTPException(status_code=500, detail="Internal database error") from error


class RentalRequest(BaseModel):
    customer_id: int = Field(gt=0)
    car_id: int = Field(gt=0)
    start_date: date
    end_date: date


class ReturnRequest(BaseModel):
    return_date: date
    payment_method: str = Field(min_length=1, max_length=20)


@app.get("/health")
def health() -> dict[str, str]:
    try:
        with database_connection() as connection:
            connection.execute("SELECT 1")
    except psycopg.Error as error:
        raise_database_error(error)
    return {"status": "ok"}


@app.get("/cars")
def list_cars() -> list[dict]:
    try:
        with database_connection() as connection:
            rows = connection.execute(
                """
                SELECT car_id, make, model, model_year, license_plate, daily_rate, status
                FROM cars ORDER BY car_id
                """
            ).fetchall()
    except psycopg.Error as error:
        raise_database_error(error)
    return rows


@app.get("/rentals/quote")
def quote_rental(
    car_id: int = Query(gt=0),
    start_date: date = Query(),
    end_date: date = Query(),
) -> dict:
    try:
        with database_connection() as connection:
            car = connection.execute(
                "SELECT car_id, make, model, daily_rate FROM cars WHERE car_id = %s",
                (car_id,),
            ).fetchone()
            if car is None:
                raise HTTPException(status_code=404, detail="Car does not exist")
            quote = connection.execute(
                """
                SELECT rental_day_count(%s, %s) AS rental_days,
                       calculate_rental_cost(%s, %s, %s) AS total_cost
                """,
                (start_date, end_date, car["daily_rate"], start_date, end_date),
            ).fetchone()
    except psycopg.Error as error:
        raise_database_error(error)

    return {
        "car_id": car["car_id"],
        "car": f'{car["make"]} {car["model"]}',
        "daily_rate": car["daily_rate"],
        **quote,
    }


@app.post("/rentals", status_code=201)
def create_rental(request: RentalRequest) -> dict:
    try:
        with database_connection() as connection:
            rental_id = connection.execute(
                "CALL book_rental(%s, %s, %s, %s, NULL)",
                (
                    request.customer_id,
                    request.car_id,
                    request.start_date,
                    request.end_date,
                ),
            ).fetchone()["p_rental_id"]
            rental = connection.execute(
                """
                SELECT rental_id, customer_id, car_id, start_date, end_date,
                       total_cost, status, created_at
                FROM rentals WHERE rental_id = %s
                """,
                (rental_id,),
            ).fetchone()
    except psycopg.Error as error:
        raise_database_error(error)
    return rental


@app.post("/rentals/{rental_id}/return")
def return_car(rental_id: int, request: ReturnRequest) -> dict:
    try:
        with database_connection() as connection:
            connection.execute(
                "CALL return_rental(%s, %s, %s)",
                (rental_id, request.return_date, request.payment_method),
            )
            result = connection.execute(
                """
                SELECT r.rental_id, r.status, r.actual_return_date, r.total_cost,
                       p.payment_id, p.amount AS paid_amount, p.payment_method, p.paid_at
                FROM rentals AS r
                JOIN payments AS p ON p.rental_id = r.rental_id
                WHERE r.rental_id = %s
                """,
                (rental_id,),
            ).fetchone()
    except psycopg.Error as error:
        raise_database_error(error)
    return result


@app.post("/rentals/{rental_id}/cancel")
def cancel_rental(rental_id: int) -> dict:
    try:
        with database_connection() as connection:
            connection.execute("CALL cancel_rental(%s)", (rental_id,))
            rental = connection.execute(
                "SELECT rental_id, status FROM rentals WHERE rental_id = %s",
                (rental_id,),
            ).fetchone()
    except psycopg.Error as error:
        raise_database_error(error)
    return rental


@app.get("/rentals/{rental_id}")
def get_rental(rental_id: int) -> dict:
    try:
        with database_connection() as connection:
            rental = connection.execute(
                """
                SELECT r.rental_id, r.customer_id, r.car_id, r.start_date, r.end_date,
                       r.actual_return_date, r.total_cost, r.status,
                       p.payment_id, p.amount AS paid_amount, p.payment_method, p.paid_at
                FROM rentals AS r
                LEFT JOIN payments AS p ON p.rental_id = r.rental_id
                WHERE r.rental_id = %s
                """,
                (rental_id,),
            ).fetchone()
    except psycopg.Error as error:
        raise_database_error(error)
    if rental is None:
        raise HTTPException(status_code=404, detail="Rental does not exist")
    return rental


@app.get("/customers/{customer_id}/spending")
def get_customer_spending(customer_id: int) -> dict:
    try:
        with database_connection() as connection:
            customer = connection.execute(
                "SELECT customer_id, full_name FROM customers WHERE customer_id = %s",
                (customer_id,),
            ).fetchone()
            if customer is None:
                raise HTTPException(status_code=404, detail="Customer does not exist")
            spending = connection.execute(
                "SELECT customer_total_spent(%s) AS total_spent",
                (customer_id,),
            ).fetchone()
    except psycopg.Error as error:
        raise_database_error(error)
    return {**customer, **spending}
