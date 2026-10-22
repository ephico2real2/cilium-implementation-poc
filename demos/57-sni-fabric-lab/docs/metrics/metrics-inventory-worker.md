# Metrics inventory

Source: `{job="worker"}`

24 metric names in 19 families, 46 series.

| Declared type | Families |
| --- | --- |
| counter | 6 |
| gauge | 7 |
| histogram | 1 |
| unknown | 5 |

22 of the 24 names did not change on any series in the last 30m.

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
| `scrape_series_added` | unknown | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## up (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `up` | unknown | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## worker_get (2)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `worker_get_errors_created` | counter | 4 | 0 | 4 | component (1), reason (4) | a counter: its rate over time; never the raw number |
| `worker_get_errors_total` | counter | 4 | 0 | 4 | component (1), reason (4) | a counter: its rate over time; never the raw number |

## worker_last (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `worker_last_event_timestamp_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## worker_messages (2)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `worker_messages_created` | counter | 1 | 0 | 1 | component (1), result (1) | a counter: its rate over time; never the raw number |
| `worker_messages_total` | counter | 1 | 0 | 1 | component (1), result (1) | a counter: its rate over time; never the raw number |

## worker_status (4)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `worker_status_update_seconds_bucket` | histogram | 11 | 0 | 2 | component (1), le (11) | a distribution: a percentile from its buckets, across instances |
| `worker_status_update_seconds_count` | histogram | 1 | 0 | 1 | component (1) | a distribution: a percentile from its buckets, across instances |
| `worker_status_update_seconds_created` | histogram | 1 | 0 | 1 | component (1) | a distribution: a percentile from its buckets, across instances |
| `worker_status_update_seconds_sum` | histogram | 1 | 0 | 1 | component (1) | a distribution: a percentile from its buckets, across instances |
