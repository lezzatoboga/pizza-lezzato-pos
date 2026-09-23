-- =====================================================================
-- Pengaturan POS, ongkir (manual / kalkulator jarak), kurir, diskon manual
--
-- Pengaturan (izin manage_settings: Owner & Supervisor):
--   markup marketplace (juga butuh edit_markup), tarif ongkir per km
--   (per outlet), kurir freelance, rekening bank, metode pembayaran.
--
-- Delivery (admin_toko; website menyusul di tahap jembatan):
--   * Ongkir wajib diisi eksplisit saat simpan (boleh 0). Mode jarak:
--     ongkir = ceil(km × tarif / 1000) × 1000, dihitung server.
--   * Kurir boleh menyusul; wajib sebelum dibayar (dan nanti sebelum struk
--     dicetak). Bisa diganti selama belum dibayar.
--
-- Diskon manual (admin_toko saja, semua kasir, alasan wajib):
--   persen dari subtotal item (dibulatkan ke rupiah) atau rupiah langsung,
--   tidak melebihi subtotal. Terkunci setelah struk dicetak.
--   total = subtotal − discount_amount − manual_discount_amount + shipping_cost
-- =====================================================================

-- ---------------------------------------------------------------------
-- Izin
-- ---------------------------------------------------------------------
insert into public.permissions (code, label, sort_order) values
  ('manage_settings', 'Kelola pengaturan POS', 12);

insert into public.role_permissions (role_id, permission_code, granted)
select r.id, 'manage_settings', r.code in ('owner', 'supervisor')
from public.roles r;

-- ---------------------------------------------------------------------
-- Tarif ongkir per km (per outlet)
-- ---------------------------------------------------------------------
alter table public.outlets
  add column delivery_rate_per_km integer not null default 0 check (delivery_rate_per_km >= 0);

-- ---------------------------------------------------------------------
-- Kurir freelance
-- ---------------------------------------------------------------------
create table public.couriers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  active      boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create trigger couriers_updated_at before update on public.couriers
  for each row execute function public.set_updated_at();

alter table public.couriers enable row level security;
grant select, insert, update, delete on public.couriers to service_role;
grant select on public.couriers to authenticated;
create policy pos_users_read on public.couriers for select to authenticated
  using ((select public.current_pos_user_id()) is not null);

-- ---------------------------------------------------------------------
-- Kolom transaksi
-- ---------------------------------------------------------------------
alter table public.transactions
  add column courier_type            text,
  add column courier_user_id         uuid references public.pos_users (id),
  add column courier_id              uuid references public.couriers (id),
  add column distance_km             numeric(6,2),
  add column manual_discount_type    text,
  add column manual_discount_value   numeric(12,2),
  add column manual_discount_amount  bigint,
  add column manual_discount_reason  text;

alter table public.transactions
  drop constraint transactions_total_consistent;

alter table public.transactions
  add constraint transactions_total_consistent check (
    total = subtotal - discount_amount + shipping_cost - coalesce(manual_discount_amount, 0)
  ),
  add constraint transactions_courier_type check (
    courier_type in ('karyawan', 'freelance', 'shopee_express', 'maxim')
  ),
  add constraint transactions_courier_ref check (
    (courier_type is null and courier_user_id is null and courier_id is null)
    or (courier_type = 'karyawan' and courier_user_id is not null and courier_id is null)
    or (courier_type = 'freelance' and courier_id is not null and courier_user_id is null)
    or (courier_type in ('shopee_express', 'maxim') and courier_user_id is null and courier_id is null)
  ),
  add constraint transactions_courier_delivery_only check (
    courier_type is null or (sales_type = 'delivery' and channel in ('admin_toko', 'website'))
  ),
  add constraint transactions_distance check (
    distance_km is null or (distance_km > 0 and sales_type = 'delivery')
  ),
  add constraint transactions_manual_discount check (
    (manual_discount_type is null and manual_discount_value is null
      and manual_discount_amount is null and manual_discount_reason is null)
    or (channel = 'admin_toko'
      and manual_discount_type in ('percent', 'amount')
      and manual_discount_value > 0
      and (manual_discount_type <> 'percent' or manual_discount_value <= 100)
      and manual_discount_amount > 0
      and manual_discount_amount <= subtotal
      and nullif(trim(manual_discount_reason), '') is not null)
  );

create index transactions_courier_user_idx on public.transactions (courier_user_id);
create index transactions_courier_idx on public.transactions (courier_id);

-- ---------------------------------------------------------------------
-- Penjaga update transaksi: + diskon manual & jarak terkunci setelah struk
-- dicetak; kurir terkunci setelah dibayar.
-- ---------------------------------------------------------------------
create or replace function public.guard_transaction_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.original_order_snapshot is not null
     and new.original_order_snapshot is distinct from old.original_order_snapshot then
    raise exception 'SNAPSHOT_PERMANEN: original_order_snapshot tidak boleh diubah atau dihapus';
  end if;

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
    or new.manual_discount_type    is distinct from old.manual_discount_type
    or new.manual_discount_value   is distinct from old.manual_discount_value
    or new.manual_discount_amount  is distinct from old.manual_discount_amount
    or new.manual_discount_reason  is distinct from old.manual_discount_reason
    or new.markup_percent_applied  is distinct from old.markup_percent_applied
    or new.markup_amount           is distinct from old.markup_amount
    or new.shipping_cost           is distinct from old.shipping_cost
    or new.distance_km             is distinct from old.distance_km
    or new.total                   is distinct from old.total
    or new.last_edited_by          is distinct from old.last_edited_by
    or new.last_edited_at          is distinct from old.last_edited_at
  ) then
    raise exception 'TRANSAKSI_TERKUNCI: transaksi % sudah dicetak struknya, gunakan void untuk koreksi',
      old.transaction_number;
  end if;

  if old.payment_status = 'paid' and (
       new.courier_type    is distinct from old.courier_type
    or new.courier_user_id is distinct from old.courier_user_id
    or new.courier_id      is distinct from old.courier_id
  ) then
    raise exception 'KURIR_TERKUNCI: kurir tidak bisa diganti setelah transaksi dibayar';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Validasi kurir (internal). p_courier:
--   {"type":"karyawan","user_id":uuid} | {"type":"freelance","courier_id":uuid}
--   {"type":"shopee_express"} | {"type":"maxim"}
-- Mengembalikan {type, user_id, courier_id} yang sudah divalidasi.
-- ---------------------------------------------------------------------
create or replace function public.resolve_courier(p_courier jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_type text := p_courier ->> 'type';
  v_id   uuid;
begin
  if v_type = 'karyawan' then
    select id into v_id from public.pos_users
    where id = nullif(p_courier ->> 'user_id', '')::uuid and active;
    if v_id is null then
      raise exception 'KURIR_TIDAK_VALID: pilih karyawan pengantar';
    end if;
    return jsonb_build_object('type', v_type, 'user_id', v_id, 'courier_id', null);
  elsif v_type = 'freelance' then
    select id into v_id from public.couriers
    where id = nullif(p_courier ->> 'courier_id', '')::uuid and active;
    if v_id is null then
      raise exception 'KURIR_TIDAK_VALID: pilih kurir freelance';
    end if;
    return jsonb_build_object('type', v_type, 'user_id', null, 'courier_id', v_id);
  elsif v_type in ('shopee_express', 'maxim') then
    return jsonb_build_object('type', v_type, 'user_id', null, 'courier_id', null);
  end if;

  raise exception 'KURIR_TIDAK_VALID: pilih jenis kurir';
end;
$$;

-- Daftar karyawan untuk pilihan kurir internal (tabel pos_users tidak
-- dibaca langsung dari tablet karena berisi hash PIN).
create or replace function public.list_courier_staff()
returns table (id uuid, name text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if public.current_pos_user_id() is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;
  return query select u.id, u.name from public.pos_users u where u.active order by u.name;
end;
$$;

-- Atur / ganti kurir transaksi delivery (selama belum dibayar).
create or replace function public.set_transaction_courier(p_transaction_id uuid, p_courier jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tx      public.transactions;
  v_courier jsonb;
begin
  if public.current_pos_user_id() is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;

  select * into v_tx from public.transactions where id = p_transaction_id for update;
  if v_tx.id is null then
    raise exception 'TRANSAKSI_TIDAK_ADA: transaksi tidak ditemukan';
  end if;
  if v_tx.status <> 'active' then
    raise exception 'TRANSAKSI_BATAL: transaksi sudah dibatalkan';
  end if;
  if v_tx.sales_type <> 'delivery' or v_tx.channel not in ('admin_toko', 'website') then
    raise exception 'KURIR_TIDAK_BERLAKU: kurir hanya untuk pesanan delivery';
  end if;
  if v_tx.payment_status = 'paid' then
    raise exception 'KURIR_TERKUNCI: kurir tidak bisa diganti setelah transaksi dibayar';
  end if;

  v_courier := public.resolve_courier(p_courier);

  update public.transactions
  set courier_type = v_courier ->> 'type',
      courier_user_id = (v_courier ->> 'user_id')::uuid,
      courier_id = (v_courier ->> 'courier_id')::uuid
  where id = v_tx.id;

  return v_courier;
end;
$$;

-- ---------------------------------------------------------------------
-- create_transaction: + ongkir wajib/kalkulator jarak, kurir, diskon manual
--
-- Tambahan di p_payload (admin_toko):
--   "shipping_cost": int            delivery, mode manual (wajib, boleh 0)
--   "distance_km": number           delivery, mode jarak (ongkir dihitung server)
--   "courier": {...}                opsional saat simpan (lihat resolve_courier)
--   "manual_discount": {"type":"percent"|"amount","value":n,"reason":text}
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
  v_distance    numeric(6,2) := nullif(p_payload ->> 'distance_km', '')::numeric(6,2);
  v_rate        integer;
  v_courier     jsonb;
  v_disc_in     jsonb := p_payload -> 'manual_discount';
  v_disc_type   text;
  v_disc_value  numeric(12,2);
  v_disc_amount bigint;
  v_disc_reason text;
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

  -- ---------------- Ongkir & kurir ----------------
  if v_channel = 'admin_toko' and v_sales_type = 'delivery' then
    if v_distance is not null then
      if v_distance <= 0 or v_distance > 999 then
        raise exception 'JARAK_TIDAK_VALID: jarak harus lebih dari 0 km';
      end if;
      select delivery_rate_per_km into v_rate from public.outlets where id = v_outlet_id;
      if coalesce(v_rate, 0) <= 0 then
        raise exception 'TARIF_BELUM_DIATUR: tarif ongkir per km belum diatur di Pengaturan';
      end if;
      v_shipping := ceil(v_distance * v_rate / 1000.0) * 1000;
    elsif not (p_payload ? 'shipping_cost') or p_payload -> 'shipping_cost' = 'null'::jsonb then
      raise exception 'ONGKIR_WAJIB: isi ongkir (boleh 0) atau jarak pengiriman';
    end if;

    if p_payload -> 'courier' is not null and jsonb_typeof(p_payload -> 'courier') = 'object' then
      v_courier := public.resolve_courier(p_payload -> 'courier');
    end if;
  else
    if v_distance is not null then
      raise exception 'JARAK_TIDAK_BERLAKU: jarak hanya untuk pesanan delivery admin toko';
    end if;
    if p_payload -> 'courier' is not null and jsonb_typeof(p_payload -> 'courier') = 'object' then
      raise exception 'KURIR_TIDAK_BERLAKU: kurir hanya untuk pesanan delivery admin toko';
    end if;
  end if;

  if v_shipping < 0 then
    raise exception 'ONGKIR_TIDAK_VALID: ongkir tidak boleh negatif';
  end if;
  if v_shipping > 0 and not (v_channel = 'admin_toko' and v_sales_type = 'delivery') then
    raise exception 'ONGKIR_TIDAK_BERLAKU: ongkir hanya untuk pesanan delivery admin toko';
  end if;

  -- ---------------- Diskon manual (validasi awal) ----------------
  if v_disc_in is not null and jsonb_typeof(v_disc_in) = 'object' then
    if v_channel <> 'admin_toko' then
      raise exception 'DISKON_TIDAK_BERLAKU: diskon manual hanya untuk channel admin toko';
    end if;
    v_disc_type := v_disc_in ->> 'type';
    v_disc_value := (v_disc_in ->> 'value')::numeric(12,2);
    v_disc_reason := nullif(trim(v_disc_in ->> 'reason'), '');
    if v_disc_type is null or v_disc_type not in ('percent', 'amount') then
      raise exception 'DISKON_TIDAK_VALID: pilih diskon persen atau rupiah';
    end if;
    if v_disc_value is null or v_disc_value <= 0
       or (v_disc_type = 'percent' and v_disc_value > 100) then
      raise exception 'DISKON_TIDAK_VALID: nilai diskon tidak valid';
    end if;
    if v_disc_reason is null then
      raise exception 'ALASAN_DISKON_WAJIB: isi alasan diskon';
    end if;
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
    shipping_cost, distance_km, subtotal, total,
    courier_type, courier_user_id, courier_id,
    customer_id, customer_name, customer_phone, delivery_address, delivery_patokan,
    notes, cashier_id, shift_id
  ) values (
    v_outlet_id, v_channel, v_sales_type, v_platform_id, v_pct,
    v_shipping, v_distance, 0, v_shipping,
    v_courier ->> 'type', (v_courier ->> 'user_id')::uuid, (v_courier ->> 'courier_id')::uuid,
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

  -- ---------------- Diskon manual (hitung dari subtotal) ----------------
  if v_disc_type is not null then
    v_disc_amount := case v_disc_type
      when 'percent' then round(v_subtotal * v_disc_value / 100)
      else v_disc_value::bigint
    end;
    if v_disc_amount > v_subtotal then
      raise exception 'DISKON_TERLALU_BESAR: diskon melebihi subtotal belanja';
    end if;
    if v_disc_amount <= 0 then
      raise exception 'DISKON_TIDAK_VALID: diskon terlalu kecil';
    end if;
  end if;

  update public.transactions
  set subtotal = v_subtotal,
      markup_amount = v_markup,
      manual_discount_type = v_disc_type,
      manual_discount_value = v_disc_value,
      manual_discount_amount = v_disc_amount,
      manual_discount_reason = v_disc_reason,
      total = v_subtotal - coalesce(v_disc_amount, 0) + v_shipping
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
-- pay_transaction: + delivery wajib sudah punya kurir
-- ---------------------------------------------------------------------
create or replace function public.pay_transaction(
  p_transaction_id uuid,
  p_payment_method_id uuid,
  p_amount_paid bigint default null,
  p_bank_account_id uuid default null
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
  v_bank_id  uuid;
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
  if v_tx.sales_type = 'delivery' and v_tx.channel in ('admin_toko', 'website')
     and v_tx.courier_type is null then
    raise exception 'KURIR_WAJIB: tentukan kurir pengantar sebelum pembayaran';
  end if;

  select * into v_method from public.payment_methods where id = p_payment_method_id and active;
  if v_method.id is null then
    raise exception 'METODE_TIDAK_VALID: pilih metode pembayaran';
  end if;

  if v_method.requires_bank_account then
    select id into v_bank_id from public.bank_accounts where id = p_bank_account_id and active;
    if v_bank_id is null then
      raise exception 'REKENING_WAJIB: pilih rekening bank tujuan transfer';
    end if;
  elsif p_bank_account_id is not null then
    raise exception 'REKENING_TIDAK_BERLAKU: rekening bank hanya untuk %', 'Transfer Bank';
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
      bank_account_id = v_bank_id,
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
-- RPC Pengaturan (manage_settings; markup juga butuh edit_markup)
-- ---------------------------------------------------------------------
create or replace function public.assert_permission(p_code text)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if public.current_pos_user_id() is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;
  if not public.has_permission(p_code) then
    raise exception 'TIDAK_BERIZIN: Anda tidak punya izin untuk tindakan ini';
  end if;
end;
$$;

create or replace function public.update_platform_markup(p_platform_id uuid, p_markup_percent numeric)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_permission('manage_settings');
  perform public.assert_permission('edit_markup');
  if p_markup_percent is null or p_markup_percent < 0 or p_markup_percent > 999 then
    raise exception 'MARKUP_TIDAK_VALID: markup harus 0–999%%';
  end if;
  update public.marketplace_platforms set markup_percent = p_markup_percent where id = p_platform_id;
  if not found then
    raise exception 'PLATFORM_TIDAK_ADA: platform tidak ditemukan';
  end if;
end;
$$;

create or replace function public.set_delivery_rate(p_outlet_id uuid, p_rate integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_permission('manage_settings');
  if p_rate is null or p_rate < 0 then
    raise exception 'TARIF_TIDAK_VALID: tarif tidak boleh kosong atau negatif';
  end if;
  update public.outlets set delivery_rate_per_km = p_rate where id = p_outlet_id;
  if not found then
    raise exception 'OUTLET_TIDAK_ADA: outlet tidak ditemukan';
  end if;
end;
$$;

-- p_id null = tambah baru (urutan paling akhir).
create or replace function public.save_courier(p_id uuid, p_name text, p_active boolean default true)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform public.assert_permission('manage_settings');
  if nullif(trim(p_name), '') is null then
    raise exception 'NAMA_WAJIB: isi nama kurir';
  end if;

  if p_id is null then
    insert into public.couriers (name, active, sort_order)
    values (trim(p_name), coalesce(p_active, true),
            coalesce((select max(sort_order) from public.couriers), 0) + 1)
    returning id into v_id;
  else
    update public.couriers set name = trim(p_name), active = coalesce(p_active, active)
    where id = p_id returning id into v_id;
    if v_id is null then
      raise exception 'KURIR_TIDAK_ADA: kurir tidak ditemukan';
    end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.save_bank_account(p_id uuid, p_bank_name text, p_active boolean default true)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform public.assert_permission('manage_settings');
  if nullif(trim(p_bank_name), '') is null then
    raise exception 'NAMA_WAJIB: isi nama bank';
  end if;

  if p_id is null then
    insert into public.bank_accounts (bank_name, active, sort_order)
    values (trim(p_bank_name), coalesce(p_active, true),
            coalesce((select max(sort_order) from public.bank_accounts), 0) + 1)
    returning id into v_id;
  else
    update public.bank_accounts set bank_name = trim(p_bank_name), active = coalesce(p_active, active)
    where id = p_id returning id into v_id;
    if v_id is null then
      raise exception 'REKENING_TIDAK_ADA: rekening tidak ditemukan';
    end if;
  end if;
  return v_id;
end;
$$;

-- Cash tidak bisa dinonaktifkan (rekonsiliasi tutup shift), dan minimal
-- satu metode harus tetap aktif.
create or replace function public.set_payment_method_active(p_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_method public.payment_methods;
begin
  perform public.assert_permission('manage_settings');
  select * into v_method from public.payment_methods where id = p_id for update;
  if v_method.id is null then
    raise exception 'METODE_TIDAK_ADA: metode pembayaran tidak ditemukan';
  end if;
  if not p_active then
    if v_method.is_cash then
      raise exception 'CASH_WAJIB_AKTIF: metode tunai tidak bisa dinonaktifkan';
    end if;
    if (select count(*) from public.payment_methods where active and id <> p_id) = 0 then
      raise exception 'MINIMAL_SATU_METODE: minimal satu metode pembayaran harus aktif';
    end if;
  end if;
  update public.payment_methods set active = p_active where id = p_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Hak eksekusi
-- ---------------------------------------------------------------------
revoke execute on function public.resolve_courier(jsonb) from public, anon, authenticated;
revoke execute on function public.assert_permission(text) from public, anon, authenticated;

revoke execute on function public.list_courier_staff() from public, anon;
revoke execute on function public.set_transaction_courier(uuid, jsonb) from public, anon;
revoke execute on function public.create_transaction(jsonb) from public, anon;
revoke execute on function public.pay_transaction(uuid, uuid, bigint, uuid) from public, anon;
revoke execute on function public.update_platform_markup(uuid, numeric) from public, anon;
revoke execute on function public.set_delivery_rate(uuid, integer) from public, anon;
revoke execute on function public.save_courier(uuid, text, boolean) from public, anon;
revoke execute on function public.save_bank_account(uuid, text, boolean) from public, anon;
revoke execute on function public.set_payment_method_active(uuid, boolean) from public, anon;

grant execute on function public.list_courier_staff() to authenticated;
grant execute on function public.set_transaction_courier(uuid, jsonb) to authenticated;
grant execute on function public.create_transaction(jsonb) to authenticated;
grant execute on function public.pay_transaction(uuid, uuid, bigint, uuid) to authenticated;
grant execute on function public.update_platform_markup(uuid, numeric) to authenticated;
grant execute on function public.set_delivery_rate(uuid, integer) to authenticated;
grant execute on function public.save_courier(uuid, text, boolean) to authenticated;
grant execute on function public.save_bank_account(uuid, text, boolean) to authenticated;
grant execute on function public.set_payment_method_active(uuid, boolean) to authenticated;
