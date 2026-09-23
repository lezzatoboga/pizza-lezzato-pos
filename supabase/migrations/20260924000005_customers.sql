-- =====================================================================
-- Data pelanggan
--
--   * customers: salinan pelanggan website (sync-customers, upsert by phone)
--     + pelanggan lokal yang dibuat kasir (source_customer_id null).
--     Nomor HP selalu E.164 (+62…), sama dengan website.
--   * Tablet tidak membaca tabel langsung (tanpa policy SELECT); pencarian
--     lewat search_customers: minimal 4 digit / 3 huruf, maks. 10 hasil.
--   * Transaksi menyimpan customer_id + snapshot nama/HP/alamat/patokan;
--     perubahan per pesanan tidak mengubah data master.
--   * Admin toko: pelanggan & alamat wajib untuk delivery, opsional untuk
--     dine-in/take away. Marketplace: tanpa pelanggan (nama = kode pesanan).
-- =====================================================================

create table public.customers (
  id                  uuid primary key default gen_random_uuid(),
  source_customer_id  uuid,                  -- id customers di website; null = dibuat kasir
  name                text not null,
  phone               text not null unique,
  default_address     text,
  default_patokan     text,
  phone_verified      boolean not null default false,
  created_by          uuid references public.pos_users (id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  last_synced_at      timestamptz,
  constraint customers_phone_e164 check (phone ~ '^\+[1-9][0-9]{7,14}$')
);

create index customers_source_idx on public.customers (source_customer_id);
create index customers_name_idx on public.customers (lower(name));

create trigger customers_updated_at before update on public.customers
  for each row execute function public.set_updated_at();

alter table public.customers enable row level security;
grant select, insert, update, delete on public.customers to service_role;
-- authenticated: sengaja tanpa grant/policy — akses hanya lewat fungsi.

alter table public.transactions
  add column customer_id      uuid references public.customers (id),
  add column delivery_address text,
  add column delivery_patokan text,
  add constraint transactions_marketplace_no_customer
    check (channel <> 'marketplace' or customer_id is null);

create index transactions_customer_idx on public.transactions (customer_id);

-- ---------------------------------------------------------------------
-- Log sinkron: dipakai bersama menu & pelanggan
-- ---------------------------------------------------------------------
alter table public.menu_sync_runs
  add column kind      text not null default 'menu' check (kind in ('menu', 'customers')),
  add column customers integer;

update public.permissions
set label = 'Sinkron menu & pelanggan dari website'
where code = 'sync_menu';

-- ---------------------------------------------------------------------
-- Normalisasi nomor HP ke E.164 (default Indonesia)
--   0813…  → +62813…    813… → +62813…    62813… / +62813… → +62813…
-- null kalau tidak valid.
-- ---------------------------------------------------------------------
create or replace function public.normalize_phone(p_phone text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_digits text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if v_digits like '0%' then
    v_digits := '62' || substr(v_digits, 2);
  elsif v_digits like '8%' then
    v_digits := '62' || v_digits;
  end if;

  if v_digits !~ '^[1-9][0-9]{7,14}$' then
    return null;
  end if;
  return '+' || v_digits;
end;
$$;

-- ---------------------------------------------------------------------
-- Pencarian pelanggan (satu kotak: angka = nomor HP, huruf = nama)
-- ---------------------------------------------------------------------
create or replace function public.search_customers(p_query text)
returns table (
  id uuid,
  name text,
  phone text,
  default_address text,
  default_patokan text,
  phone_verified boolean,
  from_website boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_query  text := trim(coalesce(p_query, ''));
  v_digits text;
begin
  if public.current_pos_user_id() is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;

  if v_query ~ '^[+0-9 ()-]+$' then
    v_digits := regexp_replace(v_query, '\D', '', 'g');
    if length(v_digits) < 4 then
      return;
    end if;
    if v_digits like '0%' then
      v_digits := '62' || substr(v_digits, 2);
    end if;

    return query
      select c.id, c.name, c.phone, c.default_address, c.default_patokan,
             c.phone_verified, c.source_customer_id is not null
      from public.customers c
      where substr(c.phone, 2) like '%' || v_digits || '%'
      order by (substr(c.phone, 2) like v_digits || '%') desc, c.name
      limit 10;
  else
    if length(v_query) < 3 then
      return;
    end if;

    return query
      select c.id, c.name, c.phone, c.default_address, c.default_patokan,
             c.phone_verified, c.source_customer_id is not null
      from public.customers c
      where lower(c.name) like '%' || lower(v_query) || '%'
      order by (lower(c.name) like lower(v_query) || '%') desc, c.name
      limit 10;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Sinkron pelanggan dari website (dipanggil Edge Function sync-customers)
-- Upsert by phone; pelanggan lokal dengan nomor sama otomatis tersambung.
-- ---------------------------------------------------------------------
create or replace function public.apply_customer_sync(
  p_customers jsonb,
  p_trigger text,
  p_triggered_by uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_total   integer;
  v_valid   integer;
begin
  create temp table _src_customers on commit drop as
  select x.id as source_id, trim(x.name) as name, public.normalize_phone(x.phone) as phone,
         nullif(trim(x.default_address), '') as default_address,
         nullif(trim(x.default_patokan), '') as default_patokan,
         coalesce(x.phone_verified, false) as phone_verified
  from jsonb_to_recordset(coalesce(p_customers, '[]')) as x(
    id uuid, name text, phone text, default_address text, default_patokan text,
    phone_verified boolean);

  select count(*) into v_total from _src_customers;

  -- Nomor tidak valid / nama kosong dilewati; nomor ganda di website:
  -- ambil satu saja supaya upsert tidak bentrok.
  create temp table _valid_customers on commit drop as
  select distinct on (phone) *
  from _src_customers
  where phone is not null and nullif(name, '') is not null
  order by phone, source_id;

  select count(*) into v_valid from _valid_customers;

  insert into public.customers as c
    (source_customer_id, name, phone, default_address, default_patokan, phone_verified, last_synced_at)
  select source_id, name, phone, default_address, default_patokan, phone_verified, now()
  from _valid_customers
  on conflict (phone) do update set
    source_customer_id = excluded.source_customer_id,
    name = excluded.name,
    default_address = excluded.default_address,
    default_patokan = excluded.default_patokan,
    phone_verified = excluded.phone_verified,
    last_synced_at = excluded.last_synced_at;

  insert into public.menu_sync_runs (kind, trigger, triggered_by, status, customers)
  values ('customers', p_trigger, p_triggered_by, 'success', v_valid);

  return jsonb_build_object('customers', v_valid, 'skipped', v_total - v_valid);
end;
$$;

-- ---------------------------------------------------------------------
-- create_transaction: + pelanggan & alamat pengiriman
--
-- Tambahan di p_payload:
--   "customer": { "id": uuid }                      pelanggan terdaftar, atau
--   "customer": { "name": text, "phone": text }     pelanggan baru (lokal)
--   "customer_name": text     admin_toko: nama untuk pesanan ini (override);
--                             marketplace: kode pesanan / nama bebas
--   "delivery_address", "delivery_patokan": text    hanya delivery
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
  v_cust_in     jsonb := p_payload -> 'customer';
  v_customer    public.customers;
  v_cust_name   text;
  v_cust_phone  text;
  v_address     text;
  v_patokan     text;
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

  -- ---------------- Pelanggan ----------------
  v_cust_name := nullif(trim(p_payload ->> 'customer_name'), '');

  if v_channel = 'marketplace' then
    if v_cust_in is not null and jsonb_typeof(v_cust_in) = 'object' then
      raise exception 'PELANGGAN_TIDAK_BERLAKU: pesanan marketplace tanpa data pelanggan';
    end if;
  else
    if v_cust_in is not null and jsonb_typeof(v_cust_in) = 'object' then
      if v_cust_in ? 'id' then
        select * into v_customer from public.customers
        where id = nullif(v_cust_in ->> 'id', '')::uuid;
        if v_customer.id is null then
          raise exception 'PELANGGAN_TIDAK_ADA: pelanggan tidak ditemukan';
        end if;
      else
        v_cust_phone := public.normalize_phone(v_cust_in ->> 'phone');
        if v_cust_phone is null then
          raise exception 'HP_TIDAK_VALID: nomor HP pelanggan tidak valid';
        end if;
        if nullif(trim(v_cust_in ->> 'name'), '') is null then
          raise exception 'NAMA_WAJIB: isi nama pelanggan';
        end if;

        -- Nomor sudah terdaftar (mis. baru dibuat kasir lain) → pakai yang ada.
        insert into public.customers (name, phone, default_address, default_patokan, created_by)
        values (
          trim(v_cust_in ->> 'name'), v_cust_phone,
          case when v_sales_type = 'delivery' then nullif(trim(p_payload ->> 'delivery_address'), '') end,
          case when v_sales_type = 'delivery' then nullif(trim(p_payload ->> 'delivery_patokan'), '') end,
          v_user
        )
        on conflict (phone) do nothing;

        select * into v_customer from public.customers where phone = v_cust_phone;
      end if;

      v_cust_name := coalesce(v_cust_name, v_customer.name);
      v_cust_phone := v_customer.phone;
    end if;

    if v_sales_type = 'delivery' then
      if v_customer.id is null then
        raise exception 'PELANGGAN_WAJIB: pesanan delivery wajib diisi data pelanggan';
      end if;
      v_address := nullif(trim(p_payload ->> 'delivery_address'), '');
      v_patokan := nullif(trim(p_payload ->> 'delivery_patokan'), '');
      if v_address is null then
        raise exception 'ALAMAT_WAJIB: isi alamat pengiriman';
      end if;
    end if;
  end if;

  insert into public.transactions (
    outlet_id, channel, sales_type, marketplace_platform_id, markup_percent_applied,
    shipping_cost, subtotal, total,
    customer_id, customer_name, customer_phone, delivery_address, delivery_patokan,
    notes, cashier_id, shift_id
  ) values (
    v_outlet_id, v_channel, v_sales_type, v_platform_id, v_pct,
    v_shipping, 0, v_shipping,
    v_customer.id, v_cust_name, v_cust_phone, v_address, v_patokan,
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

-- ---------------------------------------------------------------------
-- Hak eksekusi
-- ---------------------------------------------------------------------
revoke execute on function public.normalize_phone(text) from public, anon, authenticated;
revoke execute on function public.apply_customer_sync(jsonb, text, uuid) from public, anon, authenticated;
grant execute on function public.apply_customer_sync(jsonb, text, uuid) to service_role;

revoke execute on function public.search_customers(text) from public, anon;
grant execute on function public.search_customers(text) to authenticated;

revoke execute on function public.create_transaction(jsonb) from public, anon;
grant execute on function public.create_transaction(jsonb) to authenticated;
