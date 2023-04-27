-- Define the `session` CTE
with session as (
    select
        user_id,
        dt_request,
        lag(dt_request, 1) over (partition by user_id order by dt_request) as last_event
    from {{ ref('stage.core_useractivitylog') }}
),

-- Define the `session_time` CTE
session_time as (
    select
        user_id,
        dt_request,
        last_event,
        case
            when extract('EPOCH' from dt_request) - extract('EPOCH' from last_event) >= (60 * 30) or last_event is null
            then 1
            else 0
        end as is_new_session
    from session
),

-- Define the `session_duration` CTE
session_duration as (
    select
        user_id,
        dt_request,
        sum(is_new_session) over (order by user_id, dt_request) as global_session_id,
        sum(is_new_session) over (partition by user_id order by dt_request) as user_session_id,
        dt_request::date - min(dt_request::date) over(partition by user_id) as act_days
    from session_time
),

-- Define the `session_sum_ungrouped` CTE
session_sum_ungrouped as (
    select
        sd.user_id,
        user_session_id,
        global_session_id,
        max(dt_request) - min(dt_request) as duration,
        max(dt_request + (interval '1 minute')) as logout,
        min(dt_request - (interval '1 minute')) as login,
        act_days
    from session_duration as sd
    group by sd.user_id
            , user_session_id
            , global_session_id
            , act_days
),

-- Define the `session_sum` CTE
session_sum as (
    select
        user_id,
        user_session_id,
        global_session_id,
        sum(duration) as duration,
        max(logout) as logout,
        min(login) as login,
        max(act_days) as act_days
    from session_sum_ungrouped
    group by user_id
        , user_session_id
        , global_session_id
),

-- Define the final query

select
    dbt_utils.surrogate_key([user_id, user_session_id)] AS session_surrogate_key
    user_id,
    user_session_id,
    row_number() over(partition by sd.user_id, login::date order by user_session_id) as daily_logins,
    global_session_id,
    (extract('HOUR' from duration) * 60 + extract('MINUTE' from duration) + extract('SECOND' from duration) / 60) as duration,
    login,
    logout
    --, rest of our surrogate keys to join with dim_tables
from session_sum 
group by sd.user_id
      , user_session_id
      , global_session_id
      , duration
      , login
      , logout

