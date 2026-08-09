with trips as (
    select * from {{ ref('stg_trips') }}
),

zones as (
    select * from {{ ref('stg_zones') }}
)

select
    z.location_id,
    z.borough,
    z.zone_name,
    count(*)             as trip_count,
    sum(t.total_amount)  as total_revenue,
    avg(t.fare_amount)   as avg_fare,
    avg(t.trip_distance) as avg_distance
from trips t
inner join zones z
    on t.pickup_location_id = z.location_id
group by z.location_id, z.borough, z.zone_name
order by total_revenue desc
