-- =====================================================================
-- Hak akses tabel eksplisit
--
-- Project ini TIDAK otomatis memberi hak SELECT/INSERT/UPDATE/DELETE ke
-- role Data API untuk tabel baru. Konvensi mulai sekarang: setiap tabel
-- baru wajib diberi GRANT eksplisit di migration yang sama.
--
--   * anon          : tidak punya akses tabel sama sekali.
--   * authenticated : hak dasar per tabel; yang benar-benar terlihat /
--                     boleh diubah tetap ditentukan policy RLS (saat ini
--                     belum ada policy = tertutup).
--   * service_role  : akses penuh (Edge Function; melewati RLS).
-- =====================================================================

revoke all on all tables in schema public from anon, authenticated;

grant select, insert, update, delete on all tables in schema public to service_role;

-- Referensi & pengaturan: dibaca aplikasi; sebagian diubah lewat izin
-- (edit_markup, manage_permissions) yang nanti dijaga RLS.
grant select on
  public.outlets,
  public.products_cache,
  public.product_variants_cache,
  public.xtratopping_cache,
  public.xtratopping_price_cache,
  public.payment_methods,
  public.roles,
  public.permissions
to authenticated;

grant select, update on
  public.marketplace_platforms,
  public.role_permissions
to authenticated;

-- Operasional kasir.
grant select, insert, update on
  public.transactions,
  public.shifts
to authenticated;

grant select, insert on public.cash_movements to authenticated;

grant select, insert, update, delete on
  public.transaction_items,
  public.transaction_item_addons
to authenticated;

-- Sengaja tanpa grant untuk authenticated:
--   * pos_users            — berisi pin_hash; diakses lewat fungsi
--                            (get_my_profile, nanti RPC kelola pengguna).
--   * transaction_counters — hanya diubah trigger nomor transaksi.
