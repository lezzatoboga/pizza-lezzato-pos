-- =====================================================================
-- 02_peran_pos_lokal.sql — peran POS untuk LINGKUNGAN UJI LOKAL saja.
--
-- Hak akses = rancangan tahap 5 kontrak (docs/KONTRAK-DATA-POS.md §2.1, §2.2):
--   pos_reader        : SELECT 4 view schema pos + EXECUTE public.pesanan_pos() (dipanggil di dalam
--                       pos.v_pesanan; Postgres memeriksa hak fungsi di view terhadap PENGGUNA view),
--                       read-only, statement_timeout 5 dtk, maks. 3 koneksi
--                       (+ 6 kolom public.customers lama dari migrasi — masa transisi, dicabut di tahap 8)
--   pos_status_writer : hanya EXECUTE pos.pos_set_order_status, statement_timeout 5 dtk, maks. 2 koneksi
--
-- KATA SANDI DI BAWAH HANYA UNTUK UJI LOKAL — bukan kata sandi produksi dan tak boleh dipakai di
-- produksi. Di produksi kata sandi diatur Owner sendiri (password manager) dan login baru aktif di tahap 7.
--
-- Peran berlaku se-cluster (di Supabase lokal: seluruh stack lokal POS). Pengaturan per peran di bawah
-- dibatasi ke database ini (ALTER ROLE … IN DATABASE). Aman diulang. Jalankan sebagai superuser di
-- database website_tiruan, SESUDAH 01 (dan 03 boleh sebelum/sesudah).
-- =====================================================================
do $$
declare
  db text := current_database();
begin
  if not exists (select 1 from pg_roles where rolname = 'pos_reader') then create role pos_reader; end if;
  if not exists (select 1 from pg_roles where rolname = 'pos_status_writer') then create role pos_status_writer; end if;
  execute 'alter role pos_reader login inherit connection limit 3 password ''lokal-pos-reader-uji''';
  execute 'alter role pos_status_writer login noinherit connection limit 2 password ''lokal-pos-status-writer-uji''';
  execute format('alter role pos_reader in database %I set default_transaction_read_only = on', db);
  execute format('alter role pos_reader in database %I set statement_timeout = %L', db, '5s');
  execute format('alter role pos_status_writer in database %I set statement_timeout = %L', db, '5s');
  execute format('grant connect on database %I to pos_reader, pos_status_writer', db);
end
$$;

grant usage on schema pos to pos_reader, pos_status_writer;
grant select on pos.v_pesanan, pos.v_item_pesanan, pos.v_pelanggan, pos.v_pengaturan_ongkir to pos_reader;
grant execute on function public.pesanan_pos(timestamptz) to pos_reader;
grant execute on function pos.pos_set_order_status(uuid, text, boolean) to pos_status_writer;

select
  has_schema_privilege('pos_reader', 'pos', 'USAGE')                                                as reader_usage_pos,
  has_table_privilege('pos_reader', 'pos.v_pesanan', 'SELECT')
    and has_function_privilege('pos_reader', 'public.pesanan_pos(timestamptz)', 'EXECUTE')          as reader_baca_v_pesanan,
  has_table_privilege('pos_reader', 'public.orders', 'SELECT')                                      as reader_baca_orders,
  has_function_privilege('pos_status_writer', 'pos.pos_set_order_status(uuid,text,boolean)', 'EXECUTE') as writer_execute,
  has_function_privilege('pos_reader', 'pos.pos_set_order_status(uuid,text,boolean)', 'EXECUTE')       as reader_execute,
  has_table_privilege('pos_status_writer', 'pos.v_pesanan', 'SELECT')                               as writer_baca_view;
-- Harapan: true, true, false, true, false, false
