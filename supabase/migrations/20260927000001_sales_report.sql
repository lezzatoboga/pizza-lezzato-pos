-- =====================================================================
-- Laporan penjualan (SPEC §5) + riwayat shift
--
-- Definisi (disepakati 2026-09-26):
--   Penjualan      = subtotal − diskon voucher − diskon manual
--   Ongkir         = kolom terpisah
--   Total diterima = penjualan + ongkir (= transactions.total)
--   Default hanya transaksi LUNAS (opsi "termasuk belum lunas"); transaksi
--   BATAL tidak masuk angka mana pun, ditampilkan terpisah.
--   Dasar tanggal  = transaction_date (tanggal transaksi dibuat, WIB).
--   Per produk/kategori = penjualan kotor item (qty × harga jual, sebelum
--   diskon transaksi); extra topping jadi baris sendiri "Extra topping".
--
-- Filter (p_filters jsonb, semua opsional kecuali tanggal):
--   date_from, date_to (YYYY-MM-DD), include_unpaid (bool),
--   channel, platform_id, sales_type, payment_method_id, bank_account_id,
--   cashier_id, courier ('karyawan:<uuid>' | 'freelance:<uuid>' |
--   'shopee_express' | 'maxim'), product_id, category (slug)
--
-- Hak akses dicek di setiap fungsi:
--   ringkasan → view_sales_report, detail → view_transaction_detail,
--   ekspor detail → export_report + view_transaction_detail,
--   riwayat shift → view_finance_report.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Pembantu: label & kunci kurir
-- ---------------------------------------------------------------------
create or replace function public.report_courier_key(
  p_type text, p_user_id uuid, p_courier_id uuid
)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'karyawan' then 'karyawan:' || p_user_id
    when 'freelance' then 'freelance:' || p_courier_id
    else p_type
  end;
$$;

create or replace function public.report_channel_label(p_channel text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_channel
    when 'admin_toko' then 'Admin toko'
    when 'website' then 'Website'
    when 'marketplace' then 'Marketplace'
    else p_channel
  end;
$$;

create or replace function public.report_sales_type_label(p_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'dine_in' then 'Dine-in'
    when 'take_away' then 'Take away'
    when 'delivery' then 'Delivery'
    else p_type
  end;
$$;

-- Salah satu izin laporan.
create or replace function public.assert_any_permission(p_codes text[])
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
  if not exists (select 1 from unnest(p_codes) c where public.has_permission(c)) then
    raise exception 'TIDAK_BERIZIN: Anda tidak punya akses ke laporan ini';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Transaksi yang lolos filter (semua status; pemanggil memilah
-- lunas / belum lunas / batal). Internal — tidak diberikan ke klien.
-- ---------------------------------------------------------------------
create or replace function public.report_base(p_filters jsonb)
returns setof public.transactions
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_from     date := nullif(p_filters ->> 'date_from', '')::date;
  v_to       date := nullif(p_filters ->> 'date_to', '')::date;
  v_channel  text := nullif(p_filters ->> 'channel', '');
  v_platform uuid := nullif(p_filters ->> 'platform_id', '')::uuid;
  v_stype    text := nullif(p_filters ->> 'sales_type', '');
  v_method   uuid := nullif(p_filters ->> 'payment_method_id', '')::uuid;
  v_bank     uuid := nullif(p_filters ->> 'bank_account_id', '')::uuid;
  v_cashier  uuid := nullif(p_filters ->> 'cashier_id', '')::uuid;
  v_courier  text := nullif(p_filters ->> 'courier', '');
  v_product  text := nullif(p_filters ->> 'product_id', '');
  v_category text := nullif(p_filters ->> 'category', '');
begin
  if v_from is null or v_to is null then
    raise exception 'TANGGAL_WAJIB: pilih rentang tanggal';
  end if;
  if v_to < v_from then
    raise exception 'TANGGAL_TIDAK_VALID: tanggal akhir sebelum tanggal awal';
  end if;
  if v_to - v_from > 366 then
    raise exception 'RENTANG_TERLALU_PANJANG: rentang tanggal maksimal 1 tahun';
  end if;

  return query
  select t.*
  from public.transactions t
  where t.transaction_date between v_from and v_to
    and (v_channel is null or t.channel = v_channel)
    and (v_platform is null or t.marketplace_platform_id = v_platform)
    and (v_stype is null or t.sales_type = v_stype)
    and (v_method is null or t.payment_method_id = v_method)
    and (v_bank is null or t.bank_account_id = v_bank)
    and (v_cashier is null or t.cashier_id = v_cashier)
    and (v_courier is null
         or public.report_courier_key(t.courier_type, t.courier_user_id, t.courier_id) = v_courier)
    and ((v_product is null and v_category is null) or exists (
      select 1 from public.transaction_items i
      where i.transaction_id = t.id
        and (v_product is null or i.product_id = v_product)
        and (v_category is null or i.category_snapshot = v_category)
    ));
end;
$$;

-- Transaksi yang dihitung: aktif, lunas (atau juga belum lunas bila diminta).
create or replace function public.report_included(p_filters jsonb)
returns setof public.transactions
language sql
stable
security definer
set search_path = ''
as $$
  select * from public.report_base(p_filters) t
  where t.status = 'active'
    and (t.payment_status = 'paid' or coalesce((p_filters ->> 'include_unpaid')::boolean, false));
$$;

-- Dimensi pengelompokan per transaksi: {"<dim>": {"k": kunci, "l": label, "s": urutan}}.
create or replace function public.report_tx_dims(t public.transactions)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'date', jsonb_build_object('k', t.transaction_date, 'l', t.transaction_date, 's', t.transaction_date),
    'channel', jsonb_build_object(
      'k', t.channel, 'l', public.report_channel_label(t.channel),
      's', case t.channel when 'admin_toko' then 1 when 'website' then 2 else 3 end),
    'platform', jsonb_build_object(
      'k', coalesce(t.marketplace_platform_id::text, '-'),
      'l', coalesce(p.name, 'Bukan marketplace'),
      's', case when p.id is null then 'zzz' else '' end),
    'sales_type', jsonb_build_object(
      'k', t.sales_type, 'l', public.report_sales_type_label(t.sales_type),
      's', case t.sales_type when 'dine_in' then 1 when 'take_away' then 2 else 3 end),
    'payment_method', jsonb_build_object(
      'k', coalesce(t.payment_method_id::text, '-'),
      'l', coalesce(m.name, 'Belum bayar'),
      's', coalesce(lpad(m.sort_order::text, 3, '0'), 'zzz')),
    'bank', jsonb_build_object(
      'k', coalesce(t.bank_account_id::text, '-'),
      'l', coalesce(b.bank_name, 'Tanpa rekening'),
      's', coalesce(lpad(b.sort_order::text, 3, '0'), 'zzz')),
    'cashier', jsonb_build_object(
      'k', coalesce(t.cashier_id::text, '-'),
      'l', coalesce(u.name, 'Tanpa kasir'), 's', ''),
    'courier', jsonb_build_object(
      'k', coalesce(public.report_courier_key(t.courier_type, t.courier_user_id, t.courier_id), '-'),
      'l', case t.courier_type
             when 'karyawan' then coalesce(ku.name, 'Karyawan') || ' (karyawan)'
             when 'freelance' then coalesce(kc.name, 'Freelance') || ' (freelance)'
             when 'shopee_express' then 'Shopee Express'
             when 'maxim' then 'Maxim'
             else 'Tanpa kurir'
           end,
      's', case when t.courier_type is null then 'zzz' else '' end)
  )
  from (select 1) one
  left join public.marketplace_platforms p on p.id = t.marketplace_platform_id
  left join public.payment_methods m on m.id = t.payment_method_id
  left join public.bank_accounts b on b.id = t.bank_account_id
  left join public.pos_users u on u.id = t.cashier_id
  left join public.pos_users ku on ku.id = t.courier_user_id
  left join public.couriers kc on kc.id = t.courier_id;
$$;

-- ---------------------------------------------------------------------
-- Ringkasan
--   p_group_by: 0–2 dari date, channel, platform, sales_type,
--   payment_method, bank, cashier, courier, category, product, variant.
--   Bila salah satunya category/product/variant → tingkat item
--   (metrik: qty, nilai kotor, jumlah transaksi); selain itu tingkat
--   transaksi (metrik lengkap).
-- ---------------------------------------------------------------------
create or replace function public.report_summary(p_filters jsonb, p_group_by text[] default '{}')
returns jsonb
language plpgsql
volatile  -- memakai tabel sementara
security definer
set search_path = ''
as $$
declare
  v_allowed constant text[] := array[
    'date', 'channel', 'platform', 'sales_type', 'payment_method', 'bank',
    'cashier', 'courier', 'category', 'product', 'variant'];
  v_item_dims constant text[] := array['category', 'product', 'variant'];
  v_groups   text[] := coalesce(p_group_by, '{}');
  v_g1       text;
  v_g2       text;
  v_item     boolean;
  v_product  text := nullif(p_filters ->> 'product_id', '');
  v_category text := nullif(p_filters ->> 'category', '');
  v_totals   jsonb;
  v_rows     jsonb;
  v_daily    jsonb;
  v_voided   jsonb;
  v_unpaid   jsonb;
begin
  perform public.assert_permission('view_sales_report');

  if cardinality(v_groups) > 2 then
    raise exception 'GROUPING_TIDAK_VALID: maksimal dua pengelompokan';
  end if;
  if exists (select 1 from unnest(v_groups) g where g <> all (v_allowed)) then
    raise exception 'GROUPING_TIDAK_VALID: pengelompokan tidak dikenal';
  end if;
  v_g1 := v_groups[1];
  v_g2 := v_groups[2];
  if v_g1 is not null and v_g1 = v_g2 then
    v_g2 := null;
  end if;
  v_item := v_groups && v_item_dims;

  if to_regclass('pg_temp.report_tx') is null then
    create temporary table report_tx (
      t public.transactions, dims jsonb, items_qty bigint
    ) on commit drop;
  else
    truncate pg_temp.report_tx;
  end if;

  insert into pg_temp.report_tx
  select t, public.report_tx_dims(t),
    coalesce((select sum(i.qty) from public.transaction_items i where i.transaction_id = t.id), 0)
  from public.report_included(p_filters) t;

  -- Total (selalu tingkat transaksi)
  select jsonb_build_object(
    'tx_count', count(*),
    'subtotal', coalesce(sum((t).subtotal), 0),
    'voucher_discount', coalesce(sum((t).discount_amount), 0),
    'manual_discount', coalesce(sum(coalesce((t).manual_discount_amount, 0)), 0),
    'markup', coalesce(sum((t).markup_amount), 0),
    'shipping', coalesce(sum((t).shipping_cost), 0),
    'net_sales', coalesce(sum((t).subtotal - (t).discount_amount - coalesce((t).manual_discount_amount, 0)), 0),
    'total', coalesce(sum((t).total), 0),
    'items_qty', coalesce(sum(items_qty), 0),
    'topping_qty', coalesce((
      select sum(a.qty * i.qty) from pg_temp.report_tx r
      join public.transaction_items i on i.transaction_id = (r.t).id
      join public.transaction_item_addons a on a.transaction_item_id = i.id
    ), 0)
  ) into v_totals
  from pg_temp.report_tx;

  -- Grafik batang: penjualan per hari sepanjang rentang
  select coalesce(jsonb_agg(jsonb_build_object(
      'date', d.day::date, 'net_sales', coalesce(x.net_sales, 0), 'tx_count', coalesce(x.tx_count, 0)
    ) order by d.day), '[]')
  into v_daily
  from generate_series(
    (p_filters ->> 'date_from')::date, (p_filters ->> 'date_to')::date, interval '1 day') d(day)
  left join (
    select (t).transaction_date as day, count(*) as tx_count,
      sum((t).subtotal - (t).discount_amount - coalesce((t).manual_discount_amount, 0)) as net_sales
    from pg_temp.report_tx group by 1
  ) x on x.day = d.day::date;

  -- Batal & belum lunas (informasi terpisah, tidak masuk angka)
  select jsonb_build_object('tx_count', count(*), 'total', coalesce(sum(total), 0))
  into v_voided
  from public.report_base(p_filters) where status = 'voided';

  select jsonb_build_object('tx_count', count(*), 'total', coalesce(sum(total), 0))
  into v_unpaid
  from public.report_base(p_filters) where status = 'active' and payment_status = 'unpaid';

  if v_g1 is null then
    v_rows := '[]';
  elsif not v_item then
    select coalesce(jsonb_agg(r - 'sort1' - 'sort2' - 'rank1' order by
        r ->> 'sort1', (r ->> 'rank1')::numeric desc, r -> 'keys' -> 0 ->> 'k',
        r ->> 'sort2', (r ->> 'net_sales')::numeric desc, r -> 'keys' -> 1 ->> 'k'), '[]')
    into v_rows
    from (
      select jsonb_build_object(
        'keys', case when v_g2 is null then jsonb_build_array(d1 - 's')
                     else jsonb_build_array(d1 - 's', d2 - 's') end,
        'sort1', d1 ->> 's', 'sort2', coalesce(d2 ->> 's', ''),
        'rank1', sum(sum((t).subtotal - (t).discount_amount - coalesce((t).manual_discount_amount, 0)))
                   over (partition by d1),
        'tx_count', count(*),
        'subtotal', sum((t).subtotal),
        'voucher_discount', sum((t).discount_amount),
        'manual_discount', sum(coalesce((t).manual_discount_amount, 0)),
        'markup', sum((t).markup_amount),
        'shipping', sum((t).shipping_cost),
        'net_sales', sum((t).subtotal - (t).discount_amount - coalesce((t).manual_discount_amount, 0)),
        'total', sum((t).total),
        'items_qty', sum(items_qty)
      ) as r
      from (
        select t, items_qty, dims -> v_g1 as d1, case when v_g2 is not null then dims -> v_g2 end as d2
        from pg_temp.report_tx
      ) s
      group by d1, d2
    ) g;
  else
    -- Tingkat item: baris item (nilai = qty × harga jual, tanpa topping)
    -- + baris topping (nilai = subtotal topping × qty item).
    select coalesce(jsonb_agg(r - 'sort1' - 'sort2' - 'rank1' order by
        r ->> 'sort1', (r ->> 'rank1')::numeric desc, r -> 'keys' -> 0 ->> 'k',
        r ->> 'sort2', (r ->> 'value')::numeric desc, r -> 'keys' -> 1 ->> 'k'), '[]')
    into v_rows
    from (
      select jsonb_build_object(
        'keys', case when v_g2 is null then jsonb_build_array(d1 - 's')
                     else jsonb_build_array(d1 - 's', d2 - 's') end,
        'sort1', d1 ->> 's', 'sort2', coalesce(d2 ->> 's', ''),
        'rank1', sum(sum(f.value)) over (partition by d1),
        'qty', sum(f.qty),
        'value', sum(f.value),
        'tx_count', count(distinct f.tx_id)
      ) as r
      from (
        select f.tx_id, f.qty, f.value,
          f.dims -> v_g1 as d1, case when v_g2 is not null then f.dims -> v_g2 end as d2
        from (
          -- item
          select (rt.t).id as tx_id, i.qty::bigint as qty, (i.qty * i.unit_price)::bigint as value,
            rt.dims || jsonb_build_object(
              'category', jsonb_build_object(
                'k', i.category_snapshot, 'l', coalesce(c.label, initcap(i.category_snapshot)),
                's', coalesce(lpad(c.sort_order::text, 4, '0'), '9999')),
              'product', jsonb_build_object('k', i.product_id, 'l', i.product_name_snapshot, 's', ''),
              'variant', jsonb_build_object(
                'k', i.product_id || '|' || coalesce(i.variant_name_snapshot, ''),
                'l', i.product_name_snapshot
                     || coalesce(' (' || i.variant_name_snapshot || ')', ''),
                's', '')
            ) as dims
          from pg_temp.report_tx rt
          join public.transaction_items i on i.transaction_id = (rt.t).id
          left join public.menu_categories_cache c on c.slug = i.category_snapshot
          where (v_product is null or i.product_id = v_product)
            and (v_category is null or i.category_snapshot = v_category)
          union all
          -- extra topping (satu baris gabungan)
          select (rt.t).id, (a.qty * i.qty)::bigint, (a.subtotal * i.qty)::bigint,
            rt.dims || jsonb_build_object(
              'category', jsonb_build_object('k', '__topping', 'l', 'Extra topping', 's', 'zzzz'),
              'product', jsonb_build_object('k', '__topping', 'l', 'Extra topping', 's', 'zzzz'),
              'variant', jsonb_build_object('k', '__topping', 'l', 'Extra topping', 's', 'zzzz')
            )
          from pg_temp.report_tx rt
          join public.transaction_items i on i.transaction_id = (rt.t).id
          join public.transaction_item_addons a on a.transaction_item_id = i.id
          where (v_product is null or i.product_id = v_product)
            and (v_category is null or i.category_snapshot = v_category)
        ) f
      ) f
      group by d1, d2
    ) g;
  end if;

  return jsonb_build_object(
    'level', case when v_g1 is null then null when v_item then 'item' else 'transaction' end,
    'group_by', to_jsonb(array_remove(array[v_g1, v_g2], null)),
    'totals', v_totals,
    'rows', v_rows,
    'daily', v_daily,
    'voided', v_voided,
    'unpaid', v_unpaid
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Detail: daftar transaksi (bertahap)
--   p_view: 'included' (sesuai include_unpaid) | 'voided'
-- ---------------------------------------------------------------------
create or replace function public.report_tx_row(t public.transactions)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', t.id,
    'transaction_number', t.transaction_number,
    'transaction_date', t.transaction_date,
    'created_at', t.created_at,
    'paid_at', t.paid_at,
    'channel', t.channel,
    'platform', (select name from public.marketplace_platforms where id = t.marketplace_platform_id),
    'sales_type', t.sales_type,
    'customer_name', t.customer_name,
    'customer_phone', t.customer_phone,
    'cashier', (select name from public.pos_users where id = t.cashier_id),
    'payment_status', t.payment_status,
    'payment_method', (select name from public.payment_methods where id = t.payment_method_id),
    'bank', (select bank_name from public.bank_accounts where id = t.bank_account_id),
    'courier', (public.report_tx_dims(t) -> 'courier' ->> 'l'),
    'courier_type', t.courier_type,
    'distance_km', t.distance_km,
    'subtotal', t.subtotal,
    'discount_code', t.discount_code,
    'voucher_discount', t.discount_amount,
    'manual_discount', coalesce(t.manual_discount_amount, 0),
    'manual_discount_reason', t.manual_discount_reason,
    'markup_percent', t.markup_percent_applied,
    'markup', t.markup_amount,
    'shipping', t.shipping_cost,
    'net_sales', t.subtotal - t.discount_amount - coalesce(t.manual_discount_amount, 0),
    'total', t.total,
    'items_qty', coalesce((select sum(qty) from public.transaction_items where transaction_id = t.id), 0),
    'status', t.status,
    'voided_at', t.voided_at,
    'void_reason', t.void_reason,
    'voided_by', (select name from public.pos_users where id = t.voided_by),
    'void_requested_by', (select name from public.pos_users where id = t.void_requested_by),
    'notes', t.notes
  );
$$;

create or replace function public.report_filtered(p_filters jsonb, p_view text)
returns setof public.transactions
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_view = 'voided' then
    return query select * from public.report_base(p_filters) where status = 'voided';
  elsif p_view = 'included' then
    return query select * from public.report_included(p_filters);
  else
    raise exception 'TAMPILAN_TIDAK_VALID: pilih transaksi dihitung atau dibatalkan';
  end if;
end;
$$;

create or replace function public.report_transactions(
  p_filters jsonb,
  p_view    text default 'included',
  p_limit   integer default 50,
  p_offset  integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  perform public.assert_permission('view_transaction_detail');

  select jsonb_build_object(
    'total_count', (select count(*) from public.report_filtered(p_filters, p_view)),
    'rows', coalesce((
      select jsonb_agg(public.report_tx_row(t) order by t.created_at desc, t.id)
      from (
        select * from public.report_filtered(p_filters, p_view)
        order by created_at desc, id
        limit least(greatest(coalesce(p_limit, 50), 1), 200)
        offset greatest(coalesce(p_offset, 0), 0)
      ) t
    ), '[]')
  ) into v_result;

  return v_result;
end;
$$;

-- Drill-down satu transaksi: data cetak + info audit.
create or replace function public.report_transaction(p_transaction_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tx public.transactions;
begin
  perform public.assert_permission('view_transaction_detail');

  select * into v_tx from public.transactions where id = p_transaction_id;
  if v_tx.id is null then
    raise exception 'TRANSAKSI_TIDAK_ADA: transaksi tidak ditemukan';
  end if;

  return public.get_transaction_print_data(v_tx.id) || public.report_tx_row(v_tx);
end;
$$;

-- ---------------------------------------------------------------------
-- Ekspor detail: transaksi + item, urut kronologis. Maks 20.000 transaksi.
-- ---------------------------------------------------------------------
create or replace function public.report_export(p_filters jsonb, p_view text default 'included')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_count bigint;
begin
  perform public.assert_permission('export_report');
  perform public.assert_permission('view_transaction_detail');

  select count(*) into v_count from public.report_filtered(p_filters, p_view);
  if v_count > 20000 then
    raise exception 'EKSPOR_TERLALU_BESAR: % transaksi — persempit rentang tanggal (maks 20.000)', v_count;
  end if;

  return jsonb_build_object(
    'transactions', coalesce((
      select jsonb_agg(public.report_tx_row(t) order by t.created_at, t.id)
      from public.report_filtered(p_filters, p_view) t
    ), '[]'),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'transaction_number', t.transaction_number,
        'transaction_date', t.transaction_date,
        'channel', t.channel,
        'platform', (select name from public.marketplace_platforms where id = t.marketplace_platform_id),
        'item_type', i.item_type,
        'product_id', i.product_id,
        'product_name', i.product_name_snapshot,
        'variant_name', i.variant_name_snapshot,
        'category', coalesce(c.label, i.category_snapshot),
        'qty', i.qty,
        'price_snapshot', i.variant_price_snapshot,
        'unit_price', i.unit_price,
        'item_value', i.qty * i.unit_price,
        'topping_value', i.subtotal_item - i.qty * i.unit_price,
        'subtotal_item', i.subtotal_item,
        'toppings', (
          select string_agg(a.addon_name_snapshot || case when a.qty > 1 then ' x' || a.qty else '' end,
                            ', ' order by a.created_at, a.id)
          from public.transaction_item_addons a where a.transaction_item_id = i.id),
        'package_choices', (
          select string_agg(concat_ws(': ', ch ->> 'label', ch ->> 'value'), ', ')
          from jsonb_array_elements(
            case jsonb_typeof(i.package_choices_snapshot)
              when 'array' then i.package_choices_snapshot else '[]' end) ch),
        'notes', i.notes
      ) order by t.created_at, t.id, i.created_at, i.id)
      from public.report_filtered(p_filters, p_view) t
      join public.transaction_items i on i.transaction_id = t.id
      left join public.menu_categories_cache c on c.slug = i.category_snapshot
    ), '[]')
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Pilihan filter (termasuk data nonaktif/historis)
-- ---------------------------------------------------------------------
create or replace function public.report_filter_options()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.assert_any_permission(
    array['view_sales_report', 'view_transaction_detail', 'view_finance_report']);

  return jsonb_build_object(
    'platforms', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by sort_order, name)
      from public.marketplace_platforms), '[]'),
    'payment_methods', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by sort_order, name)
      from public.payment_methods), '[]'),
    'bank_accounts', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'name', bank_name) order by sort_order, bank_name)
      from public.bank_accounts), '[]'),
    'users', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name)
      from public.pos_users), '[]'),
    'couriers', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name)
      from public.couriers), '[]'),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('slug', x.slug, 'name', x.name) order by x.sort, x.name)
      from (
        select s.slug, coalesce(c.label, initcap(s.slug)) as name, coalesce(c.sort_order, 9999) as sort
        from (select distinct category_snapshot as slug from public.transaction_items
              union select slug from public.menu_categories_cache) s
        left join public.menu_categories_cache c on c.slug = s.slug
      ) x), '[]'),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object('id', product_id, 'name', name) order by name)
      from (
        select product_id, (array_agg(product_name_snapshot order by created_at desc))[1] as name
        from public.transaction_items group by product_id
      ) p), '[]')
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Riwayat shift (view_finance_report). Angka kas shift yang masih
-- terbuka tetap disembunyikan (hitung buta).
-- ---------------------------------------------------------------------
create or replace function public.report_shifts(p_date_from date, p_date_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.assert_permission('view_finance_report');

  if p_date_from is null or p_date_to is null or p_date_to < p_date_from then
    raise exception 'TANGGAL_TIDAK_VALID: pilih rentang tanggal';
  end if;
  if p_date_to - p_date_from > 366 then
    raise exception 'RENTANG_TERLALU_PANJANG: rentang tanggal maksimal 1 tahun';
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', s.id,
        'status', s.status,
        'opening_time', s.opening_time,
        'closing_time', s.closing_time,
        'opened_by', (select name from public.pos_users where id = s.cashier_id),
        'counted_by', (select name from public.pos_users where id = s.counted_by),
        'closed_by', (select name from public.pos_users where id = s.closed_by),
        'opening_balance', s.opening_balance,
        'notes', s.notes,
        'tx_count', (select count(*) from public.transactions
                     where shift_id = s.id and status = 'active'),
        'voided_count', (select count(*) from public.transactions
                         where shift_id = s.id and status = 'voided')
      )
      || case when s.status = 'open' then '{}'::jsonb else
        public.shift_cash_figures(s.id) || jsonb_build_object(
          'expected', s.expected_cash,
          'counted', s.closing_cash_counted,
          'difference', s.cash_difference,
          'sales_total', coalesce((
            select sum(total) from public.transactions
            where shift_id = s.id and status = 'active' and payment_status = 'paid'), 0)
        ) end
      order by s.opening_time desc)
    from public.shifts s
    where (s.opening_time at time zone 'Asia/Jakarta')::date between p_date_from and p_date_to
  ), '[]');
end;
$$;

-- ---------------------------------------------------------------------
-- Hak eksekusi: fungsi internal tertutup, fungsi laporan untuk pengguna login
-- ---------------------------------------------------------------------
revoke all on function public.report_courier_key(text, uuid, uuid) from public, anon;
revoke all on function public.report_channel_label(text) from public, anon;
revoke all on function public.report_sales_type_label(text) from public, anon;
revoke all on function public.assert_any_permission(text[]) from public, anon, authenticated;
revoke all on function public.report_base(jsonb) from public, anon, authenticated;
revoke all on function public.report_included(jsonb) from public, anon, authenticated;
revoke all on function public.report_tx_dims(public.transactions) from public, anon, authenticated;
revoke all on function public.report_tx_row(public.transactions) from public, anon, authenticated;
revoke all on function public.report_filtered(jsonb, text) from public, anon, authenticated;

revoke all on function public.report_summary(jsonb, text[]) from public, anon;
revoke all on function public.report_transactions(jsonb, text, integer, integer) from public, anon;
revoke all on function public.report_transaction(uuid) from public, anon;
revoke all on function public.report_export(jsonb, text) from public, anon;
revoke all on function public.report_filter_options() from public, anon;
revoke all on function public.report_shifts(date, date) from public, anon;

grant execute on function public.report_summary(jsonb, text[]) to authenticated;
grant execute on function public.report_transactions(jsonb, text, integer, integer) to authenticated;
grant execute on function public.report_transaction(uuid) to authenticated;
grant execute on function public.report_export(jsonb, text) to authenticated;
grant execute on function public.report_filter_options() to authenticated;
grant execute on function public.report_shifts(date, date) to authenticated;
