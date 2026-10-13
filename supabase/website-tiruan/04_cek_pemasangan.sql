-- =====================================================================
-- 04_cek_pemasangan.sql — bukti pemasangan (baca saja). Jalankan sebagai superuser di website_tiruan.
-- Harapan (satu baris):
--   menu 58 · pesanan_rekaan 12 · v_pesanan 10 · v_pelanggan >= 8 · ongkir 1 · outlet_lat 0.47939978361032837
--   menunggu_admin 2 · terkunci_edit 1 · format_lama 1 (PL-REKAAN10) · go_live_terisi true
--   reader_login true · writer_login true · status_7_nilai true
-- =====================================================================
select
  (select count(*) from public.menu_items)                                               as menu,
  (select count(*) from public.orders where order_code like 'PL-REKAAN%')                as pesanan_rekaan,
  (select count(*) from pos.v_pesanan)                                                   as v_pesanan,
  (select count(*) from pos.v_pelanggan)                                                 as v_pelanggan,
  (select count(*) from pos.v_pengaturan_ongkir)                                         as ongkir,
  (select outlet_lat::text from pos.v_pengaturan_ongkir)                                 as outlet_lat,
  (select count(*) from pos.v_pesanan where menunggu_admin)                              as menunggu_admin,
  (select count(*) from pos.v_pesanan where terkunci_edit)                               as terkunci_edit,
  (select count(distinct order_id) from pos.v_item_pesanan where not (options ? '_format')) as format_lama,
  (select go_live_at is not null from public.pengaturan_pos)                             as go_live_terisi,
  (select rolcanlogin from pg_roles where rolname = 'pos_reader')                        as reader_login,
  (select rolcanlogin from pg_roles where rolname = 'pos_status_writer')                 as writer_login,
  pg_get_constraintdef((select oid from pg_constraint where conname = 'orders_status_check'))
    like '%sedang_diantar%'                                                              as status_7_nilai;
