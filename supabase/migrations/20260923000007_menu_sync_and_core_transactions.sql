-- =====================================================================
-- Sinkron menu dari website + buka shift + transaksi inti & pembayaran
--
-- Prinsip:
--   * Semua penulisan data operasional lewat fungsi (RPC) security
--     definer — tabel tetap tanpa policy INSERT/UPDATE/DELETE untuk
--     authenticated. Harga, markup, dan total dihitung di server dari
--     cache menu, bukan dari kiriman tablet.
--   * Policy SELECT: semua pengguna POS aktif boleh membaca data referensi
--     dan operasional. Pembatasan laporan per izin menyusul di tahap laporan.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Izin baru
-- ---------------------------------------------------------------------
insert into public.permissions (code, label, sort_order) values
  ('sync_menu', 'Sinkron menu dari website', 11);

insert into public.role_permissions (role_id, permission_code, granted)
select r.id, 'sync_menu', r.code = 'owner'
from public.roles r;

-- ---------------------------------------------------------------------
-- Log sinkron menu
-- ---------------------------------------------------------------------
create table public.menu_sync_runs (
  id            uuid primary key default gen_random_uuid(),
  trigger       text not null check (trigger in ('cron', 'manual')),
  triggered_by  uuid references public.pos_users (id),
  status        text not null check (status in ('success', 'failed')),
  products      integer,
  variants      integer,
  toppings      integer,
  error         text,
  created_at    timestamptz not null default now()
);

create index menu_sync_runs_created_idx on public.menu_sync_runs (created_at desc);

alter table public.menu_sync_runs enable row level security;
grant select, insert, update, delete on public.menu_sync_runs to service_role;
grant select on public.menu_sync_runs to authenticated;

-- Dipanggil Edge Function sync-menu (service_role) dalam satu transaksi
-- database: semua berubah bersama, atau tidak sama sekali.
-- Item yang hilang dari website dinonaktifkan (tidak dihapus).
create or replace function public.apply_menu_sync(
  p_payload jsonb,
  p_trigger text,
  p_triggered_by uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_products integer;
  v_variants integer;
  v_toppings integer;
begin
  if jsonb_array_length(coalesce(p_payload -> 'products', '[]')) = 0 then
    raise exception 'SINKRON_KOSONG: website tidak mengirim produk apa pun, sinkron dibatalkan';
  end if;

  -- Produk (paket & kind lain di luar cakupan Fase 1 dilewati)
  create temp table _src_products on commit drop as
  select *
  from jsonb_to_recordset(p_payload -> 'products') as x(
    id text, name text, category_slug text, section_key text, kind text,
    base_price integer, active boolean, sort_order integer)
  where x.kind in ('sized', 'simple', 'variant');

  insert into public.products_cache as c
    (id, name, category, section_key, kind, base_price, active, sort_order, last_synced_at)
  select id, name, category_slug, section_key, kind, base_price,
         coalesce(active, true), coalesce(sort_order, 0), now()
  from _src_products
  on conflict (id) do update set
    name = excluded.name,
    category = excluded.category,
    section_key = excluded.section_key,
    kind = excluded.kind,
    base_price = excluded.base_price,
    active = excluded.active,
    sort_order = excluded.sort_order,
    last_synced_at = excluded.last_synced_at;

  update public.products_cache
  set active = false, last_synced_at = now()
  where id not in (select id from _src_products) and active;

  select count(*) into v_products from _src_products;

  -- Varian
  create temp table _src_variants on commit drop as
  select x.*
  from jsonb_to_recordset(p_payload -> 'variants') as x(
    id uuid, menu_item_id text, variant_key text, label text, price integer, sort_order integer)
  where x.menu_item_id in (select id from _src_products);

  delete from public.product_variants_cache
  where id not in (select id from _src_variants);

  insert into public.product_variants_cache as c
    (id, product_id, variant_key, label, price, sort_order, last_synced_at)
  select id, menu_item_id, variant_key, label, price, coalesce(sort_order, 0), now()
  from _src_variants
  on conflict (id) do update set
    product_id = excluded.product_id,
    variant_key = excluded.variant_key,
    label = excluded.label,
    price = excluded.price,
    sort_order = excluded.sort_order,
    last_synced_at = excluded.last_synced_at;

  select count(*) into v_variants from _src_variants;

  -- Topping
  create temp table _src_toppings on commit drop as
  select *
  from jsonb_to_recordset(coalesce(p_payload -> 'toppings', '[]')) as x(
    id text, name text, active boolean, sort_order integer);

  insert into public.xtratopping_cache as c (id, name, active, sort_order, last_synced_at)
  select id, name, coalesce(active, true), coalesce(sort_order, 0), now()
  from _src_toppings
  on conflict (id) do update set
    name = excluded.name,
    active = excluded.active,
    sort_order = excluded.sort_order,
    last_synced_at = excluded.last_synced_at;

  update public.xtratopping_cache
  set active = false, last_synced_at = now()
  where id not in (select id from _src_toppings) and active;

  select count(*) into v_toppings from _src_toppings;

  -- Harga topping per ukuran
  insert into public.xtratopping_price_cache as c (variant_key, price, last_synced_at)
  select x.variant_key, x.price, now()
  from jsonb_to_recordset(coalesce(p_payload -> 'topping_prices', '[]')) as x(variant_key text, price integer)
  where x.variant_key in ('personal', 'medium', 'large')
  on conflict (variant_key) do update set
    price = excluded.price,
    last_synced_at = excluded.last_synced_at;

  insert into public.menu_sync_runs (trigger, triggered_by, status, products, variants, toppings)
  values (p_trigger, p_triggered_by, 'success', v_products, v_variants, v_toppings);

  return jsonb_build_object('products', v_products, 'variants', v_variants, 'toppings', v_toppings);
end;
$$;

-- ---------------------------------------------------------------------
-- Policy SELECT untuk pengguna POS aktif
-- ---------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    'outlets', 'products_cache', 'product_variants_cache', 'xtratopping_cache',
    'xtratopping_price_cache', 'payment_methods', 'marketplace_platforms',
    'roles', 'permissions', 'role_permissions', 'shifts', 'cash_movements',
    'transactions', 'transaction_items', 'transaction_item_addons', 'menu_sync_runs'
  ] loop
    execute format(
      'create policy pos_users_read on public.%I for select to authenticated
         using ((select public.current_pos_user_id()) is not null)', t);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- Buka shift
-- ---------------------------------------------------------------------
create or replace function public.open_shift(p_outlet_id uuid, p_opening_balance bigint)
returns public.shifts
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := public.current_pos_user_id();
  v_shift public.shifts;
begin
  if v_user is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;
  if p_opening_balance is null or p_opening_balance < 0 then
    raise exception 'SALDO_TIDAK_VALID: saldo awal tidak boleh kosong atau negatif';
  end if;
  if not exists (select 1 from public.outlets where id = p_outlet_id and active) then
    raise exception 'OUTLET_TIDAK_VALID: outlet tidak ditemukan';
  end if;

  begin
    insert into public.shifts (outlet_id, cashier_id, opening_balance)
    values (p_outlet_id, v_user, p_opening_balance)
    returning * into v_shift;
  exception when unique_violation then
    raise exception 'SHIFT_SUDAH_TERBUKA: sudah ada shift yang terbuka di outlet ini';
  end;

  return v_shift;
end;
$$;

-- ---------------------------------------------------------------------
-- Buat transaksi (channel admin_toko / marketplace)
--
-- p_payload:
-- {
--   "outlet_id": uuid,
--   "channel": "admin_toko" | "marketplace",
--   "sales_type": "dine_in" | "take_away" | "delivery",   (marketplace → delivery)
--   "marketplace_platform_id": uuid,                         (wajib untuk marketplace)
--   "markup_percent": number,                                (opsional, override)
--   "shipping_cost": integer,                                (admin_toko + delivery)
--   "customer_name", "customer_phone", "notes": text,
--   "items": [{
--     "product_id": text, "variant_id": uuid|null, "qty": int, "notes": text,
--     "toppings": [{ "id": text, "qty": int }]              (hanya kind = 'sized')
--   }]
-- }
-- ---------------------------------------------------------------------
create or replace function public.create_transaction(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user        uuid := public.current_pos_user_id();
  v_outlet_id   uuid := (p_payload ->> 'outlet_id')::uuid;
  v_channel     text := p_payload ->> 'channel';
  v_sales_type  text := p_payload ->> 'sales_type';
  v_platform_id uuid := nullif(p_payload ->> 'marketplace_platform_id', '')::uuid;
  v_shipping    bigint := coalesce((p_payload ->> 'shipping_cost')::bigint, 0);
  v_shift_id    uuid;
  v_pct         numeric(5,2);
  v_default_pct numeric(5,2);
  v_mult        numeric := 1;
  v_tx          public.transactions;
  v_item        jsonb;
  v_top         jsonb;
  v_product     public.products_cache;
  v_variant     public.product_variants_cache;
  v_qty         integer;
  v_top_qty     integer;
  v_base        bigint;
  v_unit        bigint;
  v_top_name    text;
  v_top_base    bigint;
  v_top_unit    bigint;
  v_top_sum     bigint;
  v_top_markup  bigint;
  v_item_id     uuid;
  v_subtotal    bigint := 0;
  v_markup      bigint := 0;
begin
  if v_user is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;

  if v_channel is null or v_channel not in ('admin_toko', 'marketplace') then
    raise exception 'CHANNEL_TIDAK_VALID: transaksi kasir hanya untuk channel admin_toko atau marketplace';
  end if;

  select id into v_shift_id
  from public.shifts
  where outlet_id = v_outlet_id and status = 'open';
  if v_shift_id is null then
    raise exception 'SHIFT_BELUM_DIBUKA: buka shift terlebih dahulu';
  end if;

  if jsonb_array_length(coalesce(p_payload -> 'items', '[]')) = 0 then
    raise exception 'KERANJANG_KOSONG: tambahkan minimal satu item';
  end if;

  if v_channel = 'marketplace' then
    v_sales_type := 'delivery';
    select markup_percent into v_default_pct
    from public.marketplace_platforms
    where id = v_platform_id and active;
    if v_default_pct is null then
      raise exception 'PLATFORM_TIDAK_VALID: pilih platform marketplace';
    end if;

    v_pct := coalesce((p_payload ->> 'markup_percent')::numeric, v_default_pct);
    if v_pct <> v_default_pct and not public.has_permission('override_markup') then
      raise exception 'TIDAK_BERIZIN: Anda tidak punya izin mengubah markup';
    end if;
    if v_pct < 0 then
      raise exception 'MARKUP_TIDAK_VALID: markup tidak boleh negatif';
    end if;
    v_mult := 1 + v_pct / 100;
  else
    v_platform_id := null;
  end if;

  if v_sales_type is null or v_sales_type not in ('dine_in', 'take_away', 'delivery') then
    raise exception 'TIPE_TIDAK_VALID: pilih tipe penjualan';
  end if;
  if v_shipping < 0 then
    raise exception 'ONGKIR_TIDAK_VALID: ongkir tidak boleh negatif';
  end if;
  if v_shipping > 0 and not (v_channel = 'admin_toko' and v_sales_type = 'delivery') then
    raise exception 'ONGKIR_TIDAK_BERLAKU: ongkir hanya untuk pesanan delivery admin toko';
  end if;

  insert into public.transactions (
    outlet_id, channel, sales_type, marketplace_platform_id, markup_percent_applied,
    shipping_cost, subtotal, total,
    customer_name, customer_phone, notes, cashier_id, shift_id
  ) values (
    v_outlet_id, v_channel, v_sales_type, v_platform_id, v_pct,
    v_shipping, 0, v_shipping,
    nullif(trim(p_payload ->> 'customer_name'), ''),
    nullif(trim(p_payload ->> 'customer_phone'), ''),
    nullif(trim(p_payload ->> 'notes'), ''),
    v_user, v_shift_id
  )
  returning * into v_tx;

  for v_item in select * from jsonb_array_elements(p_payload -> 'items') loop
    v_qty := (v_item ->> 'qty')::integer;
    if v_qty is null or v_qty < 1 or v_qty > 999 then
      raise exception 'QTY_TIDAK_VALID: jumlah item harus 1–999';
    end if;

    select * into v_product
    from public.products_cache
    where id = v_item ->> 'product_id' and active;
    if v_product.id is null then
      raise exception 'PRODUK_TIDAK_TERSEDIA: produk % tidak tersedia', v_item ->> 'product_id';
    end if;

    v_variant := null;
    if v_product.kind in ('sized', 'variant') then
      select * into v_variant
      from public.product_variants_cache
      where id = nullif(v_item ->> 'variant_id', '')::uuid and product_id = v_product.id;
      if v_variant.id is null then
        raise exception 'VARIAN_TIDAK_VALID: pilih ukuran/varian untuk %', v_product.name;
      end if;
      v_base := v_variant.price;
    else
      if v_product.base_price is null then
        raise exception 'HARGA_TIDAK_ADA: produk % belum punya harga', v_product.name;
      end if;
      v_base := v_product.base_price;
    end if;

    v_unit := round(v_base * v_mult);

    insert into public.transaction_items (
      transaction_id, product_id, product_name_snapshot, category_snapshot,
      variant_id, variant_key_snapshot, variant_name_snapshot,
      variant_price_snapshot, unit_price, qty, subtotal_item, notes
    ) values (
      v_tx.id, v_product.id, v_product.name, v_product.category,
      v_variant.id, v_variant.variant_key, v_variant.label,
      v_base, v_unit, v_qty, 0, nullif(trim(v_item ->> 'notes'), '')
    )
    returning id into v_item_id;

    v_top_sum := 0;
    v_top_markup := 0;

    if jsonb_array_length(coalesce(v_item -> 'toppings', '[]')) > 0 then
      if v_product.kind <> 'sized' then
        raise exception 'TOPPING_TIDAK_BERLAKU: extra topping hanya untuk pizza';
      end if;

      select price into v_top_base
      from public.xtratopping_price_cache
      where variant_key = v_variant.variant_key;
      if v_top_base is null then
        raise exception 'HARGA_TOPPING_TIDAK_ADA: harga topping ukuran % belum tersedia', v_variant.label;
      end if;
      v_top_unit := round(v_top_base * v_mult);

      for v_top in select * from jsonb_array_elements(v_item -> 'toppings') loop
        v_top_qty := coalesce((v_top ->> 'qty')::integer, 1);
        if v_top_qty < 1 or v_top_qty > 20 then
          raise exception 'QTY_TIDAK_VALID: jumlah topping harus 1–20';
        end if;

        select name into v_top_name
        from public.xtratopping_cache
        where id = v_top ->> 'id' and active;
        if v_top_name is null then
          raise exception 'TOPPING_TIDAK_TERSEDIA: topping % tidak tersedia', v_top ->> 'id';
        end if;

        insert into public.transaction_item_addons (
          transaction_item_id, addon_id, addon_name_snapshot, addon_price_snapshot, unit_price, qty
        ) values (
          v_item_id, v_top ->> 'id', v_top_name, v_top_base, v_top_unit, v_top_qty
        );

        v_top_sum := v_top_sum + v_top_unit * v_top_qty;
        v_top_markup := v_top_markup + (v_top_unit - v_top_base) * v_top_qty;
      end loop;
    end if;

    update public.transaction_items
    set subtotal_item = v_qty * (v_unit + v_top_sum)
    where id = v_item_id;

    v_subtotal := v_subtotal + v_qty * (v_unit + v_top_sum);
    v_markup := v_markup + v_qty * ((v_unit - v_base) + v_top_markup);
  end loop;

  update public.transactions
  set subtotal = v_subtotal,
      markup_amount = v_markup,
      total = v_subtotal + v_shipping
  where id = v_tx.id
  returning * into v_tx;

  return jsonb_build_object(
    'id', v_tx.id,
    'transaction_number', v_tx.transaction_number,
    'total', v_tx.total
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Pembayaran (satu metode per transaksi)
-- Tunai: uang diterima ≥ total, kembalian dihitung server.
-- Non-tunai: dianggap pas sebesar total.
-- Transaksi dicatat ke shift yang sedang terbuka saat uang diterima.
-- ---------------------------------------------------------------------
create or replace function public.pay_transaction(
  p_transaction_id uuid,
  p_payment_method_id uuid,
  p_amount_paid bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := public.current_pos_user_id();
  v_tx       public.transactions;
  v_method   public.payment_methods;
  v_shift_id uuid;
  v_paid     bigint;
begin
  if v_user is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;

  select * into v_tx from public.transactions where id = p_transaction_id for update;
  if v_tx.id is null then
    raise exception 'TRANSAKSI_TIDAK_ADA: transaksi tidak ditemukan';
  end if;
  if v_tx.status <> 'active' then
    raise exception 'TRANSAKSI_BATAL: transaksi sudah dibatalkan';
  end if;
  if v_tx.payment_status = 'paid' then
    raise exception 'SUDAH_LUNAS: transaksi % sudah dibayar', v_tx.transaction_number;
  end if;

  select * into v_method from public.payment_methods where id = p_payment_method_id and active;
  if v_method.id is null then
    raise exception 'METODE_TIDAK_VALID: pilih metode pembayaran';
  end if;

  select id into v_shift_id
  from public.shifts
  where outlet_id = v_tx.outlet_id and status = 'open';
  if v_shift_id is null then
    raise exception 'SHIFT_BELUM_DIBUKA: buka shift terlebih dahulu';
  end if;

  if v_method.is_cash then
    if p_amount_paid is null or p_amount_paid < v_tx.total then
      raise exception 'UANG_KURANG: uang diterima kurang dari total';
    end if;
    v_paid := p_amount_paid;
  else
    v_paid := v_tx.total;
  end if;

  update public.transactions
  set payment_status = 'paid',
      payment_method_id = v_method.id,
      amount_paid = v_paid,
      change_amount = v_paid - v_tx.total,
      paid_at = now(),
      shift_id = v_shift_id
  where id = v_tx.id
  returning * into v_tx;

  return jsonb_build_object(
    'id', v_tx.id,
    'transaction_number', v_tx.transaction_number,
    'total', v_tx.total,
    'amount_paid', v_tx.amount_paid,
    'change_amount', v_tx.change_amount
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Hak eksekusi
-- ---------------------------------------------------------------------
revoke execute on function public.apply_menu_sync(jsonb, text, uuid) from public, anon, authenticated;
grant execute on function public.apply_menu_sync(jsonb, text, uuid) to service_role;

revoke execute on function public.open_shift(uuid, bigint) from public, anon;
revoke execute on function public.create_transaction(jsonb) from public, anon;
revoke execute on function public.pay_transaction(uuid, uuid, bigint) from public, anon;
grant execute on function public.open_shift(uuid, bigint) to authenticated;
grant execute on function public.create_transaction(jsonb) to authenticated;
grant execute on function public.pay_transaction(uuid, uuid, bigint) to authenticated;
