# Metrics inventory

Source: `{job="orders-api"}`

28 metric names in 26 families, 60 series.

| Declared type | Families |
| --- | --- |
| counter | 8 |
| gauge | 12 |
| histogram | 1 |
| unknown | 5 |

21 of the 28 names did not change on any series in the last 30m.

## orders_api (13)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `orders_api_db_ready` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `orders_api_http_request_seconds_bucket` | histogram | 22 | 22 | 2 | component (1), le (11), method (1), route (3), server (2) | a distribution: a percentile from its buckets, across instances |
| `orders_api_http_request_seconds_count` | histogram | 2 | 2 | 2 | component (1), method (1), route (3), server (2) | a distribution: a percentile from its buckets, across instances |
| `orders_api_http_request_seconds_created` | gauge | 2 | 0 | 2 | component (1), method (1), route (3), server (2) | constant, differing by series: a table or sorted bars, not a line |
| `orders_api_http_request_seconds_sum` | histogram | 2 | 2 | 2 | component (1), method (1), route (3), server (2) | a distribution: a percentile from its buckets, across instances |
| `orders_api_http_requests_created` | gauge | 2 | 0 | 2 | component (1), method (1), route (3), server (2), status (1) | constant, differing by series: a table or sorted bars, not a line |
| `orders_api_http_requests_total` | counter | 2 | 2 | 2 | component (1), method (1), route (3), server (2), status (1) | a counter: its rate over time; never the raw number |
| `orders_api_orders_created_created` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `orders_api_orders_created_total` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `orders_api_orders_replayed_created` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `orders_api_orders_replayed_total` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `orders_api_sweep_republish_created` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `orders_api_sweep_republish_total` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |

## process_cpu (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `process_cpu_seconds_total` | counter | 1 | 1 | 1 | component (1) | a counter: its rate over time; never the raw number |

## process_max (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `process_max_fds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## process_open (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `process_open_fds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## process_resident (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `process_resident_memory_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## process_start (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `process_start_time_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## process_virtual (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `process_virtual_memory_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## python_gc (3)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `python_gc_collections_total` | counter | 3 | 0 | 3 | component (1), generation (3) | a counter: its rate over time; never the raw number |
| `python_gc_objects_collected_total` | counter | 3 | 0 | 3 | component (1), generation (3) | a counter: its rate over time; never the raw number |
| `python_gc_objects_uncollectable_total` | counter | 3 | 0 | 1 | component (1), generation (3) | a counter: its rate over time; never the raw number |

## python_info (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `python_info` | gauge | 1 | 0 | 1 | component (1), implementation (1), major (1), minor (1), patchlevel (1), version (1) | facts as labels: a table |

## scrape_duration (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `scrape_duration_seconds` | unknown | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |

## scrape_samples (2)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `scrape_samples_post_metric_relabeling` | unknown | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `scrape_samples_scraped` | unknown | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## scrape_series (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `scrape_series_added` | unknown | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |

## up (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `up` | unknown | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
