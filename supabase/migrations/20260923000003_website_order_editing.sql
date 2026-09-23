-- =====================================================================
-- Edit pesanan website sebelum diproses final + ongkir + penguncian
-- item di level database.
--
-- Aturan:
--   * Ongkir hanya untuk sales_type = delivery di channel website/admin_toko.
--   * total = subtotal − discount_amount + shipping_cost
--   * original_order_snapshot: hanya channel website, sekali isi tidak
--     bisa diubah/dihapus.
--   * Setelah is_locked = true (struk pernah dicetak), item, topping, dan
--     angka harga transaksi tidak bisa diubah lagi — koreksi lewat void.
--     Berlaku untuk SEMUA channel.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Kolom baru
-- ---------------------------------------------------------------------
alter table public.transactions
  add column shipping_cost           bigint not null default 0 check (shipping_cost >= 0),
  add column original_order_snapshot jsonb,
  add column last_edited_by          uuid references public.pos_users (id),
  add column last_edited_at          timestamptz;

comment on column public.transactions.shipping_cost is
  'Ongkir, diisi manual kasir setelah konfirmasi ke customer. Menambah total.';
comment on column public.transactions.original_order_snapshot is
  'Salinan persis payload pesanan dari jembatan API website sebelum diubah kasir. Tidak bisa diubah setelah diisi.';
comment on column public.transactions.last_edited_by is
  'Kasir terakhir yang mengubah item/ongkir pesanan website.';

alter table public.transaction_items
  add column source_line_ref text;

comment on column public.transaction_items.source_line_ref is
  'Penanda baris pesanan asli di original_order_snapshot. Null untuk item yang ditambahkan kasir.';

-- ---------------------------------------------------------------------
-- Constraint
-- ---------------------------------------------------------------------
alter table public.transactions
  drop constraint transactions_total_consistent;

alter table public.transactions
  add constraint transactions_total_consistent
    check (total = subtotal - discount_amount + shipping_cost),
  add constraint transactions_shipping_rules
    check (
      shipping_cost = 0
      or (sales_type = 'delivery' and channel in ('website', 'admin_toko'))
    ),
  add constraint transactions_snapshot_website_only
    check (original_order_snapshot is null or channel = 'website');

-- ---------------------------------------------------------------------
-- Penjaga di tabel transactions
-- ---------------------------------------------------------------------
create or replace function public.guard_transaction_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Snapshot pesanan asli: sekali isi, permanen.
  if old.original_order_snapshot is not null
     and new.original_order_snapshot is distinct from old.original_order_snapshot then
    raise exception 'SNAPSHOT_PERMANEN: original_order_snapshot tidak boleh diubah atau dihapus';
  end if;

  -- Transaksi terkunci: hanya pembayaran, status pesanan, cetak ulang,
  -- dan void yang masih boleh berubah.
  if old.is_locked and (
       new.outlet_id               is distinct from old.outlet_id
    or new.transaction_number      is distinct from old.transaction_number
    or new.transaction_date        is distinct from old.transaction_date
    or new.channel                 is distinct from old.channel
    or new.sales_type              is distinct from old.sales_type
    or new.marketplace_platform_id is distinct from old.marketplace_platform_id
    or new.source_order_id         is distinct from old.source_order_id
    or new.subtotal                is distinct from old.subtotal
    or new.discount_code           is distinct from old.discount_code
    or new.discount_amount         is distinct from old.discount_amount
    or new.markup_percent_applied  is distinct from old.markup_percent_applied
    or new.markup_amount           is distinct from old.markup_amount
    or new.shipping_cost           is distinct from old.shipping_cost
    or new.total                   is distinct from old.total
    or new.last_edited_by          is distinct from old.last_edited_by
    or new.last_edited_at          is distinct from old.last_edited_at
  ) then
    raise exception 'TRANSAKSI_TERKUNCI: transaksi % sudah dicetak struknya, gunakan void untuk koreksi',
      old.transaction_number;
  end if;

  return new;
end;
$$;

create trigger transactions_guard_update
  before update on public.transactions
  for each row execute function public.guard_transaction_update();

-- ---------------------------------------------------------------------
-- Penjaga di item & topping: tolak perubahan kalau transaksi terkunci.
-- security definer supaya pengecekan tidak terhalang RLS pemanggil.
-- ---------------------------------------------------------------------
create or replace function public.assert_transaction_unlocked(p_transaction_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_locked boolean;
  v_number text;
begin
  select is_locked, transaction_number into v_locked, v_number
  from public.transactions where id = p_transaction_id;

  if v_locked then
    raise exception 'TRANSAKSI_TERKUNCI: item transaksi % tidak bisa diubah setelah struk dicetak, gunakan void',
      v_number;
  end if;
end;
$$;

create or replace function public.guard_transaction_item_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    perform public.assert_transaction_unlocked(old.transaction_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    perform public.assert_transaction_unlocked(new.transaction_id);
    return new;
  end if;
  return old;
end;
$$;

create trigger transaction_items_guard_lock
  before insert or update or delete on public.transaction_items
  for each row execute function public.guard_transaction_item_change();

create or replace function public.guard_transaction_item_addon_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_transaction_id uuid;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    select transaction_id into v_transaction_id
    from public.transaction_items where id = old.transaction_item_id;
    perform public.assert_transaction_unlocked(v_transaction_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    select transaction_id into v_transaction_id
    from public.transaction_items where id = new.transaction_item_id;
    perform public.assert_transaction_unlocked(v_transaction_id);
    return new;
  end if;
  return old;
end;
$$;

create trigger transaction_item_addons_guard_lock
  before insert or update or delete on public.transaction_item_addons
  for each row execute function public.guard_transaction_item_addon_change();

-- Fungsi internal: tidak boleh dipanggil lewat API.
revoke execute on function public.guard_transaction_update() from public, anon, authenticated;
revoke execute on function public.assert_transaction_unlocked(uuid) from public, anon, authenticated;
revoke execute on function public.guard_transaction_item_change() from public, anon, authenticated;
revoke execute on function public.guard_transaction_item_addon_change() from public, anon, authenticated;
