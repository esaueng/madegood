const levels = {
  account_deletion_failing: "error",
  account_deletion_retry: "warn",
  export_inline_failed: "error",
  export_message_invalid: "warn",
  export_queue_failed: "error",
  export_step_retry: "error",
  live_share_revoke_failed: "warn",
  og_cache_read_failed: "warn",
  og_cache_write_failed: "warn",
  og_image_failed: "error",
  postprocess_inline_failed: "warn",
  postprocess_message_invalid: "warn",
  postprocess_queue_failed: "error",
  postprocess_retry: "error",
  postprocess_zone_change_queue_failed: "warn",
  preview_tags_failed: "error",
  privacy_zone_add_queue_failed: "error",
  privacy_zone_remove_queue_failed: "error",
  request_failed: "error",
  scheduled_sweep_failed: "error",
  track_garbage_collect_failed: "warn",
  track_garbage_delete_failed: "warn",
  track_upload_cleanup_failed: "warn",
  track_upload_expired_cleanup_failed: "warn",
  wind_lookup_queue_failed: "warn",
  zip_stream_failed: "error",
} as const;

/** Log only a fixed event code. Errors can contain query parameters, tokens or user data
 * in any property, including messages, causes and stacks. Discard the entire value. */
export function logFailure(event: keyof typeof levels, _error?: unknown): void {
  if (!Object.hasOwn(levels, event)) return;
  console[levels[event]]({ event });
}
