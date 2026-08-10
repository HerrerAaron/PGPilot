with trips as (
    select * from {{ ref('stg_trips') }}
)

select
    pickup_date,
    count(*)            as trip_count,
    sum(total_amount)   as total_revenue,
    avg(fare_amount)    as avg_fare,
    avg(trip_distance)  as avg_distance,
    avg(tip_amount)     as avg_tip,
    avg(trip_minutes)   as avg_trip_minutes
from trips
group by pickup_date
order by pickup_date
