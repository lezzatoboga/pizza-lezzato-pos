-- =====================================================================
-- 02_peran_pos_lokal.sql — DIBUAT OTOMATIS oleh scripts/buat-paket-website-tiruan.mjs (repo website).
-- Peran POS untuk LINGKUNGAN UJI LOKAL saja. Jalankan sebagai superuser di database website_tiruan,
-- SESUDAH 01 (03 boleh sebelum/sesudah). Aman diulang.
--
-- Bagian 1 = salinan PERSIS supabase/APPLY_KONTRAK_POS_2_PERAN.sql (berkas yang dijalankan Owner di produksi,
--            tahap 5): hak akses & pengaturan per peran (read-only, statement_timeout, lock_timeout,
--            idle_in_transaction_session_timeout, batas koneksi) sama dengan produksi.
-- Bagian 2 = khusus lokal: LOGIN + kata sandi UJI LOKAL (di produksi: tahap 7, kata sandi milik Owner,
--            lewat verifier SCRAM — tak pernah di berkas).
--
-- KATA SANDI DI BAGIAN 2 HANYA UNTUK UJI LOKAL — bukan kata sandi produksi dan tak boleh dipakai di produksi.
-- Peran berlaku se-cluster (Supabase lokal: seluruh stack POS); hak hanya ada di website_tiruan.
-- =====================================================================

-- ---------------- Bagian 1: APPLY_KONTRAK_POS_2_PERAN.sql ----------------
-- =====================================================================
-- KONTRAK POS 2 — peran & hak akses POS (docs/KONTRAK-DATA-POS.md §2.1, §2.2; rencana
-- docs/RENCANA-KONTRAK-POS-TAHAP-5-7.md tahap 5). Jalankan SESUDAH 1A, 1A2, 1B, 1C. Aman diulang.
--
-- Isi:
--   1. Penjaga: batal bila objek tahap 1C belum ada.
--   2. pos_status_writer dibuat NOLOGIN NOINHERIT, maks. 2 koneksi (bila belum ada).
--   3. pos_reader: maks. 3 koneksi; read-only, statement_timeout 5s, idle_in_transaction 30s.
--      pos_status_writer: statement_timeout 5s, lock_timeout 3s, idle_in_transaction 30s.
--      (pengaturan PER PERAN — ikut terbawa lewat pooler)
--   4. pos_reader: USAGE schema pos, SELECT 4 view, EXECUTE public.pesanan_pos(timestamptz)
--      (wajib: v_pesanan memanggil fungsi itu, dan hak fungsi di dalam view diperiksa terhadap
--      PENGGUNA view). Akses lama 6 kolom public.customers TETAP (transisi; dicabut tahap 8).
--   5. pos_status_writer: USAGE schema pos, EXECUTE pos.pos_set_order_status — tanpa hak tabel/view.
--
-- TIDAK ADA KATA SANDI DAN TIDAK ADA LOGIN di berkas ini. Status LOGIN kedua peran tidak disentuh
-- (dijalankan ulang sesudah tahap 7 tidak mematikan POS). Login & kata sandi = tahap 7, oleh Owner,
-- lewat scripts/buat-verifier-scram.mjs.
--
-- Untuk situs yang sedang berjalan: aman — hanya peran & hak akses; tidak menyentuh tabel, data, atau
-- hak anon/authenticated/service_role. Tak ada yang bisa login, dan go_live_at NULL (v_pesanan kosong,
-- fungsi menolak semua).
--
-- Hasil yang diharapkan (baris SELECT terakhir, produksi sebelum tahap 7):
--   reader_login = false, writer_login = false, writer_noinherit = true,
--   reader_batas = 3, writer_batas = 2,
--   reader_pengaturan = 'default_transaction_read_only=on, idle_in_transaction_session_timeout=30s, statement_timeout=5s'
--   writer_pengaturan = 'idle_in_transaction_session_timeout=30s, lock_timeout=3s, statement_timeout=5s'
--   reader_baca_4_view = true, reader_execute_pesanan_pos = true, reader_execute_fungsi_pos = false,
--   reader_tabel = '' (kosong), reader_kolom = 'public.customers' (transisi, dicabut tahap 8),
--   writer_execute_fungsi_pos = true, writer_tabel = '', writer_kolom = '',
--   reader_definer_lain = '', writer_definer_lain = '',
--   siapa_execute_fungsi_pos = 'pos_status_writer', supabase_usage_pos = false, go_live_kosong = true
-- reader_definer_lain / writer_definer_lain TIDAK kosong → jangan lanjut ke tahap 7; kirim isinya ke sesi website.
-- Pembalikan: ROLLBACK_KONTRAK_POS_2_PERAN.sql.
-- =====================================================================

begin;

-- 1. Penjaga ------------------------------------------------------------------------------------------
do $$
begin
  if to_regnamespace('pos') is null
     or to_regclass('pos.v_pesanan') is null or to_regclass('pos.v_item_pesanan') is null
     or to_regclass('pos.v_pelanggan') is null or to_regclass('pos.v_pengaturan_ongkir') is null
     or to_regprocedure('pos.pos_set_order_status(uuid, text, boolean)') is null
     or to_regprocedure('public.pesanan_pos(timestamptz)') is null then
    raise exception 'Objek tahap 1C belum lengkap (schema pos, 4 view, pos_set_order_status, pesanan_pos) — jalankan APPLY_KONTRAK_POS_1A/1A2/1B/1C dulu.';
  end if;
end
$$;

-- 2. Peran --------------------------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'pos_reader') then
    create role pos_reader nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'pos_status_writer') then
    create role pos_status_writer nologin noinherit connection limit 2;
  end if;
end
$$;
-- Ditegakkan juga saat diulang — LOGIN/kata sandi sengaja tidak disebut.
alter role pos_status_writer noinherit connection limit 2;
alter role pos_reader connection limit 3;

-- 3. Pengaturan per peran (berlaku untuk koneksi BARU) --------------------------------------------------
alter role pos_reader set default_transaction_read_only = on;
alter role pos_reader set statement_timeout = '5s';
alter role pos_reader set idle_in_transaction_session_timeout = '30s';
alter role pos_status_writer set statement_timeout = '5s';
alter role pos_status_writer set lock_timeout = '3s';
alter role pos_status_writer set idle_in_transaction_session_timeout = '30s';

-- 4. Hak pos_reader -----------------------------------------------------------------------------------
grant usage on schema pos to pos_reader;
grant select on pos.v_pesanan, pos.v_item_pesanan, pos.v_pelanggan, pos.v_pengaturan_ongkir to pos_reader;
grant execute on function public.pesanan_pos(timestamptz) to pos_reader;

-- 5. Hak pos_status_writer ----------------------------------------------------------------------------
grant usage on schema pos to pos_status_writer;
grant execute on function pos.pos_set_order_status(uuid, text, boolean) to pos_status_writer;

commit;

-- ---------------- Bagian 2: khusus lokal ----------------
do $$
declare
  db text := current_database();
begin
  execute 'alter role pos_reader login password ''lokal-pos-reader-uji''';
  execute 'alter role pos_status_writer login password ''lokal-pos-status-writer-uji''';
  -- paket lama (41e0503) memasang pengaturan per database; kini per peran seperti produksi
  execute format('alter role pos_reader in database %I reset all', db);
  execute format('alter role pos_status_writer in database %I reset all', db);
  execute format('grant connect on database %I to pos_reader, pos_status_writer', db);
end
$$;

select
  has_schema_privilege('pos_reader', 'pos', 'USAGE')                                                as reader_usage_pos,
  has_table_privilege('pos_reader', 'pos.v_pesanan', 'SELECT')
    and has_function_privilege('pos_reader', 'public.pesanan_pos(timestamptz)', 'EXECUTE')          as reader_baca_v_pesanan,
  has_table_privilege('pos_reader', 'public.orders', 'SELECT')                                      as reader_baca_orders,
  has_function_privilege('pos_status_writer', 'pos.pos_set_order_status(uuid,text,boolean)', 'EXECUTE') as writer_execute,
  has_function_privilege('pos_reader', 'pos.pos_set_order_status(uuid,text,boolean)', 'EXECUTE')       as reader_execute,
  has_table_privilege('pos_status_writer', 'pos.v_pesanan', 'SELECT')                               as writer_baca_view;
-- Harapan: true, true, false, true, false, false
