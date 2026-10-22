# Metrics inventory

Source: `{job="postgres"}`

397 metric names in 395 families, 607 series.

| Declared type | Families |
| --- | --- |
| counter | 56 |
| gauge | 331 |
| summary | 1 |
| unknown | 7 |

356 of the 397 names did not change on any series in the last 30m.

## go_gc (5)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `go_gc_duration_seconds` | summary | 5 | 4 | 5 | component (1), quantile (5) | a summary: an average from _sum over_count; its own quantiles do not combine across instances |
| `go_gc_duration_seconds_count` | summary | 1 | 1 | 1 | component (1) | a summary: an average from _sum over_count; its own quantiles do not combine across instances |
| `go_gc_duration_seconds_sum` | summary | 1 | 1 | 1 | component (1) | a summary: an average from _sum over_count; its own quantiles do not combine across instances |
| `go_gc_gogc_percent` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `go_gc_gomemlimit_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## go_goroutines (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `go_goroutines` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## go_info (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `go_info` | gauge | 1 | 0 | 1 | component (1), version (1) | facts as labels: a table |

## go_memstats (22)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `go_memstats_alloc_bytes` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `go_memstats_alloc_bytes_total` | counter | 1 | 1 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `go_memstats_buck_hash_sys_bytes` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
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
| `go_memstats_sys_bytes` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |

## go_sched (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `go_sched_gomaxprocs_threads` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## go_threads (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `go_threads` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |

## pg_database (2)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `pg_database_connection_limit` | gauge | 4 | 0 | 1 | component (1), datname (4) | constant, the same on every series: a number or a table row, not a line |
| `pg_database_size_bytes` | gauge | 4 | 0 | 4 | component (1), datname (4) | constant, differing by series: a table or sorted bars, not a line |

## pg_exporter (3)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `pg_exporter_last_scrape_duration_seconds` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `pg_exporter_last_scrape_error` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_exporter_scrapes_total` | counter | 1 | 1 | 1 | component (1) | a counter: its rate over time; never the raw number |

## pg_locks (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `pg_locks_count` | gauge | 36 | 0 | 2 | component (1), datname (4), mode (9) | constant, differing by series: a table or sorted bars, not a line |

## pg_replication (3)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `pg_replication_is_replica` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_replication_lag_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_replication_last_replay_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## pg_roles (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `pg_roles_connection_limit` | gauge | 16 | 0 | 1 | component (1), rolname (16) | constant, the same on every series: a number or a table row, not a line |

## pg_scrape (2)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `pg_scrape_collector_duration_seconds` | gauge | 15 | 15 | 15 | collector (15), component (1) | a level that moves: a line over time; a number for now |
| `pg_scrape_collector_success` | gauge | 15 | 0 | 1 | collector (15), component (1) | constant, the same on every series: a number or a table row, not a line |

## pg_settings (270)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `pg_settings_allow_alter_system` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_allow_in_place_tablespaces` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_allow_system_table_mods` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_archive_timeout_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_array_nulls` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_authentication_timeout_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_autovacuum` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_autovacuum_analyze_scale_factor` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_autovacuum_analyze_threshold` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_autovacuum_freeze_max_age` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_autovacuum_max_workers` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_autovacuum_multixact_freeze_max_age` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_autovacuum_naptime_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_autovacuum_vacuum_cost_delay_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_autovacuum_vacuum_cost_limit` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_autovacuum_vacuum_insert_scale_factor` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_autovacuum_vacuum_insert_threshold` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_autovacuum_vacuum_scale_factor` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_autovacuum_vacuum_threshold` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_autovacuum_work_mem_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_backend_flush_after_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_bgwriter_delay_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_bgwriter_flush_after_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_bgwriter_lru_maxpages` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_bgwriter_lru_multiplier` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_block_size` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_bonjour` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_check_function_bodies` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_checkpoint_completion_target` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_checkpoint_flush_after_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_checkpoint_timeout_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_checkpoint_warning_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_client_connection_check_interval_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_commit_delay` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_commit_siblings` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_commit_timestamp_buffers_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_cpu_index_tuple_cost` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_cpu_operator_cost` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_cpu_tuple_cost` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_cursor_tuple_fraction` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_data_checksums` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_data_directory_mode` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_data_sync_retry` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_deadlock_timeout_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_debug_assertions` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_debug_discard_caches` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_debug_pretty_print` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_debug_print_parse` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_debug_print_plan` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_debug_print_rewritten` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_default_statistics_target` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_default_transaction_deferrable` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_default_transaction_read_only` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_effective_cache_size_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_effective_io_concurrency` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_async_append` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_bitmapscan` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_gathermerge` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_group_by_reordering` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_hashagg` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_hashjoin` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_incremental_sort` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_indexonlyscan` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_indexscan` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_material` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_memoize` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_mergejoin` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_nestloop` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_parallel_append` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_parallel_hash` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_partition_pruning` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_partitionwise_aggregate` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_partitionwise_join` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_presorted_aggregate` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_seqscan` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_sort` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_enable_tidscan` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_escape_string_warning` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_event_triggers` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_exit_on_error` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_extra_float_digits` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_from_collapse_limit` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_fsync` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_full_page_writes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_geqo` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_geqo_effort` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_geqo_generations` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_geqo_pool_size` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_geqo_seed` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_geqo_selection_bias` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_geqo_threshold` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_gin_fuzzy_search_limit` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_gin_pending_list_limit_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_gss_accept_delegation` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_hash_mem_multiplier` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_hot_standby` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_hot_standby_feedback` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_huge_page_size_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_idle_in_transaction_session_timeout_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_idle_session_timeout_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_ignore_checksum_failure` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_ignore_invalid_pages` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_ignore_system_indexes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_in_hot_standby` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_integer_datetimes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_io_combine_limit_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_jit` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_jit_above_cost` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_jit_debugging_support` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_jit_dump_bitcode` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_jit_expressions` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_jit_inline_above_cost` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_jit_optimize_above_cost` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_jit_profiling_support` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_jit_tuple_deforming` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_join_collapse_limit` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_krb_caseins_users` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_lo_compat_privileges` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_lock_timeout_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_autovacuum_min_duration_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_checkpoints` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_connections` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_disconnections` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_duration` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_executor_stats` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_file_mode` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_hostname` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_lock_waits` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_min_duration_sample_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_min_duration_statement_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_parameter_max_length_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_parameter_max_length_on_error_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_parser_stats` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_planner_stats` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_recovery_conflict_waits` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_replication_commands` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_rotation_age_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_rotation_size_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_startup_progress_interval_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_statement_sample_rate` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_statement_stats` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_temp_files_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_transaction_sample_rate` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_log_truncate_on_rotation` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_logging_collector` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_logical_decoding_work_mem_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_maintenance_io_concurrency` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_maintenance_work_mem_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_connections` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_files_per_process` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_function_args` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_identifier_length` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_index_keys` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_locks_per_transaction` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_logical_replication_workers` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_notify_queue_pages` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_parallel_apply_workers_per_subscription` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_parallel_maintenance_workers` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_parallel_workers` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_parallel_workers_per_gather` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_pred_locks_per_page` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_pred_locks_per_relation` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_pred_locks_per_transaction` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_prepared_transactions` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_replication_slots` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_slot_wal_keep_size_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_stack_depth_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_standby_archive_delay_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_standby_streaming_delay_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_sync_workers_per_subscription` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_wal_senders` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_wal_size_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_max_worker_processes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_min_dynamic_shared_memory_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_min_parallel_index_scan_size_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_min_parallel_table_scan_size_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_min_wal_size_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_multixact_member_buffers_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_multixact_offset_buffers_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_notify_buffers_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_parallel_leader_participation` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_parallel_setup_cost` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_parallel_tuple_cost` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_port` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_post_auth_delay_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_pre_auth_delay_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_quote_all_identifiers` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_random_page_cost` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_recovery_min_apply_delay_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_recovery_target_inclusive` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_recursive_worktable_factor` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_remove_temp_files_after_crash` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_reserved_connections` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_restart_after_crash` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_row_security` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_scram_iterations` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_segment_size_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_send_abort_for_crash` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_send_abort_for_kill` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_seq_page_cost` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_serializable_buffers_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_server_version_num` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_shared_buffers_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_shared_memory_size_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_shared_memory_size_in_huge_pages` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_ssl` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_ssl_passphrase_command_supports_reload` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_ssl_prefer_server_ciphers` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_standard_conforming_strings` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_statement_timeout_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_subtransaction_buffers_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_summarize_wal` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_superuser_reserved_connections` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_sync_replication_slots` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_synchronize_seqscans` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_syslog_sequence_numbers` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_syslog_split_messages` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_tcp_keepalives_count` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_tcp_keepalives_idle_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_tcp_keepalives_interval_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_tcp_user_timeout_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_temp_buffers_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_temp_file_limit_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_trace_connection_negotiation` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_trace_notify` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_trace_sort` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_track_activities` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_track_activity_query_size_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_track_commit_timestamp` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_track_counts` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_track_io_timing` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_track_wal_io_timing` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_transaction_buffers_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_transaction_deferrable` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_transaction_read_only` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_transaction_timeout_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_transform_null_equals` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_unix_socket_permissions` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_update_process_title` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_vacuum_buffer_usage_limit_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_vacuum_cost_delay_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_vacuum_cost_limit` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_vacuum_cost_page_dirty` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_vacuum_cost_page_hit` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_vacuum_cost_page_miss` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_vacuum_failsafe_age` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_vacuum_freeze_min_age` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_vacuum_freeze_table_age` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_vacuum_multixact_failsafe_age` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_vacuum_multixact_freeze_min_age` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_vacuum_multixact_freeze_table_age` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_wal_block_size` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_wal_buffers_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_wal_decode_buffer_size_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_wal_init_zero` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_wal_keep_size_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_wal_log_hints` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_wal_receiver_create_temp_slot` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_wal_receiver_status_interval_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_wal_receiver_timeout_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_wal_recycle` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_wal_retrieve_retry_interval_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_wal_segment_size_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_wal_sender_timeout_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_wal_skip_threshold_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_wal_summary_keep_time_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_wal_writer_delay_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_wal_writer_flush_after_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_work_mem_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_settings_zero_damaged_pages` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## pg_stat (53)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `pg_stat_activity_count` | gauge | 25 | 0 | 3 | application_name (1), backend_type (1), component (1), datname (4), state (6), usename (1), wait_event (1), wait_event_type (1) | constant, differing by series: a table or sorted bars, not a line |
| `pg_stat_activity_max_tx_duration` | gauge | 25 | 0 | 1 | application_name (1), backend_type (1), component (1), datname (4), state (6), usename (1), wait_event (1), wait_event_type (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_stat_archiver_archived_count` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `pg_stat_archiver_failed_count` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `pg_stat_bgwriter_buffers_alloc_total` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `pg_stat_bgwriter_buffers_clean_total` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `pg_stat_bgwriter_maxwritten_clean_total` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `pg_stat_bgwriter_stats_reset_total` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `pg_stat_database_active_time_seconds_total` | counter | 4 | 1 | 3 | component (1), datid (4), datname (4) | a counter: its rate over time; never the raw number |
| `pg_stat_database_blk_read_time` | counter | 4 | 0 | 1 | component (1), datid (4), datname (4) | a counter: its rate over time; never the raw number |
| `pg_stat_database_blk_write_time` | counter | 4 | 0 | 1 | component (1), datid (4), datname (4) | a counter: its rate over time; never the raw number |
| `pg_stat_database_blks_hit` | counter | 4 | 3 | 4 | component (1), datid (4), datname (4) | a counter: its rate over time; never the raw number |
| `pg_stat_database_blks_read` | counter | 4 | 0 | 4 | component (1), datid (4), datname (4) | a counter: its rate over time; never the raw number |
| `pg_stat_database_conflicts` | counter | 4 | 0 | 1 | component (1), datid (4), datname (4) | a counter: its rate over time; never the raw number |
| `pg_stat_database_conflicts_confl_active_logicalslot` | unknown | 4 | 0 | 1 | component (1), datid (4), datname (4), server (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_stat_database_conflicts_confl_bufferpin` | counter | 4 | 0 | 1 | component (1), datid (4), datname (4), server (1) | a counter: its rate over time; never the raw number |
| `pg_stat_database_conflicts_confl_deadlock` | counter | 4 | 0 | 1 | component (1), datid (4), datname (4), server (1) | a counter: its rate over time; never the raw number |
| `pg_stat_database_conflicts_confl_lock` | counter | 4 | 0 | 1 | component (1), datid (4), datname (4), server (1) | a counter: its rate over time; never the raw number |
| `pg_stat_database_conflicts_confl_snapshot` | counter | 4 | 0 | 1 | component (1), datid (4), datname (4), server (1) | a counter: its rate over time; never the raw number |
| `pg_stat_database_conflicts_confl_tablespace` | counter | 4 | 0 | 1 | component (1), datid (4), datname (4), server (1) | a counter: its rate over time; never the raw number |
| `pg_stat_database_deadlocks` | counter | 4 | 0 | 1 | component (1), datid (4), datname (4) | a counter: its rate over time; never the raw number |
| `pg_stat_database_numbackends` | gauge | 4 | 0 | 2 | component (1), datid (4), datname (4) | constant, differing by series: a table or sorted bars, not a line |
| `pg_stat_database_stats_reset` | counter | 4 | 0 | 1 | component (1), datid (4), datname (4) | a counter: its rate over time; never the raw number |
| `pg_stat_database_temp_bytes` | counter | 4 | 0 | 1 | component (1), datid (4), datname (4) | a counter: its rate over time; never the raw number |
| `pg_stat_database_temp_files` | counter | 4 | 0 | 1 | component (1), datid (4), datname (4) | a counter: its rate over time; never the raw number |
| `pg_stat_database_tup_deleted` | counter | 4 | 0 | 2 | component (1), datid (4), datname (4) | a counter: its rate over time; never the raw number |
| `pg_stat_database_tup_fetched` | counter | 4 | 3 | 4 | component (1), datid (4), datname (4) | a counter: its rate over time; never the raw number |
| `pg_stat_database_tup_inserted` | counter | 4 | 0 | 3 | component (1), datid (4), datname (4) | a counter: its rate over time; never the raw number |
| `pg_stat_database_tup_returned` | counter | 4 | 3 | 4 | component (1), datid (4), datname (4) | a counter: its rate over time; never the raw number |
| `pg_stat_database_tup_updated` | counter | 4 | 0 | 3 | component (1), datid (4), datname (4) | a counter: its rate over time; never the raw number |
| `pg_stat_database_xact_commit` | counter | 4 | 3 | 4 | component (1), datid (4), datname (4) | a counter: its rate over time; never the raw number |
| `pg_stat_database_xact_rollback` | counter | 4 | 0 | 2 | component (1), datid (4), datname (4) | a counter: its rate over time; never the raw number |
| `pg_stat_user_tables_analyze_count` | counter | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_stat_user_tables_autoanalyze_count` | counter | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_stat_user_tables_autovacuum_count` | counter | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_stat_user_tables_idx_scan` | counter | 1 | 1 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_stat_user_tables_idx_tup_fetch` | counter | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_stat_user_tables_index_size_bytes` | gauge | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_stat_user_tables_last_analyze` | gauge | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_stat_user_tables_last_autoanalyze` | gauge | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_stat_user_tables_last_autovacuum` | gauge | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_stat_user_tables_last_vacuum` | gauge | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_stat_user_tables_n_dead_tup` | gauge | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_stat_user_tables_n_live_tup` | gauge | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_stat_user_tables_n_mod_since_analyze` | gauge | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_stat_user_tables_n_tup_del` | counter | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_stat_user_tables_n_tup_hot_upd` | counter | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_stat_user_tables_n_tup_ins` | counter | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_stat_user_tables_n_tup_upd` | counter | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_stat_user_tables_seq_scan` | counter | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_stat_user_tables_seq_tup_read` | counter | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_stat_user_tables_table_size_bytes` | gauge | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_stat_user_tables_vacuum_count` | counter | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |

## pg_static (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `pg_static` | unknown | 1 | 0 | 1 | component (1), server (1), short_version (1), version (1) | constant, the same on every series: a number or a table row, not a line |

## pg_statio (8)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `pg_statio_user_tables_heap_blocks_hit` | counter | 1 | 1 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_statio_user_tables_heap_blocks_read` | counter | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_statio_user_tables_idx_blocks_hit` | counter | 1 | 1 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_statio_user_tables_idx_blocks_read` | counter | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_statio_user_tables_tidx_blocks_hit` | counter | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_statio_user_tables_tidx_blocks_read` | counter | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_statio_user_tables_toast_blocks_hit` | counter | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |
| `pg_statio_user_tables_toast_blocks_read` | counter | 1 | 0 | 1 | component (1), datname (1), relname (1), schemaname (1) | a counter: its rate over time; never the raw number |

## pg_up (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `pg_up` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## pg_wal (2)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `pg_wal_segments` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `pg_wal_size_bytes` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## postgres_exporter (3)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `postgres_exporter_build_info` | gauge | 1 | 0 | 1 | branch (1), component (1), goarch (1), goos (1), goversion (1), revision (1), tags (1), version (1) | facts as labels: a table |
| `postgres_exporter_config_last_reload_success_timestamp_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `postgres_exporter_config_last_reload_successful` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## process_cpu (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `process_cpu_seconds_total` | counter | 1 | 1 | 1 | component (1) | a counter: its rate over time; never the raw number |

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
| `process_open_fds` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |

## process_resident (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `process_resident_memory_bytes` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |

## process_start (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `process_start_time_seconds` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |

## process_virtual (2)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `process_virtual_memory_bytes` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
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
