-- =====================================================================
-- Jadwal sinkron pelanggan setiap 15 menit — memakai secret Vault yang
-- sama dengan sinkron menu (project_url, sync_menu_cron_secret).
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
  );
  $job$
);
