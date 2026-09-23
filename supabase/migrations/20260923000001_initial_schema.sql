-- =====================================================================
-- POS Pizza Lezzato — Fase 1: skema awal
-- Referensi: SPEC_POS_Pizza_Lezzato_Fase1.md bagian 3 + penyesuaian
-- yang disepakati (status bayar, void, order_status, outlet, topping global).
--
-- Konvensi:
--   * Uang transaksi  : bigint rupiah bulat (tanpa desimal)
--   * Harga cache     : integer (mengikuti tipe di database website)
--   * Persentase      : numeric(5,2)
--   * Waktu           : timestamptz; tanggal bisnis dihitung di Asia/Jakarta
--   * Nilai pilihan   : text + CHECK (lebih mudah diubah daripada enum)
--   * RLS aktif di semua tabel TANPA policy = tertutup total untuk
--     anon/authenticated. Policy detail ditambahkan di migration berikutnya.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Utilitas
-- ---------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Outlet
-- ---------------------------------------------------------------------
create table public.outlets (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,         -- prefix nomor transaksi, mis. 'PL'
  name        text not null,
  address     text,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint outlets_code_format check (code ~ '^[A-Z0-9]{1,6}$')
);

-- ---------------------------------------------------------------------
-- 3.1 Referensi produk (cache dari database website)
-- Paket (kind = 'package') tidak termasuk cakupan POS Fase 1.
-- ---------------------------------------------------------------------
create table public.products_cache (
  id              text primary key,         -- = menu_items.id (slug, mis. 'chk5')
  name            text not null,
  category        text not null,            -- = menu_items.category_slug
  section_key     text,
  kind            text not null,
  base_price      integer check (base_price >= 0),  -- untuk item tanpa varian
  active          boolean not null default true,
  sort_order      integer not null default 0,
  last_synced_at  timestamptz not null default now(),
  constraint products_cache_kind check (kind in ('sized', 'simple', 'variant'))
);

create index products_cache_category_idx on public.products_cache (category);

create table public.product_variants_cache (
  id              uuid primary key,         -- = menu_item_variants.id
  product_id      text not null references public.products_cache (id) on delete cascade,
  variant_key     text not null,            -- mis. 'personal' / 'medium' / 'large'
  label           text not null,
  price           integer not null check (price >= 0),
  sort_order      integer not null default 0,
  last_synced_at  timestamptz not null default now(),
  unique (product_id, variant_key)
);

create index product_variants_cache_product_idx on public.product_variants_cache (product_id);

-- Extra topping: global untuk semua pizza.
create table public.xtratopping_cache (
  id              text primary key,         -- = xtratopping.id (slug)
  name            text not null,
  active          boolean not null default true,
  sort_order      integer not null default 0,
  last_synced_at  timestamptz not null default now()
);

-- Harga topping flat per ukuran pizza (3 baris), sama untuk semua jenis topping.
create table public.xtratopping_price_cache (
  variant_key     text primary key check (variant_key in ('personal', 'medium', 'large')),
  price           integer not null check (price >= 0),
  last_synced_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3.2 Pengaturan
-- ---------------------------------------------------------------------
create table public.payment_methods (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,         -- 'cash' / 'transfer' / 'qris'
  name        text not null,
  is_cash     boolean not null default false,  -- dipakai hitung expected_cash shift
  active      boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.marketplace_platforms (
  id              uuid primary key default gen_random_uuid(),
  code            text not null unique,     -- 'gofood' / 'grabfood' / 'shopeefood'
  name            text not null,
  markup_percent  numeric(5,2) not null default 0 check (markup_percent >= 0),
  active          boolean not null default true,
  sort_order      integer not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3.5 Pengguna, role & hak akses
-- (dibuat sebelum transaksi karena direferensikan oleh transaksi & shift)
-- ---------------------------------------------------------------------
create table public.roles (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,         -- 'owner' / 'supervisor' / 'kasir'
  name        text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.permissions (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  label       text not null,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now()
);

create table public.role_permissions (
  role_id          uuid not null references public.roles (id) on delete cascade,
  permission_code  text not null references public.permissions (code) on update cascade on delete cascade,
  granted          boolean not null default false,
  updated_at       timestamptz not null default now(),
  primary key (role_id, permission_code)
);

create table public.pos_users (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  role_id       uuid not null references public.roles (id),
  pin_hash      text not null,              -- hash PIN (bcrypt), tidak pernah PIN asli
  auth_user_id  uuid unique references auth.users (id) on delete set null,
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index pos_users_role_idx on public.pos_users (role_id);

-- ---------------------------------------------------------------------
-- 3.4 Shift & kas
-- ---------------------------------------------------------------------
create table public.shifts (
  id                    uuid primary key default gen_random_uuid(),
  outlet_id             uuid not null references public.outlets (id),
  cashier_id            uuid not null references public.pos_users (id),
  opening_balance       bigint not null check (opening_balance >= 0),
  opening_time          timestamptz not null default now(),
  closing_time          timestamptz,
  closing_cash_counted  bigint check (closing_cash_counted >= 0),
  expected_cash         bigint,
  cash_difference       bigint,             -- closing_cash_counted - expected_cash
  status                text not null default 'open',
  closed_by             uuid references public.pos_users (id),
  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint shifts_status check (status in ('open', 'closed')),
  constraint shifts_closed_complete check (
    status = 'open'
    or (closing_time is not null and closing_cash_counted is not null
        and expected_cash is not null and cash_difference is not null)
  )
);

-- Hanya satu shift terbuka per outlet dalam satu waktu.
create unique index shifts_one_open_per_outlet on public.shifts (outlet_id) where status = 'open';
create index shifts_cashier_idx on public.shifts (cashier_id);

create table public.cash_movements (
  id           uuid primary key default gen_random_uuid(),
  shift_id     uuid not null references public.shifts (id),
  type         text not null,
  amount       bigint not null check (amount > 0),
  description  text not null,
  created_by   uuid references public.pos_users (id),
  created_at   timestamptz not null default now(),
  constraint cash_movements_type check (type in ('masuk', 'keluar'))
);

create index cash_movements_shift_idx on public.cash_movements (shift_id);

-- ---------------------------------------------------------------------
-- 3.3 Transaksi
-- ---------------------------------------------------------------------

-- Penghitung nomor transaksi harian per outlet (PL-260923-0001).
create table public.transaction_counters (
  outlet_id     uuid not null references public.outlets (id),
  counter_date  date not null,
  last_number   integer not null default 0,
  primary key (outlet_id, counter_date)
);

create table public.transactions (
  id                        uuid primary key default gen_random_uuid(),
  outlet_id                 uuid not null references public.outlets (id),
  transaction_number        text not null unique,   -- diisi otomatis oleh trigger
  transaction_date          date not null default (now() at time zone 'Asia/Jakarta')::date,

  channel                   text not null,
  sales_type                text not null,
  marketplace_platform_id   uuid references public.marketplace_platforms (id),
  source_order_id           text unique,            -- id order website; mencegah order ganda

  customer_name             text,
  customer_phone            text,
  notes                     text,

  -- Harga
  subtotal                  bigint not null default 0 check (subtotal >= 0),
  discount_code             text,
  discount_amount           bigint not null default 0 check (discount_amount >= 0),
  markup_percent_applied    numeric(5,2) check (markup_percent_applied >= 0),
  markup_amount             bigint not null default 0 check (markup_amount >= 0),
  total                     bigint not null default 0 check (total >= 0),

  -- Pembayaran (satu metode per transaksi di Fase 1)
  payment_status            text not null default 'unpaid',
  payment_method_id         uuid references public.payment_methods (id),
  amount_paid               bigint check (amount_paid >= 0),
  change_amount             bigint check (change_amount >= 0),
  paid_at                   timestamptz,

  -- Status pesanan (dikirim balik ke website)
  order_status              text not null default 'baru',

  -- Kasir & shift
  cashier_id                uuid references public.pos_users (id),
  shift_id                  uuid references public.shifts (id),

  -- Cetak & penguncian
  kitchen_ticket_printed_at timestamptz,
  receipt_printed_status    text,
  receipt_printed_at        timestamptz,
  is_locked                 boolean not null default false,

  -- Pembatalan (void) — jejak audit, tidak pernah dihapus
  status                    text not null default 'active',
  voided_by                 uuid references public.pos_users (id),
  voided_at                 timestamptz,
  void_reason               text,

  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),

  constraint transactions_channel check (channel in ('admin_toko', 'website', 'marketplace')),
  constraint transactions_sales_type check (sales_type in ('dine_in', 'take_away', 'delivery')),
  constraint transactions_payment_status check (payment_status in ('unpaid', 'paid')),
  constraint transactions_order_status check (order_status in ('baru', 'diproses', 'siap', 'selesai')),
  constraint transactions_receipt_status check (receipt_printed_status in ('belum_lunas', 'lunas')),
  constraint transactions_status check (status in ('active', 'voided')),

  -- Marketplace: wajib delivery + platform; channel lain tanpa platform & markup.
  constraint transactions_marketplace_rules check (
    (channel = 'marketplace'
       and sales_type = 'delivery'
       and marketplace_platform_id is not null
       and markup_percent_applied is not null)
    or
    (channel <> 'marketplace'
       and marketplace_platform_id is null
       and markup_percent_applied is null
       and markup_amount = 0)
  ),
  -- Diskon hanya untuk channel website.
  constraint transactions_discount_website_only check (
    channel = 'website' or (discount_code is null and discount_amount = 0)
  ),
  constraint transactions_total_consistent check (total = subtotal - discount_amount),
  constraint transactions_paid_complete check (
    payment_status = 'unpaid' or (payment_method_id is not null and paid_at is not null)
  ),
  constraint transactions_void_complete check (
    status = 'active'
    or (voided_by is not null and voided_at is not null and void_reason is not null)
  ),
  constraint transactions_receipt_complete check (
    (receipt_printed_status is null) = (receipt_printed_at is null)
  )
);

create index transactions_outlet_date_idx on public.transactions (outlet_id, transaction_date);
create index transactions_channel_idx on public.transactions (channel);
create index transactions_platform_idx on public.transactions (marketplace_platform_id);
create index transactions_payment_method_idx on public.transactions (payment_method_id);
create index transactions_cashier_idx on public.transactions (cashier_id);
create index transactions_shift_idx on public.transactions (shift_id);

-- product_id / variant_id sengaja TANPA foreign key ke cache: produk bisa
-- dihapus di website, transaksi historis tetap utuh lewat snapshot.
create table public.transaction_items (
  id                      uuid primary key default gen_random_uuid(),
  transaction_id          uuid not null references public.transactions (id) on delete cascade,
  product_id              text not null,
  product_name_snapshot   text not null,
  category_snapshot       text not null,
  variant_id              uuid,
  variant_key_snapshot    text,             -- null untuk item tanpa varian
  variant_name_snapshot   text,
  variant_price_snapshot  bigint not null check (variant_price_snapshot >= 0),
  unit_price              bigint not null check (unit_price >= 0),
  qty                     integer not null check (qty > 0),
  subtotal_item           bigint not null check (subtotal_item >= 0),
  notes                   text,
  created_at              timestamptz not null default now()
);

comment on column public.transaction_items.variant_price_snapshot is
  'Harga asli dari website saat transaksi (harga varian, atau base_price untuk item tanpa varian).';
comment on column public.transaction_items.unit_price is
  'Harga jual per unit yang dikenakan (= variant_price_snapshot, atau setelah markup untuk marketplace).';
comment on column public.transaction_items.subtotal_item is
  'qty × (unit_price + Σ subtotal topping per unit).';

create index transaction_items_transaction_idx on public.transaction_items (transaction_id);
create index transaction_items_product_idx on public.transaction_items (product_id);
create index transaction_items_category_idx on public.transaction_items (category_snapshot);

create table public.transaction_item_addons (
  id                    uuid primary key default gen_random_uuid(),
  transaction_item_id   uuid not null references public.transaction_items (id) on delete cascade,
  addon_id              text not null,      -- = xtratopping id (tanpa FK, sama alasan dgn produk)
  addon_name_snapshot   text not null,
  addon_price_snapshot  bigint not null check (addon_price_snapshot >= 0),
  unit_price            bigint not null check (unit_price >= 0),
  qty                   integer not null default 1 check (qty > 0),
  subtotal              bigint generated always as (qty * unit_price) stored,
  created_at            timestamptz not null default now()
);

comment on column public.transaction_item_addons.addon_price_snapshot is
  'Harga topping dari website sesuai ukuran pizza (xtratopping_price) saat transaksi.';
comment on column public.transaction_item_addons.unit_price is
  'Harga topping yang dikenakan per 1 porsi (setelah markup untuk marketplace).';
comment on column public.transaction_item_addons.qty is
  'Jumlah topping ini per 1 unit pizza (mis. extra keju x2).';

create index transaction_item_addons_item_idx on public.transaction_item_addons (transaction_item_id);

-- ---------------------------------------------------------------------
-- Trigger: nomor transaksi otomatis PL-YYMMDD-NNNN (reset harian per outlet)
-- ---------------------------------------------------------------------
create or replace function public.assign_transaction_number()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code   text;
  v_number integer;
begin
  if new.transaction_number is not null then
    return new;
  end if;

  select code into v_code from public.outlets where id = new.outlet_id;
  if v_code is null then
    raise exception 'Outlet % tidak ditemukan', new.outlet_id;
  end if;

  insert into public.transaction_counters as c (outlet_id, counter_date, last_number)
  values (new.outlet_id, new.transaction_date, 1)
  on conflict (outlet_id, counter_date)
  do update set last_number = c.last_number + 1
  returning last_number into v_number;

  new.transaction_number :=
    v_code || '-' || to_char(new.transaction_date, 'YYMMDD') || '-' || lpad(v_number::text, 4, '0');
  return new;
end;
$$;

create trigger transactions_assign_number
  before insert on public.transactions
  for each row execute function public.assign_transaction_number();

-- ---------------------------------------------------------------------
-- Trigger: kunci transaksi begitu struk pernah dicetak (tidak bisa dibuka lagi)
-- ---------------------------------------------------------------------
create or replace function public.lock_transaction_on_receipt()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.receipt_printed_at is not null then
    new.is_locked := true;
  end if;
  if tg_op = 'UPDATE' and old.is_locked and not new.is_locked then
    new.is_locked := true;
  end if;
  return new;
end;
$$;

create trigger transactions_lock_on_receipt
  before insert or update on public.transactions
  for each row execute function public.lock_transaction_on_receipt();

-- ---------------------------------------------------------------------
-- Trigger updated_at
-- ---------------------------------------------------------------------
create trigger outlets_updated_at before update on public.outlets
  for each row execute function public.set_updated_at();
create trigger payment_methods_updated_at before update on public.payment_methods
  for each row execute function public.set_updated_at();
create trigger marketplace_platforms_updated_at before update on public.marketplace_platforms
  for each row execute function public.set_updated_at();
create trigger roles_updated_at before update on public.roles
  for each row execute function public.set_updated_at();
create trigger role_permissions_updated_at before update on public.role_permissions
  for each row execute function public.set_updated_at();
create trigger pos_users_updated_at before update on public.pos_users
  for each row execute function public.set_updated_at();
create trigger shifts_updated_at before update on public.shifts
  for each row execute function public.set_updated_at();
create trigger transactions_updated_at before update on public.transactions
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- Row Level Security: aktif di semua tabel, belum ada policy = tertutup.
-- ---------------------------------------------------------------------
alter table public.outlets                  enable row level security;
alter table public.products_cache           enable row level security;
alter table public.product_variants_cache   enable row level security;
alter table public.xtratopping_cache        enable row level security;
alter table public.xtratopping_price_cache  enable row level security;
alter table public.payment_methods          enable row level security;
alter table public.marketplace_platforms    enable row level security;
alter table public.roles                    enable row level security;
alter table public.permissions              enable row level security;
alter table public.role_permissions         enable row level security;
alter table public.pos_users                enable row level security;
alter table public.shifts                   enable row level security;
alter table public.cash_movements           enable row level security;
alter table public.transaction_counters     enable row level security;
alter table public.transactions             enable row level security;
alter table public.transaction_items        enable row level security;
alter table public.transaction_item_addons  enable row level security;

-- Fungsi trigger tidak boleh dipanggil langsung lewat API.
revoke execute on function public.assign_transaction_number() from public, anon, authenticated;
revoke execute on function public.lock_transaction_on_receipt() from public, anon, authenticated;
revoke execute on function public.set_updated_at() from public, anon, authenticated;
