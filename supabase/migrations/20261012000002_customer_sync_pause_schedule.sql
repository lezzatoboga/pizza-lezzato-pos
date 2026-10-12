-- =====================================================================
-- Jadwal sinkron pelanggan: lewati panggilan selama saklar jeda aktif
-- (public.sync_settings.customers_paused). cron.schedule dengan nama job
-- yang sama mengganti perintah job yang sudah ada.
-- =====================================================================

select cron.schedule(
  'sync-customers-every-15-min',
  '*/15 * * * *',
  $job$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
           || '/functions/v1/sync-customers',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'sync_menu_cron_secret')
    ),
    body := '{}'::jsonb
  )
  from public.sync_settings
  where not customers_paused;
  $job$
);
