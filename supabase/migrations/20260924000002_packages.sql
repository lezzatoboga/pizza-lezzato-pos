-- =====================================================================
-- Paket (menu_items.kind = 'package') masuk POS Fase 1
--
--   * packages_cache: disinkron dari menu_items website (kind = package).
--   * Harga paket = base_price paket (tetap), × (1 + markup%) untuk
--     marketplace — sama seperti item lain. Tanpa extra topping.
--   * package_choices wajib dipilih kasir, satu opsi per grup, divalidasi
--     server terhadap cache. package_note hanya info tetap (tanpa validasi).
--   * Baris transaksi paket menyimpan snapshot isi, pilihan, dan note.
-- =====================================================================

create table public.packages_cache (
  id               text primary key,        -- = menu_items.id (mis. 'pb1')
  name             text not null,
  category_slug    text,
  section_key      text,
  base_price       integer not null check (base_price >= 0),
  package_items    jsonb,                   -- ["1 Medium Pizza", ...] apa adanya
  package_choices  jsonb,                   -- [{"key","label","options":[...]}] apa adanya
  package_note     text,
  sort_order       integer not null default 0,
  active           boolean not null default true,
  last_synced_at   timestamptz not null default now()
);

alter table public.packages_cache enable row level security;
grant select, insert, update, delete on public.packages_cache to service_role;
grant select on public.packages_cache to authenticated;
create policy pos_users_read on public.packages_cache for select to authenticated
  using ((select public.current_pos_user_id()) is not null);

-- ---------------------------------------------------------------------
-- Baris transaksi paket
-- ---------------------------------------------------------------------
alter table public.transaction_items
  add column item_type                text not null default 'product',
  add column package_items_snapshot   jsonb,
  add column package_choices_snapshot jsonb,
  add column package_note_snapshot    text,
  add constraint transaction_items_item_type check (item_type in ('product', 'package')),
  add constraint transaction_items_package_no_variant check (
    item_type = 'product'
    or (variant_id is null and variant_key_snapshot is null and variant_name_snapshot is null)
  );

comment on column public.transaction_items.product_id is
  'id produk (products_cache) atau id paket (packages_cache) sesuai item_type.';
comment on column public.transaction_items.package_choices_snapshot is
  'Pilihan kasir: [{"key":"pizza","label":"Pilihan Pizza","value":"Meat Lovers"}].';

-- ---------------------------------------------------------------------
-- apply_menu_sync: + paket (dari payload products, kind = 'package')
-- ---------------------------------------------------------------------
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
  v_products   integer;
  v_packages   integer;
  v_variants   integer;
  v_toppings   integer;
  v_categories integer;
  v_sections   integer;
begin
  if jsonb_array_length(coalesce(p_payload -> 'products', '[]')) = 0 then
    raise exception 'SINKRON_KOSONG: website tidak mengirim produk apa pun, sinkron dibatalkan';
  end if;

  create temp table _src_items on commit drop as
  select *
  from jsonb_to_recordset(p_payload -> 'products') as x(
    id text, name text, category_slug text, section_key text, kind text,
    base_price integer, active boolean, sort_order integer,
    package_items jsonb, package_choices jsonb, package_note text);

  -- Produk
  create temp table _src_products on commit drop as
  select * from _src_items where kind in ('sized', 'simple', 'variant');

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

  -- Paket (tanpa harga dilewati supaya tidak terjual dengan harga kosong)
  create temp table _src_packages on commit drop as
  select * from _src_items where kind = 'package' and base_price is not null;

  insert into public.packages_cache as c
    (id, name, category_slug, section_key, base_price, package_items, package_choices,
     package_note, sort_order, active, last_synced_at)
  select id, name, category_slug, section_key, base_price,
         coalesce(package_items, '[]'), coalesce(package_choices, '[]'),
         package_note, coalesce(sort_order, 0), coalesce(active, true), now()
  from _src_packages
  on conflict (id) do update set
    name = excluded.name,
    category_slug = excluded.category_slug,
    section_key = excluded.section_key,
    base_price = excluded.base_price,
    package_items = excluded.package_items,
    package_choices = excluded.package_choices,
    package_note = excluded.package_note,
    sort_order = excluded.sort_order,
    active = excluded.active,
    last_synced_at = excluded.last_synced_at;

  update public.packages_cache
  set active = false, last_synced_at = now()
  where id not in (select id from _src_packages) and active;

  select count(*) into v_packages from _src_packages;

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

  -- Kategori & section (dilewati kalau website belum mengirimnya)
  if p_payload ? 'categories' then
    create temp table _src_categories on commit drop as
    select *
    from jsonb_to_recordset(p_payload -> 'categories') as x(slug text, label text, sort_order integer);

    delete from public.menu_categories_cache
    where slug not in (select slug from _src_categories);

    insert into public.menu_categories_cache as c (slug, label, sort_order, last_synced_at)
    select slug, label, coalesce(sort_order, 0), now()
    from _src_categories
    on conflict (slug) do update set
      label = excluded.label,
      sort_order = excluded.sort_order,
      last_synced_at = excluded.last_synced_at;

    select count(*) into v_categories from _src_categories;
  end if;

  if p_payload ? 'sections' then
    create temp table _src_sections on commit drop as
    select *
    from jsonb_to_recordset(p_payload -> 'sections') as x(
      key text, category_slug text, label text, sort_order integer);

    delete from public.menu_sections_cache
    where key not in (select key from _src_sections);

    insert into public.menu_sections_cache as c (key, category_slug, label, sort_order, last_synced_at)
    select key, category_slug, label, coalesce(sort_order, 0), now()
    from _src_sections
    on conflict (key) do update set
      category_slug = excluded.category_slug,
      label = excluded.label,
      sort_order = excluded.sort_order,
      last_synced_at = excluded.last_synced_at;

    select count(*) into v_sections from _src_sections;
  end if;

  insert into public.menu_sync_runs (trigger, triggered_by, status, products, variants, toppings)
  values (p_trigger, p_triggered_by, 'success', v_products + v_packages, v_variants, v_toppings);

  return jsonb_build_object(
    'products', v_products,
    'packages', v_packages,
    'variants', v_variants,
    'toppings', v_toppings,
    'categories', v_categories,
    'sections', v_sections
  );
end;
$$;

revoke execute on function public.apply_menu_sync(jsonb, text, uuid) from public, anon, authenticated;
grant execute on function public.apply_menu_sync(jsonb, text, uuid) to service_role;

-- ---------------------------------------------------------------------
-- create_transaction: + item paket
--
-- Item paket di p_payload.items:
--   { "item_type": "package", "product_id": "pb1", "qty": 1, "notes": "...",
--     "choices": { "pizza": "Meat Lovers" } }
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
  v_group       jsonb;
  v_product     public.products_cache;
  v_package     public.packages_cache;
  v_variant     public.product_variants_cache;
  v_choices     jsonb;
  v_choice      text;
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

    -- ---------------- Paket ----------------
    if coalesce(v_item ->> 'item_type', 'product') = 'package' then
      select * into v_package
      from public.packages_cache
      where id = v_item ->> 'product_id' and active;
      if v_package.id is null then
        raise exception 'PAKET_TIDAK_TERSEDIA: paket % tidak tersedia', v_item ->> 'product_id';
      end if;

      if jsonb_array_length(coalesce(v_item -> 'toppings', '[]')) > 0 then
        raise exception 'TOPPING_TIDAK_BERLAKU: extra topping tidak berlaku untuk paket';
      end if;

      v_choices := '[]'::jsonb;
      for v_group in select * from jsonb_array_elements(coalesce(v_package.package_choices, '[]')) loop
        v_choice := v_item -> 'choices' ->> (v_group ->> 'key');
        if v_choice is null or not coalesce(v_group -> 'options', '[]') ? v_choice then
          raise exception 'PILIHAN_PAKET_WAJIB: pilih % untuk %', v_group ->> 'label', v_package.name;
        end if;
        v_choices := v_choices || jsonb_build_array(jsonb_build_object(
          'key', v_group ->> 'key',
          'label', v_group ->> 'label',
          'value', v_choice
        ));
      end loop;

      v_base := v_package.base_price;
      v_unit := round(v_base * v_mult);

      insert into public.transaction_items (
        transaction_id, item_type, product_id, product_name_snapshot, category_snapshot,
        variant_price_snapshot, unit_price, qty, subtotal_item, notes,
        package_items_snapshot, package_choices_snapshot, package_note_snapshot
      ) values (
        v_tx.id, 'package', v_package.id, v_package.name, coalesce(v_package.category_slug, 'paket'),
        v_base, v_unit, v_qty, v_qty * v_unit, nullif(trim(v_item ->> 'notes'), ''),
        coalesce(v_package.package_items, '[]'), v_choices, v_package.package_note
      );

      v_subtotal := v_subtotal + v_qty * v_unit;
      v_markup := v_markup + v_qty * (v_unit - v_base);
      continue;
    end if;

    -- ---------------- Produk ----------------
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

revoke execute on function public.create_transaction(jsonb) from public, anon;
grant execute on function public.create_transaction(jsonb) to authenticated;
