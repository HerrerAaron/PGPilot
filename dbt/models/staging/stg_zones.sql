-- The raw column is named `zone`; standardized here to `zone_name` for
-- downstream models, since "zone" alone is ambiguous next to "service_zone".
with source as (
    select * from {{ source('taxidb', 'zones') }}
)

select
    location_id,
    borough,
    zone as zone_name,
    service_zone
from source
