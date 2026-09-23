-- =====================================================================
-- Data referensi awal: outlet utama, metode bayar, platform marketplace,
-- role, permission, dan hak akses default (SPEC bagian 7).
-- Semua bisa diubah Owner lewat aplikasi nanti.
-- =====================================================================

insert into public.outlets (code, name) values
  ('PL', 'Pizza Lezzato — Outlet Utama');

insert into public.payment_methods (code, name, is_cash, sort_order) values
  ('cash',     'Cash',          true,  1),
  ('transfer', 'Transfer Bank', false, 2),
  ('qris',     'QRIS',          false, 3);

-- Markup awal 0% — silakan diisi sesuai persentase tiap platform.
insert into public.marketplace_platforms (code, name, markup_percent, sort_order) values
  ('gofood',     'GoFood',     0, 1),
  ('grabfood',   'GrabFood',   0, 2),
  ('shopeefood', 'ShopeeFood', 0, 3);

insert into public.roles (code, name) values
  ('owner',      'Owner'),
  ('supervisor', 'Supervisor'),
  ('kasir',      'Kasir');

insert into public.permissions (code, label, sort_order) values
  ('view_sales_report',         'Lihat laporan ringkasan',                      1),
  ('view_transaction_detail',   'Lihat laporan detail transaksi',               2),
  ('export_report',             'Ekspor laporan',                               3),
  ('view_finance_report',       'Lihat laporan keuangan & rekap shift',         4),
  ('edit_markup',               'Ubah setting markup marketplace',              5),
  ('override_markup',           'Override markup per transaksi',                6),
  ('void_unlocked_transaction', 'Batalkan transaksi sebelum struk dicetak',     7),
  ('void_transaction',          'Batalkan transaksi setelah struk dicetak',     8),
  ('manage_users',              'Kelola pengguna & PIN',                        9),
  ('manage_permissions',        'Kelola hak akses role',                       10);

-- Matriks default: Owner semua; "Bisa diatur" di spek = default TIDAK,
-- Owner bisa menyalakan kapan saja.
insert into public.role_permissions (role_id, permission_code, granted)
select r.id, p.code,
  case r.code
    when 'owner' then true
    when 'supervisor' then p.code in (
      'view_sales_report', 'view_transaction_detail', 'export_report',
      'view_finance_report', 'override_markup', 'void_unlocked_transaction')
    when 'kasir' then p.code in (
      'override_markup', 'void_unlocked_transaction')
  end
from public.roles r
cross join public.permissions p;
