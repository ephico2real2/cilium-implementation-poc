# Metrics inventory

Source: `{job="envoy"}`

404 metric names in 376 families, 4143 series.

| Declared type | Families |
| --- | --- |
| counter | 283 |
| gauge | 74 |
| histogram | 14 |
| unknown | 5 |

305 of the 404 names did not change on any series in the last 30m.

## envoy_cluster (174)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `envoy_cluster_assignment_stale` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_assignment_timeout_received` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_assignment_use_cached` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_bind_errors` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_circuit_breakers_default_cx_open` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_circuit_breakers_default_cx_pool_open` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_circuit_breakers_default_rq_open` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_circuit_breakers_default_rq_pending_open` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_circuit_breakers_default_rq_retry_open` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_circuit_breakers_high_cx_open` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_circuit_breakers_high_cx_pool_open` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_circuit_breakers_high_rq_open` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_circuit_breakers_high_rq_pending_open` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_circuit_breakers_high_rq_retry_open` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_client_ssl_socket_factory_downstream_context_secrets_not_ready` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_client_ssl_socket_factory_ssl_context_update_by_sds` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_client_ssl_socket_factory_upstream_context_secrets_not_ready` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_default_total_match_count` | counter | 15 | 14 | 2 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_external_upstream_rq` | counter | 10 | 7 | 6 | component (1), envoy_cluster_name (9), envoy_response_code (2) | a counter: its rate over time; never the raw number |
| `envoy_cluster_external_upstream_rq_completed` | counter | 9 | 7 | 5 | component (1), envoy_cluster_name (9) | a counter: its rate over time; never the raw number |
| `envoy_cluster_external_upstream_rq_time_bucket` | histogram | 180 | 118 | 12 | component (1), envoy_cluster_name (9), le (20) | a distribution: a percentile from its buckets, across instances |
| `envoy_cluster_external_upstream_rq_time_count` | histogram | 9 | 7 | 5 | component (1), envoy_cluster_name (9) | a distribution: a percentile from its buckets, across instances |
| `envoy_cluster_external_upstream_rq_time_sum` | histogram | 9 | 7 | 8 | component (1), envoy_cluster_name (9) | a distribution: a percentile from its buckets, across instances |
| `envoy_cluster_external_upstream_rq_xx` | counter | 9 | 7 | 5 | component (1), envoy_cluster_name (9), envoy_response_code_class (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_http1_dropped_headers_with_underscores` | counter | 9 | 0 | 1 | component (1), envoy_cluster_name (9) | a counter: its rate over time; never the raw number |
| `envoy_cluster_http1_metadata_not_supported_error` | counter | 9 | 0 | 1 | component (1), envoy_cluster_name (9) | a counter: its rate over time; never the raw number |
| `envoy_cluster_http1_requests_rejected_with_underscores_in_headers` | counter | 9 | 0 | 1 | component (1), envoy_cluster_name (9) | a counter: its rate over time; never the raw number |
| `envoy_cluster_http1_response_flood` | counter | 9 | 0 | 1 | component (1), envoy_cluster_name (9) | a counter: its rate over time; never the raw number |
| `envoy_cluster_lb_healthy_panic` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_lb_local_cluster_not_ok` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_lb_recalculate_zone_structures` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_lb_subsets_active` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_lb_subsets_created` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_lb_subsets_fallback` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_lb_subsets_fallback_panic` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_lb_subsets_removed` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_lb_subsets_selected` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_lb_zone_cluster_too_small` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_lb_zone_no_capacity_left` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_lb_zone_routing_all_directly` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_lb_zone_routing_cross_zone` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_lb_zone_routing_sampled` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_manager_active_clusters` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_manager_cluster_added` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_manager_cluster_modified` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_manager_cluster_removed` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_manager_cluster_updated` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_manager_cluster_updated_via_merge` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_manager_update_merge_cancelled` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_manager_update_out_of_merge_window` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_manager_warming_clusters` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_max_host_weight` | gauge | 15 | 0 | 2 | component (1), envoy_cluster_name (15) | constant, differing by series: a table or sorted bars, not a line |
| `envoy_cluster_membership_change` | counter | 15 | 0 | 2 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_membership_degraded` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_membership_excluded` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_membership_healthy` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_membership_total` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_original_dst_host_invalid` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_active` | gauge | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_outlier_detection_ejections_consecutive_5xx` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_detected_consecutive_5xx` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_detected_consecutive_gateway_failure` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_detected_consecutive_local_origin_failure` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_detected_failure_percentage` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_detected_local_origin_failure_percentage` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_detected_local_origin_success_rate` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_detected_success_rate` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_enforced_consecutive_5xx` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_enforced_consecutive_gateway_failure` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_enforced_consecutive_local_origin_failure` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_enforced_failure_percentage` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_enforced_local_origin_failure_percentage` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_enforced_local_origin_success_rate` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_enforced_success_rate` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_enforced_total` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_overflow` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_success_rate` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_outlier_detection_ejections_total` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_retry_or_shadow_abandoned` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_ssl_certificate_expiration_unix_time_seconds` | gauge | 1 | 0 | 1 | component (1), envoy_cluster_name (1), envoy_tls_certificate (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_ssl_ciphers` | counter | 1 | 1 | 1 | cipher_suite (1), component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_ssl_connection_error` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_ssl_curves` | counter | 1 | 1 | 1 | component (1), envoy_cluster_name (1), envoy_ssl_curve (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_ssl_fail_verify_cert_hash` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_ssl_fail_verify_error` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_ssl_fail_verify_no_cert` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_ssl_fail_verify_san` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_ssl_handshake` | counter | 1 | 1 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_ssl_no_certificate` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_ssl_ocsp_staple_failed` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_ssl_ocsp_staple_omitted` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_ssl_ocsp_staple_requests` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_ssl_ocsp_staple_responses` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_ssl_session_reused` | counter | 1 | 1 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_ssl_sigalgs` | counter | 1 | 1 | 1 | component (1), envoy_cluster_name (1), envoy_ssl_sigalg (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_ssl_versions` | counter | 1 | 1 | 1 | component (1), envoy_cluster_name (1), envoy_ssl_version (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_ssl_was_key_usage_invalid` | counter | 1 | 0 | 1 | component (1), envoy_cluster_name (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_update_attempt` | counter | 15 | 14 | 2 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_update_empty` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_update_failure` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_update_no_rebuild` | counter | 15 | 14 | 3 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_update_success` | counter | 15 | 14 | 2 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_active` | gauge | 15 | 3 | 4 | component (1), envoy_cluster_name (15) | a level that moves: a line over time; a number for now |
| `envoy_cluster_upstream_cx_close_notify` | counter | 15 | 2 | 3 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_connect_attempts_exceeded` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_connect_fail` | counter | 15 | 0 | 2 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_connect_ms_bucket` | histogram | 300 | 120 | 8 | component (1), envoy_cluster_name (15), le (20) | a distribution: a percentile from its buckets, across instances |
| `envoy_cluster_upstream_cx_connect_ms_count` | histogram | 15 | 6 | 7 | component (1), envoy_cluster_name (15) | a distribution: a percentile from its buckets, across instances |
| `envoy_cluster_upstream_cx_connect_ms_sum` | histogram | 15 | 0 | 2 | component (1), envoy_cluster_name (15) | a distribution: a percentile from its buckets, across instances |
| `envoy_cluster_upstream_cx_connect_timeout` | counter | 15 | 0 | 2 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_connect_with_0_rtt` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_destroy` | counter | 15 | 4 | 5 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_destroy_local` | counter | 15 | 2 | 4 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_destroy_local_with_active_rq` | counter | 15 | 0 | 2 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_destroy_remote` | counter | 15 | 2 | 4 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_destroy_remote_with_active_rq` | counter | 15 | 1 | 3 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_destroy_with_active_rq` | counter | 15 | 1 | 3 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_http1_total` | counter | 15 | 6 | 6 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_http2_total` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_http3_total` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_idle_timeout` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_length_ms_bucket` | histogram | 300 | 62 | 9 | component (1), envoy_cluster_name (15), le (20) | a distribution: a percentile from its buckets, across instances |
| `envoy_cluster_upstream_cx_length_ms_count` | histogram | 15 | 4 | 5 | component (1), envoy_cluster_name (15) | a distribution: a percentile from its buckets, across instances |
| `envoy_cluster_upstream_cx_length_ms_sum` | histogram | 15 | 4 | 8 | component (1), envoy_cluster_name (15) | a distribution: a percentile from its buckets, across instances |
| `envoy_cluster_upstream_cx_max_duration_reached` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_max_requests` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_none_healthy` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_overflow` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_pool_overflow` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_protocol_error` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_rx_bytes_buffered` | gauge | 15 | 7 | 9 | component (1), envoy_cluster_name (15) | a level that moves: a line over time; a number for now |
| `envoy_cluster_upstream_cx_rx_bytes_total` | counter | 15 | 10 | 14 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_total` | counter | 15 | 7 | 7 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_cx_tx_bytes_buffered` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_upstream_cx_tx_bytes_total` | counter | 15 | 10 | 14 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_flow_control_backed_up_total` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_flow_control_drained_total` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_flow_control_paused_reading_total` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_flow_control_resumed_reading_total` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_http3_broken` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_internal_redirect_failed_total` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_internal_redirect_succeeded_total` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq` | counter | 10 | 7 | 6 | component (1), envoy_cluster_name (9), envoy_response_code (2) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_0rtt` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_active` | gauge | 15 | 0 | 3 | component (1), envoy_cluster_name (15) | constant, differing by series: a table or sorted bars, not a line |
| `envoy_cluster_upstream_rq_cancelled` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_completed` | counter | 15 | 9 | 6 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_maintenance_mode` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_max_duration_reached` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_pending_active` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_upstream_rq_pending_failure_eject` | counter | 15 | 0 | 2 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_pending_overflow` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_pending_total` | counter | 15 | 7 | 7 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_per_cx_bucket` | histogram | 300 | 54 | 3 | component (1), envoy_cluster_name (15), le (20) | a distribution: a percentile from its buckets, across instances |
| `envoy_cluster_upstream_rq_per_cx_count` | histogram | 15 | 3 | 3 | component (1), envoy_cluster_name (15) | a distribution: a percentile from its buckets, across instances |
| `envoy_cluster_upstream_rq_per_cx_sum` | histogram | 15 | 3 | 3 | component (1), envoy_cluster_name (15) | a distribution: a percentile from its buckets, across instances |
| `envoy_cluster_upstream_rq_per_try_idle_timeout` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_per_try_timeout` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_retry` | counter | 15 | 0 | 2 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_retry_backoff_exponential` | counter | 15 | 0 | 2 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_retry_backoff_ratelimited` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_retry_limit_exceeded` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_retry_overflow` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_retry_success` | counter | 15 | 0 | 2 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_rx_reset` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_time_bucket` | histogram | 180 | 118 | 12 | component (1), envoy_cluster_name (9), le (20) | a distribution: a percentile from its buckets, across instances |
| `envoy_cluster_upstream_rq_time_count` | histogram | 9 | 7 | 5 | component (1), envoy_cluster_name (9) | a distribution: a percentile from its buckets, across instances |
| `envoy_cluster_upstream_rq_time_sum` | histogram | 9 | 7 | 8 | component (1), envoy_cluster_name (9) | a distribution: a percentile from its buckets, across instances |
| `envoy_cluster_upstream_rq_timeout` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_total` | counter | 15 | 10 | 7 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_tx_reset` | counter | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | a counter: its rate over time; never the raw number |
| `envoy_cluster_upstream_rq_xx` | counter | 9 | 7 | 5 | component (1), envoy_cluster_name (9), envoy_response_code_class (1) | a counter: its rate over time; never the raw number |
| `envoy_cluster_version` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |
| `envoy_cluster_warming_state` | gauge | 15 | 0 | 1 | component (1), envoy_cluster_name (15) | constant, the same on every series: a number or a table row, not a line |

## envoy_dns (6)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `envoy_dns_cares_get_addr_failure` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_dns_cares_not_found` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_dns_cares_pending_resolutions` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_dns_cares_reinits` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_dns_cares_resolve_total` | counter | 1 | 1 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_dns_cares_timeouts` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |

## envoy_envoy (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `envoy_envoy_overload_actions_reset_high_memory_stream_count` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |

## envoy_filesystem (6)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `envoy_filesystem_flushed_by_timer` | counter | 1 | 1 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_filesystem_reopen_failed` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_filesystem_write_buffered` | counter | 1 | 1 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_filesystem_write_completed` | counter | 1 | 1 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_filesystem_write_failed` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_filesystem_write_total_buffered` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |

## envoy_http (78)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `envoy_http_downstream_cx_active` | gauge | 4 | 0 | 3 | component (1), envoy_http_conn_manager_prefix (4) | constant, differing by series: a table or sorted bars, not a line |
| `envoy_http_downstream_cx_delayed_close_timeout` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_destroy` | counter | 4 | 3 | 4 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_destroy_active_rq` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_destroy_local` | counter | 4 | 2 | 3 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_destroy_local_active_rq` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_destroy_remote` | counter | 4 | 1 | 3 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_destroy_remote_active_rq` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_drain_close` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_http1_active` | gauge | 4 | 0 | 3 | component (1), envoy_http_conn_manager_prefix (4) | constant, differing by series: a table or sorted bars, not a line |
| `envoy_http_downstream_cx_http1_soft_drain` | gauge | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | constant, the same on every series: a number or a table row, not a line |
| `envoy_http_downstream_cx_http1_total` | counter | 4 | 3 | 4 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_http2_active` | gauge | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | constant, the same on every series: a number or a table row, not a line |
| `envoy_http_downstream_cx_http2_total` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_http3_active` | gauge | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | constant, the same on every series: a number or a table row, not a line |
| `envoy_http_downstream_cx_http3_total` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_idle_timeout` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_length_ms_bucket` | histogram | 80 | 58 | 9 | component (1), envoy_http_conn_manager_prefix (4), le (20) | a distribution: a percentile from its buckets, across instances |
| `envoy_http_downstream_cx_length_ms_count` | histogram | 4 | 3 | 4 | component (1), envoy_http_conn_manager_prefix (4) | a distribution: a percentile from its buckets, across instances |
| `envoy_http_downstream_cx_length_ms_sum` | histogram | 4 | 2 | 4 | component (1), envoy_http_conn_manager_prefix (4) | a distribution: a percentile from its buckets, across instances |
| `envoy_http_downstream_cx_max_duration_reached` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_max_requests_reached` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_overload_disable_keepalive` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_protocol_error` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_rx_bytes_buffered` | gauge | 4 | 0 | 3 | component (1), envoy_http_conn_manager_prefix (4) | constant, differing by series: a table or sorted bars, not a line |
| `envoy_http_downstream_cx_rx_bytes_total` | counter | 4 | 3 | 4 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_ssl_active` | gauge | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | constant, the same on every series: a number or a table row, not a line |
| `envoy_http_downstream_cx_ssl_total` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_total` | counter | 4 | 3 | 4 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_tx_bytes_buffered` | gauge | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | constant, the same on every series: a number or a table row, not a line |
| `envoy_http_downstream_cx_tx_bytes_total` | counter | 4 | 3 | 4 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_cx_upgrades_active` | gauge | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | constant, the same on every series: a number or a table row, not a line |
| `envoy_http_downstream_cx_upgrades_total` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_flow_control_paused_reading_total` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_flow_control_resumed_reading_total` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_active` | gauge | 4 | 0 | 3 | component (1), envoy_http_conn_manager_prefix (4) | constant, differing by series: a table or sorted bars, not a line |
| `envoy_http_downstream_rq_completed` | counter | 4 | 3 | 4 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_failed_path_normalization` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_header_timeout` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_http1_total` | counter | 4 | 3 | 4 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_http2_total` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_http3_total` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_idle_timeout` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_max_duration_reached` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_non_relative_path` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_overload_close` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_redirected_with_normalized_path` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_rejected_via_ip_detection` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_response_before_rq_complete` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_rx_reset` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_time_bucket` | histogram | 80 | 60 | 12 | component (1), envoy_http_conn_manager_prefix (4), le (20) | a distribution: a percentile from its buckets, across instances |
| `envoy_http_downstream_rq_time_count` | histogram | 4 | 3 | 4 | component (1), envoy_http_conn_manager_prefix (4) | a distribution: a percentile from its buckets, across instances |
| `envoy_http_downstream_rq_time_sum` | histogram | 4 | 2 | 3 | component (1), envoy_http_conn_manager_prefix (4) | a distribution: a percentile from its buckets, across instances |
| `envoy_http_downstream_rq_timeout` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_too_large` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_too_many_premature_resets` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_total` | counter | 4 | 3 | 4 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_tx_reset` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_ws_on_non_ws_route` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_downstream_rq_xx` | counter | 20 | 3 | 4 | component (1), envoy_http_conn_manager_prefix (4), envoy_response_code_class (5) | a counter: its rate over time; never the raw number |
| `envoy_http_no_cluster` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_no_route` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_passthrough_internal_redirect_bad_location` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_passthrough_internal_redirect_no_route` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_passthrough_internal_redirect_predicate` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_passthrough_internal_redirect_too_many_redirects` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_passthrough_internal_redirect_unsafe_scheme` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_rq_direct_response` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_rq_overload_local_reply` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_rq_redirect` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_rq_reset_after_downstream_response_started` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_rq_total` | counter | 4 | 2 | 3 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_rs_too_large` | counter | 4 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (4) | a counter: its rate over time; never the raw number |
| `envoy_http_tracing_client_enabled` | counter | 3 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (3) | a counter: its rate over time; never the raw number |
| `envoy_http_tracing_health_check` | counter | 3 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (3) | a counter: its rate over time; never the raw number |
| `envoy_http_tracing_not_traceable` | counter | 3 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (3) | a counter: its rate over time; never the raw number |
| `envoy_http_tracing_random_sampling` | counter | 3 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (3) | a counter: its rate over time; never the raw number |
| `envoy_http_tracing_service_forced` | counter | 3 | 0 | 1 | component (1), envoy_http_conn_manager_prefix (3) | a counter: its rate over time; never the raw number |

## envoy_http1 (4)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `envoy_http1_dropped_headers_with_underscores` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_http1_metadata_not_supported_error` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_http1_requests_rejected_with_underscores_in_headers` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_http1_response_flood` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |

## envoy_listener (58)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `envoy_listener_admin_connections_accepted_per_socket_event_bucket` | histogram | 20 | 18 | 2 | component (1), le (20) | a distribution: a percentile from its buckets, across instances |
| `envoy_listener_admin_connections_accepted_per_socket_event_count` | histogram | 1 | 1 | 1 | component (1) | a distribution: a percentile from its buckets, across instances |
| `envoy_listener_admin_connections_accepted_per_socket_event_sum` | histogram | 1 | 1 | 1 | component (1) | a distribution: a percentile from its buckets, across instances |
| `envoy_listener_admin_downstream_cx_active` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_listener_admin_downstream_cx_destroy` | counter | 1 | 1 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_admin_downstream_cx_length_ms_bucket` | histogram | 20 | 20 | 2 | component (1), le (20) | a distribution: a percentile from its buckets, across instances |
| `envoy_listener_admin_downstream_cx_length_ms_count` | histogram | 1 | 1 | 1 | component (1) | a distribution: a percentile from its buckets, across instances |
| `envoy_listener_admin_downstream_cx_length_ms_sum` | histogram | 1 | 0 | 1 | component (1) | a distribution: a percentile from its buckets, across instances |
| `envoy_listener_admin_downstream_cx_overflow` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_admin_downstream_cx_overload_reject` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_admin_downstream_cx_total` | counter | 1 | 1 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_admin_downstream_cx_transport_socket_connect_timeout` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_admin_downstream_global_cx_overflow` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_admin_downstream_listener_filter_error` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_admin_downstream_listener_filter_remote_close` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_admin_downstream_pre_cx_active` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_listener_admin_downstream_pre_cx_timeout` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_admin_http_downstream_rq_completed` | counter | 1 | 1 | 1 | component (1), envoy_http_conn_manager_prefix (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_admin_http_downstream_rq_xx` | counter | 5 | 1 | 2 | component (1), envoy_http_conn_manager_prefix (1), envoy_response_code_class (5) | a counter: its rate over time; never the raw number |
| `envoy_listener_admin_main_thread_downstream_cx_active` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_listener_admin_main_thread_downstream_cx_total` | counter | 1 | 1 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_admin_no_filter_chain_match` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_connections_accepted_per_socket_event_bucket` | histogram | 100 | 54 | 5 | component (1), envoy_listener_address (5), le (20) | a distribution: a percentile from its buckets, across instances |
| `envoy_listener_connections_accepted_per_socket_event_count` | histogram | 5 | 3 | 5 | component (1), envoy_listener_address (5) | a distribution: a percentile from its buckets, across instances |
| `envoy_listener_connections_accepted_per_socket_event_sum` | histogram | 5 | 3 | 5 | component (1), envoy_listener_address (5) | a distribution: a percentile from its buckets, across instances |
| `envoy_listener_downstream_cx_active` | gauge | 5 | 0 | 3 | component (1), envoy_listener_address (5) | constant, differing by series: a table or sorted bars, not a line |
| `envoy_listener_downstream_cx_destroy` | counter | 5 | 3 | 5 | component (1), envoy_listener_address (5) | a counter: its rate over time; never the raw number |
| `envoy_listener_downstream_cx_length_ms_bucket` | histogram | 100 | 54 | 11 | component (1), envoy_listener_address (5), le (20) | a distribution: a percentile from its buckets, across instances |
| `envoy_listener_downstream_cx_length_ms_count` | histogram | 5 | 3 | 5 | component (1), envoy_listener_address (5) | a distribution: a percentile from its buckets, across instances |
| `envoy_listener_downstream_cx_length_ms_sum` | histogram | 5 | 3 | 5 | component (1), envoy_listener_address (5) | a distribution: a percentile from its buckets, across instances |
| `envoy_listener_downstream_cx_overflow` | counter | 5 | 0 | 1 | component (1), envoy_listener_address (5) | a counter: its rate over time; never the raw number |
| `envoy_listener_downstream_cx_overload_reject` | counter | 5 | 0 | 1 | component (1), envoy_listener_address (5) | a counter: its rate over time; never the raw number |
| `envoy_listener_downstream_cx_total` | counter | 5 | 3 | 5 | component (1), envoy_listener_address (5) | a counter: its rate over time; never the raw number |
| `envoy_listener_downstream_cx_transport_socket_connect_timeout` | counter | 5 | 0 | 1 | component (1), envoy_listener_address (5) | a counter: its rate over time; never the raw number |
| `envoy_listener_downstream_global_cx_overflow` | counter | 5 | 0 | 1 | component (1), envoy_listener_address (5) | a counter: its rate over time; never the raw number |
| `envoy_listener_downstream_listener_filter_error` | counter | 5 | 0 | 1 | component (1), envoy_listener_address (5) | a counter: its rate over time; never the raw number |
| `envoy_listener_downstream_listener_filter_remote_close` | counter | 5 | 0 | 1 | component (1), envoy_listener_address (5) | a counter: its rate over time; never the raw number |
| `envoy_listener_downstream_pre_cx_active` | gauge | 5 | 0 | 1 | component (1), envoy_listener_address (5) | constant, the same on every series: a number or a table row, not a line |
| `envoy_listener_downstream_pre_cx_timeout` | counter | 5 | 0 | 1 | component (1), envoy_listener_address (5) | a counter: its rate over time; never the raw number |
| `envoy_listener_extension_config_missing` | counter | 5 | 0 | 1 | component (1), envoy_listener_address (5) | a counter: its rate over time; never the raw number |
| `envoy_listener_http_downstream_rq_completed` | counter | 3 | 2 | 3 | component (1), envoy_http_conn_manager_prefix (3), envoy_listener_address (3) | a counter: its rate over time; never the raw number |
| `envoy_listener_http_downstream_rq_xx` | counter | 15 | 2 | 3 | component (1), envoy_http_conn_manager_prefix (3), envoy_listener_address (3), envoy_response_code_class (5) | a counter: its rate over time; never the raw number |
| `envoy_listener_manager_listener_added` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_manager_listener_create_failure` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_manager_listener_create_success` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_manager_listener_in_place_updated` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_manager_listener_modified` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_manager_listener_removed` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_manager_listener_stopped` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_listener_manager_total_filter_chains_draining` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_listener_manager_total_listeners_active` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_listener_manager_total_listeners_draining` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_listener_manager_total_listeners_warming` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_listener_manager_workers_started` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_listener_network_extension_config_missing` | counter | 5 | 0 | 1 | component (1), envoy_listener_address (5) | a counter: its rate over time; never the raw number |
| `envoy_listener_no_filter_chain_match` | counter | 5 | 0 | 1 | component (1), envoy_listener_address (5) | a counter: its rate over time; never the raw number |
| `envoy_listener_worker_downstream_cx_active` | gauge | 20 | 0 | 3 | component (1), envoy_listener_address (5), envoy_worker_id (4) | constant, differing by series: a table or sorted bars, not a line |
| `envoy_listener_worker_downstream_cx_total` | counter | 20 | 10 | 9 | component (1), envoy_listener_address (5), envoy_worker_id (4) | a counter: its rate over time; never the raw number |

## envoy_main (2)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `envoy_main_thread_watchdog_mega_miss` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_main_thread_watchdog_miss` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |

## envoy_overload (4)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `envoy_overload_envoy_resource_monitors_global_downstream_max_connections_failed_updates` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_overload_refresh_interval_delay_bucket` | histogram | 20 | 0 | 1 | component (1), le (20) | a distribution: a percentile from its buckets, across instances |
| `envoy_overload_refresh_interval_delay_count` | histogram | 1 | 0 | 1 | component (1) | a distribution: a percentile from its buckets, across instances |
| `envoy_overload_refresh_interval_delay_sum` | histogram | 1 | 0 | 1 | component (1) | a distribution: a percentile from its buckets, across instances |

## envoy_runtime (9)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `envoy_runtime_admin_overrides_active` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_runtime_deprecated_feature_seen_since_process_start` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_runtime_deprecated_feature_use` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_runtime_load_error` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_runtime_load_success` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_runtime_num_keys` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_runtime_num_layers` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_runtime_override_dir_exists` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_runtime_override_dir_not_exists` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |

## envoy_server (29)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `envoy_server_compilation_settings_fips_mode` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_server_concurrency` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_server_days_until_first_cert_expiring` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_server_debug_assertion_failures` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_server_dropped_stat_flushes` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_server_dynamic_unknown_fields` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_server_envoy_bug_failures` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_server_envoy_notifications` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_server_hot_restart_epoch` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_server_initialization_time_ms_bucket` | histogram | 20 | 0 | 2 | component (1), le (20) | a distribution: a percentile from its buckets, across instances |
| `envoy_server_initialization_time_ms_count` | histogram | 1 | 0 | 1 | component (1) | a distribution: a percentile from its buckets, across instances |
| `envoy_server_initialization_time_ms_sum` | histogram | 1 | 0 | 1 | component (1) | a distribution: a percentile from its buckets, across instances |
| `envoy_server_live` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_server_main_thread_watchdog_mega_miss` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_server_main_thread_watchdog_miss` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_server_memory_allocated` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `envoy_server_memory_heap_size` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_server_memory_physical_size` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_server_parent_connections` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_server_seconds_until_first_ocsp_response_expiring` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_server_state` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_server_static_unknown_fields` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_server_stats_recent_lookups` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `envoy_server_total_connections` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_server_uptime` | gauge | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `envoy_server_version` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_server_wip_protos` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_server_worker_watchdog_mega_miss` | counter | 4 | 0 | 1 | component (1), envoy_worker_id (4) | a counter: its rate over time; never the raw number |
| `envoy_server_worker_watchdog_miss` | counter | 4 | 0 | 1 | component (1), envoy_worker_id (4) | a counter: its rate over time; never the raw number |

## envoy_tcmalloc (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `envoy_tcmalloc_released_by_timer` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |

## envoy_tcp (13)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `envoy_tcp_downstream_cx_no_route` | counter | 6 | 0 | 1 | component (1), envoy_tcp_prefix (6) | a counter: its rate over time; never the raw number |
| `envoy_tcp_downstream_cx_rx_bytes_buffered` | gauge | 6 | 1 | 2 | component (1), envoy_tcp_prefix (6) | a level that moves: a line over time; a number for now |
| `envoy_tcp_downstream_cx_rx_bytes_total` | counter | 6 | 1 | 5 | component (1), envoy_tcp_prefix (6) | a counter: its rate over time; never the raw number |
| `envoy_tcp_downstream_cx_total` | counter | 6 | 1 | 3 | component (1), envoy_tcp_prefix (6) | a counter: its rate over time; never the raw number |
| `envoy_tcp_downstream_cx_tx_bytes_buffered` | gauge | 6 | 0 | 1 | component (1), envoy_tcp_prefix (6) | constant, the same on every series: a number or a table row, not a line |
| `envoy_tcp_downstream_cx_tx_bytes_total` | counter | 6 | 1 | 5 | component (1), envoy_tcp_prefix (6) | a counter: its rate over time; never the raw number |
| `envoy_tcp_downstream_flow_control_paused_reading_total` | counter | 6 | 0 | 1 | component (1), envoy_tcp_prefix (6) | a counter: its rate over time; never the raw number |
| `envoy_tcp_downstream_flow_control_resumed_reading_total` | counter | 6 | 0 | 1 | component (1), envoy_tcp_prefix (6) | a counter: its rate over time; never the raw number |
| `envoy_tcp_early_data_received_count_total` | counter | 6 | 0 | 1 | component (1), envoy_tcp_prefix (6) | a counter: its rate over time; never the raw number |
| `envoy_tcp_idle_timeout` | counter | 6 | 0 | 1 | component (1), envoy_tcp_prefix (6) | a counter: its rate over time; never the raw number |
| `envoy_tcp_max_downstream_connection_duration` | counter | 6 | 0 | 1 | component (1), envoy_tcp_prefix (6) | a counter: its rate over time; never the raw number |
| `envoy_tcp_upstream_flush_active` | gauge | 6 | 0 | 1 | component (1), envoy_tcp_prefix (6) | constant, the same on every series: a number or a table row, not a line |
| `envoy_tcp_upstream_flush_total` | counter | 6 | 0 | 1 | component (1), envoy_tcp_prefix (6) | a counter: its rate over time; never the raw number |

## envoy_thread (2)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `envoy_thread_local_cluster_manager_main_thread_clusters_inflated` | gauge | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
| `envoy_thread_local_cluster_manager_worker_clusters_inflated` | gauge | 4 | 0 | 1 | component (1), envoy_worker_id (4) | constant, the same on every series: a number or a table row, not a line |

## envoy_tls (10)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `envoy_tls_inspector_alpn_found` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_tls_inspector_alpn_not_found` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_tls_inspector_bytes_processed_bucket` | histogram | 20 | 0 | 3 | component (1), le (20) | a distribution: a percentile from its buckets, across instances |
| `envoy_tls_inspector_bytes_processed_count` | histogram | 1 | 0 | 1 | component (1) | a distribution: a percentile from its buckets, across instances |
| `envoy_tls_inspector_bytes_processed_sum` | histogram | 1 | 0 | 1 | component (1) | a distribution: a percentile from its buckets, across instances |
| `envoy_tls_inspector_client_hello_too_large` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_tls_inspector_sni_found` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_tls_inspector_sni_not_found` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_tls_inspector_tls_found` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_tls_inspector_tls_not_found` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |

## envoy_workers (2)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `envoy_workers_watchdog_mega_miss` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |
| `envoy_workers_watchdog_miss` | counter | 1 | 0 | 1 | component (1) | a counter: its rate over time; never the raw number |

## scrape_duration (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `scrape_duration_seconds` | unknown | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |

## scrape_samples (2)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `scrape_samples_post_metric_relabeling` | unknown | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |
| `scrape_samples_scraped` | unknown | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |

## scrape_series (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `scrape_series_added` | unknown | 1 | 1 | 1 | component (1) | a level that moves: a line over time; a number for now |

## up (1)

| Metric | Type | Series | Changed | Distinct values | Labels | Kind of data |
| --- | --- | --- | --- | --- | --- | --- |
| `up` | unknown | 1 | 0 | 1 | component (1) | constant, the same on every series: a number or a table row, not a line |
