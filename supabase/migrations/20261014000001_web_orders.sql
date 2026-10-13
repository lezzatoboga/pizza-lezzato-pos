-- =====================================================================
-- Jembatan pesanan website → POS (tahap A: sisi POS)
--
-- Kontrak: docs/KONTRAK-DATA-POS.md (salinan dari repo website).
-- Keputusan Owner 13 Okt 2026: docs/JEMBATAN-PESANAN.md.
--
-- Alur:
--   Edge Function web-orders-sync (cron 30 dtk + tombol "Cek pesanan")
--     1. mengirim antrean status (web_status_outbox) ke pos.pos_set_order_status
--     2. menarik pos.v_pesanan / pos.v_item_pesanan (kursor updated_at − 2 menit)
--     3. apply_web_orders(): upsert idempoten; pesanan baru → transaksi POS
--        channel 'website' (dibuat SAAT DITARIK, walau shift belum dibuka)
--        + antre status 'diterima'.
--   Kasir: Konfirmasi & Proses → 'diproses'; Siap → 'siap_diambil' (Pick Up /
--   Dine-in) atau 'sedang_diantar' (Delivery); Selesai (wajib lunas) →
--   'selesai'; void → 'dibatalkan'. Semua lewat antrean (website tak
--   terjangkau tidak menahan dapur; Konfirmasi memakai penanda terakhir).
--   Edit item/ongkir: hanya SEBELUM Konfirmasi & Proses, dan hanya setelah
--   penanda diubah_kasir diterima website (Edge Function web-order-edit).
--   Pesanan dibatalkan di website: transaksi belum dibayar di-void otomatis
--   (void_source 'website', tanpa nama kasir); yang sudah dibayar → peringatan.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Kolom transaksi & item
-- ---------------------------------------------------------------------
alter table public.transactions
  add column web_order_code text,
  add column void_source text not null default 'pos';

alter table public.transactions
  add constraint transactions_void_source check (void_source in ('pos', 'website'));

-- Void oleh website tidak punya penyetuju (pos_users).
alter table public.transactions drop constraint transactions_void_complete;
alter table public.transactions
  add constraint transactions_void_complete check (
    status = 'active'
    or (voided_at is not null and void_reason is not null
        and (voided_by is not null or void_source = 'website'))
  );

-- Status pesanan mengikuti nilai kontrak website (nilai lama 'siap' tidak dipakai).
alter table public.transactions drop constraint transactions_order_status;
alter table public.transactions
  add constraint transactions_order_status check (
    order_status in ('baru', 'diterima', 'diproses', 'siap_diambil', 'sedang_diantar', 'selesai')
  );

comment on column public.transactions.web_order_code is 'Kode pesanan website (order_code), untuk tiket & struk.';
comment on column public.transactions.void_source is 'pos = dibatalkan kasir; website = dibatalkan dari sisi website (otomatis).';

alter table public.transaction_items
  add column source_options jsonb,
  add column mapping_warning text;

comment on column public.transaction_items.source_options is 'options asli item pesanan website.';
comment on column public.transaction_items.mapping_warning is
  'Diisi bila item website tidak bisa dipetakan ke menu POS — tiket dapur menandai "PERIKSA".';

-- ---------------------------------------------------------------------
-- Tabel jembatan
-- ---------------------------------------------------------------------
create table public.web_orders (
  id                   uuid primary key,          -- = orders.id website
  order_code           text not null,
  order_type           text not null check (order_type in ('delivery', 'takeaway', 'dinein')),
  web_status           text not null,
  web_created_at       timestamptz not null,
  web_updated_at       timestamptz not null,
  header               jsonb not null,            -- baris pos.v_pesanan terbaru
  items                jsonb not null default '[]'::jsonb,  -- pos.v_item_pesanan (sekali)
  menunggu_admin       boolean not null default false,
  terkunci_edit        boolean not null default false,
  diubah_di_pos        boolean not null default false,
  metode_bayar         text,
  status_bayar         text,
  kasir_shipping_cost  bigint check (kasir_shipping_cost >= 0),  -- null = ikut ongkir website
  transaction_id       uuid unique references public.transactions (id),
  first_seen_at        timestamptz not null default now(),
  last_pulled_at       timestamptz not null default now(),
  opened_at            timestamptz,
  opened_by            uuid references public.pos_users (id),
  header_notice        text,     -- perubahan angka website yang tidak bisa diterapkan lagi
  cancel_notice        text,     -- dibatalkan di website tetapi transaksi sudah dibayar
  void_slip_pending    boolean not null default false  -- slip BATAL perlu dicetak tablet
);

create index web_orders_unopened_idx on public.web_orders (first_seen_at) where opened_at is null;

create table public.web_status_outbox (
  id               bigint generated always as identity primary key,
  web_order_id     uuid not null references public.web_orders (id),
  status           text not null check (status in
                     ('diterima', 'diproses', 'siap_diambil', 'sedang_diantar', 'selesai', 'dibatalkan')),
  diubah_kasir     boolean not null default false,
  created_at       timestamptz not null default now(),
  created_by       uuid references public.pos_users (id),
  attempts         integer not null default 0,
  next_attempt_at  timestamptz not null default now(),
  sent_at          timestamptz,
  failed_at        timestamptz,       -- galat aturan (tidak dicoba ulang)
  last_error       text,
  result           jsonb
);

create index web_status_outbox_pending_idx
  on public.web_status_outbox (web_order_id, id) where sent_at is null and failed_at is null;

create table public.web_bridge_state (
  id               boolean primary key default true check (id),
  orders_cursor    timestamptz,
  last_run_at      timestamptz,
  last_ok_at       timestamptz,
  last_error       text,
  view_empty       boolean not null default true,
  inactive_reason  text,               -- mis. 'sebelum_go_live'
  lease_until      timestamptz,
  lease_token      uuid
);
insert into public.web_bridge_state default values;

alter table public.web_orders enable row level security;
alter table public.web_status_outbox enable row level security;
alter table public.web_bridge_state enable row level security;

grant select, insert, update, delete on public.web_orders, public.web_status_outbox, public.web_bridge_state
  to service_role;
grant select on public.web_orders, public.web_status_outbox, public.web_bridge_state to authenticated;

-- Pesanan terlihat bila transaksinya terlihat (RLS transaksi berlaku di subquery).
create policy web_orders_read on public.web_orders for select to authenticated
  using (
    (select public.current_pos_user_id()) is not null
    and (transaction_id is null
         or exists (select 1 from public.transactions t where t.id = transaction_id))
  );
create policy web_outbox_read on public.web_status_outbox for select to authenticated
  using (exists (select 1 from public.web_orders w where w.id = web_order_id));
create policy web_bridge_read on public.web_bridge_state for select to authenticated
  using ((select public.current_pos_user_id()) is not null);

-- ---------------------------------------------------------------------
-- Pembantu internal
-- ---------------------------------------------------------------------
create or replace function public.web_enqueue_status(
  p_order_id uuid, p_status text, p_user uuid default null, p_diubah_kasir boolean default false
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.web_status_outbox (web_order_id, status, created_by, diubah_kasir)
  values (p_order_id, p_status, p_user, p_diubah_kasir);
$$;

-- Angka header website → angka transaksi POS.
create or replace function public.web_header_discount(h jsonb)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select coalesce((h ->> 'discount')::bigint, 0) + coalesce((h ->> 'diskon_ongkir')::bigint, 0);
$$;

create or replace function public.web_header_shipping(h jsonb)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select case when h ->> 'order_type' = 'delivery'
              then coalesce((h ->> 'ongkir_rupiah')::bigint, 0) else 0 end;
$$;

-- Satu item pesanan website → transaction_items (+ addons). Kunci teknis
-- options (_format 2) dipakai lebih dulu; pesanan lama dipetakan lewat nama.
-- Yang tak terbaca tidak ditebak: item tetap masuk dengan nama & harga
-- website + mapping_warning. Subtotal baris = unit_price × qty website PERSIS.
create or replace function public.web_insert_item(p_tx uuid, w jsonb)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_menu      text := w ->> 'menu_id';
  v_qty       integer := (w ->> 'qty')::integer;
  v_unit_web  bigint := (w ->> 'unit_price')::bigint;
  v_opts      jsonb := coalesce(w -> 'options', '{}'::jsonb);
  v_fmt       boolean := coalesce(w -> 'options', '{}'::jsonb) ? '_format';
  v_warn      text[] := '{}';
  v_package   public.packages_cache;
  v_product   public.products_cache;
  v_variant   public.product_variants_cache;
  v_group     jsonb;
  v_choice    text;
  v_choices   jsonb := '[]'::jsonb;
  v_key       text;
  v_top_ids   text[] := '{}';
  v_top_name  text;
  v_top_price bigint;
  v_top_sum   bigint := 0;
  v_item_id   uuid;
  v_unit      bigint;
  v_label     text;
begin
  if v_qty is null or v_qty < 1 or v_unit_web is null or v_unit_web < 0 then
    raise exception 'ITEM_WEBSITE_TIDAK_VALID: qty/harga item % tidak valid', w ->> 'id';
  end if;

  -- ---------------- Paket ----------------
  select * into v_package from public.packages_cache where id = v_menu;
  if v_package.id is not null then
    for v_group in select * from jsonb_array_elements(coalesce(v_package.package_choices, '[]'::jsonb)) loop
      v_choice := case when v_fmt then v_opts -> '_pilihan' ->> (v_group ->> 'key')
                       else v_opts ->> (v_group ->> 'label') end;
      if v_choice is null or not coalesce(v_group -> 'options', '[]'::jsonb) ? v_choice then
        v_warn := v_warn || format('pilihan "%s" tidak terbaca', v_group ->> 'label');
      else
        v_choices := v_choices || jsonb_build_array(jsonb_build_object(
          'key', v_group ->> 'key', 'label', v_group ->> 'label', 'value', v_choice));
      end if;
    end loop;

    insert into public.transaction_items (
      transaction_id, item_type, product_id, product_name_snapshot, category_snapshot,
      variant_price_snapshot, unit_price, qty, subtotal_item,
      package_items_snapshot, package_choices_snapshot, package_note_snapshot,
      source_line_ref, source_options, mapping_warning
    ) values (
      p_tx, 'package', v_package.id,
      case when cardinality(v_warn) > 0 then w ->> 'name' else v_package.name end,
      coalesce(v_package.category_slug, 'paket'),
      v_unit_web, v_unit_web, v_qty, v_qty * v_unit_web,
      coalesce(v_package.package_items, '[]'::jsonb), v_choices, v_package.package_note,
      w ->> 'id', v_opts, nullif(array_to_string(v_warn, '; '), '')
    );
    return v_qty * v_unit_web;
  end if;

  -- ---------------- Produk ----------------
  select * into v_product from public.products_cache where id = v_menu;
  if v_product.id is null then
    insert into public.transaction_items (
      transaction_id, product_id, product_name_snapshot, category_snapshot,
      variant_price_snapshot, unit_price, qty, subtotal_item,
      source_line_ref, source_options, mapping_warning
    ) values (
      p_tx, v_menu, w ->> 'name', 'website',
      v_unit_web, v_unit_web, v_qty, v_qty * v_unit_web,
      w ->> 'id', v_opts, 'menu tidak dikenal di POS'
    );
    return v_qty * v_unit_web;
  end if;

  if v_product.kind in ('sized', 'variant') then
    if v_product.kind = 'sized' then
      if v_fmt then
        v_key := v_opts ->> '_ukuran_key';
      else
        select variant_key into v_key from public.product_variants_cache
        where product_id = v_product.id and lower(label) = lower(btrim(v_opts ->> 'ukuran'));
      end if;
    else
      v_key := case when v_fmt then v_opts ->> '_varian_key' else v_opts ->> 'varian' end;
    end if;
    select * into v_variant from public.product_variants_cache
    where product_id = v_product.id and variant_key = v_key;
    if v_variant.id is null then
      v_warn := v_warn || 'ukuran/varian tidak terbaca'::text;
    end if;
  end if;

  -- Topping ekstra (qty selalu 1 per topping di website)
  if v_fmt then
    select coalesce(array_agg(x), '{}') into v_top_ids
    from jsonb_array_elements_text(coalesce(v_opts -> '_topping_ids', '[]'::jsonb)) x;
  elsif nullif(btrim(v_opts ->> 'Topping Ekstra'), '') is not null then
    for v_label in select btrim(x) from unnest(string_to_array(v_opts ->> 'Topping Ekstra', ',')) x loop
      select id into v_key from public.xtratopping_cache where lower(name) = lower(v_label);
      if v_key is null then
        v_warn := v_warn || format('topping "%s" tidak terbaca', v_label);
      else
        v_top_ids := v_top_ids || v_key;
      end if;
    end loop;
  end if;

  if cardinality(v_top_ids) > 0 then
    -- Harga topping mengikuti ukuran; tanpa ukuran (mis. Pizza Kotak) memakai harga large.
    select price into v_top_price from public.xtratopping_price_cache
    where variant_key = case when v_variant.variant_key in ('personal', 'medium', 'large')
                             then v_variant.variant_key else 'large' end;
    if v_top_price is null then
      v_warn := v_warn || 'harga topping tidak tersedia'::text;
      v_top_price := 0;
    end if;
    v_top_sum := v_top_price * cardinality(v_top_ids);
    if v_top_sum > v_unit_web then
      v_warn := v_warn || 'harga topping tidak cocok dengan harga website'::text;
      v_top_price := 0;
      v_top_sum := 0;
    end if;
  end if;

  v_unit := v_unit_web - v_top_sum;

  -- Pilihan lain berlabel (mis. "Pilihan Saus" pada Rice Box) — kunci label lama
  -- tetap ada juga di pesanan format baru, jadi dibaca dari situ.
  select coalesce(jsonb_agg(jsonb_build_object('key', k, 'label', k, 'value', v) order by k), '[]'::jsonb)
  into v_choices
  from jsonb_each_text(v_opts) e(k, v)
  where left(k, 1) <> '_' and k not in ('ukuran', 'varian', 'Topping Ekstra') and btrim(v) <> '';

  insert into public.transaction_items (
    transaction_id, product_id, product_name_snapshot, category_snapshot,
    variant_id, variant_key_snapshot, variant_name_snapshot,
    variant_price_snapshot, unit_price, qty, subtotal_item, package_choices_snapshot,
    source_line_ref, source_options, mapping_warning
  ) values (
    p_tx, v_product.id,
    case when v_variant.id is null and v_product.kind in ('sized', 'variant') then w ->> 'name' else v_product.name end,
    v_product.category,
    v_variant.id, v_variant.variant_key, v_variant.label,
    v_unit, v_unit, v_qty, v_qty * v_unit_web, nullif(v_choices, '[]'::jsonb),
    w ->> 'id', v_opts, nullif(array_to_string(v_warn, '; '), '')
  )
  returning id into v_item_id;

  foreach v_key in array v_top_ids loop
    select name into v_top_name from public.xtratopping_cache where id = v_key;
    if v_top_name is null then
      update public.transaction_items
      set mapping_warning = concat_ws('; ', mapping_warning, format('topping "%s" tidak dikenal', v_key))
      where id = v_item_id;
      v_top_name := v_key;
    end if;
    insert into public.transaction_item_addons (
      transaction_item_id, addon_id, addon_name_snapshot, addon_price_snapshot, unit_price, qty
    ) values (v_item_id, v_key, v_top_name, v_top_price, v_top_price, 1);
  end loop;

  return v_qty * v_unit_web;
end;
$$;

-- ---------------------------------------------------------------------
-- Terapkan hasil tarik (service_role saja)
--   p_orders: [{ "header": <baris v_pesanan>, "items": [<baris v_item_pesanan>] }]
--   items wajib untuk pesanan yang belum pernah ditarik.
-- ---------------------------------------------------------------------
create or replace function public.apply_web_orders(p_orders jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_o        jsonb;
  h          jsonb;
  v_items    jsonb;
  v_id       uuid;
  v_wo       public.web_orders;
  v_tx       public.transactions;
  v_outlet   uuid;
  v_customer uuid;
  v_subtotal bigint;
  v_discount bigint;
  v_shipping bigint;
  v_item     jsonb;
  v_created  integer := 0;
  v_updated  integer := 0;
  v_voided   integer := 0;
  v_sales    text;
begin
  select id into v_outlet from public.outlets where active order by created_at limit 1;

  for v_o in select * from jsonb_array_elements(coalesce(p_orders, '[]'::jsonb)) loop
    h := v_o -> 'header';
    v_id := (h ->> 'id')::uuid;
    select * into v_wo from public.web_orders where id = v_id for update;

    if v_wo.id is null then
      v_items := coalesce(v_o -> 'items', '[]'::jsonb);
      insert into public.web_orders (
        id, order_code, order_type, web_status, web_created_at, web_updated_at, header, items,
        menunggu_admin, terkunci_edit, diubah_di_pos, metode_bayar, status_bayar
      ) values (
        v_id, h ->> 'order_code', h ->> 'order_type', h ->> 'status',
        (h ->> 'created_at')::timestamptz, (h ->> 'updated_at')::timestamptz, h, v_items,
        coalesce((h ->> 'menunggu_admin')::boolean, false), coalesce((h ->> 'terkunci_edit')::boolean, false),
        coalesce((h ->> 'diubah_di_pos')::boolean, false), h ->> 'metode_bayar', h ->> 'status_bayar'
      )
      returning * into v_wo;
      v_created := v_created + 1;

      -- Pesanan yang sudah selesai/batal sebelum sempat ditarik: dicatat saja.
      if h ->> 'status' in ('selesai', 'batal') then
        continue;
      end if;

      v_sales := case h ->> 'order_type'
        when 'delivery' then 'delivery' when 'takeaway' then 'take_away' else 'dine_in' end;
      v_subtotal := coalesce((select sum((i ->> 'unit_price')::bigint * (i ->> 'qty')::integer)
                              from jsonb_array_elements(v_items) i), 0);
      v_discount := least(public.web_header_discount(h), v_subtotal);
      v_shipping := public.web_header_shipping(h);
      select id into v_customer from public.customers
      where source_customer_id = nullif(h ->> 'customer_id', '')::uuid limit 1;

      insert into public.transactions (
        outlet_id, channel, sales_type, source_order_id, web_order_code,
        customer_id, customer_name, customer_phone, delivery_address, delivery_patokan, notes,
        subtotal, discount_code, discount_amount, shipping_cost, total,
        order_status, original_order_snapshot
      ) values (
        v_outlet, 'website', v_sales, v_id::text, h ->> 'order_code',
        v_customer, h ->> 'recipient_name', h ->> 'recipient_phone',
        case when v_sales = 'delivery' then h ->> 'address' end,
        case when v_sales = 'delivery' then h ->> 'patokan' end,
        nullif(btrim(h ->> 'note'), ''),
        v_subtotal, nullif(h ->> 'voucher_code', ''), v_discount, v_shipping,
        v_subtotal - v_discount + v_shipping,
        'diterima', jsonb_build_object('header', h, 'items', v_items)
      )
      returning * into v_tx;

      for v_item in select * from jsonb_array_elements(v_items) loop
        perform public.web_insert_item(v_tx.id, v_item);
      end loop;

      update public.web_orders
      set transaction_id = v_tx.id,
          header_notice = case when v_tx.total <> coalesce((h ->> 'total')::bigint, v_tx.total)
            then format('Total POS Rp%s berbeda dengan total website Rp%s — periksa', v_tx.total, h ->> 'total')
          end
      where id = v_id;
      perform public.web_enqueue_status(v_id, 'diterima');
      continue;
    end if;

    -- ---------------- Pesanan yang sudah ada ----------------
    update public.web_orders
    set web_status = h ->> 'status',
        web_updated_at = (h ->> 'updated_at')::timestamptz,
        header = h,
        menunggu_admin = coalesce((h ->> 'menunggu_admin')::boolean, false),
        terkunci_edit = coalesce((h ->> 'terkunci_edit')::boolean, false),
        diubah_di_pos = diubah_di_pos or coalesce((h ->> 'diubah_di_pos')::boolean, false),
        metode_bayar = h ->> 'metode_bayar',
        status_bayar = h ->> 'status_bayar',
        last_pulled_at = now()
    where id = v_id
    returning * into v_wo;
    v_updated := v_updated + 1;

    select * into v_tx from public.transactions where id = v_wo.transaction_id for update;
    if v_tx.id is null or v_tx.status <> 'active' then
      continue;
    end if;

    if h ->> 'status' = 'batal' then
      if v_tx.payment_status = 'unpaid' then
        update public.transactions
        set status = 'voided', void_source = 'website', voided_at = now(),
            void_reason = 'Dibatalkan di website'
        where id = v_tx.id;
        update public.web_orders
        set void_slip_pending = v_tx.kitchen_ticket_print_count > 0
        where id = v_id;
        -- Status yang belum terkirim tidak relevan lagi.
        update public.web_status_outbox
        set failed_at = now(), last_error = 'dibatalkan di website'
        where web_order_id = v_id and sent_at is null and failed_at is null;
        v_voided := v_voided + 1;
      else
        update public.web_orders
        set cancel_notice = 'Pesanan dibatalkan di website, tetapi transaksi sudah dibayar — tangani pengembalian dana dan batalkan transaksi bila perlu.'
        where id = v_id;
      end if;
      continue;
    end if;

    -- Angka header terbaru (mis. diskon dicabut admin) selama belum diproses & belum terkunci.
    v_discount := least(public.web_header_discount(h), v_tx.subtotal);
    v_shipping := coalesce(v_wo.kasir_shipping_cost, public.web_header_shipping(h));
    if v_discount <> v_tx.discount_amount or v_shipping <> v_tx.shipping_cost
       or nullif(h ->> 'voucher_code', '') is distinct from v_tx.discount_code then
      if v_tx.order_status in ('baru', 'diterima') and not v_tx.is_locked then
        update public.transactions
        set discount_amount = v_discount,
            discount_code = nullif(h ->> 'voucher_code', ''),
            shipping_cost = v_shipping,
            total = subtotal - v_discount + v_shipping - coalesce(manual_discount_amount, 0)
        where id = v_tx.id;
      else
        update public.web_orders
        set header_notice = 'Angka diskon/ongkir di website berubah setelah pesanan diproses atau struk dicetak — periksa dengan admin website.'
        where id = v_id;
      end if;
    end if;
  end loop;

  return jsonb_build_object('created', v_created, 'updated', v_updated, 'voided', v_voided);
end;
$$;

-- ---------------------------------------------------------------------
-- Lease & laporan run Edge Function (satu run sekaligus)
-- ---------------------------------------------------------------------
create or replace function public.web_bridge_lease(p_seconds integer default 60)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token uuid := gen_random_uuid();
begin
  update public.web_bridge_state
  set lease_until = now() + make_interval(secs => p_seconds), lease_token = v_token
  where lease_until is null or lease_until < now();
  if not found then
    return null;
  end if;
  return v_token;
end;
$$;

-- p_report: {ok, error, view_empty, orders_cursor, inactive_reason}
create or replace function public.web_bridge_release(p_token uuid, p_report jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.web_bridge_state
  set lease_until = null,
      lease_token = null,
      last_run_at = now(),
      last_ok_at = case when coalesce((p_report ->> 'ok')::boolean, false) then now() else last_ok_at end,
      last_error = case when coalesce((p_report ->> 'ok')::boolean, false) then null else p_report ->> 'error' end,
      view_empty = coalesce((p_report ->> 'view_empty')::boolean, view_empty),
      orders_cursor = coalesce((p_report ->> 'orders_cursor')::timestamptz, orders_cursor),
      inactive_reason = case when p_report ? 'inactive_reason' then p_report ->> 'inactive_reason' else inactive_reason end
  where lease_token = p_token;
end;
$$;

-- ---------------------------------------------------------------------
-- Antrean status
-- ---------------------------------------------------------------------
-- Baris berikutnya per pesanan (urut), yang sudah waktunya dicoba. Selama
-- pesanan menunggu admin website, status ditahan (fungsi website menolaknya
-- dengan menunggu_admin) — kecuali pembatalan; lanjut otomatis setelah penanda hilang.
create or replace function public.web_outbox_due(p_limit integer default 20)
returns setof public.web_status_outbox
language sql
stable
security definer
set search_path = ''
as $$
  select o.* from (
    select distinct on (web_order_id) *
    from public.web_status_outbox
    where sent_at is null and failed_at is null
    order by web_order_id, id
  ) o
  join public.web_orders w on w.id = o.web_order_id
  where o.next_attempt_at <= now()
    and (not w.menunggu_admin or o.status = 'dibatalkan')
  order by o.id
  limit p_limit;
$$;

-- p_outcome: 'ok' | 'retry' | 'failed'
create or replace function public.web_outbox_mark(
  p_id bigint, p_outcome text, p_result jsonb default null, p_error text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.web_status_outbox;
begin
  select * into v_row from public.web_status_outbox where id = p_id for update;
  if v_row.id is null then
    return;
  end if;

  if p_outcome = 'ok' then
    update public.web_status_outbox
    set sent_at = now(), result = p_result, last_error = null, attempts = attempts + 1
    where id = p_id;
    update public.web_orders
    set diubah_di_pos = diubah_di_pos or coalesce((p_result ->> 'diubah_di_pos')::boolean, false),
        metode_bayar = coalesce(p_result ->> 'metode_bayar', metode_bayar)
    where id = v_row.web_order_id;
  elsif p_outcome = 'failed' then
    update public.web_status_outbox
    set failed_at = now(), last_error = p_error, result = p_result, attempts = attempts + 1
    where id = p_id;
  else
    -- Jeda bertahap: 30 dtk, 1, 2, 5, lalu 10 menit.
    update public.web_status_outbox
    set attempts = attempts + 1,
        last_error = p_error,
        next_attempt_at = now() + case
          when attempts = 0 then interval '30 seconds'
          when attempts = 1 then interval '1 minute'
          when attempts = 2 then interval '2 minutes'
          when attempts = 3 then interval '5 minutes'
          else interval '10 minutes' end
    where id = p_id;
  end if;
end;
$$;

-- Penanda diubah_kasir sudah diterima website (dipanggil web-order-edit).
create or replace function public.web_mark_flag_ok(p_order_id uuid, p_result jsonb)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.web_orders
  set diubah_di_pos = true,
      metode_bayar = coalesce(p_result ->> 'metode_bayar', metode_bayar)
  where id = p_order_id;
$$;

-- ---------------------------------------------------------------------
-- Aksi kasir
-- ---------------------------------------------------------------------
create or replace function public.web_load_for_action(p_transaction_id uuid)
returns public.transactions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tx public.transactions;
begin
  if public.current_pos_user_id() is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;
  select * into v_tx from public.transactions where id = p_transaction_id for update;
  if v_tx.id is null or v_tx.channel <> 'website' then
    raise exception 'PESANAN_TIDAK_ADA: pesanan website tidak ditemukan';
  end if;
  if v_tx.status <> 'active' then
    raise exception 'TRANSAKSI_BATAL: pesanan sudah dibatalkan';
  end if;
  return v_tx;
end;
$$;

create or replace function public.open_web_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := public.current_pos_user_id();
begin
  if v_user is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;
  update public.web_orders
  set opened_at = now(), opened_by = v_user
  where id = p_order_id and opened_at is null;
end;
$$;

create or replace function public.confirm_web_order(p_transaction_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := public.current_pos_user_id();
  v_tx    public.transactions := public.web_load_for_action(p_transaction_id);
  v_wo    public.web_orders;
  v_shift uuid;
begin
  if v_tx.order_status not in ('baru', 'diterima') then
    raise exception 'SUDAH_DIPROSES: pesanan % sudah dikonfirmasi', v_tx.web_order_code;
  end if;
  select * into v_wo from public.web_orders where transaction_id = v_tx.id;
  if v_wo.menunggu_admin then
    raise exception 'MENUNGGU_ADMIN: menunggu verifikasi admin website';
  end if;
  if v_wo.metode_bayar = 'online' and coalesce(v_wo.status_bayar, '') <> 'lunas' then
    raise exception 'BELUM_LUNAS_ONLINE: pembayaran online belum lunas';
  end if;
  select id into v_shift from public.shifts where outlet_id = v_tx.outlet_id and status = 'open';
  if v_shift is null then
    raise exception 'SHIFT_BELUM_DIBUKA: buka shift dulu untuk memproses pesanan';
  end if;

  update public.transactions
  set order_status = 'diproses',
      shift_id = coalesce(shift_id, v_shift),
      cashier_id = coalesce(cashier_id, v_user)
  where id = v_tx.id;
  update public.web_orders set opened_at = coalesce(opened_at, now()), opened_by = coalesce(opened_by, v_user)
  where id = v_wo.id;
  perform public.web_enqueue_status(v_wo.id, 'diproses', v_user);
  return jsonb_build_object('order_status', 'diproses');
end;
$$;

create or replace function public.ready_web_order(p_transaction_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tx     public.transactions := public.web_load_for_action(p_transaction_id);
  v_target text;
begin
  if v_tx.order_status <> 'diproses' then
    raise exception 'STATUS_TIDAK_SESUAI: pesanan belum dikonfirmasi atau sudah siap';
  end if;
  v_target := case when v_tx.sales_type = 'delivery' then 'sedang_diantar' else 'siap_diambil' end;
  update public.transactions set order_status = v_target where id = v_tx.id;
  perform public.web_enqueue_status(v_tx.source_order_id::uuid, v_target, public.current_pos_user_id());
  return jsonb_build_object('order_status', v_target);
end;
$$;

create or replace function public.finish_web_order(p_transaction_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tx public.transactions := public.web_load_for_action(p_transaction_id);
begin
  if v_tx.order_status not in ('diproses', 'siap_diambil', 'sedang_diantar') then
    raise exception 'STATUS_TIDAK_SESUAI: pesanan belum dikonfirmasi atau sudah selesai';
  end if;
  if v_tx.payment_status <> 'paid' then
    raise exception 'BELUM_LUNAS: pesanan harus lunas sebelum diselesaikan';
  end if;
  update public.transactions set order_status = 'selesai' where id = v_tx.id;
  perform public.web_enqueue_status(v_tx.source_order_id::uuid, 'selesai', public.current_pos_user_id());
  return jsonb_build_object('order_status', 'selesai');
end;
$$;

-- Void oleh kasir pada pesanan website → antre 'dibatalkan'.
create or replace function public.web_enqueue_on_void()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status = 'active' and new.status = 'voided'
     and new.channel = 'website' and new.void_source = 'pos' and new.source_order_id is not null then
    perform public.web_enqueue_status(new.source_order_id::uuid, 'dibatalkan', new.void_requested_by);
  end if;
  return null;
end;
$$;

create trigger transactions_web_void
  after update of status on public.transactions
  for each row execute function public.web_enqueue_on_void();

create or replace function public.web_void_slip_done(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.current_pos_user_id() is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;
  update public.web_orders set void_slip_pending = false where id = p_order_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Edit pesanan (hanya sebelum Konfirmasi & Proses)
--   p_payload: {
--     "lines": [{"ref": "<order_items.id>", "qty": 2}, ...],   -- baris website (qty 0/absen = hapus)
--     "new_items": [<item gaya create_transaction>],            -- tambahan kasir, harga POS
--     "shipping_cost": 12000                                    -- opsional (Delivery)
--   }
-- Syarat: penanda diubah_kasir sudah diterima website (web_orders.diubah_di_pos,
-- diisi Edge Function web-order-edit sebelum memanggil fungsi ini).
-- ---------------------------------------------------------------------
create or replace function public.web_insert_new_item(p_tx uuid, v_item jsonb)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_qty       integer := (v_item ->> 'qty')::integer;
  v_package   public.packages_cache;
  v_product   public.products_cache;
  v_variant   public.product_variants_cache;
  v_group     jsonb;
  v_choice    text;
  v_choices   jsonb := '[]'::jsonb;
  v_base      bigint;
  v_top       jsonb;
  v_top_qty   integer;
  v_top_name  text;
  v_top_base  bigint;
  v_top_sum   bigint := 0;
  v_item_id   uuid;
begin
  if v_qty is null or v_qty < 1 or v_qty > 999 then
    raise exception 'QTY_TIDAK_VALID: jumlah item harus 1–999';
  end if;

  if coalesce(v_item ->> 'item_type', 'product') = 'package' then
    select * into v_package from public.packages_cache where id = v_item ->> 'product_id' and active;
    if v_package.id is null then
      raise exception 'PAKET_TIDAK_TERSEDIA: paket % tidak tersedia', v_item ->> 'product_id';
    end if;
    for v_group in select * from jsonb_array_elements(coalesce(v_package.package_choices, '[]'::jsonb)) loop
      v_choice := v_item -> 'choices' ->> (v_group ->> 'key');
      if v_choice is null or not coalesce(v_group -> 'options', '[]'::jsonb) ? v_choice then
        raise exception 'PILIHAN_PAKET_WAJIB: pilih % untuk %', v_group ->> 'label', v_package.name;
      end if;
      v_choices := v_choices || jsonb_build_array(jsonb_build_object(
        'key', v_group ->> 'key', 'label', v_group ->> 'label', 'value', v_choice));
    end loop;
    insert into public.transaction_items (
      transaction_id, item_type, product_id, product_name_snapshot, category_snapshot,
      variant_price_snapshot, unit_price, qty, subtotal_item, notes,
      package_items_snapshot, package_choices_snapshot, package_note_snapshot
    ) values (
      p_tx, 'package', v_package.id, v_package.name, coalesce(v_package.category_slug, 'paket'),
      v_package.base_price, v_package.base_price, v_qty, v_qty * v_package.base_price,
      nullif(btrim(v_item ->> 'notes'), ''),
      coalesce(v_package.package_items, '[]'::jsonb), v_choices, v_package.package_note
    );
    return v_qty * v_package.base_price;
  end if;

  select * into v_product from public.products_cache where id = v_item ->> 'product_id' and active;
  if v_product.id is null then
    raise exception 'PRODUK_TIDAK_TERSEDIA: produk % tidak tersedia', v_item ->> 'product_id';
  end if;
  if v_product.kind in ('sized', 'variant') then
    select * into v_variant from public.product_variants_cache
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

  insert into public.transaction_items (
    transaction_id, product_id, product_name_snapshot, category_snapshot,
    variant_id, variant_key_snapshot, variant_name_snapshot,
    variant_price_snapshot, unit_price, qty, subtotal_item, notes
  ) values (
    p_tx, v_product.id, v_product.name, v_product.category,
    v_variant.id, v_variant.variant_key, v_variant.label,
    v_base, v_base, v_qty, 0, nullif(btrim(v_item ->> 'notes'), '')
  )
  returning id into v_item_id;

  if jsonb_array_length(coalesce(v_item -> 'toppings', '[]'::jsonb)) > 0 then
    if v_product.kind <> 'sized' then
      raise exception 'TOPPING_TIDAK_BERLAKU: extra topping hanya untuk pizza';
    end if;
    select price into v_top_base from public.xtratopping_price_cache where variant_key = v_variant.variant_key;
    if v_top_base is null then
      raise exception 'HARGA_TOPPING_TIDAK_ADA: harga topping ukuran % belum tersedia', v_variant.label;
    end if;
    for v_top in select * from jsonb_array_elements(v_item -> 'toppings') loop
      v_top_qty := coalesce((v_top ->> 'qty')::integer, 1);
      if v_top_qty < 1 or v_top_qty > 20 then
        raise exception 'QTY_TIDAK_VALID: jumlah topping harus 1–20';
      end if;
      select name into v_top_name from public.xtratopping_cache where id = v_top ->> 'id' and active;
      if v_top_name is null then
        raise exception 'TOPPING_TIDAK_TERSEDIA: topping % tidak tersedia', v_top ->> 'id';
      end if;
      insert into public.transaction_item_addons (
        transaction_item_id, addon_id, addon_name_snapshot, addon_price_snapshot, unit_price, qty
      ) values (v_item_id, v_top ->> 'id', v_top_name, v_top_base, v_top_base, v_top_qty);
      v_top_sum := v_top_sum + v_top_base * v_top_qty;
    end loop;
  end if;

  update public.transaction_items set subtotal_item = v_qty * (v_base + v_top_sum) where id = v_item_id;
  return v_qty * (v_base + v_top_sum);
end;
$$;

create or replace function public.edit_web_order(p_transaction_id uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tx       public.transactions := public.web_load_for_action(p_transaction_id);
  v_wo       public.web_orders;
  v_line     record;
  v_qty      integer;
  v_item     jsonb;
  v_subtotal bigint;
  v_shipping bigint;
  v_count    integer;
begin
  select * into v_wo from public.web_orders where transaction_id = v_tx.id for update;
  if v_tx.order_status not in ('baru', 'diterima') then
    raise exception 'EDIT_DITUTUP: pesanan sudah dikonfirmasi — perubahan hanya lewat pembatalan';
  end if;
  if v_tx.is_locked then
    raise exception 'TRANSAKSI_TERKUNCI: struk sudah dicetak — perubahan hanya lewat pembatalan';
  end if;
  if v_wo.terkunci_edit then
    raise exception 'TERKUNCI_EDIT: pesanan sudah lunas online, tidak bisa diubah';
  end if;
  if not v_wo.diubah_di_pos then
    raise exception 'PENANDA_BELUM_TERKIRIM: penanda perubahan belum diterima website, coba lagi';
  end if;

  -- Baris website: ubah qty atau hapus (harga website tetap).
  for v_line in
    select i.id, i.source_line_ref, i.unit_price,
           coalesce((select sum(a.unit_price * a.qty) from public.transaction_item_addons a
                     where a.transaction_item_id = i.id), 0) as addon_sum
    from public.transaction_items i
    where i.transaction_id = v_tx.id and i.source_line_ref is not null
  loop
    select (l ->> 'qty')::integer into v_qty
    from jsonb_array_elements(coalesce(p_payload -> 'lines', '[]'::jsonb)) l
    where l ->> 'ref' = v_line.source_line_ref;
    if coalesce(v_qty, 0) <= 0 then
      delete from public.transaction_items where id = v_line.id;
    elsif v_qty > 999 then
      raise exception 'QTY_TIDAK_VALID: jumlah item harus 1–999';
    else
      update public.transaction_items
      set qty = v_qty, subtotal_item = v_qty * (v_line.unit_price + v_line.addon_sum)
      where id = v_line.id;
    end if;
  end loop;

  -- Tambahan kasir: diganti seluruhnya dengan daftar baru (harga normal POS).
  delete from public.transaction_items where transaction_id = v_tx.id and source_line_ref is null;
  for v_item in select * from jsonb_array_elements(coalesce(p_payload -> 'new_items', '[]'::jsonb)) loop
    perform public.web_insert_new_item(v_tx.id, v_item);
  end loop;

  select count(*), coalesce(sum(subtotal_item), 0) into v_count, v_subtotal
  from public.transaction_items where transaction_id = v_tx.id;
  if v_count = 0 then
    raise exception 'KERANJANG_KOSONG: pesanan harus berisi minimal satu item — batalkan pesanan bila perlu';
  end if;

  if p_payload ? 'shipping_cost' and v_tx.sales_type = 'delivery' then
    v_shipping := (p_payload ->> 'shipping_cost')::bigint;
    if v_shipping is null or v_shipping < 0 then
      raise exception 'ONGKIR_TIDAK_VALID: ongkir tidak valid';
    end if;
    update public.web_orders set kasir_shipping_cost = v_shipping where id = v_wo.id;
  else
    v_shipping := v_tx.shipping_cost;
  end if;

  if v_subtotal - least(v_tx.discount_amount, v_subtotal) + v_shipping < 0 then
    raise exception 'TOTAL_TIDAK_VALID: total menjadi negatif';
  end if;

  update public.transactions
  set subtotal = v_subtotal,
      discount_amount = least(discount_amount, v_subtotal),
      shipping_cost = v_shipping,
      total = v_subtotal - least(discount_amount, v_subtotal) + v_shipping - coalesce(manual_discount_amount, 0)
  where id = v_tx.id
  returning * into v_tx;

  return jsonb_build_object('subtotal', v_tx.subtotal, 'shipping_cost', v_tx.shipping_cost, 'total', v_tx.total);
end;
$$;

-- ---------------------------------------------------------------------
-- Void: pesanan website yang belum dikonfirmasi (belum punya shift), belum
-- dibayar, dan belum terkunci boleh dibatalkan pemegang
-- void_unlocked_transaction tanpa PIN penyetuju. Aturan lain tetap.
-- ---------------------------------------------------------------------
create or replace function public.user_can_void(
  p_user_id uuid,
  p_tx public.transactions,
  p_open_shift_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.user_has_permission(p_user_id, 'void_transaction')
      or (not p_tx.is_locked
          and public.user_has_permission(p_user_id, 'void_unlocked_transaction')
          and (
            (p_tx.shift_id is not distinct from p_open_shift_id and p_open_shift_id is not null)
            or (p_tx.channel = 'website' and p_tx.shift_id is null and p_tx.payment_status = 'unpaid')
          ));
$$;

-- ---------------------------------------------------------------------
-- Data cetak: kode pesanan website & penanda item tak terpetakan
-- ---------------------------------------------------------------------
create or replace function public.transaction_print_data(p_transaction_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tx     public.transactions;
  v_result jsonb;
begin
  if public.current_pos_user_id() is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;

  select * into v_tx from public.transactions where id = p_transaction_id;
  if v_tx.id is null then
    raise exception 'TRANSAKSI_TIDAK_ADA: transaksi tidak ditemukan';
  end if;

  select jsonb_build_object(
    'id', v_tx.id,
    'outlet_id', v_tx.outlet_id,
    'transaction_number', v_tx.transaction_number,
    'web_order_code', v_tx.web_order_code,
    'created_at', v_tx.created_at,
    'channel', v_tx.channel,
    'sales_type', v_tx.sales_type,
    'status', v_tx.status,
    'platform_name', (select name from public.marketplace_platforms where id = v_tx.marketplace_platform_id),
    'customer_name', v_tx.customer_name,
    'delivery_address', v_tx.delivery_address,
    'delivery_patokan', v_tx.delivery_patokan,
    'notes', v_tx.notes,
    'cashier_name', (select name from public.pos_users where id = v_tx.cashier_id),
    'courier_type', v_tx.courier_type,
    'courier_name', case v_tx.courier_type
        when 'karyawan' then (select name from public.pos_users where id = v_tx.courier_user_id)
        when 'freelance' then (select name from public.couriers where id = v_tx.courier_id)
        when 'shopee_express' then 'Shopee Express'
        when 'maxim' then 'Maxim'
      end,
    'subtotal', v_tx.subtotal,
    'discount_code', v_tx.discount_code,
    'discount_amount', v_tx.discount_amount,
    'manual_discount_type', v_tx.manual_discount_type,
    'manual_discount_value', v_tx.manual_discount_value,
    'manual_discount_amount', v_tx.manual_discount_amount,
    'shipping_cost', v_tx.shipping_cost,
    'total', v_tx.total,
    'payment_status', v_tx.payment_status,
    'payment_method_name', (select name from public.payment_methods where id = v_tx.payment_method_id),
    'payment_is_cash', (select is_cash from public.payment_methods where id = v_tx.payment_method_id),
    'bank_name', (select bank_name from public.bank_accounts where id = v_tx.bank_account_id),
    'amount_paid', v_tx.amount_paid,
    'change_amount', v_tx.change_amount,
    'kitchen_ticket_print_count', v_tx.kitchen_ticket_print_count,
    'receipt_print_count', v_tx.receipt_print_count,
    'receipt_printed_status', v_tx.receipt_printed_status,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'item_type', i.item_type,
        'qty', i.qty,
        'product_name', i.product_name_snapshot,
        'variant_name', i.variant_name_snapshot,
        'unit_price', i.unit_price,
        'subtotal_item', i.subtotal_item,
        'notes', i.notes,
        'package_items', i.package_items_snapshot,
        'package_choices', i.package_choices_snapshot,
        'package_note', i.package_note_snapshot,
        'mapping_warning', i.mapping_warning,
        'addons', coalesce((
          select jsonb_agg(jsonb_build_object(
            'name', a.addon_name_snapshot, 'qty', a.qty, 'unit_price', a.unit_price
          ) order by a.created_at, a.id)
          from public.transaction_item_addons a
          where a.transaction_item_id = i.id
        ), '[]')
      ) order by i.created_at, i.id)
      from public.transaction_items i
      where i.transaction_id = v_tx.id
    ), '[]')
  ) into v_result;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- Hak eksekusi
-- ---------------------------------------------------------------------
revoke all on function public.web_enqueue_status(uuid, text, uuid, boolean) from public, anon, authenticated;
revoke all on function public.web_header_discount(jsonb) from public, anon, authenticated;
revoke all on function public.web_header_shipping(jsonb) from public, anon, authenticated;
revoke all on function public.web_insert_item(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.web_insert_new_item(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.web_load_for_action(uuid) from public, anon, authenticated;
revoke all on function public.web_enqueue_on_void() from public, anon, authenticated;

-- Hanya Edge Function (service_role).
revoke all on function public.apply_web_orders(jsonb) from public, anon, authenticated;
revoke all on function public.web_bridge_lease(integer) from public, anon, authenticated;
revoke all on function public.web_bridge_release(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.web_outbox_due(integer) from public, anon, authenticated;
revoke all on function public.web_outbox_mark(bigint, text, jsonb, text) from public, anon, authenticated;
revoke all on function public.web_mark_flag_ok(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.apply_web_orders(jsonb) to service_role;
grant execute on function public.web_bridge_lease(integer) to service_role;
grant execute on function public.web_bridge_release(uuid, jsonb) to service_role;
grant execute on function public.web_outbox_due(integer) to service_role;
grant execute on function public.web_outbox_mark(bigint, text, jsonb, text) to service_role;
grant execute on function public.web_mark_flag_ok(uuid, jsonb) to service_role;

-- Kasir (login).
revoke all on function public.open_web_order(uuid) from public, anon;
revoke all on function public.confirm_web_order(uuid) from public, anon;
revoke all on function public.ready_web_order(uuid) from public, anon;
revoke all on function public.finish_web_order(uuid) from public, anon;
revoke all on function public.edit_web_order(uuid, jsonb) from public, anon;
revoke all on function public.web_void_slip_done(uuid) from public, anon;
grant execute on function public.open_web_order(uuid) to authenticated;
grant execute on function public.confirm_web_order(uuid) to authenticated;
grant execute on function public.ready_web_order(uuid) to authenticated;
grant execute on function public.finish_web_order(uuid) to authenticated;
grant execute on function public.edit_web_order(uuid, jsonb) to authenticated;
grant execute on function public.web_void_slip_done(uuid) to authenticated;
