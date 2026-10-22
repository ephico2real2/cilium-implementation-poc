# Metrics inventory

Source: `{job="tcp-svc"}`

22 metric names in 19 families, 44 series.

| Declared type | Families |
| --- | --- |
| counter | 7 |
| gauge | 7 |
| unknown | 5 |

20 of the 22 names did not change on any series in the last 30m.

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
| `python_gc_objects_collected_total` | counter | 3 | 0 | 2 | component (1), generation (3) | a counter: its rate over time; never the raw number |
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

## tcp_svc (7)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `tcp_svc_active_connections` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `tcp_svc_commands_created` | counter | 6 | 0 | 6 | command (6), component (1) | a counter: its rate over time; never the raw number |
| `tcp_svc_commands_total` | counter | 6 | 0 | 2 | command (6), component (1) | a counter: its rate over time; never the raw number |
| `tcp_svc_connections_closed_created` | counter | 4 | 0 | 4 | component (1), reason (4) | a counter: its rate over time; never the raw number |
| `tcp_svc_connections_closed_total` | counter | 4 | 0 | 2 | component (1), reason (4) | a counter: its rate over time; never the raw number |
| `tcp_svc_connections_created` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `tcp_svc_connections_total` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |

## up (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `up` | unknown | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
