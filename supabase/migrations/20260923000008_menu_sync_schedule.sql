-- =====================================================================
-- Jadwal sinkron menu otomatis setiap 15 menit (pg_cron + pg_net).
--
-- URL project dan rahasia cron dibaca dari Supabase Vault saat job
-- berjalan, supaya tidak tersimpan di repository. Buat sekali lewat
-- SQL Editor (lihat README / instruksi setup):
--   select vault.create_secret('https://<ref>.supabase.co', 'project_url');
--   select vault.create_secret('<rahasia acak>', 'sync_menu_cron_secret');
-- Rahasia yang sama dipasang di Edge Function:
--   npx supabase secrets set SYNC_MENU_CRON_SECRET=<rahasia acak>
-- =====================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

select cron.schedule(
  'sync-menu-every-15-min',
  '*/15 * * * *',
  $job$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
           || '/functions/v1/sync-menu',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'sync_menu_cron_secret')
    ),
    body := '{}'::jsonb
  );
  $job$
);
