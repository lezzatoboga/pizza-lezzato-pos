-- =====================================================================
-- 00_HANYA_postgres_biasa.sql — LEWATI berkas ini di Supabase lokal (supabase start).
-- Hanya untuk jalur cadangan tanpa Docker (Postgres biasa, mis. WSL): membuat peran tiruan yang di
-- Supabase sudah ada sejak awal. Peran berlaku se-cluster; aman diulang (dibuat hanya bila belum ada).
-- Jalankan sebagai superuser di database website_tiruan.
-- =====================================================================
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon')          then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role')  then create role service_role nologin bypassrls; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then create role authenticator nologin noinherit; end if;
end
$$;
grant anon, authenticated, service_role to authenticator;
