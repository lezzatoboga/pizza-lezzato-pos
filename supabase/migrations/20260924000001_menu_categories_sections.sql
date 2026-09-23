-- =====================================================================
-- Cache kategori & section menu dari website (menu_categories,
-- menu_sections) — sumber urutan tampilan menu:
--   kategori (sort_order) → section (sort_order) → produk (sort_order)
-- sort_order produk di website dimulai ulang per section, jadi urutan
-- antar kategori/section hanya bisa diambil dari kedua tabel ini.
-- =====================================================================

create table public.menu_categories_cache (
  slug            text primary key,         -- = menu_categories.slug = products_cache.category
  label           text not null,
  sort_order      integer not null default 0,
  last_synced_at  timestamptz not null default now()
);

create table public.menu_sections_cache (
  key             text primary key,         -- = menu_sections.key = products_cache.section_key
  category_slug   text not null,
  label           text not null,
  sort_order      integer not null default 0,
  last_synced_at  timestamptz not null default now()
);

alter table public.menu_categories_cache enable row level security;
alter table public.menu_sections_cache enable row level security;

grant select, insert, update, delete on public.menu_categories_cache, public.menu_sections_cache to service_role;
grant select on public.menu_categories_cache, public.menu_sections_cache to authenticated;

create policy pos_users_read on public.menu_categories_cache for select to authenticated
  using ((select public.current_pos_user_id()) is not null);
create policy pos_users_read on public.menu_sections_cache for select to authenticated
  using ((select public.current_pos_user_id()) is not null);

-- ---------------------------------------------------------------------
-- apply_menu_sync: + kategori & section. Keduanya hanya metadata urutan,
-- jadi baris yang hilang dari website dihapus.
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
  v_variants   integer;
  v_toppings   integer;
  v_categories integer;
  v_sections   integer;
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
  values (p_trigger, p_triggered_by, 'success', v_products, v_variants, v_toppings);

  return jsonb_build_object(
    'products', v_products,
    'variants', v_variants,
    'toppings', v_toppings,
    'categories', v_categories,
    'sections', v_sections
  );
end;
$$;

revoke execute on function public.apply_menu_sync(jsonb, text, uuid) from public, anon, authenticated;
grant execute on function public.apply_menu_sync(jsonb, text, uuid) to service_role;
