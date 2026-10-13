-- =====================================================================
-- 05_alat_uji.sql — potongan SQL untuk meniru kejadian di sisi WEBSITE selama uji POS lokal.
-- JANGAN dijalankan sekaligus: salin potongan yang perlu, jalankan sebagai postgres di website_tiruan.
-- (Di produksi semua ini dilakukan website/admin/Owner — POS tidak pernah punya hak ini.)
-- =====================================================================

-- A. Pesanan baru dari "website" (meniru pelanggan memesan) — buat ulang semua data rekaan:
--    jalankan ulang 03_data_rekaan.sql (aman diulang).

-- B. Admin website menyelesaikan verifikasi HP (menunggu_admin hilang) — PL-REKAAN05:
-- update public.orders set verification_status = 'verified' where order_code = 'PL-REKAAN05';

-- C. Admin website "Konfirmasi Sah" diskon ditahan — PL-REKAAN06 (angka tetap):
-- update public.orders set discount_held = false, verification_status = 'verified' where order_code = 'PL-REKAAN06';
--    atau "Cabut Diskon" (angka header berubah — POS harus memakai angka terbaru):
-- select public.resolusi_diskon_tertahan('PL-REKAAN06', null, 'cabut_diskon');

-- D. Pembayaran online LUNAS (meniru webhook Midtrans) — PL-REKAAN07:
-- update public.orders set status_bayar = 'lunas', dibayar_rupiah = total, dibayar_at = now(),
--        gateway = 'midtrans', gateway_ref = 'REKAAN-TRX-07' where order_code = 'PL-REKAAN07';

-- E. QRIS kedaluwarsa — PL-REKAAN08 (penanda kasir boleh lagi):
-- update public.orders set status_bayar = 'kedaluwarsa' where order_code = 'PL-REKAAN08';

-- F. Saklar darurat go-live (meniru Owner): kosongkan → v_pesanan kosong, fungsi menolak semua;
--    isi lagi → kembali normal.
-- update public.pengaturan_pos set go_live_at = null where id = 1;
-- update public.pengaturan_pos set go_live_at = now() - interval '20 days' where id = 1;

-- G. Lihat riwayat status (yang ditulis trigger; sumber 'pos' bila dari login pos_status_writer):
-- select order_code, dari, ke, sumber, catatan, waktu from public.order_status_log order by id desc limit 20;

-- H. Contoh panggilan POS (login sebagai pos_status_writer):
--   (pos_status_writer tak bisa SELECT apa pun — ambil id pesanan dari pos.v_pesanan lewat pos_reader.)
-- select pos.pos_set_order_status('<id dari v_pesanan>'::uuid, 'diterima');
-- select pos.pos_set_order_status('<id dari v_pesanan>'::uuid, 'diterima', true);  -- + penanda diubah kasir
-- select pos.pos_set_order_status('<id dari v_pesanan>'::uuid, 'dibatalkan');
