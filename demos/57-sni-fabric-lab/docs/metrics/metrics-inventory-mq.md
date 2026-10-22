# Metrics inventory

Source: `{job="mq"}`

135 metric names in 133 families, 141 series.

| Declared type | Families |
| --- | --- |
| counter | 67 |
| gauge | 60 |
| summary | 1 |
| unknown | 5 |

91 of the 135 names did not change on any series in the last 30m.

## go_gc (5)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `go_gc_duration_seconds` | summary | 5 | 3 | 5 | component (1), quantile (5) | a summary: an average from _sum over_count; its own quantiles do not combine across instances |
| `go_gc_duration_seconds_count` | summary | 1 | 1 | 1 | component (1) | a summary: an average from _sum over_count; its own quantiles do not combine across instances |
| `go_gc_duration_seconds_sum` | summary | 1 | 1 | 1 | component (1) | a summary: an average from _sum over_count; its own quantiles do not combine across instances |
| `go_gc_gogc_percent` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `go_gc_gomemlimit_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## go_goroutines (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `go_goroutines` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |

## go_info (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `go_info` | gauge | 1 | 0 | 1 | component (1), version (1) | facts as labels: a table |

## go_memstats (22)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `go_memstats_alloc_bytes` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `go_memstats_alloc_bytes_total` | counter | 1 | 1 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `go_memstats_buck_hash_sys_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `go_memstats_frees_total` | counter | 1 | 1 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `go_memstats_gc_sys_bytes` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `go_memstats_heap_alloc_bytes` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `go_memstats_heap_idle_bytes` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `go_memstats_heap_inuse_bytes` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `go_memstats_heap_objects` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `go_memstats_heap_released_bytes` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `go_memstats_heap_sys_bytes` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `go_memstats_last_gc_time_seconds` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `go_memstats_mallocs_total` | counter | 1 | 1 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `go_memstats_mcache_inuse_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `go_memstats_mcache_sys_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `go_memstats_mspan_inuse_bytes` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `go_memstats_mspan_sys_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `go_memstats_next_gc_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `go_memstats_other_sys_bytes` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `go_memstats_stack_inuse_bytes` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `go_memstats_stack_sys_bytes` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `go_memstats_sys_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## go_sched (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `go_sched_gomaxprocs_threads` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## go_threads (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `go_threads` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## ibmmq_qmgr (88)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `ibmmq_qmgr_commit_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_cpu_load_fifteen_minute_average_percentage` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_cpu_load_five_minute_average_percentage` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_cpu_load_one_minute_average_percentage` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_destructive_get_bytes_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_destructive_get_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_durable_subscription_alter_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_durable_subscription_create_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_durable_subscription_delete_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_durable_subscription_resume_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_errors_file_system_free_space_percentage` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_errors_file_system_in_use_bytes` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_expired_message_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_failed_browse_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_failed_mqcb_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_failed_mqclose_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_failed_mqconn_mqconnx_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_failed_mqget_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_failed_mqinq_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_failed_mqopen_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_failed_mqput1_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_failed_mqput_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_failed_mqset_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_failed_mqsubrq_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_failed_subscription_create_alter_resume_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_failed_subscription_delete_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_failed_topic_mqput_mqput1_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_fdc_files` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_log_file_system_free_space_percentage` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_log_file_system_in_use_bytes` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_log_file_system_max_bytes` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_log_in_use_bytes` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_log_logical_written_bytes_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_log_max_bytes` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_log_physical_written_bytes_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_log_primary_space_in_use_percentage` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_log_sequence_number_disk_total` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_log_slowest_write_since_restart_seconds` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_log_slowest_write_timestamp_seconds` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_log_workload_primary_space_utilization_percentage` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_log_write_latency_seconds` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_log_write_size_bytes` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_mqcb_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_mqclose_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_mqconn_mqconnx_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_mqctl_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_mqdisc_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_mqinq_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_mqopen_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_mqput_mqput1_bytes_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_mqput_mqput1_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_mqset_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_mqstat_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_mqsubrq_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_non_durable_subscription_create_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_non_durable_subscription_delete_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_non_persistent_message_browse_bytes_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_non_persistent_message_browse_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_non_persistent_message_destructive_get_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_non_persistent_message_get_bytes_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_non_persistent_message_mqput1_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_non_persistent_message_mqput_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_non_persistent_message_put_bytes_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_non_persistent_topic_mqput_mqput1_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_persistent_message_browse_bytes_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_persistent_message_browse_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_persistent_message_destructive_get_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_persistent_message_get_bytes_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_persistent_message_mqput1_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_persistent_message_mqput_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_persistent_message_put_bytes_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_persistent_topic_mqput_mqput1_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_published_to_subscribers_bytes_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_published_to_subscribers_message_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_purged_queue_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_queue_manager_file_system_free_space_percentage` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_queue_manager_file_system_in_use_bytes` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_ram_free_percentage` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_ram_usage_estimate_for_queue_manager_bytes` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_rollback_total` | counter | 1 | 0 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_system_cpu_time_estimate_for_queue_manager_percentage` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_system_cpu_time_percentage` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_topic_mqput_mqput1_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_topic_put_bytes_total` | counter | 1 | 1 | 1 | component (1), qmgr (1) | a counter: its rate over time; never the raw number |
| `ibmmq_qmgr_trace_file_system_free_space_percentage` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_trace_file_system_in_use_bytes` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_user_cpu_time_estimate_for_queue_manager_percentage` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |
| `ibmmq_qmgr_user_cpu_time_percentage` | gauge | 1 | 0 | 1 | component (1), qmgr (1) | constant, the same on every series: a number or a table row, not a line |

## process_cpu (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `process_cpu_seconds_total` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |

## process_max (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `process_max_fds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## process_network (2)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `process_network_receive_bytes_total` | counter | 1 | 1 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `process_network_transmit_bytes_total` | counter | 1 | 1 | 1 | component (1) | a counter: its rate over time; never the raw number |

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
| `process_start_time_seconds` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |

## process_virtual (2)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `process_virtual_memory_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `process_virtual_memory_max_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## promhttp_metric (2)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `promhttp_metric_handler_requests_in_flight` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `promhttp_metric_handler_requests_total` | counter | 3 | 1 | 2 | code (3), component (1) | a counter: its rate over time; never the raw number |

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
