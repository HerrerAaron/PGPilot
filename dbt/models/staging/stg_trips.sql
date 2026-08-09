-- Standardize the already-cleaned trips table and add light derivations.
with source as (
    select * from {{ source('taxidb', 'trips') }}
)

select
    trip_id,
    pickup_location_id,
    dropoff_location_id,
    pickup_datetime,
    dropoff_datetime,
    passenger_count,
    trip_distance,
    fare_amount,
    tip_amount,
    total_amount,
    payment_type,
    date(pickup_datetime)                                          as pickup_date,
    extract(epoch from (dropoff_datetime - pickup_datetime)) / 60.0 as trip_minutes
from source
