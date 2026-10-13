-- =====================================================================
-- 01_skema_website.sql — DIBUAT OTOMATIS oleh scripts/buat-paket-website-tiruan.mjs (repo website).
-- JANGAN diedit manual. Isi: 59 migrasi website (urut nama) = skema produksi website,
-- termasuk kontrak POS tahap 1 (schema pos, view, pos_set_order_status, pengaturan_pos, outlet).
-- Jalankan di database KOSONG "website_tiruan" (bukan database POS!) — lihat README.md.
--
-- pg_cron: di database ini tidak dipakai → tiruan skema cron (jadwal hanya dicatat, tak pernah jalan).
-- =====================================================================

create schema if not exists cron;
create table if not exists cron.job (jobid bigserial primary key, jobname text unique, schedule text, command text);
create or replace function cron.schedule(p_nama text, p_jadwal text, p_perintah text) returns bigint language sql as $f$
  insert into cron.job (jobname, schedule, command) values (p_nama, p_jadwal, p_perintah)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command returning jobid $f$;
create or replace function cron.unschedule(p_nama text) returns boolean language sql as $f$
  with d as (delete from cron.job where jobname = p_nama returning 1) select exists (select 1 from d) $f$;

-- ===================================================================== 20260827120000_init.sql
-- Pizza Lezzato — skema awal (Fase 2)
-- Semua akses tulis lewat server (service_role, bypass RLS). RLS diaktifkan tanpa
-- policy publik sehingga anon/authenticated tidak bisa baca/tulis langsung.

-- ------------------------------------------------------------------
-- Referensi: kecamatan Kota Pekanbaru (delivery hanya di wilayah ini)
-- ------------------------------------------------------------------
create table if not exists public.kecamatan (
  name text primary key
);

insert into public.kecamatan (name) values
  ('Binawidya'), ('Bukit Raya'), ('Kulim'), ('Lima Puluh'), ('Marpoyan Damai'),
  ('Payung Sekaki'), ('Pekanbaru Kota'), ('Rumbai'), ('Rumbai Barat'),
  ('Rumbai Timur'), ('Sail'), ('Senapelan'), ('Sukajadi'), ('Tampan'),
  ('Tenayan Raya')
on conflict (name) do nothing;

-- ------------------------------------------------------------------
-- Pelanggan (nama + nomor HP; tanpa password/OTP untuk sekarang)
-- ------------------------------------------------------------------
create table if not exists public.customers (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  phone      text not null unique,          -- format E.164, mis. +6281378099099
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------------
-- Voucher
-- ------------------------------------------------------------------
create table if not exists public.vouchers (
  code             text primary key,
  discount_percent int  not null check (discount_percent between 1 and 100),
  first_order_only boolean not null default true,
  active           boolean not null default true,
  starts_at        timestamptz,
  ends_at          timestamptz,
  created_at       timestamptz not null default now()
);

insert into public.vouchers (code, discount_percent, first_order_only, active) values
  ('PESANONLINE10', 10, true, true)
on conflict (code) do nothing;

-- ------------------------------------------------------------------
-- Pesanan
-- ------------------------------------------------------------------
create table if not exists public.orders (
  id              uuid primary key default gen_random_uuid(),
  order_code      text not null unique,
  customer_id     uuid references public.customers(id) on delete set null,
  order_type      text not null check (order_type in ('delivery','takeaway','dinein')),
  status          text not null default 'baru'
                    check (status in ('baru','diproses','selesai','batal')),
  subtotal        integer not null check (subtotal >= 0),
  discount        integer not null default 0 check (discount >= 0),
  voucher_code    text references public.vouchers(code),
  total           integer not null check (total >= 0),
  recipient_name  text not null,
  recipient_phone text not null,
  kecamatan       text references public.kecamatan(name),
  address         text,
  patokan         text,
  note            text,
  payment_method  text not null default 'wa_confirm',
  payment_status  text not null default 'pending'
                    check (payment_status in ('pending','paid','cancelled')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  -- delivery wajib punya kecamatan + alamat
  constraint orders_delivery_needs_address check (
    order_type <> 'delivery'
    or (kecamatan is not null and address is not null and length(btrim(address)) > 0)
  )
);

create index if not exists orders_customer_id_idx on public.orders (customer_id);
create index if not exists orders_created_at_idx  on public.orders (created_at desc);
create index if not exists orders_status_idx      on public.orders (status);

-- ------------------------------------------------------------------
-- Item pesanan
-- ------------------------------------------------------------------
create table if not exists public.order_items (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references public.orders(id) on delete cascade,
  menu_id    text not null,
  name       text not null,
  unit_price integer not null check (unit_price >= 0),
  qty        integer not null check (qty > 0),
  options    jsonb not null default '{}'::jsonb,
  line_total integer generated always as (unit_price * qty) stored
);

create index if not exists order_items_order_id_idx on public.order_items (order_id);

-- ------------------------------------------------------------------
-- Pemakaian voucher (1x per pelanggan per kode)
-- ------------------------------------------------------------------
create table if not exists public.voucher_redemptions (
  id           uuid primary key default gen_random_uuid(),
  voucher_code text not null references public.vouchers(code),
  customer_id  uuid not null references public.customers(id) on delete cascade,
  order_id     uuid not null references public.orders(id) on delete cascade,
  redeemed_at  timestamptz not null default now(),
  unique (voucher_code, customer_id)
);

-- ------------------------------------------------------------------
-- Trigger updated_at pada orders
-- ------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists orders_set_updated_at on public.orders;
create trigger orders_set_updated_at
  before update on public.orders
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------------
-- RLS: aktif, tanpa policy publik (semua akses lewat service_role di server)
-- ------------------------------------------------------------------
alter table public.kecamatan           enable row level security;
alter table public.customers           enable row level security;
alter table public.vouchers            enable row level security;
alter table public.orders              enable row level security;
alter table public.order_items         enable row level security;
alter table public.voucher_redemptions enable row level security;

-- Kecamatan boleh dibaca publik (dipakai untuk dropdown bila perlu di klien)
drop policy if exists kecamatan_read_all on public.kecamatan;
create policy kecamatan_read_all on public.kecamatan
  for select using (true);

-- ===================================================================== 20260827120100_create_order_fn.sql
-- Pizza Lezzato — RPC create_order (Fase 2)
-- Membuat order + item + pemakaian voucher dalam satu transaksi.
--
-- Harga dihitung ULANG di server (Route Handler) dari lib/menu/data.ts, lalu
-- item yang sudah tervalidasi dikirim ke fungsi ini. Fungsi ini menegakkan:
--  - keunikan order_code
--  - keabsahan voucher (aktif, dalam rentang tanggal, first_order_only)
--  - pencatatan voucher_redemptions (unik per pelanggan)

create or replace function public.create_order(
  p_customer_id     uuid,
  p_order_code      text,
  p_order_type      text,
  p_recipient_name  text,
  p_recipient_phone text,
  p_kecamatan       text,
  p_address         text,
  p_patokan         text,
  p_note            text,
  p_voucher_code    text,
  p_items           jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_subtotal int := 0;
  v_discount int := 0;
  v_total    int;
  v_order_id uuid;
  v_voucher  public.vouchers%rowtype;
  v_has_orders boolean;
  v_item jsonb;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'items kosong' using errcode = 'P0001';
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    if (v_item->>'unit_price') is null or (v_item->>'qty') is null
       or (v_item->>'unit_price')::int < 0 or (v_item->>'qty')::int <= 0 then
      raise exception 'item tidak valid' using errcode = 'P0001';
    end if;
    v_subtotal := v_subtotal + (v_item->>'unit_price')::int * (v_item->>'qty')::int;
  end loop;

  if p_voucher_code is not null and length(btrim(p_voucher_code)) > 0 then
    select * into v_voucher from public.vouchers where code = p_voucher_code;
    if not found or not v_voucher.active then
      raise exception 'voucher tidak berlaku' using errcode = 'P0001';
    end if;
    if v_voucher.starts_at is not null and now() < v_voucher.starts_at then
      raise exception 'voucher belum aktif' using errcode = 'P0001';
    end if;
    if v_voucher.ends_at is not null and now() > v_voucher.ends_at then
      raise exception 'voucher kedaluwarsa' using errcode = 'P0001';
    end if;
    if v_voucher.first_order_only then
      select exists(select 1 from public.orders where customer_id = p_customer_id)
        into v_has_orders;
      if v_has_orders then
        raise exception 'voucher hanya untuk pesanan pertama' using errcode = 'P0001';
      end if;
    end if;
    v_discount := round(v_subtotal * v_voucher.discount_percent / 100.0);
  else
    p_voucher_code := null;
  end if;

  v_total := v_subtotal - v_discount;

  insert into public.orders (
    order_code, customer_id, order_type, subtotal, discount, voucher_code, total,
    recipient_name, recipient_phone, kecamatan, address, patokan, note
  ) values (
    p_order_code, p_customer_id, p_order_type, v_subtotal, v_discount, p_voucher_code, v_total,
    p_recipient_name, p_recipient_phone,
    nullif(btrim(coalesce(p_kecamatan, '')), ''),
    nullif(btrim(coalesce(p_address, '')), ''),
    nullif(btrim(coalesce(p_patokan, '')), ''),
    nullif(btrim(coalesce(p_note, '')), '')
  )
  returning id into v_order_id;

  insert into public.order_items (order_id, menu_id, name, unit_price, qty, options)
  select
    v_order_id,
    elem->>'menu_id',
    elem->>'name',
    (elem->>'unit_price')::int,
    (elem->>'qty')::int,
    coalesce(elem->'options', '{}'::jsonb)
  from jsonb_array_elements(p_items) as elem;

  if p_voucher_code is not null then
    insert into public.voucher_redemptions (voucher_code, customer_id, order_id)
    values (p_voucher_code, p_customer_id, v_order_id);
  end if;

  return jsonb_build_object(
    'order_id',   v_order_id,
    'order_code', p_order_code,
    'subtotal',   v_subtotal,
    'discount',   v_discount,
    'total',      v_total
  );
end;
$$;

-- Fungsi hanya boleh dipanggil dari server (service_role). Cabut akses publik,
-- lalu beri akses eksplisit ke service_role.
revoke all on function public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb
) from public, anon, authenticated;

grant execute on function public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb
) to service_role;

-- ===================================================================== 20260827120200_owner_views.sql
-- Pizza Lezzato — view bantu untuk owner (dipakai di Supabase Table Editor / SQL Editor)

-- Pesanan hari ini (WIB = UTC+7)
create or replace view public.v_orders_hari_ini as
select
  o.order_code,
  o.created_at at time zone 'Asia/Jakarta' as waktu_wib,
  o.status,
  o.order_type,
  o.recipient_name,
  o.recipient_phone,
  o.kecamatan,
  o.address,
  o.total,
  o.voucher_code,
  o.note
from public.orders o
where (o.created_at at time zone 'Asia/Jakarta')::date
      = (now() at time zone 'Asia/Jakarta')::date
order by o.created_at desc;

-- Pesanan yang belum selesai
create or replace view public.v_orders_pending as
select
  o.order_code,
  o.created_at at time zone 'Asia/Jakarta' as waktu_wib,
  o.status,
  o.order_type,
  o.recipient_name,
  o.recipient_phone,
  o.kecamatan,
  o.total
from public.orders o
where o.status in ('baru', 'diproses')
order by o.created_at asc;

-- Rincian item per pesanan
create or replace view public.v_order_items as
select
  o.order_code,
  oi.name,
  oi.qty,
  oi.unit_price,
  oi.line_total,
  oi.options
from public.order_items oi
join public.orders o on o.id = oi.order_id
order by o.created_at desc, oi.name;

-- View berisi data pelanggan (nama, HP, alamat) — JANGAN diekspos ke API publik.
-- Supabase secara default memberi SELECT ke anon/authenticated pada objek di schema
-- public, jadi cabut di sini. Owner (SQL Editor) & service_role tetap bisa.
revoke all on public.v_orders_hari_ini from anon, authenticated;
revoke all on public.v_orders_pending  from anon, authenticated;
revoke all on public.v_order_items     from anon, authenticated;

-- ===================================================================== 20260827130000_auth_attempts.sql
-- Pizza Lezzato — rate limiting sederhana untuk endpoint auth (Fase 3)

create table if not exists public.auth_attempts (
  id         bigint generated always as identity primary key,
  ip         text not null,
  action     text not null check (action in ('register','login')),
  phone      text,
  created_at timestamptz not null default now()
);

create index if not exists auth_attempts_ip_time_idx
  on public.auth_attempts (ip, created_at desc);

alter table public.auth_attempts enable row level security;
-- tanpa policy publik: hanya service_role (server) yang akses

-- Hitung percobaan dari satu IP dalam N menit terakhir, sekaligus catat percobaan ini.
-- Return jumlah percobaan SEBELUM yang ini (server memutuskan blokir bila >= batas).
create or replace function public.record_auth_attempt(
  p_ip text,
  p_action text,
  p_phone text,
  p_window_minutes int default 15
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  select count(*) into v_count
  from public.auth_attempts
  where ip = p_ip
    and created_at > now() - make_interval(mins => p_window_minutes);

  insert into public.auth_attempts (ip, action, phone)
  values (p_ip, p_action, nullif(btrim(coalesce(p_phone, '')), ''));

  return v_count;
end;
$$;

revoke all on function public.record_auth_attempt(text, text, text, int)
  from public, anon, authenticated;
grant execute on function public.record_auth_attempt(text, text, text, int)
  to service_role;

-- ===================================================================== 20260828090000_owner_helpers.sql
-- Pizza Lezzato — alat bantu owner (Fase 5): view rekap + ganti status pesanan.

-- ------------------------------------------------------------------
-- Satu baris per pesanan, semua info penting + daftar item sebagai teks.
-- Ini view utama yang dilihat owner setiap hari.
-- ------------------------------------------------------------------
create or replace view public.v_pesanan as
select
  o.order_code                                                    as no_pesanan,
  to_char(o.created_at at time zone 'Asia/Jakarta',
          'DD-MM-YYYY HH24:MI')                                   as waktu,
  o.status,
  case o.order_type
    when 'delivery' then 'Delivery'
    when 'takeaway' then 'Take Away'
    when 'dinein'   then 'Dine-in'
    else o.order_type
  end                                                             as tipe,
  o.recipient_name                                                as penerima,
  o.recipient_phone                                               as hp,
  coalesce(o.kecamatan, '-')                                      as kecamatan,
  coalesce(o.address, '-')                                        as alamat,
  coalesce(o.patokan, '-')                                        as patokan,
  (select string_agg(oi.qty || 'x ' || oi.name, ', ' order by oi.name)
     from public.order_items oi where oi.order_id = o.id)         as isi_pesanan,
  coalesce(o.note, '-')                                           as catatan,
  o.subtotal,
  o.discount                                                      as diskon,
  coalesce(o.voucher_code, '-')                                   as voucher,
  o.total,
  o.payment_status                                                as pembayaran
from public.orders o
order by o.created_at desc;

-- ------------------------------------------------------------------
-- Rekap harian: jumlah pesanan & omzet per tanggal (WIB).
-- ------------------------------------------------------------------
create or replace view public.v_rekap_harian as
select
  (o.created_at at time zone 'Asia/Jakarta')::date               as tanggal,
  count(*)                                                        as jumlah_pesanan,
  count(*) filter (where o.status = 'batal')                      as dibatalkan,
  coalesce(sum(o.total) filter (where o.status <> 'batal'), 0)    as omzet,
  coalesce(sum(o.discount) filter (where o.status <> 'batal'), 0) as total_diskon,
  count(*) filter (where o.order_type = 'delivery')              as delivery,
  count(*) filter (where o.order_type = 'takeaway')              as takeaway,
  count(*) filter (where o.order_type = 'dinein')                as dinein
from public.orders o
group by 1
order by 1 desc;

-- ------------------------------------------------------------------
-- Pemakaian voucher: siapa yang sudah pakai kode apa.
-- ------------------------------------------------------------------
create or replace view public.v_pemakaian_voucher as
select
  vr.voucher_code,
  c.name                                                          as pelanggan,
  c.phone                                                         as hp,
  o.order_code                                                    as no_pesanan,
  o.total,
  to_char(vr.redeemed_at at time zone 'Asia/Jakarta',
          'DD-MM-YYYY HH24:MI')                                   as waktu
from public.voucher_redemptions vr
join public.customers c on c.id = vr.customer_id
join public.orders o    on o.id = vr.order_id
order by vr.redeemed_at desc;

-- ------------------------------------------------------------------
-- Ganti status pesanan lewat SQL Editor:  select ubah_status_pesanan('PL-xxxx', 'diproses');
-- ------------------------------------------------------------------
create or replace function public.ubah_status_pesanan(p_order_code text, p_status text)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_status not in ('baru', 'diproses', 'selesai', 'batal') then
    raise exception 'status harus salah satu dari: baru / diproses / selesai / batal'
      using errcode = 'P0001';
  end if;
  update public.orders set status = p_status where order_code = p_order_code;
  if not found then
    raise exception 'pesanan % tidak ditemukan', p_order_code using errcode = 'P0001';
  end if;
  return format('Pesanan %s sekarang berstatus "%s".', p_order_code, p_status);
end;
$$;

revoke all on function public.ubah_status_pesanan(text, text)
  from public, anon, authenticated;
grant execute on function public.ubah_status_pesanan(text, text) to service_role;

-- View memuat data pelanggan — jangan diekspos ke API publik.
revoke all on public.v_pesanan           from anon, authenticated;
revoke all on public.v_rekap_harian      from anon, authenticated;
revoke all on public.v_pemakaian_voucher from anon, authenticated;

-- ===================================================================== 20260828100000_rate_limit_orders.sql
-- Pizza Lezzato — Fase 6: izinkan pencatatan percobaan 'order' untuk rate limiting checkout.

alter table public.auth_attempts
  drop constraint if exists auth_attempts_action_check;

alter table public.auth_attempts
  add constraint auth_attempts_action_check
  check (action in ('register', 'login', 'order'));

-- ===================================================================== 20260830090000_admin_users.sql
-- Pizza Lezzato — Fase A0: akun admin untuk /admin (kelola menu)

create table if not exists public.admin_users (
  id            uuid primary key default gen_random_uuid(),
  email         text not null unique,
  password_hash text not null,               -- format: pbkdf2$<iterasi>$<salt_b64>$<hash_b64>
  name          text,
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  last_login_at timestamptz
);

alter table public.admin_users enable row level security;
-- tanpa policy publik — hanya service_role (server) yang boleh akses
revoke all on public.admin_users from anon, authenticated;

-- Izinkan pencatatan percobaan login admin untuk rate limiting
alter table public.auth_attempts
  drop constraint if exists auth_attempts_action_check;
alter table public.auth_attempts
  add constraint auth_attempts_action_check
  check (action in ('register', 'login', 'order', 'admin_login'));

-- ===================================================================== 20260830100000_menu_items.sql
-- Pizza Lezzato — Fase A1: data menu pindah dari kode ke DB.
-- Struktur kategori/layout halaman tetap di kode; ini isi item yang bisa diedit admin.

create table if not exists public.menu_items (
  id             text primary key,               -- id lama dipertahankan: beef1, ps1, sig1, tea1…
  category_slug  text not null,                   -- halaman: pizza-beef, paket-sendiri, minuman-tea…
  section_key    text not null,                   -- section dalam halaman (biasanya = category_slug;
                                                  --   minuman-tea: 'tea'/'refresh', minuman-coffee: 'coffee'/'choco')
  kind           text not null check (kind in ('simple', 'sized', 'variant', 'package')),
  name           text not null,
  description    text not null default '',
  emoji          text,                            -- ikon bulat bila belum ada foto
  image_url      text,                            -- '/menu/xxx.jpg' (dari migrasi) atau URL Supabase Storage
  base_price     integer,                         -- untuk 'simple' & 'package'
  package_items  text[]  not null default '{}',   -- isi paket ("1 Personal Pizza", …)
  package_choices jsonb  not null default '[]'::jsonb,  -- [{key,label,options[]}] (dikelola via kode/seed di v1)
  package_note   text,
  sort_order     integer not null default 0,
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint menu_items_price_present check (
    kind not in ('simple', 'package') or base_price is not null
  )
);

create index if not exists menu_items_page_idx
  on public.menu_items (category_slug, section_key, sort_order);

create table if not exists public.menu_item_variants (
  id           uuid primary key default gen_random_uuid(),
  menu_item_id text not null references public.menu_items(id) on delete cascade,
  variant_key  text not null,                     -- 'personal'/'medium'/'large' atau label varian
  label        text not null,                     -- "Personal", "Mini (2 pcs)"
  price        integer not null check (price >= 0),
  sort_order   integer not null default 0,
  unique (menu_item_id, variant_key)
);

create index if not exists menu_item_variants_item_idx
  on public.menu_item_variants (menu_item_id, sort_order);

-- updated_at otomatis
drop trigger if exists menu_items_set_updated_at on public.menu_items;
create trigger menu_items_set_updated_at
  before update on public.menu_items
  for each row execute function public.set_updated_at();

-- RLS: aktif, tanpa policy publik — semua akses lewat service_role di server
alter table public.menu_items         enable row level security;
alter table public.menu_item_variants enable row level security;
revoke all on public.menu_items         from anon, authenticated;
revoke all on public.menu_item_variants from anon, authenticated;

-- ===================================================================== 20260830110000_menu_audit.sql
-- Pizza Lezzato — Fase A4: jejak perubahan menu dari /admin (opsional).
-- Aplikasi tetap jalan tanpa tabel ini (pencatatan bersifat fail-open).

create table if not exists public.menu_audit (
  id            bigint generated always as identity primary key,
  menu_item_id  text not null,
  admin_email   text not null,
  summary       text not null,          -- ringkasan perubahan, mis. "harga 27000 -> 28000; aktif: ya -> tidak"
  changed_at    timestamptz not null default now()
);

create index if not exists menu_audit_item_idx
  on public.menu_audit (menu_item_id, changed_at desc);

alter table public.menu_audit enable row level security;
revoke all on public.menu_audit from anon, authenticated;

-- ===================================================================== 20260830120000_menu_delete_guard.sql
-- Pizza Lezzato — Fase A6: jaring pengaman hapus item menu.
-- Item yang pernah muncul di order_items TIDAK boleh dihapus permanen —
-- riwayat pesanan lama harus tetap bisa dibuka. Arsipkan saja (active=false).
-- order_items menyimpan snapshot (menu_id/name/unit_price), tanpa FK ke menu_items,
-- jadi hapus TIDAK memutus riwayat — larangan ini murni soal kebersihan data.

create or replace function public.guard_menu_item_delete()
returns trigger
language plpgsql
as $$
begin
  if exists (select 1 from public.order_items where menu_id = old.id) then
    raise exception
      'menu_item % sudah pernah dipesan pelanggan — arsipkan (active=false), jangan hapus permanen', old.id
      using errcode = 'P0001';
  end if;
  return old;
end;
$$;

drop trigger if exists menu_items_guard_delete on public.menu_items;
create trigger menu_items_guard_delete
  before delete on public.menu_items
  for each row execute function public.guard_menu_item_delete();

-- ===================================================================== 20260911090000_absensi_init.sql
-- Pizza Lezzato — modul Absensi (lihat SPEK_ABSENSI_LEZZATO_v2.md Bagian 8).
-- Semua akses tulis lewat server (service_role, bypass RLS), sama seperti modul
-- lain di project ini. RLS diaktifkan tanpa policy publik.

-- ------------------------------------------------------------------
-- Karyawan
-- ------------------------------------------------------------------
create table if not exists public.employees (
  id                   uuid primary key default gen_random_uuid(),
  nama                 text not null,
  no_hp                text,
  pin_hash             text not null,          -- format sama dgn admin_users: pbkdf2$<iterasi>$<salt_b64>$<hash_b64>
  role                 text not null check (role in ('owner', 'admin', 'karyawan')),
  status_aktif         boolean not null default true,
  tanggal_mulai_kerja  date not null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

drop trigger if exists employees_set_updated_at on public.employees;
create trigger employees_set_updated_at
  before update on public.employees
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------------
-- Roster: template siklus 2 mingguan (ganjil/genap) per karyawan
-- ------------------------------------------------------------------
create table if not exists public.roster_templates (
  id           uuid primary key default gen_random_uuid(),
  employee_id  uuid not null references public.employees(id) on delete cascade,
  pekan        text not null check (pekan in ('ganjil', 'genap')),
  hari         text not null check (hari in ('senin', 'selasa', 'rabu', 'kamis', 'jumat', 'sabtu', 'ahad')),
  jam_mulai    time not null,
  jam_selesai  time not null,
  unique (employee_id, pekan, hari)
);

-- ------------------------------------------------------------------
-- Roster: override per tanggal (penyesuaian mendadak, mis. tukar shift)
-- ------------------------------------------------------------------
create table if not exists public.roster (
  id              uuid primary key default gen_random_uuid(),
  employee_id     uuid not null references public.employees(id) on delete cascade,
  tanggal         date not null,
  jam_mulai       time not null,
  jam_selesai     time not null,
  last_edited_by  uuid references public.employees(id) on delete set null,
  last_edited_at  timestamptz not null default now(),
  unique (employee_id, tanggal)
);

create or replace function public.set_roster_last_edited_at()
returns trigger
language plpgsql
as $$
begin
  new.last_edited_at := now();
  return new;
end;
$$;

drop trigger if exists roster_set_last_edited_at on public.roster;
create trigger roster_set_last_edited_at
  before update on public.roster
  for each row execute function public.set_roster_last_edited_at();

-- ------------------------------------------------------------------
-- Pengaturan absensi global (1 baris konfigurasi)
-- ------------------------------------------------------------------
create table if not exists public.attendance_settings (
  id                          boolean primary key default true,
  durasi_jam_kerja_default    integer not null default 8,   -- satuan jam
  toleransi_keterlambatan_menit integer not null default 10, -- satuan menit
  updated_at                  timestamptz not null default now(),
  constraint attendance_settings_singleton check (id)
);

insert into public.attendance_settings (id) values (true)
on conflict (id) do nothing;

drop trigger if exists attendance_settings_set_updated_at on public.attendance_settings;
create trigger attendance_settings_set_updated_at
  before update on public.attendance_settings
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------------
-- Jenis cuti (master data — reguler + 7 jenis khusus, Bagian 6.1)
-- ------------------------------------------------------------------
create table if not exists public.leave_types (
  id                           smallint generated always as identity primary key,
  nama_cuti                    text not null unique,
  kategori                     text not null check (kategori in ('reguler', 'khusus')),
  kuota_hari                   integer not null check (kuota_hari > 0),
  maks_hari_per_pengajuan      integer,   -- diisi utk kategori reguler, null utk khusus
  maks_pengajuan_per_periode   integer,   -- diisi utk kategori reguler, null utk khusus
  keterangan                   text
);

insert into public.leave_types
  (nama_cuti, kategori, kuota_hari, maks_hari_per_pengajuan, maks_pengajuan_per_periode) values
  ('Cuti Reguler', 'reguler', 14, 8, 2)
on conflict (nama_cuti) do nothing;

insert into public.leave_types (nama_cuti, kategori, kuota_hari, keterangan) values
  ('Karyawan menikah', 'khusus', 3, 'hari kalender'),
  ('Menikahkan anak', 'khusus', 2, 'hari kalender'),
  ('Mengkhitankan anak', 'khusus', 2, 'hari kalender'),
  ('Aqiqah anak', 'khusus', 2, 'hari kalender'),
  ('Istri melahirkan/keguguran', 'khusus', 2, 'hari kalender'),
  ('Istri/orang tua/mertua/anak/menantu meninggal', 'khusus', 2, 'hari kalender'),
  ('Anggota keluarga serumah meninggal', 'khusus', 1, 'hari kalender')
on conflict (nama_cuti) do nothing;

-- ------------------------------------------------------------------
-- Periode cuti (kalender Hijriah, berlaku utk seluruh perusahaan)
-- ------------------------------------------------------------------
create table if not exists public.leave_periods (
  id              uuid primary key default gen_random_uuid(),
  tanggal_mulai   date not null,
  tanggal_selesai date not null,
  keterangan      text,
  input_by        uuid references public.employees(id) on delete set null,
  created_at      timestamptz not null default now(),
  constraint leave_periods_date_order check (tanggal_selesai > tanggal_mulai)
);

create index if not exists leave_periods_range_idx
  on public.leave_periods (tanggal_mulai, tanggal_selesai);

-- ------------------------------------------------------------------
-- Hak cuti reguler per karyawan per periode (hasil prorata, Bagian 6.3)
-- ------------------------------------------------------------------
create table if not exists public.leave_entitlements (
  id               uuid primary key default gen_random_uuid(),
  employee_id      uuid not null references public.employees(id) on delete cascade,
  leave_period_id  uuid not null references public.leave_periods(id) on delete cascade,
  hak_hari         numeric(5, 2) not null check (hak_hari >= 0),
  catatan          text,
  unique (employee_id, leave_period_id)
);

-- ------------------------------------------------------------------
-- Pengajuan cuti
-- ------------------------------------------------------------------
create table if not exists public.leave_requests (
  id              uuid primary key default gen_random_uuid(),
  employee_id     uuid not null references public.employees(id) on delete cascade,
  leave_type_id   smallint not null references public.leave_types(id),
  requested_by    uuid not null references public.employees(id),
  tanggal_mulai   date not null,
  tanggal_selesai date not null,
  alasan          text,
  status          text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  approved_by     uuid references public.employees(id),
  approved_at     timestamptz,
  created_at      timestamptz not null default now(),
  constraint leave_requests_date_order check (tanggal_selesai >= tanggal_mulai)
);

create index if not exists leave_requests_employee_idx on public.leave_requests (employee_id, status);
create index if not exists leave_requests_status_idx   on public.leave_requests (status);

-- ------------------------------------------------------------------
-- Log absensi (scan QR + validasi GPS)
-- ------------------------------------------------------------------
create table if not exists public.attendance_logs (
  id                 uuid primary key default gen_random_uuid(),
  employee_id        uuid not null references public.employees(id) on delete cascade,
  tipe               text not null check (tipe in ('masuk', 'pulang')),
  timestamp          timestamptz not null default now(),
  latitude           double precision not null,
  longitude          double precision not null,
  jarak_dari_outlet  numeric(6, 1) not null,   -- meter
  status             text not null check (status in ('tepat_waktu', 'telat', 'lebih_awal', 'tanpa_keterangan'))
);

create index if not exists attendance_logs_employee_idx on public.attendance_logs (employee_id, timestamp desc);

-- Cegah dobel absen (mis. 2x "masuk" di hari yang sama), hari dihitung di WIB (UTC+7).
-- Pakai offset interval tetap (bukan nama zona) supaya ekspresi IMMUTABLE dan bisa diindeks.
create unique index if not exists attendance_logs_one_per_day_idx
  on public.attendance_logs (employee_id, tipe, ((timestamp at time zone interval '+07:00')::date));

-- ------------------------------------------------------------------
-- Konfigurasi QR statis outlet
-- ------------------------------------------------------------------
create table if not exists public.qr_config (
  id               uuid primary key default gen_random_uuid(),
  kode_qr          text not null unique,
  latitude_outlet  double precision not null,
  longitude_outlet double precision not null,
  radius_meter     integer not null default 75 check (radius_meter > 0),
  created_at       timestamptz not null default now()
);

-- ------------------------------------------------------------------
-- RLS: aktif, tanpa policy publik (semua akses lewat service_role di server)
-- ------------------------------------------------------------------
alter table public.employees          enable row level security;
alter table public.roster_templates   enable row level security;
alter table public.roster             enable row level security;
alter table public.attendance_settings enable row level security;
alter table public.leave_types        enable row level security;
alter table public.leave_periods      enable row level security;
alter table public.leave_entitlements enable row level security;
alter table public.leave_requests     enable row level security;
alter table public.attendance_logs    enable row level security;
alter table public.qr_config          enable row level security;

revoke all on public.employees          from anon, authenticated;
revoke all on public.roster_templates   from anon, authenticated;
revoke all on public.roster             from anon, authenticated;
revoke all on public.attendance_settings from anon, authenticated;
revoke all on public.leave_types        from anon, authenticated;
revoke all on public.leave_periods      from anon, authenticated;
revoke all on public.leave_entitlements from anon, authenticated;
revoke all on public.leave_requests     from anon, authenticated;
revoke all on public.attendance_logs    from anon, authenticated;
revoke all on public.qr_config          from anon, authenticated;

-- ===================================================================== 20260912090000_absensi_auth_attempts.sql
-- Pizza Lezzato — modul Absensi: izinkan pencatatan percobaan login karyawan
-- (rate limiting) di tabel auth_attempts yang sudah ada.

alter table public.auth_attempts
  drop constraint if exists auth_attempts_action_check;
alter table public.auth_attempts
  add constraint auth_attempts_action_check
  check (action in ('register', 'login', 'order', 'admin_login', 'employee_login'));

-- ===================================================================== 20260913120000_customer_default_address.sql
-- Pizza Lezzato — Fase S3: alamat default pelanggan (opsional)
-- Hanya menambah kolom nullable ke customers; tidak menyentuh orders/order_items
-- (setiap pesanan tetap menyimpan snapshot alamat/nama/HP sendiri, pola yang sama
-- seperti order_items menyimpan snapshot nama+harga menu).
--
-- Catatan: kecamatan SENGAJA tidak dijadikan kolom default (lihat migrasi
-- 20260913130000_orders_delivery_area_expansion.sql) — area layanan kini juga
-- mencakup sebagian Kabupaten Kampar yang berdekatan, jadi alamat pelanggan
-- tidak lagi dibatasi/divalidasi lewat daftar 15 kecamatan Kota Pekanbaru.

alter table public.customers
  add column if not exists default_address text,
  add column if not exists default_patokan text;

-- ===================================================================== 20260913130000_orders_delivery_area_expansion.sql
-- Pizza Lezzato — perluasan area layanan Delivery: lepas kewajiban kecamatan
--
-- Ditemukan di lapangan: ada area yang masih dalam radius layanan outlet tapi
-- secara administratif masuk Kabupaten Kampar, bukan salah satu dari 15
-- kecamatan Kota Pekanbaru. Daripada memelihara whitelist kecamatan yang tidak
-- lagi mencerminkan area layanan sesungguhnya, kecamatan dihapus total dari
-- alur checkout — pesanan Delivery kini cukup mewajibkan alamat lengkap;
-- admin memastikan alamat bisa dilayani lewat konfirmasi WhatsApp manual.
--
-- orders.kecamatan & tabel lookup public.kecamatan TIDAK dihapus — pesanan
-- lama yang sudah terisi kecamatan tetap tampil apa adanya di riwayat/admin.
-- Kolom baru boleh NULL, dan FK ke public.kecamatan tidak masalah karena FK
-- selalu meloloskan nilai NULL.

alter table public.orders
  drop constraint if exists orders_delivery_needs_address;

alter table public.orders
  add constraint orders_delivery_needs_address check (
    order_type <> 'delivery'
    or (address is not null and length(btrim(address)) > 0)
  );

-- ===================================================================== 20260914090000_admin_roles.sql
-- Pizza Lezzato — peran admin: Owner (akses penuh) vs Admin/operator (terbatas)
-- Kolom baru, aditif, default 'owner' — akun admin yang sudah ada otomatis jadi
-- Owner, tidak ada perubahan akses untuk siapa pun sampai peran diubah manual.

alter table public.admin_users
  add column if not exists role text not null default 'owner'
    check (role in ('owner', 'admin'));

-- ===================================================================== 20260914090000_attendance_logs_tanggal_lokal.sql
-- Pizza Lezzato — modul Absensi: kolom generated `tanggal_lokal` di attendance_logs,
-- menggantikan ekspresi inline di unique index. Dipakai modul cuti untuk query rentang
-- tanggal (hitung "tanpa keterangan") tanpa mengulang ekspresi `at time zone` tiap kali.

alter table public.attendance_logs
  add column if not exists tanggal_lokal date
  generated always as ((timestamp at time zone interval '+07:00')::date) stored;

drop index if exists public.attendance_logs_one_per_day_idx;

create unique index if not exists attendance_logs_one_per_day_idx
  on public.attendance_logs (employee_id, tipe, tanggal_lokal);

create index if not exists attendance_logs_tanggal_lokal_idx
  on public.attendance_logs (employee_id, tanggal_lokal);

-- ===================================================================== 20260914130000_voucher_flexible.sql
-- Pizza Lezzato — voucher fleksibel: batas pemakaian per pelanggan (1x/N kali/
-- tanpa batas) + kuota total lintas pelanggan, di atas rentang tanggal &
-- "khusus pesanan pertama" yang sudah ada. Dikelola dari /admin/voucher (Owner).

-- 1) Kolom baru di vouchers, nullable = tanpa batas (aditif, tidak mengubah
--    baris/voucher yang sudah ada — PESANONLINE10 tetap first_order_only=true,
--    tanpa batas tambahan sampai diubah manual dari panel).
alter table public.vouchers
  add column if not exists max_uses_per_customer integer,
  add column if not exists total_quota integer;

-- 1b) Rate limit untuk endpoint cek voucher baru (POST /api/vouchers/check).
alter table public.auth_attempts
  drop constraint if exists auth_attempts_action_check;
alter table public.auth_attempts
  add constraint auth_attempts_action_check
  check (action in ('register', 'login', 'order', 'admin_login', 'employee_login', 'voucher_check'));

-- 2) voucher_redemptions selama ini unique(voucher_code, customer_id) — cocok
--    untuk "1x per pelanggan" tapi memblokir total "N kali". Dilonggarkan jadi
--    index biasa; penegakan batas (1x/N kali/kuota total) pindah ke dalam RPC
--    create_order (lihat bagian 3), persis pola yang sudah dipakai untuk
--    "khusus pesanan pertama" — bukan mekanisme baru, cuma diperluas.
alter table public.voucher_redemptions
  drop constraint if exists voucher_redemptions_voucher_code_customer_id_key;

create index if not exists voucher_redemptions_code_customer_idx
  on public.voucher_redemptions (voucher_code, customer_id);

-- 3) create_order: tambah pengecekan max_uses_per_customer & total_quota.
--    PENTING (soal race condition dua pesanan hampir bersamaan): baris
--    `select ... for update` mengunci baris voucher itu untuk durasi transaksi
--    — pesanan lain yang memakai voucher yang SAMA dan datang nyaris
--    bersamaan akan menunggu transaksi pertama selesai (commit/rollback)
--    sebelum ikut menghitung ulang jumlah pemakaian, bukan membaca angka basi.
--    Ini otomatis juga menutup celah race yang sama pada pengecekan
--    "khusus pesanan pertama" (sebelumnya tidak terkunci). Pesanan yang TIDAK
--    memakai voucher tidak terpengaruh sama sekali (tidak ada lock diambil).
create or replace function public.create_order(
  p_customer_id     uuid,
  p_order_code      text,
  p_order_type      text,
  p_recipient_name  text,
  p_recipient_phone text,
  p_kecamatan       text,
  p_address         text,
  p_patokan         text,
  p_note            text,
  p_voucher_code    text,
  p_items           jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_subtotal int := 0;
  v_discount int := 0;
  v_total    int;
  v_order_id uuid;
  v_voucher  public.vouchers%rowtype;
  v_has_orders boolean;
  v_uses_by_customer int;
  v_total_uses int;
  v_item jsonb;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'items kosong' using errcode = 'P0001';
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    if (v_item->>'unit_price') is null or (v_item->>'qty') is null
       or (v_item->>'unit_price')::int < 0 or (v_item->>'qty')::int <= 0 then
      raise exception 'item tidak valid' using errcode = 'P0001';
    end if;
    v_subtotal := v_subtotal + (v_item->>'unit_price')::int * (v_item->>'qty')::int;
  end loop;

  if p_voucher_code is not null and length(btrim(p_voucher_code)) > 0 then
    select * into v_voucher from public.vouchers where code = p_voucher_code for update;
    if not found or not v_voucher.active then
      raise exception 'voucher tidak berlaku' using errcode = 'P0001';
    end if;
    if v_voucher.starts_at is not null and now() < v_voucher.starts_at then
      raise exception 'voucher belum aktif' using errcode = 'P0001';
    end if;
    if v_voucher.ends_at is not null and now() > v_voucher.ends_at then
      raise exception 'voucher kedaluwarsa' using errcode = 'P0001';
    end if;
    if v_voucher.first_order_only then
      select exists(select 1 from public.orders where customer_id = p_customer_id)
        into v_has_orders;
      if v_has_orders then
        raise exception 'voucher hanya untuk pesanan pertama' using errcode = 'P0001';
      end if;
    end if;
    if v_voucher.max_uses_per_customer is not null then
      select count(*) into v_uses_by_customer from public.voucher_redemptions
        where voucher_code = p_voucher_code and customer_id = p_customer_id;
      if v_uses_by_customer >= v_voucher.max_uses_per_customer then
        raise exception 'voucher sudah mencapai batas pemakaian Anda' using errcode = 'P0001';
      end if;
    end if;
    if v_voucher.total_quota is not null then
      select count(*) into v_total_uses from public.voucher_redemptions
        where voucher_code = p_voucher_code;
      if v_total_uses >= v_voucher.total_quota then
        raise exception 'voucher sudah mencapai kuota pemakaian' using errcode = 'P0001';
      end if;
    end if;
    v_discount := round(v_subtotal * v_voucher.discount_percent / 100.0);
  else
    p_voucher_code := null;
  end if;

  v_total := v_subtotal - v_discount;

  insert into public.orders (
    order_code, customer_id, order_type, subtotal, discount, voucher_code, total,
    recipient_name, recipient_phone, kecamatan, address, patokan, note
  ) values (
    p_order_code, p_customer_id, p_order_type, v_subtotal, v_discount, p_voucher_code, v_total,
    p_recipient_name, p_recipient_phone,
    nullif(btrim(coalesce(p_kecamatan, '')), ''),
    nullif(btrim(coalesce(p_address, '')), ''),
    nullif(btrim(coalesce(p_patokan, '')), ''),
    nullif(btrim(coalesce(p_note, '')), '')
  )
  returning id into v_order_id;

  insert into public.order_items (order_id, menu_id, name, unit_price, qty, options)
  select
    v_order_id,
    elem->>'menu_id',
    elem->>'name',
    (elem->>'unit_price')::int,
    (elem->>'qty')::int,
    coalesce(elem->'options', '{}'::jsonb)
  from jsonb_array_elements(p_items) as elem;

  if p_voucher_code is not null then
    insert into public.voucher_redemptions (voucher_code, customer_id, order_id)
    values (p_voucher_code, p_customer_id, v_order_id);
  end if;

  return jsonb_build_object(
    'order_id',   v_order_id,
    'order_code', p_order_code,
    'subtotal',   v_subtotal,
    'discount',   v_discount,
    'total',      v_total
  );
end;
$$;

revoke all on function public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb
) from public, anon, authenticated;

grant execute on function public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb
) to service_role;

-- ===================================================================== 20260914150000_order_preview_rate_limit.sql
-- Pizza Lezzato — Poin 2: rate limit untuk endpoint ringkasan pesanan baru
-- (POST /api/orders/preview) sebelum commit sungguhan.

alter table public.auth_attempts
  drop constraint if exists auth_attempts_action_check;
alter table public.auth_attempts
  add constraint auth_attempts_action_check
  check (action in ('register', 'login', 'order', 'admin_login', 'employee_login', 'voucher_check', 'order_preview'));

-- ===================================================================== 20260914180000_fix_rate_limit_action_scope.sql
-- Pizza Lezzato — perbaikan bug: record_auth_attempt() menghitung SEMUA jenis
-- aksi (register/login/order/admin_login/dst.) tergabung per IP, bukan per
-- jenis aksi masing-masing. Akibatnya jatah tiap aksi (LIMITS di rateLimit.ts)
-- diam-diam berbagi satu jatah gabungan, terbatas ke angka terkecil (8, milik
-- admin_login) — ditemukan 14 Sep 2026 setelah operator terkunci login admin
-- hanya dari 1 percobaan gagal, karena tercampur aksi lain (checkout/voucher)
-- dari IP yang sama dalam 15 menit terakhir.

create or replace function public.record_auth_attempt(
  p_ip text,
  p_action text,
  p_phone text,
  p_window_minutes int default 15
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  select count(*) into v_count
  from public.auth_attempts
  where ip = p_ip
    and action = p_action
    and created_at > now() - make_interval(mins => p_window_minutes);

  insert into public.auth_attempts (ip, action, phone)
  values (p_ip, p_action, nullif(btrim(coalesce(p_phone, '')), ''));

  return v_count;
end;
$$;

-- ===================================================================== 20260914200000_ricebox_sauce_choice.sql
-- Pizza Lezzato — pilihan saus/sambal wajib untuk Rice Box (14 Sep 2026)
-- Sebelumnya pelanggan diminta menulis pilihan saus di catatan pesanan bebas
-- (lihat footnote lama di lib/menu/groups.ts). Sekarang jadi pilihan wajib
-- terstruktur, dengan pola yang sama seperti `package_choices` pada paket
-- (lib/menu/query.ts kini juga membaca kolom ini untuk item kind="simple").
update public.menu_items
set package_choices = '[{"key":"saus","label":"Pilihan Saus","options":["Sambal Matah","Saos Spicy","Saos BBQ","Saos Mentega"]}]'::jsonb
where id in ('rb1', 'rb2');

-- ===================================================================== 20260915090000_attendance_settings_mulai_berlaku.sql
-- Pizza Lezzato — modul Cuti: tanggal resmi mulai berlaku penghitungan "tanpa
-- keterangan". Periode cuti (mis. 1448 H) bisa mulai jauh sebelum sistem
-- absensi ini benar-benar dipakai semua karyawan — hari kerja SEBELUM tanggal
-- ini tidak boleh dihitung sbg tanpa keterangan (sistem belum bisa merekam
-- kehadiran sama sekali saat itu). Dipakai bareng tanggal_mulai periode:
-- dipakai yang LEBIH BARU di antara keduanya sbg titik awal hitung.

alter table public.attendance_settings
  add column if not exists mulai_berlaku_tanpa_keterangan date;

update public.attendance_settings
  set mulai_berlaku_tanpa_keterangan = '2026-09-15'
  where id = true and mulai_berlaku_tanpa_keterangan is null;

-- ===================================================================== 20260916090000_cuti_edit_batal_sakit.sql
-- Pizza Lezzato — modul Cuti: edit/batalkan pengajuan approved + jenis "Sakit".

-- Status baru 'dibatalkan' — bukan hard delete, tetap tercatat sbg riwayat.
-- Tidak ikut dihitung getSisaKuotaReguler/countPengajuanAktifDalamPeriode (yg cuma
-- menghitung status approved/pending), jadi membatalkan otomatis mengembalikan kuota.
alter table public.leave_requests
  drop constraint if exists leave_requests_status_check;
alter table public.leave_requests
  add constraint leave_requests_status_check
  check (status in ('pending', 'approved', 'rejected', 'dibatalkan'));

-- Audit trail: siapa & kapan mengedit/membatalkan pengajuan yg sudah approved.
alter table public.leave_requests
  add column if not exists edited_by uuid references public.employees(id) on delete set null;
alter table public.leave_requests
  add column if not exists edited_at timestamptz;

-- Perubahan aturan bisnis: batas JUMLAH KALI pengajuan Cuti Reguler per periode dihapus
-- (null = tanpa batas). Yang tetap berlaku: total sisa kuota (14 hari/prorata) & maks 8
-- hari per 1x pengajuan (maks_hari_per_pengajuan, tidak diubah).
update public.leave_types
  set maks_pengajuan_per_periode = null
  where nama_cuti = 'Cuti Reguler';

-- "Sakit" — kategori reguler, berbagi kuota hari yang SAMA dgn Cuti Reguler (bukan kuota
-- terpisah spt 7 jenis cuti khusus), juga tanpa batas jumlah kali pengajuan.
-- getRegularLeaveTypeIds() mengambil semua baris kategori='reguler' secara generik, jadi
-- otomatis ikut tanpa perubahan kode.
insert into public.leave_types
  (nama_cuti, kategori, kuota_hari, maks_hari_per_pengajuan, maks_pengajuan_per_periode) values
  ('Sakit', 'reguler', 14, 8, null)
on conflict (nama_cuti) do nothing;

-- ===================================================================== 20260917090000_roster_off_paksa.sql
-- Pizza Lezzato — modul Roster: dukung "Off paksa" pada override tanggal
-- spesifik (tabel `roster`). Konvensi: jam_mulai + jam_selesai keduanya null
-- berarti karyawan di-Off-kan paksa pada tanggal tsb (beda dari "tidak ada
-- baris override" yang berarti ikut jadwal default roster_templates).

alter table public.roster
  alter column jam_mulai drop not null,
  alter column jam_selesai drop not null;

alter table public.roster
  add constraint roster_jam_null_pair check (
    (jam_mulai is null and jam_selesai is null) or
    (jam_mulai is not null and jam_selesai is not null)
  );

-- ===================================================================== 20260918090000_leave_requests_pengganti.sql
-- Pizza Lezzato — modul Cuti: kolom pengganti_id (opsi A, murni catatan).
-- Tidak memicu apa pun ke roster/absen — cuma FK nullable + informasi tampilan.

alter table public.leave_requests
  add column if not exists pengganti_id uuid references public.employees(id);

-- ===================================================================== 20260918090000_phone_verification.sql
-- Pizza Lezzato — verifikasi manual nomor HP pelanggan via WhatsApp.
-- Gate: order pakai voucher + pelanggan belum pernah phone_verified -> verification_status = 'pending'.
-- phone_verified permanen sekali true, tidak pernah dicek ulang untuk pelanggan yang sama.
-- Logic penentuan verification_status dihitung di RPC create_order (server-side), bukan di sini
-- — lihat migration berikutnya untuk perubahan create_order.
-- "Tandai Tidak Cocok" (mismatch) SENGAJA belum punya efek otomatis ke voucher/harga di v1 —
-- keputusan itu masih terbuka (lihat SPEK_VERIFIKASI_MANUAL_LEZZATO_v1.md Bagian 7), status
-- 'mismatch' cukup tersimpan dulu tanpa side effect, supaya tidak perlu ubah skema lagi nanti.
-- Kolom aditif, nullable/default aman — tidak mengubah baris yang sudah ada.

alter table public.customers
  add column if not exists phone_verified boolean not null default false,
  add column if not exists phone_verified_at timestamptz,
  add column if not exists phone_verified_by uuid references public.admin_users(id) on delete set null;

alter table public.orders
  add column if not exists verification_status text not null default 'not_required'
    check (verification_status in ('not_required', 'pending', 'verified', 'mismatch')),
  add column if not exists verified_at timestamptz,
  add column if not exists verified_by uuid references public.admin_users(id) on delete set null;

create index if not exists orders_verification_status_idx
  on public.orders (verification_status);

-- ===================================================================== 20260918100000_leave_requests_pengganti_on_delete.sql
-- Perbaikan: pengganti_id murni catatan (opsi A) — kalau karyawan yang pernah
-- jadi pengganti suatu saat dihapus dari sistem (hard delete), jangan sampai
-- itu memblokir penghapusan (FK default NO ACTION). Ganti jadi ON DELETE SET
-- NULL — catatan pengganti cukup hilang, tidak menghalangi apa pun.

alter table public.leave_requests
  drop constraint leave_requests_pengganti_id_fkey;

alter table public.leave_requests
  add constraint leave_requests_pengganti_id_fkey
  foreign key (pengganti_id) references public.employees(id) on delete set null;

-- ===================================================================== 20260918100000_phone_verification_create_order.sql
-- Pizza Lezzato — verifikasi manual nomor HP: hitung verification_status saat
-- order dibuat (SPEK_VERIFIKASI_MANUAL_LEZZATO_v1.md Bagian 3.3), di dalam RPC
-- create_order supaya atomic dengan insert order & tidak bisa dilewati dari client.
--
--   voucher dipakai (p_voucher_code not null setelah lolos validasi voucher)
--   DAN customer belum phone_verified  -> verification_status = 'pending'
--   selain itu                         -> verification_status = 'not_required'
--
-- Order TANPA voucher tidak menambah query/lock apa pun ke customers (cabang
-- else langsung 'not_required', sama seperti sebelum migration ini).

create or replace function public.create_order(
  p_customer_id     uuid,
  p_order_code      text,
  p_order_type      text,
  p_recipient_name  text,
  p_recipient_phone text,
  p_kecamatan       text,
  p_address         text,
  p_patokan         text,
  p_note            text,
  p_voucher_code    text,
  p_items           jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_subtotal int := 0;
  v_discount int := 0;
  v_total    int;
  v_order_id uuid;
  v_voucher  public.vouchers%rowtype;
  v_has_orders boolean;
  v_uses_by_customer int;
  v_total_uses int;
  v_item jsonb;
  v_phone_verified boolean;
  v_verification_status text;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'items kosong' using errcode = 'P0001';
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    if (v_item->>'unit_price') is null or (v_item->>'qty') is null
       or (v_item->>'unit_price')::int < 0 or (v_item->>'qty')::int <= 0 then
      raise exception 'item tidak valid' using errcode = 'P0001';
    end if;
    v_subtotal := v_subtotal + (v_item->>'unit_price')::int * (v_item->>'qty')::int;
  end loop;

  if p_voucher_code is not null and length(btrim(p_voucher_code)) > 0 then
    select * into v_voucher from public.vouchers where code = p_voucher_code for update;
    if not found or not v_voucher.active then
      raise exception 'voucher tidak berlaku' using errcode = 'P0001';
    end if;
    if v_voucher.starts_at is not null and now() < v_voucher.starts_at then
      raise exception 'voucher belum aktif' using errcode = 'P0001';
    end if;
    if v_voucher.ends_at is not null and now() > v_voucher.ends_at then
      raise exception 'voucher kedaluwarsa' using errcode = 'P0001';
    end if;
    if v_voucher.first_order_only then
      select exists(select 1 from public.orders where customer_id = p_customer_id)
        into v_has_orders;
      if v_has_orders then
        raise exception 'voucher hanya untuk pesanan pertama' using errcode = 'P0001';
      end if;
    end if;
    if v_voucher.max_uses_per_customer is not null then
      select count(*) into v_uses_by_customer from public.voucher_redemptions
        where voucher_code = p_voucher_code and customer_id = p_customer_id;
      if v_uses_by_customer >= v_voucher.max_uses_per_customer then
        raise exception 'voucher sudah mencapai batas pemakaian Anda' using errcode = 'P0001';
      end if;
    end if;
    if v_voucher.total_quota is not null then
      select count(*) into v_total_uses from public.voucher_redemptions
        where voucher_code = p_voucher_code;
      if v_total_uses >= v_voucher.total_quota then
        raise exception 'voucher sudah mencapai kuota pemakaian' using errcode = 'P0001';
      end if;
    end if;
    v_discount := round(v_subtotal * v_voucher.discount_percent / 100.0);
  else
    p_voucher_code := null;
  end if;

  v_total := v_subtotal - v_discount;

  if p_voucher_code is not null then
    select phone_verified into v_phone_verified
      from public.customers where id = p_customer_id;
    if coalesce(v_phone_verified, false) then
      v_verification_status := 'not_required';
    else
      v_verification_status := 'pending';
    end if;
  else
    v_verification_status := 'not_required';
  end if;

  insert into public.orders (
    order_code, customer_id, order_type, subtotal, discount, voucher_code, total,
    recipient_name, recipient_phone, kecamatan, address, patokan, note,
    verification_status
  ) values (
    p_order_code, p_customer_id, p_order_type, v_subtotal, v_discount, p_voucher_code, v_total,
    p_recipient_name, p_recipient_phone,
    nullif(btrim(coalesce(p_kecamatan, '')), ''),
    nullif(btrim(coalesce(p_address, '')), ''),
    nullif(btrim(coalesce(p_patokan, '')), ''),
    nullif(btrim(coalesce(p_note, '')), ''),
    v_verification_status
  )
  returning id into v_order_id;

  insert into public.order_items (order_id, menu_id, name, unit_price, qty, options)
  select
    v_order_id,
    elem->>'menu_id',
    elem->>'name',
    (elem->>'unit_price')::int,
    (elem->>'qty')::int,
    coalesce(elem->'options', '{}'::jsonb)
  from jsonb_array_elements(p_items) as elem;

  if p_voucher_code is not null then
    insert into public.voucher_redemptions (voucher_code, customer_id, order_id)
    values (p_voucher_code, p_customer_id, v_order_id);
  end if;

  return jsonb_build_object(
    'order_id',   v_order_id,
    'order_code', p_order_code,
    'subtotal',   v_subtotal,
    'discount',   v_discount,
    'total',      v_total,
    'verification_status', v_verification_status
  );
end;
$$;

revoke all on function public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb
) from public, anon, authenticated;

grant execute on function public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb
) to service_role;

-- ===================================================================== 20260918120000_phone_verification_actions.sql
-- Pizza Lezzato — RPC untuk aksi admin "Tandai Terverifikasi" / "Tandai Tidak
-- Cocok" (SPEK_VERIFIKASI_MANUAL_LEZZATO_v1.md Bagian 6.2).
--
-- Atomic: kalau hasil = 'verified', customers.phone_verified ikut diset true
-- dalam transaksi yang sama dengan update orders.verification_status — supaya
-- tidak ada state setengah-jalan kalau salah satu update gagal.
--
-- Guard: hanya order berstatus 'pending' yang bisa diaksi (mencegah klik ganda
-- / aksi ulang menimpa audit trail verified_at/verified_by yang sudah terisi).
--
-- 'mismatch' SENGAJA tidak menyentuh voucher/discount/total sama sekali di v1
-- — keputusan efeknya masih terbuka (Bagian 7 spek), status ini cuma tersimpan.

create or replace function public.verifikasi_pesanan(
  p_order_code text,
  p_admin_id   uuid,
  p_hasil      text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
begin
  if p_hasil not in ('verified', 'mismatch') then
    raise exception 'hasil harus "verified" atau "mismatch"' using errcode = 'P0001';
  end if;

  select * into v_order from public.orders where order_code = p_order_code for update;
  if not found then
    raise exception 'pesanan % tidak ditemukan', p_order_code using errcode = 'P0001';
  end if;
  if v_order.verification_status <> 'pending' then
    raise exception 'pesanan % tidak sedang menunggu verifikasi (status saat ini: %)',
      p_order_code, v_order.verification_status using errcode = 'P0001';
  end if;

  if p_hasil = 'verified' then
    update public.customers
      set phone_verified = true, phone_verified_at = now(), phone_verified_by = p_admin_id
      where id = v_order.customer_id;
  end if;

  update public.orders
    set verification_status = p_hasil, verified_at = now(), verified_by = p_admin_id
    where order_code = p_order_code;

  return format('Pesanan %s ditandai "%s".', p_order_code, p_hasil);
end;
$$;

revoke all on function public.verifikasi_pesanan(text, uuid, text)
  from public, anon, authenticated;
grant execute on function public.verifikasi_pesanan(text, uuid, text) to service_role;

-- ===================================================================== 20260918150000_customer_audit.sql
-- Pizza Lezzato — jejak audit perubahan data pelanggan dari /admin/pelanggan
-- (18 Sep 2026). Data pribadi pelanggan (nama, alamat), bukan konfigurasi
-- toko — dicatat siapa admin mengubah apa & kapan, pola sama seperti
-- menu_audit. Aplikasi tetap jalan tanpa tabel ini (pencatatan fail-open).
--
-- SENGAJA tanpa foreign key ke customers (sama seperti menu_audit.menu_item_id
-- yang juga cuma text lepas) — supaya jejak audit tetap utuh sebagai histori
-- walau baris pelanggannya sendiri suatu saat dihapus, bukan malah ikut
-- terhapus lewat cascade atau jadi yatim karena constraint.

create table if not exists public.customer_audit (
  id            bigint generated always as identity primary key,
  customer_id   uuid not null,
  admin_email   text not null,
  summary       text not null,
  changed_at    timestamptz not null default now()
);

create index if not exists customer_audit_customer_idx
  on public.customer_audit (customer_id, changed_at desc);

alter table public.customer_audit enable row level security;
revoke all on public.customer_audit from anon, authenticated;

-- ===================================================================== 20260919090000_phone_verification_discount_held.sql
-- Pizza Lezzato — verifikasi manual nomor HP, Bagian 7 (final, dikonfirmasi
-- 16 Sep 2026): efek "Tandai Tidak Cocok" TIDAK menghentikan order dan TIDAK
-- langsung mencabut diskon — statusnya "ditahan" (discount_held = true) sampai
-- admin resolusi manual (SPEK_VERIFIKASI_MANUAL_LEZZATO_v1.md Bagian 7.1-7.2).
--
-- Kolom aditif, default aman (false/null) — tidak mengubah baris order yang sudah ada.
-- Logic yang MENGISI kolom ini (di RPC verifikasi_pesanan) dan yang MERESOLVE-nya
-- (RPC baru utk "Konfirmasi Sah"/"Cabut Diskon") ada di migration berikutnya —
-- ini cuma skema dulu, sesuai pola kerja bertahap yang sama seperti Bagian 3-6.
--
-- resolved_at/resolved_by SENGAJA terpisah dari verified_at/verified_by yang
-- sudah ada: verified_at/verified_by tetap mencatat kapan & siapa yang PERTAMA
-- KALI menandai mismatch (tidak pernah ditimpa lagi setelahnya); resolved_at/by
-- mencatat kapan & siapa yang meresolusi (konfirmasi_sah/cabut_diskon). Kedua
-- jejak ini sengaja dijaga terpisah untuk deteksi pola abuse berulang (Bagian 7).

alter table public.orders
  add column if not exists discount_held boolean not null default false,
  add column if not exists resolved_at timestamptz,
  add column if not exists resolved_by uuid references public.admin_users(id) on delete set null;

create index if not exists orders_discount_held_idx
  on public.orders (discount_held);

-- ===================================================================== 20260919100000_phone_verification_mismatch_discount_held.sql
-- Pizza Lezzato — verifikasi manual nomor HP, Bagian 7: RPC verifikasi_pesanan
-- (aksi "Tandai Tidak Cocok") sekarang juga menahan diskon (discount_held=true)
-- kalau order itu memang punya discount > 0. Order TIDAK dihentikan — cuma
-- diskonnya yang ditahan sampai admin resolusi lewat resolusi_diskon_tertahan
-- (migration berikutnya). Signature tidak berubah, aman di-replace.

create or replace function public.verifikasi_pesanan(
  p_order_code text,
  p_admin_id   uuid,
  p_hasil      text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
begin
  if p_hasil not in ('verified', 'mismatch') then
    raise exception 'hasil harus "verified" atau "mismatch"' using errcode = 'P0001';
  end if;

  select * into v_order from public.orders where order_code = p_order_code for update;
  if not found then
    raise exception 'pesanan % tidak ditemukan', p_order_code using errcode = 'P0001';
  end if;
  if v_order.verification_status <> 'pending' then
    raise exception 'pesanan % tidak sedang menunggu verifikasi (status saat ini: %)',
      p_order_code, v_order.verification_status using errcode = 'P0001';
  end if;

  if p_hasil = 'verified' then
    update public.customers
      set phone_verified = true, phone_verified_at = now(), phone_verified_by = p_admin_id
      where id = v_order.customer_id;
  end if;

  update public.orders
    set verification_status = p_hasil,
        verified_at = now(),
        verified_by = p_admin_id,
        discount_held = (p_hasil = 'mismatch' and v_order.discount > 0)
    where order_code = p_order_code;

  return format('Pesanan %s ditandai "%s".', p_order_code, p_hasil);
end;
$$;

revoke all on function public.verifikasi_pesanan(text, uuid, text)
  from public, anon, authenticated;
grant execute on function public.verifikasi_pesanan(text, uuid, text) to service_role;

-- ===================================================================== 20260919110000_phone_verification_resolusi_diskon.sql
-- Pizza Lezzato — verifikasi manual nomor HP, Bagian 7.2: RPC baru untuk dua
-- aksi resolusi order yang discount_held=true — "Konfirmasi Sah" & "Cabut
-- Diskon". Pola sama dgn verifikasi_pesanan (satu RPC, param aksi menentukan
-- cabang), guard GANDA: cuma order dgn discount_held=true DAN
-- verification_status='mismatch' yang bisa diresolusi. Dalam alur normal dua
-- kondisi ini selalu berbarengan (sama-sama diset di verifikasi_pesanan, dalam
-- 1 update yang sama) — guard kedua ini cuma jaring pengaman kalau suatu saat
-- ada state tidak konsisten (mis. hasil edit manual di SQL Editor).
--
--   konfirmasi_sah -> discount_held=false, verification_status='verified'.
--     Opsional (p_verifikasi_permanen=true): customers.phone_verified ikut
--     diset permanen — TIDAK default, karena klarifikasi verbal soal 1 order
--     tidak otomatis membuktikan kepemilikan nomor utk transaksi berikutnya.
--   cabut_diskon -> discount_held=false, verification_status TETAP 'mismatch'
--     (final, tidak diubah). discount->0, total->subtotal (recompute; tidak
--     ada diskon lain di skema ini selain voucher, jadi cukup itu). Kuota
--     voucher dilepas dgn hapus baris voucher_redemptions punya order ini —
--     simetris dgn cara "konsumsi" kuota di create_order (insert 1 baris),
--     bukan proses terpisah. voucher_code di orders SENGAJA tidak di-null-kan
--     (tetap sbg jejak audit/pola abuse, sesuai keputusan pemilik produk).
--
-- resolved_at/resolved_by (BUKAN verified_at/verified_by) yang dicatat di sini
-- — verified_at/verified_by tetap murni jejak "pertama kali ketahuan mismatch".

create or replace function public.resolusi_diskon_tertahan(
  p_order_code          text,
  p_admin_id            uuid,
  p_aksi                text,
  p_verifikasi_permanen boolean default false
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
begin
  if p_aksi not in ('konfirmasi_sah', 'cabut_diskon') then
    raise exception 'aksi harus "konfirmasi_sah" atau "cabut_diskon"' using errcode = 'P0001';
  end if;

  select * into v_order from public.orders where order_code = p_order_code for update;
  if not found then
    raise exception 'pesanan % tidak ditemukan', p_order_code using errcode = 'P0001';
  end if;
  if not v_order.discount_held then
    raise exception 'pesanan % tidak sedang menahan diskon', p_order_code using errcode = 'P0001';
  end if;
  if v_order.verification_status <> 'mismatch' then
    raise exception 'pesanan % tidak berstatus mismatch (status saat ini: %)',
      p_order_code, v_order.verification_status using errcode = 'P0001';
  end if;

  if p_aksi = 'konfirmasi_sah' then
    update public.orders
      set discount_held = false,
          verification_status = 'verified',
          resolved_at = now(),
          resolved_by = p_admin_id
      where order_code = p_order_code;

    if p_verifikasi_permanen then
      update public.customers
        set phone_verified = true, phone_verified_at = now(), phone_verified_by = p_admin_id
        where id = v_order.customer_id;
    end if;
  else
    update public.orders
      set discount_held = false,
          discount = 0,
          total = subtotal,
          resolved_at = now(),
          resolved_by = p_admin_id
      where order_code = p_order_code;

    delete from public.voucher_redemptions where order_id = v_order.id;
  end if;

  return format('Pesanan %s diresolusi: "%s".', p_order_code, p_aksi);
end;
$$;

revoke all on function public.resolusi_diskon_tertahan(text, uuid, text, boolean)
  from public, anon, authenticated;
grant execute on function public.resolusi_diskon_tertahan(text, uuid, text, boolean) to service_role;

-- ===================================================================== 20260921090000_menu_recommended.sql
-- Pizza Lezzato — penanda "Menu Rekomendasi" (21 Sep 2026)
-- Admin (Owner maupun Operator) bisa menandai item menu sebagai rekomendasi dari
-- /admin/menu; item bertanda + aktif tampil di halaman /menu/rekomendasi dan
-- section kecil di Beranda. Default false: semua item yang sudah ada TIDAK
-- otomatis jadi rekomendasi. Kolom murni tambahan — kode lama tak terpengaruh.

alter table public.menu_items
  add column if not exists recommended boolean not null default false;

-- ===================================================================== 20260922090000_attendance_logs_override.sql
-- Pizza Lezzato — modul Riwayat Absensi: kolom justifikasi status oleh Owner
-- (mis. telat dimaafkan krn alasan sah), dengan audit trail, TANPA menimpa
-- data mentah — supaya tetap bisa ditelusuri balik utk payroll/dispute.

-- Kontrak utk RPC payroll (baca "Dampak ke RPC payroll" di rencana fase Riwayat
-- Absensi): `status` = arsip mentah immutable, JANGAN dipakai langsung utk
-- potong gaji. status_efektif = coalesce(status_override, status) = yang
-- WAJIB dipakai RPC payroll utk keputusan yang berdampak ke gaji.
alter table public.attendance_logs
  add column if not exists status_override text
    check (status_override in ('tepat_waktu', 'telat', 'lebih_awal')),
  add column if not exists override_alasan text,
  add column if not exists override_by uuid references public.employees(id),
  add column if not exists override_at timestamptz;

-- ===================================================================== 20260923090000_menu_discount.sql
-- Pizza Lezzato — Fase 1: diskon otomatis per item menu (23 Sep 2026)
-- Persen tetap tersimpan walau toggle nonaktif, supaya admin tak perlu isi ulang
-- saat mengaktifkan lagi (pola sama seperti kolom `recommended`/`active`).

alter table public.menu_items
  add column if not exists discount_percent smallint,
  add column if not exists discount_active boolean not null default false;

alter table public.menu_items
  drop constraint if exists menu_items_discount_percent_check;
alter table public.menu_items
  add constraint menu_items_discount_percent_check
  check (discount_percent is null or discount_percent between 1 and 90);

-- order_items.original_unit_price: harga SEBELUM diskon otomatis, dicatat per
-- baris pesanan supaya riwayat/struk tetap bisa dipertanggungjawabkan sampai
-- ke rupiah walau persen diskon menu berubah/dicabut belakangan. NULL berarti
-- baris itu tidak sedang didiskon otomatis saat dipesan (harga = unit_price).
alter table public.order_items
  add column if not exists original_unit_price integer;

alter table public.order_items
  drop constraint if exists order_items_original_unit_price_check;
alter table public.order_items
  add constraint order_items_original_unit_price_check
  check (original_unit_price is null or original_unit_price >= 0);

-- create_order: TANPA mengubah logika subtotal/diskon voucher/total sama sekali
-- (Fase 2 yang akan menyentuh itu) — perubahan di sini murni menyalurkan satu
-- field tambahan (opsional) dari p_items ke kolom baru di atas.
create or replace function public.create_order(
  p_customer_id     uuid,
  p_order_code      text,
  p_order_type      text,
  p_recipient_name  text,
  p_recipient_phone text,
  p_kecamatan       text,
  p_address         text,
  p_patokan         text,
  p_note            text,
  p_voucher_code    text,
  p_items           jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_subtotal int := 0;
  v_discount int := 0;
  v_total    int;
  v_order_id uuid;
  v_voucher  public.vouchers%rowtype;
  v_has_orders boolean;
  v_uses_by_customer int;
  v_total_uses int;
  v_item jsonb;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'items kosong' using errcode = 'P0001';
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    if (v_item->>'unit_price') is null or (v_item->>'qty') is null
       or (v_item->>'unit_price')::int < 0 or (v_item->>'qty')::int <= 0 then
      raise exception 'item tidak valid' using errcode = 'P0001';
    end if;
    v_subtotal := v_subtotal + (v_item->>'unit_price')::int * (v_item->>'qty')::int;
  end loop;

  if p_voucher_code is not null and length(btrim(p_voucher_code)) > 0 then
    select * into v_voucher from public.vouchers where code = p_voucher_code for update;
    if not found or not v_voucher.active then
      raise exception 'voucher tidak berlaku' using errcode = 'P0001';
    end if;
    if v_voucher.starts_at is not null and now() < v_voucher.starts_at then
      raise exception 'voucher belum aktif' using errcode = 'P0001';
    end if;
    if v_voucher.ends_at is not null and now() > v_voucher.ends_at then
      raise exception 'voucher kedaluwarsa' using errcode = 'P0001';
    end if;
    if v_voucher.first_order_only then
      select exists(select 1 from public.orders where customer_id = p_customer_id)
        into v_has_orders;
      if v_has_orders then
        raise exception 'voucher hanya untuk pesanan pertama' using errcode = 'P0001';
      end if;
    end if;
    if v_voucher.max_uses_per_customer is not null then
      select count(*) into v_uses_by_customer from public.voucher_redemptions
        where voucher_code = p_voucher_code and customer_id = p_customer_id;
      if v_uses_by_customer >= v_voucher.max_uses_per_customer then
        raise exception 'voucher sudah mencapai batas pemakaian Anda' using errcode = 'P0001';
      end if;
    end if;
    if v_voucher.total_quota is not null then
      select count(*) into v_total_uses from public.voucher_redemptions
        where voucher_code = p_voucher_code;
      if v_total_uses >= v_voucher.total_quota then
        raise exception 'voucher sudah mencapai kuota pemakaian' using errcode = 'P0001';
      end if;
    end if;
    v_discount := round(v_subtotal * v_voucher.discount_percent / 100.0);
  else
    p_voucher_code := null;
  end if;

  v_total := v_subtotal - v_discount;

  insert into public.orders (
    order_code, customer_id, order_type, subtotal, discount, voucher_code, total,
    recipient_name, recipient_phone, kecamatan, address, patokan, note
  ) values (
    p_order_code, p_customer_id, p_order_type, v_subtotal, v_discount, p_voucher_code, v_total,
    p_recipient_name, p_recipient_phone,
    nullif(btrim(coalesce(p_kecamatan, '')), ''),
    nullif(btrim(coalesce(p_address, '')), ''),
    nullif(btrim(coalesce(p_patokan, '')), ''),
    nullif(btrim(coalesce(p_note, '')), '')
  )
  returning id into v_order_id;

  insert into public.order_items (order_id, menu_id, name, unit_price, qty, options, original_unit_price)
  select
    v_order_id,
    elem->>'menu_id',
    elem->>'name',
    (elem->>'unit_price')::int,
    (elem->>'qty')::int,
    coalesce(elem->'options', '{}'::jsonb),
    (elem->>'original_unit_price')::int  -- NULL bila field tak dikirim (item tanpa diskon otomatis)
  from jsonb_array_elements(p_items) as elem;

  if p_voucher_code is not null then
    insert into public.voucher_redemptions (voucher_code, customer_id, order_id)
    values (p_voucher_code, p_customer_id, v_order_id);
  end if;

  return jsonb_build_object(
    'order_id',   v_order_id,
    'order_code', p_order_code,
    'subtotal',   v_subtotal,
    'discount',   v_discount,
    'total',      v_total
  );
end;
$$;

revoke all on function public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb
) from public, anon, authenticated;

grant execute on function public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb
) to service_role;

-- ===================================================================== 20260923150000_voucher_restrictions.sql
-- Pizza Lezzato — Fase 2: voucher dgn syarat menu tertentu & tipe pesanan
-- tertentu, + aturan "diskon otomatis mengecualikan voucher" (23 Sep 2026).
--
-- Aturan yang disepakati (bukan "ambil yang lebih murah", disederhanakan):
--   1. Voucher bisa dibatasi ke tipe pesanan tertentu (Delivery/Take Away/
--      Dine-in) — kalau tak cocok, voucher DITOLAK TOTAL (bukan per-baris).
--   2. Voucher bisa dibatasi ke item menu tertentu — diskon HANYA memotong
--      baris item itu, baris lain tetap harga normal.
--   3. Baris yang SEDANG AKTIF diskon otomatisnya (Fase 1) OTOMATIS
--      DIKECUALIKAN dari voucher, apa pun syarat menu di atas — tak pernah
--      menumpuk. Kalau SEMUA baris yang berlaku sedang didiskon otomatis
--      (atau tak ada baris yang cocok sama sekali), voucher DITOLAK dgn
--      pesan jelas (jalur yang sama, tidak membakar jatah pemakaian).

alter table public.vouchers
  add column if not exists applies_to_menu_ids text[],
  add column if not exists applies_to_order_types text[];

alter table public.vouchers
  drop constraint if exists vouchers_applies_to_order_types_check;
alter table public.vouchers
  add constraint vouchers_applies_to_order_types_check
  check (applies_to_order_types is null or applies_to_order_types <@ array['delivery','takeaway','dinein']::text[]);

-- order_items.voucher_discount: potongan RUPIAH voucher UNTUK BARIS INI saja
-- (0 kalau baris ini tak eligible). SELALU 0 bila baris ini punya
-- original_unit_price (sedang diskon otomatis) — mutually exclusive dgn Fase 1.
-- sum(voucher_discount) across satu order harus PERSIS = orders.discount.
alter table public.order_items
  add column if not exists voucher_discount integer not null default 0;

alter table public.order_items
  drop constraint if exists order_items_voucher_discount_check;
alter table public.order_items
  add constraint order_items_voucher_discount_check
  check (voucher_discount >= 0);

create or replace function public.create_order(
  p_customer_id     uuid,
  p_order_code      text,
  p_order_type      text,
  p_recipient_name  text,
  p_recipient_phone text,
  p_kecamatan       text,
  p_address         text,
  p_patokan         text,
  p_note            text,
  p_voucher_code    text,
  p_items           jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_subtotal int := 0;
  v_discount int := 0;
  v_total    int;
  v_order_id uuid;
  v_voucher  public.vouchers%rowtype;
  v_has_orders boolean;
  v_uses_by_customer int;
  v_total_uses int;
  v_item jsonb;
  -- Fase 2 — eligibilitas per baris
  v_is_eligible        boolean;
  v_eligible_subtotal  int := 0;
  v_eligible_count     int := 0;
  v_eligible_seen      int := 0;
  v_used               int := 0;
  v_line_discount      int;
  v_items_out          jsonb := '[]'::jsonb;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'items kosong' using errcode = 'P0001';
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    if (v_item->>'unit_price') is null or (v_item->>'qty') is null
       or (v_item->>'unit_price')::int < 0 or (v_item->>'qty')::int <= 0 then
      raise exception 'item tidak valid' using errcode = 'P0001';
    end if;
    v_subtotal := v_subtotal + (v_item->>'unit_price')::int * (v_item->>'qty')::int;
  end loop;

  if p_voucher_code is not null and length(btrim(p_voucher_code)) > 0 then
    select * into v_voucher from public.vouchers where code = p_voucher_code for update;
    if not found or not v_voucher.active then
      raise exception 'voucher tidak berlaku' using errcode = 'P0001';
    end if;
    if v_voucher.starts_at is not null and now() < v_voucher.starts_at then
      raise exception 'voucher belum aktif' using errcode = 'P0001';
    end if;
    if v_voucher.ends_at is not null and now() > v_voucher.ends_at then
      raise exception 'voucher kedaluwarsa' using errcode = 'P0001';
    end if;
    if v_voucher.first_order_only then
      select exists(select 1 from public.orders where customer_id = p_customer_id)
        into v_has_orders;
      if v_has_orders then
        raise exception 'voucher hanya untuk pesanan pertama' using errcode = 'P0001';
      end if;
    end if;
    if v_voucher.max_uses_per_customer is not null then
      select count(*) into v_uses_by_customer from public.voucher_redemptions
        where voucher_code = p_voucher_code and customer_id = p_customer_id;
      if v_uses_by_customer >= v_voucher.max_uses_per_customer then
        raise exception 'voucher sudah mencapai batas pemakaian Anda' using errcode = 'P0001';
      end if;
    end if;
    if v_voucher.total_quota is not null then
      select count(*) into v_total_uses from public.voucher_redemptions
        where voucher_code = p_voucher_code;
      if v_total_uses >= v_voucher.total_quota then
        raise exception 'voucher sudah mencapai kuota pemakaian' using errcode = 'P0001';
      end if;
    end if;
    -- Fase 2, aturan #1 — gerbang tipe pesanan, seluruh voucher (bukan per baris)
    if v_voucher.applies_to_order_types is not null
       and not (p_order_type = any(v_voucher.applies_to_order_types)) then
      raise exception 'voucher tidak berlaku untuk tipe pesanan ini' using errcode = 'P0001';
    end if;

    -- Fase 2, aturan #2 & #3 — eligibilitas per baris: cocok daftar menu
    -- (bila dibatasi) DAN baris ini TIDAK sedang aktif diskon otomatisnya.
    for v_item in select * from jsonb_array_elements(p_items)
    loop
      v_is_eligible := (v_item->>'original_unit_price') is null
        and (v_voucher.applies_to_menu_ids is null
             or (v_item->>'menu_id') = any(v_voucher.applies_to_menu_ids));
      if v_is_eligible then
        v_eligible_subtotal := v_eligible_subtotal + (v_item->>'unit_price')::int * (v_item->>'qty')::int;
        v_eligible_count := v_eligible_count + 1;
      end if;
    end loop;

    if v_eligible_count = 0 then
      raise exception 'voucher tidak memotong item apa pun di keranjang Anda' using errcode = 'P0001';
    end if;

    v_discount := round(v_eligible_subtotal * v_voucher.discount_percent / 100.0);

    -- Bangun ulang p_items dgn voucher_discount per baris, presisi rupiah:
    -- semua baris eligible KECUALI yang TERAKHIR pakai round() normal; baris
    -- eligible TERAKHIR menyerap sisa pembulatan — menjamin
    -- sum(voucher_discount) == v_discount PERSIS (bukan cuma mendekati).
    for v_item in select * from jsonb_array_elements(p_items)
    loop
      v_is_eligible := (v_item->>'original_unit_price') is null
        and (v_voucher.applies_to_menu_ids is null
             or (v_item->>'menu_id') = any(v_voucher.applies_to_menu_ids));
      if v_is_eligible then
        v_eligible_seen := v_eligible_seen + 1;
        if v_eligible_seen = v_eligible_count then
          v_line_discount := v_discount - v_used;
        else
          v_line_discount := round((v_item->>'unit_price')::int * (v_item->>'qty')::int * v_voucher.discount_percent / 100.0);
          v_used := v_used + v_line_discount;
        end if;
      else
        v_line_discount := 0;
      end if;
      v_items_out := v_items_out || jsonb_build_array(v_item || jsonb_build_object('voucher_discount', v_line_discount));
    end loop;
  else
    p_voucher_code := null;
    v_items_out := p_items;
  end if;

  v_total := v_subtotal - v_discount;

  insert into public.orders (
    order_code, customer_id, order_type, subtotal, discount, voucher_code, total,
    recipient_name, recipient_phone, kecamatan, address, patokan, note
  ) values (
    p_order_code, p_customer_id, p_order_type, v_subtotal, v_discount, p_voucher_code, v_total,
    p_recipient_name, p_recipient_phone,
    nullif(btrim(coalesce(p_kecamatan, '')), ''),
    nullif(btrim(coalesce(p_address, '')), ''),
    nullif(btrim(coalesce(p_patokan, '')), ''),
    nullif(btrim(coalesce(p_note, '')), '')
  )
  returning id into v_order_id;

  insert into public.order_items (order_id, menu_id, name, unit_price, qty, options, original_unit_price, voucher_discount)
  select
    v_order_id,
    elem->>'menu_id',
    elem->>'name',
    (elem->>'unit_price')::int,
    (elem->>'qty')::int,
    coalesce(elem->'options', '{}'::jsonb),
    (elem->>'original_unit_price')::int,
    coalesce((elem->>'voucher_discount')::int, 0)
  from jsonb_array_elements(v_items_out) as elem;

  if p_voucher_code is not null then
    insert into public.voucher_redemptions (voucher_code, customer_id, order_id)
    values (p_voucher_code, p_customer_id, v_order_id);
  end if;

  return jsonb_build_object(
    'order_id',   v_order_id,
    'order_code', p_order_code,
    'subtotal',   v_subtotal,
    'discount',   v_discount,
    'total',      v_total
  );
end;
$$;

revoke all on function public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb
) from public, anon, authenticated;

grant execute on function public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb
) to service_role;

-- ===================================================================== 20260923180000_xtratopping.sql
-- Pizza Lezzato — topping ekstra pindah dari kode (lib/menu/toppings.ts) ke DB,
-- supaya bisa dibaca read-only (RLS) oleh sistem POS terpisah & dikelola lewat
-- Table Editor Supabase (tanpa panel admin baru, sama seperti menu_items).
--
-- xtratopping: katalog topping (nama, aktif, urutan). id = slug teks, ikut pola
-- id menu_items (mis. "beef1", "sig1").
--
-- xtratopping_price: harga per ukuran pizza — SAMA untuk semua jenis topping,
-- cuma beda per ukuran. Jadi cuma 3 baris (personal/medium/large), BUKAN
-- kombinasi topping x ukuran. variant_key ikut nilai yang dipakai
-- menu_item_variants untuk pizza bersize.
--
-- CATATAN: Pizza Kotak (sig1) juga boleh topping ekstra, tapi bukan item
-- "sized" (tidak punya variant_key di menu_item_variants) — sebelumnya
-- TOPPING_PRICE.kotak disamakan dengan tier 'large' (Rp14.000). Itu TETAP
-- berlaku, tapi sebagai aturan di kode (bukan baris ke-4 di tabel ini), sesuai
-- permintaan agar tabel ini cukup 3 baris.

create table if not exists public.xtratopping (
  id         text primary key,               -- slug: mozzarella, beef_seasoned, …
  name       text not null,
  active     boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists xtratopping_active_idx
  on public.xtratopping (active, sort_order);

create table if not exists public.xtratopping_price (
  variant_key text primary key check (variant_key in ('personal', 'medium', 'large')),
  price       integer not null check (price >= 0),
  updated_at  timestamptz not null default now()
);

drop trigger if exists xtratopping_set_updated_at on public.xtratopping;
create trigger xtratopping_set_updated_at
  before update on public.xtratopping
  for each row execute function public.set_updated_at();

drop trigger if exists xtratopping_price_set_updated_at on public.xtratopping_price;
create trigger xtratopping_price_set_updated_at
  before update on public.xtratopping_price
  for each row execute function public.set_updated_at();

-- Seed: data awal dipindah persis dari TOPPING_CATALOG & TOPPING_PRICE (toppings.ts)
insert into public.xtratopping (id, name, active, sort_order) values
  ('mozzarella',       'Keju Mozzarella',    true, 0),
  ('beef_seasoned',    'Seasoned Beef',      true, 1),
  ('chicken_seasoned', 'Seasoned Chicken',   true, 2),
  ('beef_sausage',     'Sosis Sapi',         true, 3),
  ('chicken_sausage',  'Sosis Ayam',         true, 4)
on conflict (id) do nothing;

insert into public.xtratopping_price (variant_key, price) values
  ('personal', 6000),
  ('medium',   9000),
  ('large',    14000)
on conflict (variant_key) do nothing;

-- RLS: siapa saja boleh baca (dipakai kartu menu publik & POS terpisah lewat
-- anon/read-only key), tulis tetap dibatasi — sama seperti pola `kecamatan`.
alter table public.xtratopping       enable row level security;
alter table public.xtratopping_price enable row level security;

revoke insert, update, delete on public.xtratopping       from anon, authenticated;
revoke insert, update, delete on public.xtratopping_price from anon, authenticated;

drop policy if exists xtratopping_read_all on public.xtratopping;
create policy xtratopping_read_all on public.xtratopping
  for select using (true);

drop policy if exists xtratopping_price_read_all on public.xtratopping_price;
create policy xtratopping_price_read_all on public.xtratopping_price
  for select using (true);

-- ===================================================================== 20260923190000_menu_items_anon_read.sql
-- Pizza Lezzato — izin baca publik untuk menu_items & menu_item_variants,
-- supaya bisa dibaca read-only oleh sistem POS terpisah (anon key), sama
-- seperti xtratopping/xtratopping_price. Sebelumnya kedua tabel ini
-- `revoke all from anon, authenticated` (tanpa policy publik) — situs sendiri
-- tetap baca lewat service_role (supabaseAdmin), jadi ini TIDAK mengubah
-- perilaku situs, cuma menambah akses baca utk anon.

grant select on public.menu_items, public.menu_item_variants to anon;

drop policy if exists "anon read menu_items" on public.menu_items;
create policy "anon read menu_items" on public.menu_items
  for select to anon using (true);

drop policy if exists "anon read menu_item_variants" on public.menu_item_variants;
create policy "anon read menu_item_variants" on public.menu_item_variants
  for select to anon using (true);

-- ===================================================================== 20260923200000_menu_layout_order.sql
-- Pizza Lezzato — urutan tampil kategori & section menu pindah dari kode
-- (lib/menu/groups.ts: CATEGORY_PAGES/MENU_GROUPS) ke DB, supaya bisa
-- disinkron ke POS terpisah. Website TETAP simpan judul/deskripsi/emoji/tone
-- per kategori & section di kode (groups.ts) — cuma URUTAN render yang
-- sekarang datang dari sini (lihat lib/menu/layoutOrder.ts).
--
-- menu_categories.slug  = menu_items.category_slug (satu halaman /menu/<slug>)
-- menu_sections.key     = menu_items.section_key    (sub-bagian dlm satu halaman;
--                          biasanya = category_slug, kecuali minuman-tea →
--                          tea/refresh & minuman-coffee → coffee/choco)
--
-- CATATAN: dropdown navigasi di Header (navbar, tampil di semua halaman situs)
-- SENGAJA tetap statis di kode (bukan baca tabel ini) — dropdown itu ada di
-- root layout yg dirender di SETIAP halaman (termasuk /admin, /absensi), jadi
-- menjadikannya baca DB berarti query tambahan di semua halaman situs, bukan
-- cuma halaman menu. Kalau urutan di sini diubah, dropdown Header perlu
-- disamakan manual di groups.ts.

create table if not exists public.menu_categories (
  slug       text primary key,
  label      text not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.menu_sections (
  key           text primary key,
  category_slug text not null references public.menu_categories(slug),
  label         text not null,
  sort_order    integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists menu_sections_category_idx
  on public.menu_sections (category_slug, sort_order);

drop trigger if exists menu_categories_set_updated_at on public.menu_categories;
create trigger menu_categories_set_updated_at
  before update on public.menu_categories
  for each row execute function public.set_updated_at();

drop trigger if exists menu_sections_set_updated_at on public.menu_sections;
create trigger menu_sections_set_updated_at
  before update on public.menu_sections
  for each row execute function public.set_updated_at();

-- Seed: urutan & label dipindah persis dari CATEGORY_PAGES/MENU_GROUPS (groups.ts)
-- yang berlaku saat ini — tampilan tidak berubah dari sebelum migrasi ini.
insert into public.menu_categories (slug, label, sort_order) values
  ('paket-sendiri',    'Paket Sendiri',          0),
  ('paket-berdua',     'Paket Berdua',           1),
  ('paket-keluarga',   'Paket Keluarga',         2),
  ('pizza-beef',       'Beef Collection',        3),
  ('pizza-chicken',    'Chicken Collection',     4),
  ('pizza-umami',      'Umami Collection',       5),
  ('pizza-signature',  'Signature Collection',   6),
  ('pendamping-zuppa', 'Zuppa Soup & Pastry',    7),
  ('pendamping-sides', 'Sides & Desserts',       8),
  ('favorit-pasta',    'Pasta',                  9),
  ('favorit-ricebox',  'Rice Box',              10),
  ('minuman-tea',      'Tea & Refreshments',    11),
  ('minuman-coffee',   'Coffee & Chocolate',    12)
on conflict (slug) do nothing;

insert into public.menu_sections (key, category_slug, label, sort_order) values
  ('paket-sendiri',    'paket-sendiri',    'Paket Sendiri',          0),
  ('paket-berdua',     'paket-berdua',     'Paket Berdua',           1),
  ('paket-keluarga',   'paket-keluarga',   'Paket Keluarga',         2),
  ('pizza-beef',       'pizza-beef',       'Beef Collection',        3),
  ('pizza-chicken',    'pizza-chicken',    'Chicken Collection',     4),
  ('pizza-umami',      'pizza-umami',      'Umami Collection',       5),
  ('pizza-signature',  'pizza-signature',  'Signature Collection',   6),
  ('pendamping-zuppa', 'pendamping-zuppa', 'Zuppa Soup & Pastry',    7),
  ('pendamping-sides', 'pendamping-sides', 'Sides & Desserts',       8),
  ('favorit-pasta',    'favorit-pasta',    'Pasta',                  9),
  ('favorit-ricebox',  'favorit-ricebox',  'Rice Box',              10),
  ('tea',              'minuman-tea',      'Tea Series',            11),
  ('refresh',          'minuman-tea',      'Refreshments Series',   12),
  ('coffee',           'minuman-coffee',   'Coffee Series',         13),
  ('choco',            'minuman-coffee',   'Chocolate Series',      14)
on conflict (key) do nothing;

-- RLS: sama seperti pola menu_items/menu_item_variants — baca dibatasi ke anon
-- (dipakai POS), tulis tetap lewat service_role saja.
alter table public.menu_categories enable row level security;
alter table public.menu_sections   enable row level security;

revoke all on public.menu_categories from anon, authenticated;
revoke all on public.menu_sections   from anon, authenticated;

grant select on public.menu_categories, public.menu_sections to anon;

drop policy if exists "anon read menu_categories" on public.menu_categories;
create policy "anon read menu_categories" on public.menu_categories
  for select to anon using (true);

drop policy if exists "anon read menu_sections" on public.menu_sections;
create policy "anon read menu_sections" on public.menu_sections
  for select to anon using (true);

-- ===================================================================== 20260924090000_pos_reader_customers.sql
-- Pizza Lezzato — kredensial baca terpisah untuk POS: data pelanggan
-- (customers: nama, HP, alamat) SENSITIF, TIDAK cocok dibuka lewat anon key
-- publik seperti data menu — siapa pun yang punya anon key situs (ada di kode
-- klien browser, mudah diambil) bisa baca SEMUA pelanggan kalau dipakai pola
-- yang sama. Sebagai gantinya: role Postgres baru (pos_reader), HANYA boleh
-- SELECT customers, dipakai POS lewat KONEKSI POSTGRES LANGSUNG (bukan lewat
-- REST API/anon key seperti kode website ini) — kredensial ini SAMA SEKALI
-- TIDAK dipakai oleh kode website.
--
-- PENTING — jangan pernah simpan password di file SQL/git:
-- migrasi ini SENGAJA tidak menetapkan password role. Setelah menjalankan
-- ini, atur sendiri passwordnya lewat SQL Editor (dijalankan sendiri,
-- TIDAK disimpan ke repo ini):
--   alter role pos_reader with password 'pilih-password-kuat-di-sini';
-- atau lewat Dashboard Supabase: Database → Roles → pos_reader → reset
-- password. Connection string untuk POS ada di Dashboard Supabase →
-- Project Settings → Database → Connection string (host + port Postgres,
-- ganti user/password dengan pos_reader).

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'pos_reader') then
    create role pos_reader with login;
  end if;
end
$$;

grant usage on schema public to pos_reader;
grant select on public.customers to pos_reader;

drop policy if exists "pos_reader read customers" on public.customers;
create policy "pos_reader read customers" on public.customers
  for select to pos_reader using (true);

-- ===================================================================== 20260925090000_pengaturan_ongkir.sql
-- Pizza Lezzato — Ongkir otomatis Fase 1: tabel pengaturan tarif (25 Sep 2026)
-- Lihat SPEK_ONGKIR_LEZZATO_v2.md §5.2. Tabel berdiri sendiri — TIDAK menyentuh
-- orders maupun create_order, jadi aman diterapkan kapan pun sebelum Fase 2.
--
-- Singleton (id = 1). Tarif SENGAJA tanpa default kolom: kode server membaca
-- baris ini tiap kalkulasi dan menganggap gagal-baca sebagai kegagalan (fallback
-- ke alur manual), bukan diam-diam memakai angka cadangan.

create table if not exists public.pengaturan_ongkir (
  id           smallint primary key default 1,
  tarif_per_km integer not null,
  updated_at   timestamptz not null default now(),
  -- null = masih nilai seed awal (belum pernah diubah dari panel admin)
  updated_by   uuid references public.admin_users(id) on delete set null
);

alter table public.pengaturan_ongkir
  drop constraint if exists pengaturan_ongkir_singleton;
alter table public.pengaturan_ongkir
  add constraint pengaturan_ongkir_singleton check (id = 1);

-- Batas wajar (placeholder, angka final dari Owner) — lapis kedua di belakang
-- validasi server, supaya salah ketik fatal (mis. 18000) tak pernah tersimpan.
-- Harus sama dengan TARIF_MIN/TARIF_MAX di src/lib/ongkir/tarif.ts.
alter table public.pengaturan_ongkir
  drop constraint if exists pengaturan_ongkir_tarif_check;
alter table public.pengaturan_ongkir
  add constraint pengaturan_ongkir_tarif_check check (tarif_per_km between 500 and 10000);

insert into public.pengaturan_ongkir (id, tarif_per_km)
values (1, 1800)
on conflict (id) do nothing;

-- Tertutup total untuk client publik: RLS aktif tanpa policy + revoke. Baca &
-- tulis hanya lewat server (service_role) setelah cek sesi/role admin.
alter table public.pengaturan_ongkir enable row level security;
revoke all on public.pengaturan_ongkir from anon, authenticated;

-- ===================================================================== 20260925100000_ongkir_area_faktor.sql
-- Pizza Lezzato — Ongkir otomatis Fase 1 (revisi v4): batas area + faktor rute
-- + rate limit/pencatatan kuota ORS (25 Sep 2026). Lihat SPEK_ONGKIR_LEZZATO_v4.md
-- §5.2 & §6. Aditif — tidak menyentuh orders maupun create_order.

-- ------------------------------------------------------------------
-- 1. Kolom baru pengaturan_ongkir
-- ------------------------------------------------------------------
-- Default HANYA untuk mengisi baris singleton yang sudah ada, lalu dicabut:
-- kode server membaca nilai ini tiap kalkulasi dan tak punya angka cadangan.
alter table public.pengaturan_ongkir
  add column if not exists batas_lurus_km numeric(5,1) not null default 18,
  add column if not exists batas_rute_km  numeric(5,1) not null default 27,
  add column if not exists faktor_rute    numeric(3,2) not null default 1.40;

alter table public.pengaturan_ongkir
  alter column batas_lurus_km drop default,
  alter column batas_rute_km  drop default,
  alter column faktor_rute    drop default;

-- Batas wajar (placeholder, angka final dari Owner). Harus sama dengan
-- BATAS_WAJAR di src/lib/ongkir/pengaturan.ts.
alter table public.pengaturan_ongkir
  drop constraint if exists pengaturan_ongkir_batas_lurus_check;
alter table public.pengaturan_ongkir
  add constraint pengaturan_ongkir_batas_lurus_check check (batas_lurus_km between 1 and 100);

alter table public.pengaturan_ongkir
  drop constraint if exists pengaturan_ongkir_batas_rute_check;
alter table public.pengaturan_ongkir
  add constraint pengaturan_ongkir_batas_rute_check check (batas_rute_km between 1 and 100);

-- Jarak jalan tak mungkin lebih pendek dari garis lurus → batas rute < batas
-- lurus hampir pasti salah ketik.
alter table public.pengaturan_ongkir
  drop constraint if exists pengaturan_ongkir_batas_urut_check;
alter table public.pengaturan_ongkir
  add constraint pengaturan_ongkir_batas_urut_check check (batas_rute_km >= batas_lurus_km);

alter table public.pengaturan_ongkir
  drop constraint if exists pengaturan_ongkir_faktor_rute_check;
alter table public.pengaturan_ongkir
  add constraint pengaturan_ongkir_faktor_rute_check check (faktor_rute between 1.00 and 2.50);

-- ------------------------------------------------------------------
-- 2. auth_attempts: aksi baru
-- ------------------------------------------------------------------
--   ongkir_geocode / ongkir_hitung — rate limit per IP (lewat record_auth_attempt)
--   ors_geocode / ors_directions   — log panggilan ORS SUNGGUHAN, untuk batas
--                                     harian seluruh pengunjung (kuota akun ORS)
-- WAJIB: allowAttempt() fail-open — tanpa aksi di constraint ini, insert gagal
-- diam-diam dan rate limit tak pernah berlaku.
alter table public.auth_attempts
  drop constraint if exists auth_attempts_action_check;
alter table public.auth_attempts
  add constraint auth_attempts_action_check
  check (action in (
    'register', 'login', 'order', 'admin_login', 'employee_login', 'voucher_check', 'order_preview',
    'ongkir_geocode', 'ongkir_hitung', 'ors_geocode', 'ors_directions'
  ));

-- Hitung pemakaian ORS 24 jam terakhir per aksi (tanpa filter IP).
create index if not exists auth_attempts_action_time_idx
  on public.auth_attempts (action, created_at desc);

-- ===================================================================== 20260926090000_ongkir_fase2.sql
-- Pizza Lezzato — Ongkir otomatis Fase 2 (SPEK_ONGKIR_LEZZATO_v5.md) — 26 Sep 2026
--
-- Isi (SATU transaksi — drop+create create_order tanpa jeda saat website live):
--   1. pengaturan_ongkir.mode         mati / uji_admin / aktif (flag, diubah Owner)
--   2. orders: kolom ongkir (§5.1) + diskon_ongkir + constraint
--   3. vouchers: target item/ongkir + maks_potongan_rupiah + constraint
--   4. customer_lokasi_default        koordinat pin alamat default (TIDAK terbaca POS)
--   5. simpan_alamat_default()        SATU jalur tulis alamat default (2 tabel sekaligus)
--      + trigger sinkronisasi di customers (jalur lain yg mengubah teks alamat
--        otomatis membuang pin yg tak lagi cocok)
--   6. create_order                   + p_ongkir (default null → kode live tetap jalan),
--                                       voucher ongkir, total termasuk ongkir.
--                                       verification_status SENGAJA tidak diisi (pakai
--                                       default kolom 'not_required') — SAMA dengan
--                                       create_order yang live sejak 20260923090000.
--                                       Keputusan Owner 26 Sep 2026: verifikasi HP
--                                       tidak dipakai admin & akan dirancang ulang,
--                                       jadi perilakunya tidak diubah di sini.
--   7. verifikasi_pesanan             tahan diskon juga bila hanya ada diskon_ongkir
--   8. resolusi_diskon_tertahan       "Cabut Diskon" tak lagi membuang ongkir dari total
--
-- Aditif & kompatibel ke belakang: kode yang SEDANG live (tanpa p_ongkir) tetap
-- bisa memanggil create_order dengan hasil identik untuk voucher item.

begin;

-- ------------------------------------------------------------------
-- 1. Mode ongkir otomatis (menggantikan env ENABLE_AUTO_ONGKIR)
-- ------------------------------------------------------------------
--   mati      → checkout Delivery memakai alur lama (alamat teks + konfirmasi WA)
--   uji_admin → alur baru hanya untuk browser yang juga login admin (uji di produksi)
--   aktif     → alur baru untuk semua pelanggan
alter table public.pengaturan_ongkir
  add column if not exists mode text not null default 'mati';
alter table public.pengaturan_ongkir
  drop constraint if exists pengaturan_ongkir_mode_check;
alter table public.pengaturan_ongkir
  add constraint pengaturan_ongkir_mode_check check (mode in ('mati', 'uji_admin', 'aktif'));

-- ------------------------------------------------------------------
-- 2. Kolom ongkir di orders (§5.1). Semua nullable: order lama, Take Away,
--    Dine-in, dan Delivery alur lama (mode mati) tidak punya ongkir.
-- ------------------------------------------------------------------
alter table public.orders
  add column if not exists alamat_lat            numeric(9,6),
  add column if not exists alamat_lng            numeric(9,6),
  add column if not exists jarak_lurus_km        numeric(7,3),
  add column if not exists jarak_rute_km         numeric(7,3),   -- null bila ORS gagal
  add column if not exists jarak_tagih_km        numeric(7,3),
  add column if not exists metode_jarak          text,
  add column if not exists ongkir_rupiah         integer,
  add column if not exists tarif_per_km_snapshot integer,
  add column if not exists diskon_ongkir         integer not null default 0;

alter table public.orders drop constraint if exists orders_metode_jarak_check;
alter table public.orders add constraint orders_metode_jarak_check
  check (metode_jarak is null or metode_jarak in ('rute', 'estimasi_lurus'));

-- Ongkir terisi ⇒ order Delivery dengan data audit lengkap (koordinat pin,
-- jarak, metode, tarif). jarak_rute_km boleh null (metode estimasi_lurus).
alter table public.orders drop constraint if exists orders_ongkir_lengkap_check;
alter table public.orders add constraint orders_ongkir_lengkap_check check (
  ongkir_rupiah is null
  or (
    order_type = 'delivery'
    and ongkir_rupiah >= 0
    and alamat_lat is not null and alamat_lng is not null
    and jarak_lurus_km is not null and jarak_tagih_km is not null
    and metode_jarak is not null
    and tarif_per_km_snapshot is not null and tarif_per_km_snapshot > 0
    and (metode_jarak = 'estimasi_lurus' or jarak_rute_km is not null)
  )
);

-- Potongan ongkir tak pernah melebihi ongkir (sisa tak memotong item).
alter table public.orders drop constraint if exists orders_diskon_ongkir_check;
alter table public.orders add constraint orders_diskon_ongkir_check
  check (diskon_ongkir >= 0 and diskon_ongkir <= coalesce(ongkir_rupiah, 0));

-- ------------------------------------------------------------------
-- 3. Voucher: target item / ongkir, batas maksimal potongan (ongkir saja)
-- ------------------------------------------------------------------
-- Voucher lama otomatis 'item' — perilakunya tidak berubah.
alter table public.vouchers
  add column if not exists target text not null default 'item',
  add column if not exists maks_potongan_rupiah integer;

alter table public.vouchers drop constraint if exists vouchers_target_check;
alter table public.vouchers add constraint vouchers_target_check
  check (target in ('item', 'ongkir'));

alter table public.vouchers drop constraint if exists vouchers_maks_potongan_check;
alter table public.vouchers add constraint vouchers_maks_potongan_check check (
  maks_potongan_rupiah is null
  or (target = 'ongkir' and maks_potongan_rupiah > 0)
);

-- Voucher ongkir: syarat "menu tertentu" tidak bermakna (itu penentu baris yg
-- dipotong di voucher item) → wajib kosong; tipe pesanan kosong atau Delivery saja.
alter table public.vouchers drop constraint if exists vouchers_target_ongkir_check;
alter table public.vouchers add constraint vouchers_target_ongkir_check check (
  target <> 'ongkir'
  or (
    applies_to_menu_ids is null
    and (applies_to_order_types is null or applies_to_order_types = array['delivery']::text[])
  )
);

-- ------------------------------------------------------------------
-- 4. Koordinat pin alamat default — tabel terpisah supaya TIDAK ikut
--    terbaca role pos_reader (yang boleh SELECT semua kolom customers).
-- ------------------------------------------------------------------
create table if not exists public.customer_lokasi_default (
  customer_id uuid primary key references public.customers(id) on delete cascade,
  alamat      text not null check (length(btrim(alamat)) > 0),
  patokan     text,
  lat         numeric(9,6) not null check (lat between -90 and 90),
  lng         numeric(9,6) not null check (lng between -180 and 180),
  updated_at  timestamptz not null default now()
);

-- Tertutup total: tanpa policy, tanpa grant. Hanya server (service_role)
-- setelah cek sesi pelanggan pemiliknya.
alter table public.customer_lokasi_default enable row level security;
revoke all on public.customer_lokasi_default from public, anon, authenticated;
grant select, insert, update, delete on public.customer_lokasi_default to service_role;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'pos_reader') then
    execute 'revoke all on public.customer_lokasi_default from pos_reader';
  end if;
end
$$;

-- ------------------------------------------------------------------
-- 5. SATU jalur simpan alamat default: customer_lokasi_default +
--    customers.default_address/default_patokan dalam satu transaksi.
-- ------------------------------------------------------------------
--   dengan p_lat & p_lng → alamat default terkonfirmasi pin (upsert koordinat)
--   tanpa koordinat      → alamat default teks saja (alur lama / mode mati) —
--                          pin lama DIBUANG karena tak lagi mewakili teks baru
--   p_alamat kosong      → hapus alamat default sepenuhnya
-- Pemeriksaan "di luar area" dilakukan server SEBELUM memanggil fungsi ini
-- (butuh ORS & pengaturan_ongkir); fungsi ini menjaga konsistensi data.
create or replace function public.simpan_alamat_default(
  p_customer_id uuid,
  p_alamat      text,
  p_patokan     text,
  p_lat         numeric default null,
  p_lng         numeric default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_alamat  text := nullif(btrim(coalesce(p_alamat, '')), '');
  v_patokan text := nullif(btrim(coalesce(p_patokan, '')), '');
begin
  if (p_lat is null) <> (p_lng is null) then
    raise exception 'koordinat tidak lengkap' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'pelanggan tidak ditemukan' using errcode = 'P0001';
  end if;

  if v_alamat is not null and p_lat is not null then
    insert into public.customer_lokasi_default (customer_id, alamat, patokan, lat, lng, updated_at)
    values (p_customer_id, v_alamat, v_patokan, p_lat, p_lng, now())
    on conflict (customer_id) do update
      set alamat = excluded.alamat, patokan = excluded.patokan,
          lat = excluded.lat, lng = excluded.lng, updated_at = now();
  else
    if v_alamat is null and p_lat is not null then
      raise exception 'alamat wajib diisi untuk menyimpan pin' using errcode = 'P0001';
    end if;
    delete from public.customer_lokasi_default where customer_id = p_customer_id;
  end if;

  -- Urutan penting: koordinat dulu, lalu teks — trigger di bawah melihat teks
  -- baru SAMA dengan alamat di customer_lokasi_default sehingga pin dipertahankan.
  update public.customers
    set default_address = v_alamat, default_patokan = v_patokan
    where id = p_customer_id;
end;
$$;

revoke all on function public.simpan_alamat_default(uuid, text, text, numeric, numeric)
  from public, anon, authenticated;
grant execute on function public.simpan_alamat_default(uuid, text, text, numeric, numeric) to service_role;

-- Jaring pengaman: jalur lain yang mengubah teks alamat default (mis. edit
-- pelanggan oleh Owner di /admin/pelanggan, atau SQL Editor) tidak boleh
-- meninggalkan pin yang menunjuk tempat lain.
--   teks alamat berubah & beda dari alamat di pin → pin dibuang (wajib konfirmasi ulang)
--   hanya patokan berubah                          → patokan di pin ikut disalin
create or replace function public.sinkron_lokasi_default()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lok public.customer_lokasi_default%rowtype;
begin
  select * into v_lok from public.customer_lokasi_default where customer_id = new.id;
  if not found then
    return new;
  end if;
  if new.default_address is distinct from v_lok.alamat then
    delete from public.customer_lokasi_default where customer_id = new.id;
  elsif new.default_patokan is distinct from v_lok.patokan then
    update public.customer_lokasi_default
      set patokan = new.default_patokan, updated_at = now()
      where customer_id = new.id;
  end if;
  return new;
end;
$$;

revoke all on function public.sinkron_lokasi_default() from public, anon, authenticated;

drop trigger if exists customers_sinkron_lokasi_default on public.customers;
create trigger customers_sinkron_lokasi_default
  after update of default_address, default_patokan on public.customers
  for each row execute function public.sinkron_lokasi_default();

-- ------------------------------------------------------------------
-- 6. create_order — drop + create (signature berubah: + p_ongkir)
-- ------------------------------------------------------------------
-- p_ongkir (jsonb, dihitung SERVER dari koordinat pin — lihat
-- src/lib/ongkir): { alamat_lat, alamat_lng, jarak_lurus_km, jarak_rute_km,
-- jarak_tagih_km, metode_jarak, ongkir_rupiah, tarif_per_km_snapshot }.
-- null = tanpa ongkir otomatis (alur lama). Fungsi ini hanya bisa dipanggil
-- service_role; nilai ongkir tidak pernah berasal dari klien.
drop function if exists public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb
);
-- signature baru juga — supaya file ini aman dijalankan ulang
drop function if exists public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb, jsonb
);

create function public.create_order(
  p_customer_id     uuid,
  p_order_code      text,
  p_order_type      text,
  p_recipient_name  text,
  p_recipient_phone text,
  p_kecamatan       text,
  p_address         text,
  p_patokan         text,
  p_note            text,
  p_voucher_code    text,
  p_items           jsonb,
  p_ongkir          jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_subtotal int := 0;
  v_discount int := 0;
  v_total    int;
  v_order_id uuid;
  v_voucher  public.vouchers%rowtype;
  v_has_orders boolean;
  v_uses_by_customer int;
  v_total_uses int;
  v_item jsonb;
  -- eligibilitas per baris (voucher item)
  v_is_eligible        boolean;
  v_eligible_subtotal  int := 0;
  v_eligible_count     int := 0;
  v_eligible_seen      int := 0;
  v_used               int := 0;
  v_line_discount      int;
  v_items_out          jsonb := '[]'::jsonb;
  -- ongkir (Fase 2)
  v_ongkir         int;
  v_diskon_ongkir  int := 0;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'items kosong' using errcode = 'P0001';
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    if (v_item->>'unit_price') is null or (v_item->>'qty') is null
       or (v_item->>'unit_price')::int < 0 or (v_item->>'qty')::int <= 0 then
      raise exception 'item tidak valid' using errcode = 'P0001';
    end if;
    v_subtotal := v_subtotal + (v_item->>'unit_price')::int * (v_item->>'qty')::int;
  end loop;

  -- Ongkir: hanya Delivery. Kelengkapan kolom audit dijaga constraint
  -- orders_ongkir_lengkap_check saat insert di bawah.
  if p_ongkir is not null then
    if p_order_type <> 'delivery' then
      raise exception 'ongkir hanya untuk pesanan Delivery' using errcode = 'P0001';
    end if;
    v_ongkir := (p_ongkir->>'ongkir_rupiah')::int;
    if v_ongkir is null or v_ongkir < 0 then
      raise exception 'ongkir tidak valid' using errcode = 'P0001';
    end if;
  end if;

  if p_voucher_code is not null and length(btrim(p_voucher_code)) > 0 then
    select * into v_voucher from public.vouchers where code = p_voucher_code for update;
    if not found or not v_voucher.active then
      raise exception 'voucher tidak berlaku' using errcode = 'P0001';
    end if;
    if v_voucher.starts_at is not null and now() < v_voucher.starts_at then
      raise exception 'voucher belum aktif' using errcode = 'P0001';
    end if;
    if v_voucher.ends_at is not null and now() > v_voucher.ends_at then
      raise exception 'voucher kedaluwarsa' using errcode = 'P0001';
    end if;
    if v_voucher.first_order_only then
      select exists(select 1 from public.orders where customer_id = p_customer_id)
        into v_has_orders;
      if v_has_orders then
        raise exception 'voucher hanya untuk pesanan pertama' using errcode = 'P0001';
      end if;
    end if;
    if v_voucher.max_uses_per_customer is not null then
      select count(*) into v_uses_by_customer from public.voucher_redemptions
        where voucher_code = p_voucher_code and customer_id = p_customer_id;
      if v_uses_by_customer >= v_voucher.max_uses_per_customer then
        raise exception 'voucher sudah mencapai batas pemakaian Anda' using errcode = 'P0001';
      end if;
    end if;
    if v_voucher.total_quota is not null then
      select count(*) into v_total_uses from public.voucher_redemptions
        where voucher_code = p_voucher_code;
      if v_total_uses >= v_voucher.total_quota then
        raise exception 'voucher sudah mencapai kuota pemakaian' using errcode = 'P0001';
      end if;
    end if;
    -- gerbang tipe pesanan, seluruh voucher (bukan per baris)
    if v_voucher.applies_to_order_types is not null
       and not (p_order_type = any(v_voucher.applies_to_order_types)) then
      raise exception 'voucher tidak berlaku untuk tipe pesanan ini' using errcode = 'P0001';
    end if;

    if v_voucher.target = 'ongkir' then
      -- Voucher ongkir: hanya Delivery dengan ongkir otomatis terhitung.
      -- (di_luar_area tak pernah sampai sini — order ditolak server.)
      if p_order_type <> 'delivery' then
        raise exception 'voucher ongkir hanya berlaku untuk pesanan Delivery' using errcode = 'P0001';
      end if;
      if v_ongkir is null then
        raise exception 'voucher ongkir hanya berlaku bila ongkir dihitung otomatis' using errcode = 'P0001';
      end if;
      if v_ongkir = 0 then
        raise exception 'tidak ada ongkir yang bisa dipotong voucher ini' using errcode = 'P0001';
      end if;
      v_diskon_ongkir := least(
        round(v_ongkir * v_voucher.discount_percent / 100.0)::int,
        coalesce(v_voucher.maks_potongan_rupiah, v_ongkir),
        v_ongkir
      );
      -- Item tidak dipotong sama sekali: voucher_discount per baris = 0.
      v_items_out := p_items;
    else
      -- Voucher item — logika identik dengan 20260923150000 (tidak berubah):
      -- eligibilitas per baris = cocok daftar menu (bila dibatasi) DAN baris
      -- ini TIDAK sedang aktif diskon otomatisnya.
      for v_item in select * from jsonb_array_elements(p_items)
      loop
        v_is_eligible := (v_item->>'original_unit_price') is null
          and (v_voucher.applies_to_menu_ids is null
               or (v_item->>'menu_id') = any(v_voucher.applies_to_menu_ids));
        if v_is_eligible then
          v_eligible_subtotal := v_eligible_subtotal + (v_item->>'unit_price')::int * (v_item->>'qty')::int;
          v_eligible_count := v_eligible_count + 1;
        end if;
      end loop;

      if v_eligible_count = 0 then
        raise exception 'voucher tidak memotong item apa pun di keranjang Anda' using errcode = 'P0001';
      end if;

      v_discount := round(v_eligible_subtotal * v_voucher.discount_percent / 100.0);

      -- voucher_discount per baris, presisi rupiah: baris eligible TERAKHIR
      -- menyerap sisa pembulatan → sum(voucher_discount) == v_discount PERSIS.
      for v_item in select * from jsonb_array_elements(p_items)
      loop
        v_is_eligible := (v_item->>'original_unit_price') is null
          and (v_voucher.applies_to_menu_ids is null
               or (v_item->>'menu_id') = any(v_voucher.applies_to_menu_ids));
        if v_is_eligible then
          v_eligible_seen := v_eligible_seen + 1;
          if v_eligible_seen = v_eligible_count then
            v_line_discount := v_discount - v_used;
          else
            v_line_discount := round((v_item->>'unit_price')::int * (v_item->>'qty')::int * v_voucher.discount_percent / 100.0);
            v_used := v_used + v_line_discount;
          end if;
        else
          v_line_discount := 0;
        end if;
        v_items_out := v_items_out || jsonb_build_array(v_item || jsonb_build_object('voucher_discount', v_line_discount));
      end loop;
    end if;
  else
    p_voucher_code := null;
    v_items_out := p_items;
  end if;

  -- Total = subtotal − potongan item + ongkir − potongan ongkir.
  v_total := v_subtotal - v_discount + coalesce(v_ongkir, 0) - v_diskon_ongkir;

  -- verification_status tidak diisi → default kolom 'not_required', sama
  -- persis dengan create_order yang live (lihat catatan di kepala file).
  insert into public.orders (
    order_code, customer_id, order_type, subtotal, discount, voucher_code, total,
    recipient_name, recipient_phone, kecamatan, address, patokan, note,
    alamat_lat, alamat_lng, jarak_lurus_km, jarak_rute_km, jarak_tagih_km,
    metode_jarak, ongkir_rupiah, tarif_per_km_snapshot, diskon_ongkir
  ) values (
    p_order_code, p_customer_id, p_order_type, v_subtotal, v_discount, p_voucher_code, v_total,
    p_recipient_name, p_recipient_phone,
    nullif(btrim(coalesce(p_kecamatan, '')), ''),
    nullif(btrim(coalesce(p_address, '')), ''),
    nullif(btrim(coalesce(p_patokan, '')), ''),
    nullif(btrim(coalesce(p_note, '')), ''),
    (p_ongkir->>'alamat_lat')::numeric,
    (p_ongkir->>'alamat_lng')::numeric,
    (p_ongkir->>'jarak_lurus_km')::numeric,
    (p_ongkir->>'jarak_rute_km')::numeric,
    (p_ongkir->>'jarak_tagih_km')::numeric,
    p_ongkir->>'metode_jarak',
    v_ongkir,
    (p_ongkir->>'tarif_per_km_snapshot')::int,
    v_diskon_ongkir
  )
  returning id into v_order_id;

  insert into public.order_items (order_id, menu_id, name, unit_price, qty, options, original_unit_price, voucher_discount)
  select
    v_order_id,
    elem->>'menu_id',
    elem->>'name',
    (elem->>'unit_price')::int,
    (elem->>'qty')::int,
    coalesce(elem->'options', '{}'::jsonb),
    (elem->>'original_unit_price')::int,
    coalesce((elem->>'voucher_discount')::int, 0)
  from jsonb_array_elements(v_items_out) as elem;

  if p_voucher_code is not null then
    insert into public.voucher_redemptions (voucher_code, customer_id, order_id)
    values (p_voucher_code, p_customer_id, v_order_id);
  end if;

  return jsonb_build_object(
    'order_id',            v_order_id,
    'order_code',          p_order_code,
    'subtotal',            v_subtotal,
    'discount',            v_discount,
    'ongkir',              v_ongkir,
    'diskon_ongkir',       v_diskon_ongkir,
    'total',               v_total
  );
end;
$$;

revoke all on function public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb, jsonb
) from public, anon, authenticated;
grant execute on function public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb, jsonb
) to service_role;

-- ------------------------------------------------------------------
-- 7. verifikasi_pesanan — tahan diskon juga bila hanya ada potongan ongkir
-- ------------------------------------------------------------------
create or replace function public.verifikasi_pesanan(
  p_order_code text,
  p_admin_id   uuid,
  p_hasil      text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
begin
  if p_hasil not in ('verified', 'mismatch') then
    raise exception 'hasil harus "verified" atau "mismatch"' using errcode = 'P0001';
  end if;

  select * into v_order from public.orders where order_code = p_order_code for update;
  if not found then
    raise exception 'pesanan % tidak ditemukan', p_order_code using errcode = 'P0001';
  end if;
  if v_order.verification_status <> 'pending' then
    raise exception 'pesanan % tidak sedang menunggu verifikasi (status saat ini: %)',
      p_order_code, v_order.verification_status using errcode = 'P0001';
  end if;

  if p_hasil = 'verified' then
    update public.customers
      set phone_verified = true, phone_verified_at = now(), phone_verified_by = p_admin_id
      where id = v_order.customer_id;
  end if;

  update public.orders
    set verification_status = p_hasil,
        verified_at = now(),
        verified_by = p_admin_id,
        discount_held = (p_hasil = 'mismatch' and (v_order.discount > 0 or v_order.diskon_ongkir > 0))
    where order_code = p_order_code;

  return format('Pesanan %s ditandai "%s".', p_order_code, p_hasil);
end;
$$;

revoke all on function public.verifikasi_pesanan(text, uuid, text)
  from public, anon, authenticated;
grant execute on function public.verifikasi_pesanan(text, uuid, text) to service_role;

-- ------------------------------------------------------------------
-- 8. resolusi_diskon_tertahan — "Cabut Diskon" mencabut potongan item DAN
--    ongkir, tapi ongkirnya sendiri tetap ditagih.
-- ------------------------------------------------------------------
create or replace function public.resolusi_diskon_tertahan(
  p_order_code          text,
  p_admin_id            uuid,
  p_aksi                text,
  p_verifikasi_permanen boolean default false
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
begin
  if p_aksi not in ('konfirmasi_sah', 'cabut_diskon') then
    raise exception 'aksi harus "konfirmasi_sah" atau "cabut_diskon"' using errcode = 'P0001';
  end if;

  select * into v_order from public.orders where order_code = p_order_code for update;
  if not found then
    raise exception 'pesanan % tidak ditemukan', p_order_code using errcode = 'P0001';
  end if;
  if not v_order.discount_held then
    raise exception 'pesanan % tidak sedang menahan diskon', p_order_code using errcode = 'P0001';
  end if;
  if v_order.verification_status <> 'mismatch' then
    raise exception 'pesanan % tidak berstatus mismatch (status saat ini: %)',
      p_order_code, v_order.verification_status using errcode = 'P0001';
  end if;

  if p_aksi = 'konfirmasi_sah' then
    update public.orders
      set discount_held = false,
          verification_status = 'verified',
          resolved_at = now(),
          resolved_by = p_admin_id
      where order_code = p_order_code;

    if p_verifikasi_permanen then
      update public.customers
        set phone_verified = true, phone_verified_at = now(), phone_verified_by = p_admin_id
        where id = v_order.customer_id;
    end if;
  else
    update public.orders
      set discount_held = false,
          discount = 0,
          diskon_ongkir = 0,
          total = subtotal + coalesce(ongkir_rupiah, 0),
          resolved_at = now(),
          resolved_by = p_admin_id
      where order_code = p_order_code;

    delete from public.voucher_redemptions where order_id = v_order.id;
  end if;

  return format('Pesanan %s diresolusi: "%s".', p_order_code, p_aksi);
end;
$$;

revoke all on function public.resolusi_diskon_tertahan(text, uuid, text, boolean)
  from public, anon, authenticated;
grant execute on function public.resolusi_diskon_tertahan(text, uuid, text, boolean) to service_role;

commit;

-- PostgREST memuat ulang daftar fungsi (signature create_order berubah).
notify pgrst, 'reload schema';

-- ===================================================================== 20260927090000_ongkir_tarif_bertingkat.sql
-- Pizza Lezzato — Ongkir: rumus tarif bertingkat, TAHAP A (27 Sep 2026)
--
-- Menggantikan tarif_per_km × jarak (dibulatkan per Rp500) dengan praktik toko:
--   jarak ≤ radius_gratis_km                 → Rp0
--   jarak ≤ batas_tarif_dasar_km             → tarif_dasar
--   lainnya → tarif_dasar + ceil((jarak − batas_tarif_dasar_km) / kelipatan_km)
--                           × (tarif_tambahan_per_km × kelipatan_km)
-- Jarak dihitung dalam METER bulat (jarak_tagih_km numeric(7,3)) → tanpa galat
-- desimal: tepat 1,000 km = gratis, tepat 1,500 km = tarif dasar.
--
-- MIGRASI DUA TAHAP (expand/contract). File ini = TAHAP A, hanya menambah:
--   1. pengaturan_ongkir: 5 kolom parameter baru (+ default = angka Owner) + constraint
--   2. orders: 5 kolom snapshot; orders_ongkir_lengkap_check menerima snapshot
--      LAMA (tarif_per_km_snapshot) ATAU kelima snapshot BARU
--   3. ongkir_dari_tarif(): rumus di SQL (sumber kebenaran kedua)
--   4. create_order: signature TETAP; bila p_ongkir membawa snapshot baru,
--      kelimanya wajib ada & ongkir_rupiah wajib = ongkir_dari_tarif(...).
--      Voucher ongkir pada ongkir Rp0 → pesan "Ongkir kamu sudah gratis…"
--      (exception → transaksi batal → kuota voucher tidak terpakai).
--   5. vouchers.ditawarkan: voucher yang ditawarkan otomatis di checkout ke
--      semua pelanggan yang memenuhi syarat (voucher pesanan pertama selalu
--      ditawarkan ke pelanggan yang berhak, terlepas dari kolom ini).
-- tarif_per_km SENGAJA belum dihapus: kode yang live (f0703180) & target
-- rollback masih membacanya. TAHAP B (terpisah, setelah konfirmasi Owner):
--   alter table pengaturan_ongkir drop constraint pengaturan_ongkir_tarif_check;
--   alter table pengaturan_ongkir drop column tarif_per_km;
-- orders.tarif_per_km_snapshot TIDAK pernah dihapus (riwayat pesanan lama).

begin;

-- ------------------------------------------------------------------
-- 1. Parameter tarif bertingkat (diatur Owner di /admin/ongkir)
-- ------------------------------------------------------------------
alter table public.pengaturan_ongkir
  add column if not exists radius_gratis_km      numeric(4,2) not null default 1,
  add column if not exists tarif_dasar           integer      not null default 3000,
  add column if not exists batas_tarif_dasar_km  numeric(4,2) not null default 1.5,
  add column if not exists tarif_tambahan_per_km integer      not null default 2000,
  add column if not exists kelipatan_km          numeric(4,2) not null default 0.5;

-- Batas wajar — HARUS sama dengan BATAS_WAJAR di src/lib/ongkir/pengaturan.ts.
-- Tambahan per langkah (tarif_tambahan_per_km × kelipatan_km) wajib rupiah
-- utuh kelipatan Rp100 → hasil ongkir tak pernah perlu dibulatkan.
alter table public.pengaturan_ongkir
  drop constraint if exists pengaturan_ongkir_tarif_bertingkat_check;
alter table public.pengaturan_ongkir
  add constraint pengaturan_ongkir_tarif_bertingkat_check check (
        radius_gratis_km between 0 and 5
    and batas_tarif_dasar_km between 0 and 10
    and radius_gratis_km <= batas_tarif_dasar_km
    and kelipatan_km between 0.1 and 5
    and tarif_dasar between 0 and 50000 and tarif_dasar % 100 = 0
    and tarif_tambahan_per_km between 500 and 20000
    and mod(tarif_tambahan_per_km * kelipatan_km, 100) = 0
  );

-- ------------------------------------------------------------------
-- 2. Snapshot parameter di pesanan (nullable: pesanan lama tak punya)
-- ------------------------------------------------------------------
alter table public.orders
  add column if not exists radius_gratis_km_snapshot      numeric(4,2),
  add column if not exists tarif_dasar_snapshot           integer,
  add column if not exists batas_tarif_dasar_km_snapshot  numeric(4,2),
  add column if not exists tarif_tambahan_per_km_snapshot integer,
  add column if not exists kelipatan_km_snapshot          numeric(4,2);

-- Sama dengan versi Fase 2, kecuali syarat tarif: snapshot lama ATAU kelima
-- snapshot baru (pesanan dari kode live sebelum deploy tetap sah).
alter table public.orders drop constraint if exists orders_ongkir_lengkap_check;
alter table public.orders add constraint orders_ongkir_lengkap_check check (
  ongkir_rupiah is null
  or (
    order_type = 'delivery'
    and ongkir_rupiah >= 0
    and alamat_lat is not null and alamat_lng is not null
    and jarak_lurus_km is not null and jarak_tagih_km is not null
    and metode_jarak is not null
    and (metode_jarak = 'estimasi_lurus' or jarak_rute_km is not null)
    and (
      (tarif_per_km_snapshot is not null and tarif_per_km_snapshot > 0)
      or (
        radius_gratis_km_snapshot is not null
        and tarif_dasar_snapshot is not null
        and batas_tarif_dasar_km_snapshot is not null
        and tarif_tambahan_per_km_snapshot is not null
        and kelipatan_km_snapshot is not null
      )
    )
  )
);

-- ------------------------------------------------------------------
-- 3. Rumus di SQL — harus identik dengan hitungRupiah() di
--    src/lib/ongkir/kalkulasi.mjs (diuji silang di scripts/uji-logika-ongkir.mjs)
-- ------------------------------------------------------------------
create or replace function public.ongkir_dari_tarif(
  p_jarak_km      numeric,
  p_radius_km     numeric,
  p_tarif_dasar   integer,
  p_batas_km      numeric,
  p_tambahan      integer,
  p_kelipatan_km  numeric
)
returns integer
language sql
immutable
set search_path = public
as $$
  select case
    when round(p_jarak_km * 1000) <= round(p_radius_km * 1000) then 0
    when round(p_jarak_km * 1000) <= round(p_batas_km * 1000) then p_tarif_dasar
    else p_tarif_dasar
      + ceil((round(p_jarak_km * 1000) - round(p_batas_km * 1000)) / round(p_kelipatan_km * 1000))::int
        * round(p_tambahan * p_kelipatan_km)::int
  end
$$;

revoke all on function public.ongkir_dari_tarif(numeric, numeric, integer, numeric, integer, numeric)
  from public, anon, authenticated;
grant execute on function public.ongkir_dari_tarif(numeric, numeric, integer, numeric, integer, numeric)
  to service_role;

-- ------------------------------------------------------------------
-- 4. create_order — signature SAMA (create or replace, hak akses tetap).
--    Perubahan vs Fase 2 hanya: validasi & penyimpanan snapshot tarif baru,
--    pesan voucher ongkir pada ongkir Rp0. Logika voucher item tidak berubah.
-- ------------------------------------------------------------------
-- p_ongkir (dihitung SERVER): { alamat_lat, alamat_lng, jarak_lurus_km,
-- jarak_rute_km, jarak_tagih_km, metode_jarak, ongkir_rupiah,
-- radius_gratis_km, tarif_dasar, batas_tarif_dasar_km, tarif_tambahan_per_km,
-- kelipatan_km }  — atau format lama dengan tarif_per_km_snapshot.
create or replace function public.create_order(
  p_customer_id     uuid,
  p_order_code      text,
  p_order_type      text,
  p_recipient_name  text,
  p_recipient_phone text,
  p_kecamatan       text,
  p_address         text,
  p_patokan         text,
  p_note            text,
  p_voucher_code    text,
  p_items           jsonb,
  p_ongkir          jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_subtotal int := 0;
  v_discount int := 0;
  v_total    int;
  v_order_id uuid;
  v_voucher  public.vouchers%rowtype;
  v_has_orders boolean;
  v_uses_by_customer int;
  v_total_uses int;
  v_item jsonb;
  -- eligibilitas per baris (voucher item)
  v_is_eligible        boolean;
  v_eligible_subtotal  int := 0;
  v_eligible_count     int := 0;
  v_eligible_seen      int := 0;
  v_used               int := 0;
  v_line_discount      int;
  v_items_out          jsonb := '[]'::jsonb;
  -- ongkir
  v_ongkir         int;
  v_diskon_ongkir  int := 0;
  v_tarif_baru     boolean := false;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'items kosong' using errcode = 'P0001';
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    if (v_item->>'unit_price') is null or (v_item->>'qty') is null
       or (v_item->>'unit_price')::int < 0 or (v_item->>'qty')::int <= 0 then
      raise exception 'item tidak valid' using errcode = 'P0001';
    end if;
    v_subtotal := v_subtotal + (v_item->>'unit_price')::int * (v_item->>'qty')::int;
  end loop;

  -- Ongkir: hanya Delivery. Kelengkapan kolom audit dijaga constraint
  -- orders_ongkir_lengkap_check saat insert di bawah.
  if p_ongkir is not null then
    if p_order_type <> 'delivery' then
      raise exception 'ongkir hanya untuk pesanan Delivery' using errcode = 'P0001';
    end if;
    v_ongkir := (p_ongkir->>'ongkir_rupiah')::int;
    if v_ongkir is null or v_ongkir < 0 then
      raise exception 'ongkir tidak valid' using errcode = 'P0001';
    end if;

    -- Tarif bertingkat: kelima parameter wajib lengkap & hasilnya wajib cocok
    -- dengan rumus SQL (menangkap selisih kode server vs DB).
    v_tarif_baru := p_ongkir ?| array['radius_gratis_km', 'tarif_dasar', 'batas_tarif_dasar_km',
                                      'tarif_tambahan_per_km', 'kelipatan_km'];
    if v_tarif_baru then
      if (p_ongkir->>'radius_gratis_km') is null or (p_ongkir->>'tarif_dasar') is null
         or (p_ongkir->>'batas_tarif_dasar_km') is null or (p_ongkir->>'tarif_tambahan_per_km') is null
         or (p_ongkir->>'kelipatan_km') is null or (p_ongkir->>'jarak_tagih_km') is null then
        raise exception 'snapshot tarif ongkir tidak lengkap' using errcode = 'P0001';
      end if;
      if v_ongkir <> public.ongkir_dari_tarif(
           (p_ongkir->>'jarak_tagih_km')::numeric,
           (p_ongkir->>'radius_gratis_km')::numeric,
           (p_ongkir->>'tarif_dasar')::int,
           (p_ongkir->>'batas_tarif_dasar_km')::numeric,
           (p_ongkir->>'tarif_tambahan_per_km')::int,
           (p_ongkir->>'kelipatan_km')::numeric) then
        raise exception 'ongkir tidak sesuai tarif' using errcode = 'P0001';
      end if;
    end if;
  end if;

  if p_voucher_code is not null and length(btrim(p_voucher_code)) > 0 then
    select * into v_voucher from public.vouchers where code = p_voucher_code for update;
    if not found or not v_voucher.active then
      raise exception 'voucher tidak berlaku' using errcode = 'P0001';
    end if;
    if v_voucher.starts_at is not null and now() < v_voucher.starts_at then
      raise exception 'voucher belum aktif' using errcode = 'P0001';
    end if;
    if v_voucher.ends_at is not null and now() > v_voucher.ends_at then
      raise exception 'voucher kedaluwarsa' using errcode = 'P0001';
    end if;
    if v_voucher.first_order_only then
      select exists(select 1 from public.orders where customer_id = p_customer_id)
        into v_has_orders;
      if v_has_orders then
        raise exception 'voucher hanya untuk pesanan pertama' using errcode = 'P0001';
      end if;
    end if;
    if v_voucher.max_uses_per_customer is not null then
      select count(*) into v_uses_by_customer from public.voucher_redemptions
        where voucher_code = p_voucher_code and customer_id = p_customer_id;
      if v_uses_by_customer >= v_voucher.max_uses_per_customer then
        raise exception 'voucher sudah mencapai batas pemakaian Anda' using errcode = 'P0001';
      end if;
    end if;
    if v_voucher.total_quota is not null then
      select count(*) into v_total_uses from public.voucher_redemptions
        where voucher_code = p_voucher_code;
      if v_total_uses >= v_voucher.total_quota then
        raise exception 'voucher sudah mencapai kuota pemakaian' using errcode = 'P0001';
      end if;
    end if;
    -- gerbang tipe pesanan, seluruh voucher (bukan per baris)
    if v_voucher.applies_to_order_types is not null
       and not (p_order_type = any(v_voucher.applies_to_order_types)) then
      raise exception 'voucher tidak berlaku untuk tipe pesanan ini' using errcode = 'P0001';
    end if;

    if v_voucher.target = 'ongkir' then
      -- Voucher ongkir: hanya Delivery dengan ongkir otomatis terhitung.
      -- (di_luar_area tak pernah sampai sini — order ditolak server.)
      if p_order_type <> 'delivery' then
        raise exception 'voucher ongkir hanya berlaku untuk pesanan Delivery' using errcode = 'P0001';
      end if;
      if v_ongkir is null then
        raise exception 'voucher ongkir hanya berlaku bila ongkir dihitung otomatis' using errcode = 'P0001';
      end if;
      if v_ongkir = 0 then
        -- exception → seluruh transaksi batal → tak ada voucher_redemptions
        raise exception 'Ongkir kamu sudah gratis, voucher ongkir tidak diperlukan' using errcode = 'P0001';
      end if;
      v_diskon_ongkir := least(
        round(v_ongkir * v_voucher.discount_percent / 100.0)::int,
        coalesce(v_voucher.maks_potongan_rupiah, v_ongkir),
        v_ongkir
      );
      -- Item tidak dipotong sama sekali: voucher_discount per baris = 0.
      v_items_out := p_items;
    else
      -- Voucher item — logika identik dengan 20260923150000 (tidak berubah):
      -- eligibilitas per baris = cocok daftar menu (bila dibatasi) DAN baris
      -- ini TIDAK sedang aktif diskon otomatisnya.
      for v_item in select * from jsonb_array_elements(p_items)
      loop
        v_is_eligible := (v_item->>'original_unit_price') is null
          and (v_voucher.applies_to_menu_ids is null
               or (v_item->>'menu_id') = any(v_voucher.applies_to_menu_ids));
        if v_is_eligible then
          v_eligible_subtotal := v_eligible_subtotal + (v_item->>'unit_price')::int * (v_item->>'qty')::int;
          v_eligible_count := v_eligible_count + 1;
        end if;
      end loop;

      if v_eligible_count = 0 then
        raise exception 'voucher tidak memotong item apa pun di keranjang Anda' using errcode = 'P0001';
      end if;

      v_discount := round(v_eligible_subtotal * v_voucher.discount_percent / 100.0);

      -- voucher_discount per baris, presisi rupiah: baris eligible TERAKHIR
      -- menyerap sisa pembulatan → sum(voucher_discount) == v_discount PERSIS.
      for v_item in select * from jsonb_array_elements(p_items)
      loop
        v_is_eligible := (v_item->>'original_unit_price') is null
          and (v_voucher.applies_to_menu_ids is null
               or (v_item->>'menu_id') = any(v_voucher.applies_to_menu_ids));
        if v_is_eligible then
          v_eligible_seen := v_eligible_seen + 1;
          if v_eligible_seen = v_eligible_count then
            v_line_discount := v_discount - v_used;
          else
            v_line_discount := round((v_item->>'unit_price')::int * (v_item->>'qty')::int * v_voucher.discount_percent / 100.0);
            v_used := v_used + v_line_discount;
          end if;
        else
          v_line_discount := 0;
        end if;
        v_items_out := v_items_out || jsonb_build_array(v_item || jsonb_build_object('voucher_discount', v_line_discount));
      end loop;
    end if;
  else
    p_voucher_code := null;
    v_items_out := p_items;
  end if;

  -- Total = subtotal − potongan item + ongkir − potongan ongkir.
  v_total := v_subtotal - v_discount + coalesce(v_ongkir, 0) - v_diskon_ongkir;

  -- verification_status tidak diisi → default kolom 'not_required' (sama
  -- dengan Fase 2).
  insert into public.orders (
    order_code, customer_id, order_type, subtotal, discount, voucher_code, total,
    recipient_name, recipient_phone, kecamatan, address, patokan, note,
    alamat_lat, alamat_lng, jarak_lurus_km, jarak_rute_km, jarak_tagih_km,
    metode_jarak, ongkir_rupiah, tarif_per_km_snapshot, diskon_ongkir,
    radius_gratis_km_snapshot, tarif_dasar_snapshot, batas_tarif_dasar_km_snapshot,
    tarif_tambahan_per_km_snapshot, kelipatan_km_snapshot
  ) values (
    p_order_code, p_customer_id, p_order_type, v_subtotal, v_discount, p_voucher_code, v_total,
    p_recipient_name, p_recipient_phone,
    nullif(btrim(coalesce(p_kecamatan, '')), ''),
    nullif(btrim(coalesce(p_address, '')), ''),
    nullif(btrim(coalesce(p_patokan, '')), ''),
    nullif(btrim(coalesce(p_note, '')), ''),
    (p_ongkir->>'alamat_lat')::numeric,
    (p_ongkir->>'alamat_lng')::numeric,
    (p_ongkir->>'jarak_lurus_km')::numeric,
    (p_ongkir->>'jarak_rute_km')::numeric,
    (p_ongkir->>'jarak_tagih_km')::numeric,
    p_ongkir->>'metode_jarak',
    v_ongkir,
    (p_ongkir->>'tarif_per_km_snapshot')::int,
    v_diskon_ongkir,
    case when v_tarif_baru then (p_ongkir->>'radius_gratis_km')::numeric end,
    case when v_tarif_baru then (p_ongkir->>'tarif_dasar')::int end,
    case when v_tarif_baru then (p_ongkir->>'batas_tarif_dasar_km')::numeric end,
    case when v_tarif_baru then (p_ongkir->>'tarif_tambahan_per_km')::int end,
    case when v_tarif_baru then (p_ongkir->>'kelipatan_km')::numeric end
  )
  returning id into v_order_id;

  insert into public.order_items (order_id, menu_id, name, unit_price, qty, options, original_unit_price, voucher_discount)
  select
    v_order_id,
    elem->>'menu_id',
    elem->>'name',
    (elem->>'unit_price')::int,
    (elem->>'qty')::int,
    coalesce(elem->'options', '{}'::jsonb),
    (elem->>'original_unit_price')::int,
    coalesce((elem->>'voucher_discount')::int, 0)
  from jsonb_array_elements(v_items_out) as elem;

  if p_voucher_code is not null then
    insert into public.voucher_redemptions (voucher_code, customer_id, order_id)
    values (p_voucher_code, p_customer_id, v_order_id);
  end if;

  return jsonb_build_object(
    'order_id',            v_order_id,
    'order_code',          p_order_code,
    'subtotal',            v_subtotal,
    'discount',            v_discount,
    'ongkir',              v_ongkir,
    'diskon_ongkir',       v_diskon_ongkir,
    'total',               v_total
  );
end;
$$;

-- create or replace mempertahankan hak akses; diulang supaya file ini
-- mandiri & aman dijalankan ulang.
revoke all on function public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb, jsonb
) from public, anon, authenticated;
grant execute on function public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb, jsonb
) to service_role;

-- ------------------------------------------------------------------
-- 5. Tawaran voucher di checkout (dibaca server lewat service_role; tabel
--    vouchers tetap tertutup untuk client publik seperti sebelumnya)
-- ------------------------------------------------------------------
alter table public.vouchers
  add column if not exists ditawarkan boolean not null default false;

commit;

-- ===================================================================== 20260927120000_label_pick_up.sql
-- Pizza Lezzato — label tipe pesanan "Take Away" → "Pick Up" di view rekap
-- owner v_pesanan (27 Sep 2026).
--
-- HANYA label tampilan (kolom `tipe`). Nilai tersimpan orders.order_type TETAP
-- 'takeaway' (constraint orders_order_type_check tak disentuh) — pesanan lama,
-- syarat voucher (applies_to_order_types), laporan, dan POS tak berubah.
-- Kolom & urutannya identik dengan 20260828090000 → create or replace aman;
-- hak akses diulang supaya file ini mandiri. Label di website: ORDER_TYPE_LABEL
-- (src/lib/order.ts).

begin;

create or replace view public.v_pesanan as
select
  o.order_code                                                    as no_pesanan,
  to_char(o.created_at at time zone 'Asia/Jakarta',
          'DD-MM-YYYY HH24:MI')                                   as waktu,
  o.status,
  case o.order_type
    when 'delivery' then 'Delivery'
    when 'takeaway' then 'Pick Up'
    when 'dinein'   then 'Dine-in'
    else o.order_type
  end                                                             as tipe,
  o.recipient_name                                                as penerima,
  o.recipient_phone                                               as hp,
  coalesce(o.kecamatan, '-')                                      as kecamatan,
  coalesce(o.address, '-')                                        as alamat,
  coalesce(o.patokan, '-')                                        as patokan,
  (select string_agg(oi.qty || 'x ' || oi.name, ', ' order by oi.name)
     from public.order_items oi where oi.order_id = o.id)         as isi_pesanan,
  coalesce(o.note, '-')                                           as catatan,
  o.subtotal,
  o.discount                                                      as diskon,
  coalesce(o.voucher_code, '-')                                   as voucher,
  o.total,
  o.payment_status                                                as pembayaran
from public.orders o
order by o.created_at desc;

revoke all on public.v_pesanan from anon, authenticated;

commit;

-- ===================================================================== 20260928090000_revoke_tabel_sensitif.sql
-- Migrasi dari supabase/APPLY_REVOKE_TABEL_SENSITIF.sql (tanpa query cek).
--
-- Pizza Lezzato — audit keamanan 28 Sep 2026, poin ⑤: cabut hak akses role
-- publik (anon = siapa pun yang memegang anon key; authenticated = tidak
-- dipakai situs ini) dari 6 tabel berisi data pelanggan/pesanan/voucher/IP.
--
-- Sebelum ini: keenam tabel masih punya GRANT bawaan Supabase ke anon &
-- authenticated. Yang menahan kebocoran hanya RLS (tanpa policy publik) —
-- satu lapis saja; kalau suatu hari RLS tak sengaja dimatikan atau ada policy
-- yang salah, datanya langsung terbuka lewat anon key. Setelah ini ada dua
-- lapis: tanpa GRANT (ditolak "permission denied") DAN RLS.
--
-- TIDAK mengubah perilaku situs: semua kode situs membaca/menulis tabel ini
-- lewat service_role (supabaseAdmin), yang tidak terpengaruh. Role pos_reader
-- (SELECT customers untuk POS) juga TIDAK disentuh. Tabel menu yang memang
-- sengaja dibuka untuk anon (menu_items, menu_categories, dst.) TIDAK disentuh.

revoke all on table
  public.orders,
  public.order_items,
  public.customers,
  public.vouchers,
  public.voucher_redemptions,
  public.auth_attempts
from anon, authenticated;

-- Jaga-jaga: pastikan RLS tetap aktif di keenam tabel (lapis kedua).
alter table public.orders              enable row level security;
alter table public.order_items         enable row level security;
alter table public.customers           enable row level security;
alter table public.vouchers            enable row level security;
alter table public.voucher_redemptions enable row level security;
alter table public.auth_attempts       enable row level security;

-- ===================================================================== 20260929090000_klik_bantuan.sql
-- Migrasi dari supabase/APPLY_KLIK_BANTUAN.sql (tanpa query cek).
--
-- Pizza Lezzato — tahap 2 (28 Sep 2026): hitung klik tombol bantuan WA.
-- Hanya mencatat DI MANA tombol diketuk, kendala apa yang sedang dialami, dan
-- apakah toko sedang tutup. TIDAK menyimpan id pelanggan, nomor HP, IP, isi
-- keranjang, atau alamat. Dibaca di dashboard admin (jumlah 7 hari terakhir).
--
-- Harus dijalankan SEBELUM deploy tahap 2. Kalau belum dijalankan, tombol
-- bantuan tetap berfungsi (WA tetap terbuka) — hanya kliknya tidak tercatat.

create table if not exists public.klik_bantuan (
  id          bigint generated always as identity primary key,
  lokasi      text not null check (lokasi in (
                'mengambang',   -- tombol "💬 Bantuan" di halaman menu/umum
                'keranjang',    -- link "Butuh bantuan? Chat admin" di isian keranjang
                'ringkasan',    -- link yang sama di layar Ringkasan
                'peta',         -- tombol di pesan pencarian alamat
                'voucher',      -- tombol di bawah pesan voucher gagal
                'luar_area'     -- "Chat admin via WhatsApp" untuk lokasi di luar area
              )),
  kendala     text check (kendala in (
                'alamat_tidak_ditemukan',
                'pencarian_tidak_tersedia',
                'voucher_gagal',
                'luar_area'
              )),
  toko_tutup  boolean not null default false,
  created_at  timestamptz not null default now()
);

create index if not exists klik_bantuan_created_at_idx on public.klik_bantuan (created_at);

-- Tertutup untuk client publik (dua lapis, seperti tabel sensitif lain):
-- ditulis & dibaca hanya lewat server (service_role).
alter table public.klik_bantuan enable row level security;
revoke all on table public.klik_bantuan from anon, authenticated;
revoke all on sequence public.klik_bantuan_id_seq from anon, authenticated;

-- Pembatas per IP untuk endpoint pencatat (supaya angka tidak bisa digelembungkan):
-- tambah aksi 'bantuan_klik' ke daftar aksi auth_attempts.
alter table public.auth_attempts
  drop constraint if exists auth_attempts_action_check;
alter table public.auth_attempts
  add constraint auth_attempts_action_check
  check (action in (
    'register', 'login', 'order', 'admin_login', 'employee_login', 'voucher_check', 'order_preview',
    'ongkir_geocode', 'ongkir_hitung', 'ors_geocode', 'ors_directions', 'bantuan_klik'
  ));

-- ===================================================================== 20260930090000_admin_keamanan.sql
-- Migrasi dari supabase/APPLY_ADMIN_KEAMANAN.sql (tanpa query cek).
--
-- Pizza Lezzato — tahap 3 (audit keamanan ③ & ⑧), skema saja:
--   1. 2FA TOTP admin (wajib untuk Owner): rahasia TOTP disimpan TERENKRIPSI
--      (kunci ADMIN_TOTP_KEY hanya di secret Cloudflare), + kode cadangan (hash).
--   2. Tabel sesi admin: setiap login = 1 baris. Dipakai untuk keluar otomatis
--      setelah tidak aktif (terakhir_aktif), batas mutlak 12 jam, dan
--      "keluarkan semua sesi" (dicabut_at) — pengganti penghitung versi sesi.
--   3. wajib_ganti_password: staf mengganti password sementara dari Owner.
--   4. Aksi baru di auth_attempts untuk batas percobaan PER AKUN
--      (password salah & kode 2FA salah dihitung per email, bukan hanya per IP).
--
-- Harus dijalankan SEBELUM deploy tahap 3. Kode lama tidak memakai kolom/tabel
-- baru ini, jadi aman dijalankan kapan saja sebelumnya.

-- 1. 2FA -------------------------------------------------------------------
alter table public.admin_users
  add column if not exists totp_rahasia_enc      text,         -- AES-GCM, base64; null = 2FA belum aktif
  add column if not exists totp_aktif_sejak      timestamptz,
  add column if not exists totp_langkah_terakhir bigint,       -- anti-replay: kode yang sama tak bisa dipakai 2x
  -- Akun staf baru / password di-reset Owner: wajib ganti password sendiri saat login berikutnya.
  add column if not exists wajib_ganti_password  boolean not null default false;

create table if not exists public.admin_kode_cadangan (
  id         bigint generated always as identity primary key,
  admin_id   uuid not null references public.admin_users(id) on delete cascade,
  kode_hash  text not null,                                     -- SHA-256 kode cadangan, kode asli tak disimpan
  dipakai_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists admin_kode_cadangan_admin_idx on public.admin_kode_cadangan (admin_id);

-- 2. Sesi admin ------------------------------------------------------------
create table if not exists public.admin_sesi (
  id             uuid primary key default gen_random_uuid(),
  admin_id       uuid not null references public.admin_users(id) on delete cascade,
  dibuat_at      timestamptz not null default now(),
  terakhir_aktif timestamptz not null default now(),
  berakhir_at    timestamptz not null,                          -- batas mutlak (12 jam)
  dicabut_at     timestamptz,
  alasan_cabut   text check (alasan_cabut in ('keluar', 'tidak_aktif', 'keluarkan_semua', 'akun_dinonaktifkan', 'password_diganti', '2fa_direset')),
  perangkat      text                                           -- ringkas dari User-Agent (mis. "Android · Chrome"); tanpa IP
);
create index if not exists admin_sesi_admin_idx on public.admin_sesi (admin_id, dicabut_at);

-- Tertutup untuk client publik (dua lapis): hanya lewat server (service_role).
alter table public.admin_kode_cadangan enable row level security;
alter table public.admin_sesi          enable row level security;
revoke all on table public.admin_kode_cadangan, public.admin_sesi from anon, authenticated;
revoke all on sequence public.admin_kode_cadangan_id_seq from anon, authenticated;

-- 4. Batas percobaan per akun ----------------------------------------------
alter table public.auth_attempts
  drop constraint if exists auth_attempts_action_check;
alter table public.auth_attempts
  add constraint auth_attempts_action_check
  check (action in (
    'register', 'login', 'order', 'admin_login', 'employee_login', 'voucher_check', 'order_preview',
    'ongkir_geocode', 'ongkir_hitung', 'ors_geocode', 'ors_directions', 'bantuan_klik',
    'admin_login_akun', 'admin_2fa'
  ));

-- ===================================================================== 20260930100000_ongkir_tahap_b.sql
-- Migrasi dari supabase/APPLY_ONGKIR_TAHAP_B.sql (tanpa query cek).
--
-- Ongkir Tahap B (30 Sep 2026): hapus kolom lama pengaturan_ongkir.tarif_per_km
-- beserta constraint-nya. Tak dibaca kode, fungsi, maupun view sejak tarif
-- bertingkat (27 Sep). orders.tarif_per_km_snapshot TIDAK disentuh (riwayat).

alter table public.pengaturan_ongkir
  drop constraint if exists pengaturan_ongkir_tarif_check;
alter table public.pengaturan_ongkir
  drop column if exists tarif_per_km;

-- ===================================================================== 20260930120000_tahap4a.sql
-- Migrasi dari supabase/APPLY_TAHAP4A.sql (tanpa query cek).
--
-- Pizza Lezzato — tahap 4a (30 Sep 2026):
--   1. customers.sesi_versi — "keluar dari semua perangkat" (sesi pelanggan 365 hari).
--   2. voucher_redemptions.phone_hash — batas voucher per pelanggan dihitung per
--      NOMOR HP (HMAC, kunci VOUCHER_HP_KEY hanya di server), bukan hanya per akun.
--   3. voucher_redemptions.customer_id: ON DELETE CASCADE → SET NULL, supaya catatan
--      pemakaian voucher TETAP ada walau akun dihapus.
--   3b. vouchers.first_order_only: bawaan kolom true → false (opsinya disembunyikan).
--   4. v_pemakaian_voucher: left join → pemakaian dari akun terhapus tetap tampil.
--   5. create_order: parameter baru p_phone_hash (default null). Versi 12 parameter
--      lama DIHAPUS di transaksi yang sama (kalau dibiarkan, panggilan jadi ambigu).
--      Kode yang live sekarang (tanpa p_phone_hash) tetap jalan: default null =
--      hitungan per akun seperti sebelumnya.
-- Baris lama (39 pemakaian) diisi phone_hash-nya oleh skrip dari laptop setelah
-- SQL ini (scripts/isi-hash-hp-voucher.mjs) — kunci HMAC tak pernah ditempel di sini.

begin;

-- 1 ------------------------------------------------------------------
alter table public.customers
  add column if not exists sesi_versi integer not null default 1;

-- 2 & 3 --------------------------------------------------------------
alter table public.voucher_redemptions
  add column if not exists phone_hash text;
create index if not exists voucher_redemptions_code_hash_idx
  on public.voucher_redemptions (voucher_code, phone_hash);

alter table public.voucher_redemptions
  alter column customer_id drop not null;
alter table public.voucher_redemptions
  drop constraint if exists voucher_redemptions_customer_id_fkey;
alter table public.voucher_redemptions
  add constraint voucher_redemptions_customer_id_fkey
  foreign key (customer_id) references public.customers(id) on delete set null;

-- 3b. Opsi "pesanan pertama" disembunyikan dari form admin → bawaan kolom jadi
--     false, supaya voucher baru tak diam-diam menjadi khusus pesanan pertama.
--     Voucher lama (mis. PESANONLINE10) tidak diubah.
alter table public.vouchers
  alter column first_order_only set default false;

-- 4 ------------------------------------------------------------------
create or replace view public.v_pemakaian_voucher as
select
  vr.voucher_code,
  coalesce(c.name, '(akun dihapus)')                          as pelanggan,
  c.phone                                                         as hp,
  o.order_code                                                    as no_pesanan,
  o.total,
  to_char(vr.redeemed_at at time zone 'Asia/Jakarta',
          'DD-MM-YYYY HH24:MI')                                   as waktu
from public.voucher_redemptions vr
left join public.customers c on c.id = vr.customer_id
join public.orders o         on o.id = vr.order_id
order by vr.redeemed_at desc;

-- 5 ------------------------------------------------------------------
drop function if exists public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb, jsonb
);

-- Isi fungsi SAMA dengan 20260927090000 (tarif bertingkat), kecuali: parameter
-- p_phone_hash, hitungan max_uses_per_customer, dan kolom phone_hash saat insert.
create or replace function public.create_order(
  p_customer_id     uuid,
  p_order_code      text,
  p_order_type      text,
  p_recipient_name  text,
  p_recipient_phone text,
  p_kecamatan       text,
  p_address         text,
  p_patokan         text,
  p_note            text,
  p_voucher_code    text,
  p_items           jsonb,
  p_ongkir          jsonb default null,
  -- Tahap 4a: HMAC nomor HP akun (dihitung server dgn VOUCHER_HP_KEY). null =
  -- kode lama (sebelum deploy 4a) → hitungan per akun saja, seperti sebelumnya.
  p_phone_hash      text  default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_subtotal int := 0;
  v_discount int := 0;
  v_total    int;
  v_order_id uuid;
  v_voucher  public.vouchers%rowtype;
  v_has_orders boolean;
  v_uses_by_customer int;
  v_total_uses int;
  v_item jsonb;
  -- eligibilitas per baris (voucher item)
  v_is_eligible        boolean;
  v_eligible_subtotal  int := 0;
  v_eligible_count     int := 0;
  v_eligible_seen      int := 0;
  v_used               int := 0;
  v_line_discount      int;
  v_items_out          jsonb := '[]'::jsonb;
  -- ongkir
  v_ongkir         int;
  v_diskon_ongkir  int := 0;
  v_tarif_baru     boolean := false;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'items kosong' using errcode = 'P0001';
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    if (v_item->>'unit_price') is null or (v_item->>'qty') is null
       or (v_item->>'unit_price')::int < 0 or (v_item->>'qty')::int <= 0 then
      raise exception 'item tidak valid' using errcode = 'P0001';
    end if;
    v_subtotal := v_subtotal + (v_item->>'unit_price')::int * (v_item->>'qty')::int;
  end loop;

  -- Ongkir: hanya Delivery. Kelengkapan kolom audit dijaga constraint
  -- orders_ongkir_lengkap_check saat insert di bawah.
  if p_ongkir is not null then
    if p_order_type <> 'delivery' then
      raise exception 'ongkir hanya untuk pesanan Delivery' using errcode = 'P0001';
    end if;
    v_ongkir := (p_ongkir->>'ongkir_rupiah')::int;
    if v_ongkir is null or v_ongkir < 0 then
      raise exception 'ongkir tidak valid' using errcode = 'P0001';
    end if;

    -- Tarif bertingkat: kelima parameter wajib lengkap & hasilnya wajib cocok
    -- dengan rumus SQL (menangkap selisih kode server vs DB).
    v_tarif_baru := p_ongkir ?| array['radius_gratis_km', 'tarif_dasar', 'batas_tarif_dasar_km',
                                      'tarif_tambahan_per_km', 'kelipatan_km'];
    if v_tarif_baru then
      if (p_ongkir->>'radius_gratis_km') is null or (p_ongkir->>'tarif_dasar') is null
         or (p_ongkir->>'batas_tarif_dasar_km') is null or (p_ongkir->>'tarif_tambahan_per_km') is null
         or (p_ongkir->>'kelipatan_km') is null or (p_ongkir->>'jarak_tagih_km') is null then
        raise exception 'snapshot tarif ongkir tidak lengkap' using errcode = 'P0001';
      end if;
      if v_ongkir <> public.ongkir_dari_tarif(
           (p_ongkir->>'jarak_tagih_km')::numeric,
           (p_ongkir->>'radius_gratis_km')::numeric,
           (p_ongkir->>'tarif_dasar')::int,
           (p_ongkir->>'batas_tarif_dasar_km')::numeric,
           (p_ongkir->>'tarif_tambahan_per_km')::int,
           (p_ongkir->>'kelipatan_km')::numeric) then
        raise exception 'ongkir tidak sesuai tarif' using errcode = 'P0001';
      end if;
    end if;
  end if;

  if p_voucher_code is not null and length(btrim(p_voucher_code)) > 0 then
    select * into v_voucher from public.vouchers where code = p_voucher_code for update;
    if not found or not v_voucher.active then
      raise exception 'voucher tidak berlaku' using errcode = 'P0001';
    end if;
    if v_voucher.starts_at is not null and now() < v_voucher.starts_at then
      raise exception 'voucher belum aktif' using errcode = 'P0001';
    end if;
    if v_voucher.ends_at is not null and now() > v_voucher.ends_at then
      raise exception 'voucher kedaluwarsa' using errcode = 'P0001';
    end if;
    if v_voucher.first_order_only then
      select exists(select 1 from public.orders where customer_id = p_customer_id)
        into v_has_orders;
      if v_has_orders then
        raise exception 'voucher hanya untuk pesanan pertama' using errcode = 'P0001';
      end if;
    end if;
    if v_voucher.max_uses_per_customer is not null then
      -- Per PELANGGAN = per akun ATAU per nomor HP (hash): hapus akun lalu daftar
      -- ulang dengan nomor yang sama tetap terhitung.
      select count(*) into v_uses_by_customer from public.voucher_redemptions
        where voucher_code = p_voucher_code
          and (customer_id = p_customer_id
               or (p_phone_hash is not null and phone_hash = p_phone_hash));
      if v_uses_by_customer >= v_voucher.max_uses_per_customer then
        raise exception 'voucher sudah mencapai batas pemakaian Anda' using errcode = 'P0001';
      end if;
    end if;
    if v_voucher.total_quota is not null then
      select count(*) into v_total_uses from public.voucher_redemptions
        where voucher_code = p_voucher_code;
      if v_total_uses >= v_voucher.total_quota then
        raise exception 'voucher sudah mencapai kuota pemakaian' using errcode = 'P0001';
      end if;
    end if;
    -- gerbang tipe pesanan, seluruh voucher (bukan per baris)
    if v_voucher.applies_to_order_types is not null
       and not (p_order_type = any(v_voucher.applies_to_order_types)) then
      raise exception 'voucher tidak berlaku untuk tipe pesanan ini' using errcode = 'P0001';
    end if;

    if v_voucher.target = 'ongkir' then
      -- Voucher ongkir: hanya Delivery dengan ongkir otomatis terhitung.
      -- (di_luar_area tak pernah sampai sini — order ditolak server.)
      if p_order_type <> 'delivery' then
        raise exception 'voucher ongkir hanya berlaku untuk pesanan Delivery' using errcode = 'P0001';
      end if;
      if v_ongkir is null then
        raise exception 'voucher ongkir hanya berlaku bila ongkir dihitung otomatis' using errcode = 'P0001';
      end if;
      if v_ongkir = 0 then
        -- exception → seluruh transaksi batal → tak ada voucher_redemptions
        raise exception 'Ongkir kamu sudah gratis, voucher ongkir tidak diperlukan' using errcode = 'P0001';
      end if;
      v_diskon_ongkir := least(
        round(v_ongkir * v_voucher.discount_percent / 100.0)::int,
        coalesce(v_voucher.maks_potongan_rupiah, v_ongkir),
        v_ongkir
      );
      -- Item tidak dipotong sama sekali: voucher_discount per baris = 0.
      v_items_out := p_items;
    else
      -- Voucher item — logika identik dengan 20260923150000 (tidak berubah):
      -- eligibilitas per baris = cocok daftar menu (bila dibatasi) DAN baris
      -- ini TIDAK sedang aktif diskon otomatisnya.
      for v_item in select * from jsonb_array_elements(p_items)
      loop
        v_is_eligible := (v_item->>'original_unit_price') is null
          and (v_voucher.applies_to_menu_ids is null
               or (v_item->>'menu_id') = any(v_voucher.applies_to_menu_ids));
        if v_is_eligible then
          v_eligible_subtotal := v_eligible_subtotal + (v_item->>'unit_price')::int * (v_item->>'qty')::int;
          v_eligible_count := v_eligible_count + 1;
        end if;
      end loop;

      if v_eligible_count = 0 then
        raise exception 'voucher tidak memotong item apa pun di keranjang Anda' using errcode = 'P0001';
      end if;

      v_discount := round(v_eligible_subtotal * v_voucher.discount_percent / 100.0);

      -- voucher_discount per baris, presisi rupiah: baris eligible TERAKHIR
      -- menyerap sisa pembulatan → sum(voucher_discount) == v_discount PERSIS.
      for v_item in select * from jsonb_array_elements(p_items)
      loop
        v_is_eligible := (v_item->>'original_unit_price') is null
          and (v_voucher.applies_to_menu_ids is null
               or (v_item->>'menu_id') = any(v_voucher.applies_to_menu_ids));
        if v_is_eligible then
          v_eligible_seen := v_eligible_seen + 1;
          if v_eligible_seen = v_eligible_count then
            v_line_discount := v_discount - v_used;
          else
            v_line_discount := round((v_item->>'unit_price')::int * (v_item->>'qty')::int * v_voucher.discount_percent / 100.0);
            v_used := v_used + v_line_discount;
          end if;
        else
          v_line_discount := 0;
        end if;
        v_items_out := v_items_out || jsonb_build_array(v_item || jsonb_build_object('voucher_discount', v_line_discount));
      end loop;
    end if;
  else
    p_voucher_code := null;
    v_items_out := p_items;
  end if;

  -- Total = subtotal − potongan item + ongkir − potongan ongkir.
  v_total := v_subtotal - v_discount + coalesce(v_ongkir, 0) - v_diskon_ongkir;

  -- verification_status tidak diisi → default kolom 'not_required' (sama
  -- dengan Fase 2).
  insert into public.orders (
    order_code, customer_id, order_type, subtotal, discount, voucher_code, total,
    recipient_name, recipient_phone, kecamatan, address, patokan, note,
    alamat_lat, alamat_lng, jarak_lurus_km, jarak_rute_km, jarak_tagih_km,
    metode_jarak, ongkir_rupiah, tarif_per_km_snapshot, diskon_ongkir,
    radius_gratis_km_snapshot, tarif_dasar_snapshot, batas_tarif_dasar_km_snapshot,
    tarif_tambahan_per_km_snapshot, kelipatan_km_snapshot
  ) values (
    p_order_code, p_customer_id, p_order_type, v_subtotal, v_discount, p_voucher_code, v_total,
    p_recipient_name, p_recipient_phone,
    nullif(btrim(coalesce(p_kecamatan, '')), ''),
    nullif(btrim(coalesce(p_address, '')), ''),
    nullif(btrim(coalesce(p_patokan, '')), ''),
    nullif(btrim(coalesce(p_note, '')), ''),
    (p_ongkir->>'alamat_lat')::numeric,
    (p_ongkir->>'alamat_lng')::numeric,
    (p_ongkir->>'jarak_lurus_km')::numeric,
    (p_ongkir->>'jarak_rute_km')::numeric,
    (p_ongkir->>'jarak_tagih_km')::numeric,
    p_ongkir->>'metode_jarak',
    v_ongkir,
    (p_ongkir->>'tarif_per_km_snapshot')::int,
    v_diskon_ongkir,
    case when v_tarif_baru then (p_ongkir->>'radius_gratis_km')::numeric end,
    case when v_tarif_baru then (p_ongkir->>'tarif_dasar')::int end,
    case when v_tarif_baru then (p_ongkir->>'batas_tarif_dasar_km')::numeric end,
    case when v_tarif_baru then (p_ongkir->>'tarif_tambahan_per_km')::int end,
    case when v_tarif_baru then (p_ongkir->>'kelipatan_km')::numeric end
  )
  returning id into v_order_id;

  insert into public.order_items (order_id, menu_id, name, unit_price, qty, options, original_unit_price, voucher_discount)
  select
    v_order_id,
    elem->>'menu_id',
    elem->>'name',
    (elem->>'unit_price')::int,
    (elem->>'qty')::int,
    coalesce(elem->'options', '{}'::jsonb),
    (elem->>'original_unit_price')::int,
    coalesce((elem->>'voucher_discount')::int, 0)
  from jsonb_array_elements(v_items_out) as elem;

  if p_voucher_code is not null then
    insert into public.voucher_redemptions (voucher_code, customer_id, order_id, phone_hash)
    values (p_voucher_code, p_customer_id, v_order_id, p_phone_hash);
  end if;

  return jsonb_build_object(
    'order_id',            v_order_id,
    'order_code',          p_order_code,
    'subtotal',            v_subtotal,
    'discount',            v_discount,
    'ongkir',              v_ongkir,
    'diskon_ongkir',       v_diskon_ongkir,
    'total',               v_total
  );
end;
$$;

revoke all on function public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb, jsonb, text
) from public, anon, authenticated;
grant execute on function public.create_order(
  uuid, text, text, text, text, text, text, text, text, text, jsonb, jsonb, text
) to service_role;

commit;

-- ===================================================================== 20260930150000_tahap5a_pembersihan.sql
-- Tahap 5A (30 Sep 2026): izin kolom pos_reader + pembersihan otomatis auth_attempts (pg_cron).
-- Salinan inti supabase/APPLY_TAHAP5A.sql (tanpa pembersihan pertama & cek hasil).
-- Catatan uji PGlite: baris create extension pg_cron harus diganti tiruan skema cron.

-- 1. pos_reader: hanya boleh membaca 6 kolom customers yang dipakai POS
--    (sync-customers: id, name, phone, default_address, default_patokan,
--    phone_verified). Kolom lain (created_at, phone_verified_at,
--    phone_verified_by, sesi_versi) tidak lagi terbaca.
-- 2. Pembersihan otomatis auth_attempts (pg_cron, tiap hari 03.15 WIB):
--      - catatan LOGIN (login, register, admin_login, admin_login_akun,
--        admin_2fa, employee_login) → dihapus setelah 30 hari
--      - catatan PEMBATAS lainnya (ors_*, ongkir_*, voucher_check,
--        order_preview, order, bantuan_klik) → dihapus setelah 2 hari
--        (jendela terpanjang yang dipakai kode = 24 jam kuota ORS)
--    Aksi baru di masa depan otomatis masuk kelompok PEMBATAS (2 hari);
--    kalau aksi baru butuh jendela > 2 hari, ubah daftar di fungsi ini.
-- 3. Pembersihan pertama langsung dijalankan di baris hasil paling bawah.
--
-- Hasil yang diharapkan (satu baris):
--   pos_reader_seluruh_tabel = false, pos_reader_kolom_dipakai = true,
--   pos_reader_kolom_lain = false, jadwal_cron = '15 20 * * *',
--   anon_bisa_jalankan = false, authenticated_bisa_jalankan = false,
--   hasil_pembersihan = {"login": 0, "pembatas": ±600} (run ulang: 0/0),
--   pembatas_tertua_jam <= 48, login_tertua_hari <= 30
-- =====================================================================

-- 1. pos_reader: izin per kolom -----------------------------------------
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'pos_reader') then
    execute 'revoke select on public.customers from pos_reader';
    execute 'grant select (id, name, phone, default_address, default_patokan, phone_verified)
             on public.customers to pos_reader';
  end if;
end
$$;

-- 2. Fungsi pembersih auth_attempts -------------------------------------
create or replace function public.bersihkan_auth_attempts()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_aksi_login constant text[] := array['login', 'register', 'admin_login', 'admin_login_akun', 'admin_2fa', 'employee_login'];
  v_login int;
  v_pembatas int;
begin
  delete from public.auth_attempts
   where action = any (v_aksi_login)
     and created_at < now() - interval '30 days';
  get diagnostics v_login = row_count;

  delete from public.auth_attempts
   where not (action = any (v_aksi_login))
     and created_at < now() - interval '2 days';
  get diagnostics v_pembatas = row_count;

  return jsonb_build_object('login', v_login, 'pembatas', v_pembatas);
end;
$$;

-- Hanya pemilik (postgres, dipakai pg_cron) yang boleh menjalankan.
revoke all on function public.bersihkan_auth_attempts() from public;
revoke all on function public.bersihkan_auth_attempts() from anon, authenticated;

-- 3. pg_cron: jadwal harian 20.15 UTC = 03.15 WIB ------------------------
-- (tiruan) create extension if not exists pg_cron;

-- cron.schedule dengan nama yang sama memperbarui jadwal (tidak dobel).
select cron.schedule(
  'bersihkan-auth-attempts',
  '15 20 * * *',
  $cron$select public.bersihkan_auth_attempts()$cron$
);

-- ===================================================================== 20260930160000_tahap5b_admin_audit.sql
-- Tahap 5B (30 Sep 2026): admin_audit append-only + pembersihan 24 bulan (pg_cron).
-- Salinan inti supabase/APPLY_TAHAP5B.sql (tanpa cek hasil).

-- 1. Tabel ----------------------------------------------------------------
create table if not exists public.admin_audit (
  id           bigint generated always as identity primary key,
  changed_at   timestamptz not null default now(),
  admin_id     uuid,                 -- tanpa FK: riwayat tetap ada walau akun admin dihapus
  admin_email  text not null,
  admin_role   text,                 -- 'owner' | 'admin' (Frontliner) saat aksi dilakukan
  action       text not null,        -- mis. 'masuk.berhasil', 'akun.buat', 'ongkir.pengaturan'
  target       text,                 -- mis. email akun, kode voucher, kode pesanan
  summary      text not null,        -- ringkasan yang dibaca manusia
  details      jsonb,                -- sebelum/sesudah seperlunya — TIDAK PERNAH password/kode 2FA
  ip           text
);
create index if not exists admin_audit_waktu_idx on public.admin_audit (changed_at desc);
create index if not exists admin_audit_admin_waktu_idx on public.admin_audit (admin_email, changed_at desc);

alter table public.admin_audit enable row level security;

-- 2. Izin: service_role hanya baca & tambah -------------------------------
revoke all on public.admin_audit from public;
revoke all on public.admin_audit from anon, authenticated, service_role;
grant select, insert on public.admin_audit to service_role;

-- 3. Trigger penjaga (lapis kedua) ------------------------------------------
create or replace function public.admin_audit_jaga()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.changed_at := now();         -- waktu dari server DB, bukan dari pengirim
    return new;
  end if;
  if tg_op = 'DELETE'
     and current_setting('lezzato.hapus_audit_lama', true) = 'ya'
     and old.changed_at < now() - interval '24 months' then
    return old;                      -- hanya lewat bersihkan_admin_audit()
  end if;
  raise exception 'admin_audit hanya bisa ditambah: % ditolak', tg_op
    using errcode = '42501';
end;
$$;

create or replace function public.admin_audit_tolak_truncate()
returns trigger
language plpgsql
as $$
begin
  raise exception 'admin_audit hanya bisa ditambah: TRUNCATE ditolak'
    using errcode = '42501';
end;
$$;

drop trigger if exists admin_audit_jaga on public.admin_audit;
create trigger admin_audit_jaga
  before insert or update or delete on public.admin_audit
  for each row execute function public.admin_audit_jaga();

drop trigger if exists admin_audit_tolak_truncate on public.admin_audit;
create trigger admin_audit_tolak_truncate
  before truncate on public.admin_audit
  for each statement execute function public.admin_audit_tolak_truncate();

-- 4. Pembersihan 24 bulan (satu-satunya jalan hapus) ------------------------
create or replace function public.bersihkan_admin_audit()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  -- Penanda berlaku sampai akhir transaksi ini saja (is_local = true).
  perform set_config('lezzato.hapus_audit_lama', 'ya', true);
  delete from public.admin_audit where changed_at < now() - interval '24 months';
  get diagnostics v_n = row_count;
  perform set_config('lezzato.hapus_audit_lama', '', true);
  return v_n;
end;
$$;

revoke all on function public.bersihkan_admin_audit() from public;
revoke all on function public.bersihkan_admin_audit() from anon, authenticated, service_role;
revoke all on function public.admin_audit_jaga() from public, anon, authenticated, service_role;
revoke all on function public.admin_audit_tolak_truncate() from public, anon, authenticated, service_role;

-- 20.30 UTC = 03.30 WIB (15 menit setelah bersihkan-auth-attempts).
select cron.schedule(
  'bersihkan-admin-audit',
  '30 20 * * *',
  $cron$select public.bersihkan_admin_audit()$cron$
);

-- ===================================================================== 20260930170000_daftar_alamat.sql
-- Daftar Alamat B1 (30 Sep 2026): alamat_pelanggan + cermin ke customers.default_* & customer_lokasi_default.
-- Salinan inti supabase/APPLY_DAFTAR_ALAMAT.sql (tanpa begin/commit & cek hasil). Dijalankan Owner 30 Sep.

-- 1. Tabel ---------------------------------------------------------------
create table if not exists public.alamat_pelanggan (
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  label       text not null check (length(btrim(label)) between 1 and 30),
  alamat      text not null check (length(btrim(alamat)) between 1 and 500),
  patokan     text check (patokan is null or length(patokan) <= 200),
  lat         numeric(9,6) check (lat between -90 and 90),
  lng         numeric(9,6) check (lng between -180 and 180),
  utama       boolean not null default false,
  sumber      text not null default 'pelanggan' check (sumber in ('pelanggan', 'admin', 'migrasi', 'sistem')),
  dibuat_at   timestamptz not null default now(),
  diubah_at   timestamptz not null default now(),
  constraint alamat_pelanggan_pin_lengkap check ((lat is null) = (lng is null))
);
create unique index if not exists alamat_pelanggan_satu_utama on public.alamat_pelanggan (customer_id) where utama;
create unique index if not exists alamat_pelanggan_label_unik on public.alamat_pelanggan (customer_id, lower(btrim(label)));
create index if not exists alamat_pelanggan_customer_idx on public.alamat_pelanggan (customer_id, dibuat_at);

-- Tertutup seperti customer_lokasi_default: hanya server (service_role).
alter table public.alamat_pelanggan enable row level security;
revoke all on public.alamat_pelanggan from public;
revoke all on public.alamat_pelanggan from anon, authenticated;
grant select, insert, update, delete on public.alamat_pelanggan to service_role;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'pos_reader') then
    execute 'revoke all on public.alamat_pelanggan from pos_reader';
  end if;
end
$$;

-- 2. Aturan daftar: maks. 5, satu utama, pindah utama otomatis -------------
create or replace function public.alamat_pelanggan_sebelum()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    -- Kunci per pelanggan: dua penambahan bersamaan tidak bisa melewati batas 5.
    perform pg_advisory_xact_lock(hashtextextended('alamat_pelanggan:' || new.customer_id::text, 0));
    if (select count(*) from public.alamat_pelanggan where customer_id = new.customer_id) >= 5 then
      raise exception 'Daftar alamat sudah penuh (maksimal 5).' using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.alamat_pelanggan where customer_id = new.customer_id and utama) then
      new.utama := true;                    -- alamat pertama selalu utama
    elsif new.utama then
      update public.alamat_pelanggan set utama = false where customer_id = new.customer_id and utama;
    end if;
    new.dibuat_at := now();
  else
    if new.customer_id <> old.customer_id then
      raise exception 'Alamat tidak bisa dipindah ke pelanggan lain.' using errcode = 'P0001';
    end if;
    if new.utama and not old.utama then     -- "Jadikan utama": yang lama otomatis turun
      update public.alamat_pelanggan set utama = false
        where customer_id = new.customer_id and utama and id <> new.id;
    end if;
  end if;
  new.label := btrim(new.label);
  new.alamat := btrim(new.alamat);
  new.patokan := nullif(btrim(coalesce(new.patokan, '')), '');
  new.diubah_at := now();
  return new;
end;
$$;

drop trigger if exists alamat_pelanggan_sebelum on public.alamat_pelanggan;
create trigger alamat_pelanggan_sebelum
  before insert or update on public.alamat_pelanggan
  for each row execute function public.alamat_pelanggan_sebelum();

-- Alamat utama dihapus → alamat yang paling baru ditambahkan jadi utama.
create or replace function public.alamat_pelanggan_sesudah_hapus()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.utama then
    update public.alamat_pelanggan set utama = true
      where id = (select id from public.alamat_pelanggan
                  where customer_id = old.customer_id
                  order by dibuat_at desc, id desc limit 1);
  end if;
  return null;
end;
$$;

drop trigger if exists alamat_pelanggan_sesudah_hapus on public.alamat_pelanggan;
create trigger alamat_pelanggan_sesudah_hapus
  after delete on public.alamat_pelanggan
  for each row execute function public.alamat_pelanggan_sesudah_hapus();

-- 3. Cermin ke customers.default_* & customer_lokasi_default ---------------
create or replace function public.alamat_pelanggan_cermin(p_customer_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_jumlah int;
  u public.alamat_pelanggan%rowtype;
begin
  select count(*) into v_jumlah from public.alamat_pelanggan where customer_id = p_customer_id;
  select * into u from public.alamat_pelanggan where customer_id = p_customer_id and utama;
  if v_jumlah > 0 and u.id is null then
    raise exception 'Harus ada satu alamat utama.' using errcode = 'P0001';
  end if;

  update public.customers
    set default_address = u.alamat, default_patokan = u.patokan
    where id = p_customer_id
      and (default_address is distinct from u.alamat or default_patokan is distinct from u.patokan);

  if u.id is not null and u.lat is not null then
    insert into public.customer_lokasi_default (customer_id, alamat, patokan, lat, lng, updated_at)
    values (p_customer_id, u.alamat, u.patokan, u.lat, u.lng, now())
    on conflict (customer_id) do update
      set alamat = excluded.alamat, patokan = excluded.patokan, lat = excluded.lat, lng = excluded.lng, updated_at = now()
      where (customer_lokasi_default.alamat, customer_lokasi_default.patokan, customer_lokasi_default.lat, customer_lokasi_default.lng)
            is distinct from (excluded.alamat, excluded.patokan, excluded.lat, excluded.lng);
  else
    delete from public.customer_lokasi_default where customer_id = p_customer_id;
  end if;
end;
$$;

create or replace function public.alamat_pelanggan_selesai()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.alamat_pelanggan_cermin(case when tg_op = 'DELETE' then old.customer_id else new.customer_id end);
  return null;
end;
$$;

drop trigger if exists alamat_pelanggan_selesai on public.alamat_pelanggan;
create constraint trigger alamat_pelanggan_selesai
  after insert or update or delete on public.alamat_pelanggan
  deferrable initially deferred
  for each row execute function public.alamat_pelanggan_selesai();

-- 4. Pindahkan alamat default yang ada jadi alamat pertama ("Rumah") --------
insert into public.alamat_pelanggan (customer_id, label, alamat, patokan, lat, lng, utama, sumber)
select c.id, 'Rumah', btrim(c.default_address), c.default_patokan, l.lat, l.lng, true, 'migrasi'
from public.customers c
left join public.customer_lokasi_default l on l.customer_id = c.id and l.alamat = c.default_address
where nullif(btrim(coalesce(c.default_address, '')), '') is not null
  and not exists (select 1 from public.alamat_pelanggan a where a.customer_id = c.id);

-- 5. Jalur lama → alamat utama ---------------------------------------------
-- 5a. Tulis langsung ke customers.default_* (edit pelanggan oleh admin, daftar
--     akun baru dgn alamat, SQL Editor) diteruskan ke alamat utama. Tidak
--     berlaku saat perubahan itu sendiri datang dari cermin (pg_trigger_depth > 1).
create or replace function public.customers_ke_alamat_pelanggan()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_alamat  text := nullif(btrim(coalesce(new.default_address, '')), '');
  v_patokan text := nullif(btrim(coalesce(new.default_patokan, '')), '');
  u public.alamat_pelanggan%rowtype;
begin
  if pg_trigger_depth() > 1 then
    return null;
  end if;
  if tg_op = 'UPDATE'
     and new.default_address is not distinct from old.default_address
     and new.default_patokan is not distinct from old.default_patokan then
    return null;
  end if;
  select * into u from public.alamat_pelanggan where customer_id = new.id and utama;
  if v_alamat is null then
    if u.id is not null then
      delete from public.alamat_pelanggan where id = u.id;
    end if;
  elsif u.id is null then
    insert into public.alamat_pelanggan (customer_id, label, alamat, patokan, utama, sumber)
    values (new.id, 'Rumah', v_alamat, v_patokan, true, 'sistem');
  elsif u.alamat is distinct from v_alamat then
    -- teks berubah → pin lama tak lagi mewakili alamat ini (aturan lama tetap)
    update public.alamat_pelanggan set alamat = v_alamat, patokan = v_patokan, lat = null, lng = null where id = u.id;
  elsif u.patokan is distinct from v_patokan then
    update public.alamat_pelanggan set patokan = v_patokan where id = u.id;
  end if;
  return null;
end;
$$;

-- Trigger lama digantikan (logikanya kini di alamat_pelanggan + cermin).
drop trigger if exists customers_sinkron_lokasi_default on public.customers;
drop trigger if exists customers_ke_alamat_pelanggan on public.customers;
create trigger customers_ke_alamat_pelanggan
  after insert or update of default_address, default_patokan on public.customers
  for each row execute function public.customers_ke_alamat_pelanggan();

-- 5b. simpan_alamat_default (kode website saat ini) → menulis alamat utama.
--     Arti tetap sama: dgn pin = alamat berpin; tanpa pin = teks saja (pin
--     lama dibuang); alamat kosong = hapus alamat utama.
create or replace function public.simpan_alamat_default(
  p_customer_id uuid,
  p_alamat      text,
  p_patokan     text,
  p_lat         numeric default null,
  p_lng         numeric default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_alamat  text := nullif(btrim(coalesce(p_alamat, '')), '');
  v_patokan text := nullif(btrim(coalesce(p_patokan, '')), '');
  v_id uuid;
begin
  if (p_lat is null) <> (p_lng is null) then
    raise exception 'koordinat tidak lengkap' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'pelanggan tidak ditemukan' using errcode = 'P0001';
  end if;
  if v_alamat is null and p_lat is not null then
    raise exception 'alamat wajib diisi untuk menyimpan pin' using errcode = 'P0001';
  end if;

  select id into v_id from public.alamat_pelanggan where customer_id = p_customer_id and utama;
  if v_alamat is null then
    delete from public.alamat_pelanggan where id = v_id;
  elsif v_id is null then
    insert into public.alamat_pelanggan (customer_id, label, alamat, patokan, lat, lng, utama, sumber)
    values (p_customer_id, 'Rumah', v_alamat, v_patokan, p_lat, p_lng, true, 'pelanggan');
  else
    update public.alamat_pelanggan
      set alamat = v_alamat, patokan = v_patokan, lat = p_lat, lng = p_lng
      where id = v_id;
  end if;
end;
$$;

revoke all on function public.simpan_alamat_default(uuid, text, text, numeric, numeric) from public, anon, authenticated;
grant execute on function public.simpan_alamat_default(uuid, text, text, numeric, numeric) to service_role;
revoke all on function public.alamat_pelanggan_sebelum() from public, anon, authenticated;
revoke all on function public.alamat_pelanggan_sesudah_hapus() from public, anon, authenticated;
revoke all on function public.alamat_pelanggan_cermin(uuid) from public, anon, authenticated;
revoke all on function public.alamat_pelanggan_selesai() from public, anon, authenticated;
revoke all on function public.customers_ke_alamat_pelanggan() from public, anon, authenticated;

-- ===================================================================== 20261005090000_b3_hapus_lokasi_default.sql
-- B3 (5 Okt 2026): hapus customer_lokasi_default; cermin alamat utama hanya ke customers.default_* (POS).
-- Salinan inti supabase/APPLY_B3_HAPUS_LOKASI_DEFAULT.sql (tanpa begin/commit & cek hasil). Dijalankan Owner 5 Okt.

-- 0. Penjaga ------------------------------------------------------------------
do $$
declare
  v_beda int;
begin
  if to_regclass('public.customer_lokasi_default') is not null then
    execute $q$
      select count(*)
      from public.customer_lokasi_default l
      left join public.alamat_pelanggan a on a.customer_id = l.customer_id and a.utama
      where a.id is null or (a.lat, a.lng) is distinct from (l.lat, l.lng)
    $q$ into v_beda;
    if v_beda > 0 then
      raise exception 'B3 dibatalkan: % baris customer_lokasi_default tidak cocok dengan pin alamat utama. Tidak ada yang diubah.', v_beda;
    end if;
  end if;
end
$$;

-- 1. Cermin: hanya ke customers.default_* (POS) ---------------------------------
create or replace function public.alamat_pelanggan_cermin(p_customer_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_jumlah int;
  u public.alamat_pelanggan%rowtype;
begin
  select count(*) into v_jumlah from public.alamat_pelanggan where customer_id = p_customer_id;
  select * into u from public.alamat_pelanggan where customer_id = p_customer_id and utama;
  if v_jumlah > 0 and u.id is null then
    raise exception 'Harus ada satu alamat utama.' using errcode = 'P0001';
  end if;

  -- Alamat utama → customers.default_address / default_patokan (dibaca POS).
  update public.customers
    set default_address = u.alamat, default_patokan = u.patokan
    where id = p_customer_id
      and (default_address is distinct from u.alamat or default_patokan is distinct from u.patokan);
end;
$$;

revoke all on function public.alamat_pelanggan_cermin(uuid) from public, anon, authenticated;

-- 2 & 3. Hapus fungsi yatim & tabel -------------------------------------------
drop function if exists public.sinkron_lokasi_default();
drop table if exists public.customer_lokasi_default restrict;

-- ===================================================================== 20261005140000_pizza_kotak.sql
-- Tempel & Run di Supabase SQL Editor. Aman dijalankan ulang.
--
-- Pizza Lezzato — koleksi "Signature Collection" berganti nama "Pizza Kotak" dan
-- pindah ke urutan PALING ATAS di kelompok Pizza (di atas Beef, Chicken, Umami).
-- (Owner, 5 Okt 2026)
--
-- Hanya DATA (label & sort_order) di menu_categories/menu_sections — tabel yang
-- menentukan urutan tampil website DAN disalin POS (sync-menu). Kunci
-- 'pizza-signature' SENGAJA tidak diganti (menu_items.category_slug/section_key,
-- cache POS, pesanan lama). Judul/deskripsi/alamat halaman website ada di kode
-- (lib/menu/groups.ts; /menu/pizza-signature → /menu/pizza-kotak).
--
-- Urutan baru (sebelumnya beef 3, chicken 4, umami 5, signature 6):
--   pizza-signature 3, pizza-beef 4, pizza-chicken 5, pizza-umami 6.
-- Kategori/section lain tidak disentuh (paket 0–2, pendamping-zuppa mulai 7).

begin;

update public.menu_categories
   set label = 'Pizza Kotak'
 where slug = 'pizza-signature' and label is distinct from 'Pizza Kotak';
update public.menu_sections
   set label = 'Pizza Kotak'
 where key = 'pizza-signature' and label is distinct from 'Pizza Kotak';

update public.menu_categories c
   set sort_order = v.urut
  from (values ('pizza-signature', 3), ('pizza-beef', 4), ('pizza-chicken', 5), ('pizza-umami', 6)) v(slug, urut)
 where c.slug = v.slug and c.sort_order is distinct from v.urut;
update public.menu_sections s
   set sort_order = v.urut
  from (values ('pizza-signature', 3), ('pizza-beef', 4), ('pizza-chicken', 5), ('pizza-umami', 6)) v(key, urut)
 where s.key = v.key and s.sort_order is distinct from v.urut;

commit;

-- Hasil — harus: 4 baris kategori & 4 baris section, Pizza Kotak di urutan 3.
select 'kategori' as tabel, slug as kunci, label, sort_order
  from public.menu_categories where slug like 'pizza-%'
union all
select 'section', key, label, sort_order
  from public.menu_sections where key like 'pizza-%'
order by tabel, sort_order;

-- ===================================================================== 20261006090000_attendance_logs_catat_manual.sql
-- Pizza Lezzato — Absensi: "Catat Absen Manual" (Owner). Karyawan lupa absen tapi
-- terbukti hadir (dikonfirmasi supervisor): Owner menyisipkan baris attendance_logs
-- pengganti scan QR, dgn jejak audit, tanpa memotong kuota cuti.
--
-- Kontrak utk RPC payroll: baris dicatat_manual = true adalah kehadiran sah; `status`
-- dihitung normal terhadap roster; aturan status_efektif = coalesce(status_override,
-- status) tak berubah; kolom dicatat_* hanya utk audit/sengketa. Baris manual TIDAK
-- punya GPS (latitude/longitude/jarak_dari_outlet = NULL) — bukan 0.
--
-- Aman diulang. Satu transaksi.
begin;

alter table public.attendance_logs
  alter column latitude drop not null,
  alter column longitude drop not null,
  alter column jarak_dari_outlet drop not null,
  add column if not exists dicatat_manual boolean not null default false,
  add column if not exists dicatat_oleh uuid references public.employees(id),
  add column if not exists dicatat_pada timestamptz,
  add column if not exists dicatat_alasan text;

-- Baris manual WAJIB berjejak audit lengkap (dijamin DB, bukan hanya aplikasi).
alter table public.attendance_logs drop constraint if exists attendance_logs_audit_manual_chk;
alter table public.attendance_logs add constraint attendance_logs_audit_manual_chk
  check (
    not dicatat_manual
    or (dicatat_oleh is not null and dicatat_pada is not null
        and dicatat_alasan is not null and length(btrim(dicatat_alasan)) > 0)
  );

-- Baris scan QR asli (bukan manual) tetap WAJIB berkoordinat lengkap.
alter table public.attendance_logs drop constraint if exists attendance_logs_koordinat_chk;
alter table public.attendance_logs add constraint attendance_logs_koordinat_chk
  check (
    dicatat_manual
    or (latitude is not null and longitude is not null and jarak_dari_outlet is not null)
  );

commit;

-- ===================================================================== 20261013120000_kontrak_pos_1a_kolom.sql
-- Migrasi dari supabase/APPLY_KONTRAK_POS_1A_KOLOM.sql (tanpa potret & query bukti). 1A dijalankan Owner 13 Okt ±12.0x WIB dgn outlet.lat/lng double precision, lalu 1A2 (±12.08) mengubahnya ke
-- numeric. Salinan ini memakai numeric langsung = keadaan akhir produksi (1A2 menjadi tanpa-perubahan).
--
-- =====================================================================
-- KONTRAK POS 1A — kolom & tabel pendukung (docs/KONTRAK-DATA-POS.md §2.0, §2.2, §2.3, §2.4)
-- Jalankan di Supabase SQL Editor SEBELUM 1B dan 1C. Aman diulang.
--
-- Isi (SEMUA hanya MENAMBAH; tidak ada data lama yang diubah):
--   1. orders: 9 kolom baru (ringkasan pembayaran + penanda "diubah kasir"), semua
--      ber-default → create_order & kode website lama tidak perlu tahu.
--   2. customers.updated_at + trigger (sinkron pelanggan POS inkremental).
--   3. Indeks orders(updated_at) & customers(updated_at) (kursor POS).
--   4. pengaturan_pos (singleton, go_live_at = NULL = belum go-live).
--   5. outlet (koordinat outlet satu sumber; baris 'lobak' = konstanta kode sekarang).
--   6. pesanan_pos(created_at) — satu aturan "pesanan POS" (selalu false selama go_live_at NULL).
--   7. pembayaran (kosong; disiapkan untuk Midtrans / Proyek B).
--   8. order_status_log (hanya-tambah) + trigger yang mencatat setiap perubahan status.
--
-- Untuk situs yang sedang berjalan: aman. Kolom baru ber-default, tabel baru tak dibaca kode
-- lama, trigger baru hanya MENCATAT (tidak pernah menolak). Satu-satunya efek yang terlihat:
-- setiap ubah status pesanan menambah 1 baris order_status_log.
--
-- Hasil yang diharapkan (baris SELECT terakhir):
--   kolom_orders_baru = 9, customers_updated_at_kosong = 0, go_live_at = null, outlet_utama = 1,
--   outlet_lat = 0.47939978361032837, outlet_lng = 101.40879003237194 (versi awal/double: tampil 15 digit),
--   pembayaran_baris = 0, anon_bisa_baca_tabel_baru = false,
--   pos_reader_baca_customers_updated_at = false, pos_reader_kolom_customers = 6,
--   orders_berubah = 0, trigger_baru = 3
--   (+ jumlah_pesanan & per_status: cocokkan dengan angka Anda sebelum menjalankan)
-- Pembalikan: ROLLBACK_KONTRAK_POS_1A_KOLOM.sql (setelah ROLLBACK 1C & 1B).
-- =====================================================================

begin;

-- 1. orders: ringkasan pembayaran + penanda diubah kasir --------------------------------
alter table public.orders
  add column if not exists metode_bayar     text        not null default 'bayar_di_tempat',
  add column if not exists status_bayar     text        not null default 'belum_bayar',
  add column if not exists dibayar_rupiah   integer,
  add column if not exists dibayar_at       timestamptz,
  add column if not exists gateway          text,
  add column if not exists gateway_ref      text,
  add column if not exists perlu_refund     boolean     not null default false,
  add column if not exists diubah_di_pos    boolean     not null default false,
  add column if not exists diubah_di_pos_at timestamptz;

alter table public.orders drop constraint if exists orders_metode_bayar_check;
alter table public.orders add constraint orders_metode_bayar_check
  check (metode_bayar in ('bayar_di_tempat', 'online'));
alter table public.orders drop constraint if exists orders_status_bayar_check;
alter table public.orders add constraint orders_status_bayar_check
  check (status_bayar in ('belum_bayar', 'menunggu', 'lunas', 'gagal', 'kedaluwarsa', 'refund'));
alter table public.orders drop constraint if exists orders_dibayar_rupiah_check;
alter table public.orders add constraint orders_dibayar_rupiah_check
  check (dibayar_rupiah is null or dibayar_rupiah >= 0);
alter table public.orders drop constraint if exists orders_diubah_di_pos_check;
alter table public.orders add constraint orders_diubah_di_pos_check
  check (diubah_di_pos = (diubah_di_pos_at is not null));

-- 2. customers.updated_at ----------------------------------------------------------------
-- now() bersifat STABLE → semua baris lama terisi waktu ALTER ini (sekali baca penuh oleh POS).
alter table public.customers
  add column if not exists updated_at timestamptz not null default now();

drop trigger if exists customers_set_updated_at on public.customers;
create trigger customers_set_updated_at
  before update on public.customers
  for each row execute function public.set_updated_at();

-- 3. Indeks kursor -------------------------------------------------------------------------
create index if not exists orders_updated_at_idx    on public.orders (updated_at);
create index if not exists customers_updated_at_idx on public.customers (updated_at);

-- 4. pengaturan_pos ------------------------------------------------------------------------
create table if not exists public.pengaturan_pos (
  id          smallint    primary key default 1 constraint pengaturan_pos_singleton check (id = 1),
  -- NULL = belum go-live. Diisi Owner lewat SQL saat POS go-live di outlet.
  go_live_at  timestamptz,
  updated_at  timestamptz not null default now()
);
insert into public.pengaturan_pos (id) values (1) on conflict (id) do nothing;

drop trigger if exists pengaturan_pos_set_updated_at on public.pengaturan_pos;
create trigger pengaturan_pos_set_updated_at
  before update on public.pengaturan_pos
  for each row execute function public.set_updated_at();

alter table public.pengaturan_pos enable row level security;
revoke all on public.pengaturan_pos from public, anon, authenticated, service_role;
grant select on public.pengaturan_pos to service_role;

-- 5. outlet --------------------------------------------------------------------------------
create table if not exists public.outlet (
  id         text             primary key,
  nama       text             not null,
  -- numeric (desimal tepat): Supabase mengirim double hanya 15 digit (lihat APPLY_KONTRAK_POS_1A2).
  -- Produksi menjalankan versi awal berkas ini (double) lalu 1A2 mengubahnya ke numeric.
  lat        numeric          not null constraint outlet_lat_check check (lat between -90 and 90),
  lng        numeric          not null constraint outlet_lng_check check (lng between -180 and 180),
  utama      boolean          not null default false,
  aktif      boolean          not null default true,
  dibuat_at  timestamptz      not null default now()
);
create unique index if not exists outlet_satu_utama on public.outlet (utama) where utama;
-- Nilai PERSIS konstanta OUTLET_KOORDINAT di src/lib/ongkir/kalkulasi.mjs (pin manual Google Maps).
insert into public.outlet (id, nama, lat, lng, utama, aktif)
values ('lobak', 'Pizza Lezzato — Jl. Lobak 103A', 0.47939978361032837, 101.40879003237194, true, true)
on conflict (id) do nothing;

alter table public.outlet enable row level security;
revoke all on public.outlet from public, anon, authenticated, service_role;
grant select on public.outlet to service_role;

-- 6. pesanan_pos() -------------------------------------------------------------------------
create or replace function public.pesanan_pos(p_created_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select p.go_live_at is not null and p_created_at >= p.go_live_at
                     from public.pengaturan_pos p where p.id = 1), false)
$$;
revoke all on function public.pesanan_pos(timestamptz) from public, anon, authenticated;
grant execute on function public.pesanan_pos(timestamptz) to service_role;

-- 7. pembayaran (kosong) -------------------------------------------------------------------
create table if not exists public.pembayaran (
  id               uuid        primary key default gen_random_uuid(),
  -- RESTRICT: bukti transaksi wajib disimpan ≥ 24 bulan (PKS Midtrans).
  order_id         uuid        not null references public.orders(id) on delete restrict,
  gateway          text        not null,
  gateway_order_id text        not null,
  gateway_ref      text,
  nominal          integer     not null constraint pembayaran_nominal_check check (nominal >= 0),
  status           text        not null default 'menunggu'
                     constraint pembayaran_status_check
                     check (status in ('menunggu', 'lunas', 'gagal', 'kedaluwarsa', 'refund')),
  payload_mentah   jsonb,
  signature_ok     boolean,
  perlu_tinjau     boolean     not null default false,
  dibuat_at        timestamptz not null default now(),
  diubah_at        timestamptz not null default now(),
  constraint pembayaran_gateway_order_unik unique (gateway, gateway_order_id)
);
create index if not exists pembayaran_order_id_idx on public.pembayaran (order_id);

alter table public.pembayaran enable row level security;
revoke all on public.pembayaran from public, anon, authenticated, service_role;
grant select, insert, update on public.pembayaran to service_role;

-- 8. order_status_log + trigger --------------------------------------------------------------
-- Tanpa FK ke orders: log tetap ada walau pesanan (mis. pesanan uji) dihapus.
create table if not exists public.order_status_log (
  id          bigserial   primary key,
  order_id    uuid        not null,
  order_code  text        not null,
  dari        text,
  ke          text        not null,
  -- dari session_user (tak terpengaruh SECURITY DEFINER): pos_status_writer → pos,
  -- authenticator (PostgREST = kode website) → website, lainnya (SQL Editor, cron) → sql.
  sumber      text        not null constraint order_status_log_sumber_check check (sumber in ('pos', 'website', 'sql')),
  catatan     text,
  waktu       timestamptz not null default now()
);
create index if not exists order_status_log_order_idx on public.order_status_log (order_id, waktu);

alter table public.order_status_log enable row level security;
revoke all on public.order_status_log from public, anon, authenticated, service_role;
grant select on public.order_status_log to service_role;
-- Baris log hanya ditulis trigger (SECURITY DEFINER) — tak ada role lain yang boleh INSERT.
revoke all on sequence public.order_status_log_id_seq from public, anon, authenticated, service_role;

create or replace function public.order_status_log_jaga()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'order_status_log hanya bisa ditambah: % ditolak', tg_op using errcode = 'P0001';
end;
$$;
drop trigger if exists order_status_log_jaga on public.order_status_log;
create trigger order_status_log_jaga
  before update or delete on public.order_status_log
  for each row execute function public.order_status_log_jaga();
drop trigger if exists order_status_log_tolak_truncate on public.order_status_log;
create trigger order_status_log_tolak_truncate
  before truncate on public.order_status_log
  for each statement execute function public.order_status_log_jaga();

create or replace function public.orders_catat_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sumber text := case session_user
                     when 'pos_status_writer' then 'pos'
                     when 'authenticator'     then 'website'
                     else 'sql'
                   end;
begin
  if new.status is distinct from old.status then
    insert into public.order_status_log (order_id, order_code, dari, ke, sumber)
    values (new.id, new.order_code, old.status, new.status, v_sumber);
  end if;
  if new.diubah_di_pos and not old.diubah_di_pos then
    insert into public.order_status_log (order_id, order_code, dari, ke, sumber, catatan)
    values (new.id, new.order_code, new.status, new.status, v_sumber, 'diubah_kasir');
  end if;
  return null;
end;
$$;
revoke all on function public.orders_catat_status() from public, anon, authenticated, service_role;
revoke all on function public.order_status_log_jaga() from public, anon, authenticated, service_role;

drop trigger if exists orders_catat_status on public.orders;
create trigger orders_catat_status
  after update of status, diubah_di_pos on public.orders
  for each row execute function public.orders_catat_status();

commit;

-- ===================================================================== 20261013121000_kontrak_pos_1b_status.sql
-- Migrasi dari supabase/APPLY_KONTRAK_POS_1B_STATUS.sql (tanpa potret & query bukti). Dijalankan Owner 13 Okt ±12.1x WIB.
--
-- =====================================================================
-- KONTRAK POS 1B — nilai status baru & aturan pesanan POS (docs/KONTRAK-DATA-POS.md §2.2, §2.5, §2.8)
-- Jalankan SESUDAH 1A, SEBELUM 1C. Aman diulang.
--
-- Isi:
--   1. CHECK orders.status: + 'diterima', 'siap_diambil', 'sedang_diantar' (7 nilai; 'batal' tetap).
--   2. ubah_status_pesanan(): menerima 7 nilai (jalur SQL darurat Owner); perilaku lain sama.
--   3. v_orders_pending: status aktif = baru, diterima, diproses, siap_diambil, sedang_diantar.
--   4. Trigger orders_jaga_status_pos: pesanan POS tidak bisa diubah statusnya oleh KODE WEBSITE
--      (session_user = authenticator) → 'status_dikelola_pos'. SQL Editor Owner & POS tetap bisa.
--   5. Trigger orders_kunci_diskon: pesanan POS berstatus diproses/siap_diambil/sedang_diantar/
--      selesai/batal → subtotal, discount, diskon_ongkir, ongkir_rupiah, total, discount_held,
--      voucher_code tak bisa diubah ('diskon_terkunci'). Koreksi darurat Owner:
--        begin; set local lezzato.buka_kunci_diskon = 'ya'; update ...; commit;
--
-- Untuk situs yang sedang berjalan: aman.
--   - CHECK hanya DIPERLUAS: semua nilai lama tetap sah; tak ada baris yang ditulis ulang.
--   - Kode website lama hanya menulis 4 nilai lama (Zod di route admin) → tak ada nilai baru
--     yang muncul sebelum POS go-live; kode lama yang bertemu nilai baru belum mungkin terjadi.
--   - Trigger 4 & 5 TIDUR selama pengaturan_pos.go_live_at NULL (pesanan_pos() = false untuk
--     semua pesanan) → perilaku panel admin & resolusi diskon persis seperti sekarang.
--
-- Hasil yang diharapkan (baris SELECT terakhir):
--   check_status = 'baru,batal,diproses,diterima,sedang_diantar,selesai,siap_diambil',
--   check_status_jumlah = 1, ubah_status_terima_nilai_baru = true, pending_memuat_diterima = true,
--   trigger_baru = 2, pesanan_pos_sekarang = 0, orders_berubah = 0
-- Pembalikan: ROLLBACK_KONTRAK_POS_1B_STATUS.sql (setelah ROLLBACK 1C).
-- =====================================================================

begin;

-- 1. CHECK status -----------------------------------------------------------------------------
-- Hapus SEMUA CHECK yang hanya menyangkut kolom `status` (nama bawaan biasanya orders_status_check),
-- lalu pasang satu CHECK baru dengan nama tetap.
do $$
declare
  r record;
begin
  for r in
    select c.conname
      from pg_constraint c
     where c.conrelid = 'public.orders'::regclass
       and c.contype = 'c'
       and c.conkey = array[(select a.attnum from pg_attribute a
                              where a.attrelid = 'public.orders'::regclass and a.attname = 'status')]
  loop
    execute format('alter table public.orders drop constraint %I', r.conname);
  end loop;
end
$$;
alter table public.orders add constraint orders_status_check
  check (status in ('baru', 'diterima', 'diproses', 'siap_diambil', 'sedang_diantar', 'selesai', 'batal'));

-- 2. ubah_status_pesanan --------------------------------------------------------------------------
create or replace function public.ubah_status_pesanan(p_order_code text, p_status text)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_status is null or p_status not in ('baru', 'diterima', 'diproses', 'siap_diambil', 'sedang_diantar', 'selesai', 'batal') then
    raise exception 'status harus salah satu dari: baru / diterima / diproses / siap_diambil / sedang_diantar / selesai / batal'
      using errcode = 'P0001';
  end if;
  update public.orders set status = p_status where order_code = p_order_code;
  if not found then
    raise exception 'pesanan % tidak ditemukan', p_order_code using errcode = 'P0001';
  end if;
  return format('Pesanan %s sekarang berstatus "%s".', p_order_code, p_status);
end;
$$;
revoke all on function public.ubah_status_pesanan(text, text) from public, anon, authenticated;
grant execute on function public.ubah_status_pesanan(text, text) to service_role;

-- 3. v_orders_pending (kolom & urutan sama → create or replace aman; hak akses tetap) ---------------
create or replace view public.v_orders_pending as
select
  o.order_code,
  o.created_at at time zone 'Asia/Jakarta' as waktu_wib,
  o.status,
  o.order_type,
  o.recipient_name,
  o.recipient_phone,
  o.kecamatan,
  o.total
from public.orders o
where o.status in ('baru', 'diterima', 'diproses', 'siap_diambil', 'sedang_diantar')
order by o.created_at asc;
revoke all on public.v_orders_pending from anon, authenticated;

-- 4. Penjaga status pesanan POS ----------------------------------------------------------------------
create or replace function public.orders_jaga_status_pos()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status is distinct from old.status
     and session_user = 'authenticator'
     and public.pesanan_pos(old.created_at) then
    raise exception 'status_dikelola_pos: status pesanan % dikelola dari POS', old.order_code
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function public.orders_jaga_status_pos() from public, anon, authenticated, service_role;

drop trigger if exists orders_jaga_status_pos on public.orders;
create trigger orders_jaga_status_pos
  before update of status on public.orders
  for each row execute function public.orders_jaga_status_pos();

-- 5. Kunci diskon setelah diproses ---------------------------------------------------------------------
create or replace function public.orders_kunci_diskon()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status in ('diproses', 'siap_diambil', 'sedang_diantar', 'selesai', 'batal')
     and (new.subtotal, new.discount, new.diskon_ongkir, new.ongkir_rupiah, new.total,
          new.discount_held, new.voucher_code)
         is distinct from
         (old.subtotal, old.discount, old.diskon_ongkir, old.ongkir_rupiah, old.total,
          old.discount_held, old.voucher_code)
     and coalesce(current_setting('lezzato.buka_kunci_diskon', true), '') <> 'ya'
     and public.pesanan_pos(old.created_at) then
    raise exception 'diskon_terkunci: diskon/total pesanan % tidak bisa diubah setelah diproses', old.order_code
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function public.orders_kunci_diskon() from public, anon, authenticated, service_role;

drop trigger if exists orders_kunci_diskon on public.orders;
create trigger orders_kunci_diskon
  before update on public.orders
  for each row execute function public.orders_kunci_diskon();

commit;

-- ===================================================================== 20261013122000_kontrak_pos_1c_skema_pos.sql
-- Migrasi dari supabase/APPLY_KONTRAK_POS_1C_SKEMA_POS.sql (tanpa potret & query bukti). Dijalankan Owner 13 Okt ±12.2x WIB.
--
-- =====================================================================
-- KONTRAK POS 1C — schema `pos`: 4 view + fungsi pos_set_order_status (docs/KONTRAK-DATA-POS.md §2.1, §2.2)
-- Jalankan SESUDAH 1A & 1B. Aman diulang.
--
-- Isi:
--   1. Schema `pos` (TIDAK diekspos PostgREST — jangan tambahkan ke "Exposed schemas" di Dashboard).
--   2. View: pos.v_pesanan, pos.v_item_pesanan, pos.v_pelanggan, pos.v_pengaturan_ongkir.
--   3. Fungsi pos.pos_set_order_status(p_order_id uuid, p_status text, p_diubah_kasir boolean default false).
--
-- BELUM ADA SIAPA PUN YANG BISA MEMAKAINYA: tidak ada GRANT ke pos_reader / pos_status_writer
-- (role & grant = berkas APPLY_KONTRAK_POS_2, tahap 5, sesudah deploy kode website). Hak
-- anon/authenticated/service_role dicabut eksplisit.
--
-- Untuk situs yang sedang berjalan: aman — objek baru di schema terpisah; tidak mengubah tabel,
-- data, atau fungsi yang dipakai kode website. Selama go_live_at NULL: v_pesanan & v_item_pesanan
-- kosong, fungsi menolak semua pesanan ('sebelum_go_live').
--
-- Hasil yang diharapkan (baris SELECT terakhir):
--   view_pos = 4, fungsi_pos = 1, v_pesanan_baris = 0, v_item_pesanan_baris = 0,
--   v_pelanggan_baris = jumlah pelanggan, v_pengaturan_ongkir_baris = 1,
--   anon_usage_pos = false, authenticated_usage_pos = false, service_role_usage_pos = false,
--   siapa_bisa_execute = '' (kosong), pos_reader_usage_pos = false
-- Pembalikan: ROLLBACK_KONTRAK_POS_1C_SKEMA_POS.sql.
-- =====================================================================

begin;

create schema if not exists pos;
revoke all on schema pos from public, anon, authenticated, service_role;

-- 2a. Pesanan: hanya pesanan POS (≥ go_live_at) dan ≤ 14 hari ----------------------------------------
create or replace view pos.v_pesanan as
select
  o.id,
  o.order_code,
  o.created_at,
  o.updated_at,
  o.status,
  o.order_type,
  o.customer_id,
  o.recipient_name,
  o.recipient_phone,
  o.address,
  o.patokan,
  o.alamat_lat,
  o.alamat_lng,
  o.note,
  o.subtotal,
  o.discount,
  o.voucher_code,
  o.ongkir_rupiah,
  o.diskon_ongkir,
  o.total,
  o.jarak_tagih_km,
  o.metode_jarak,
  o.verification_status,
  o.discount_held,
  (o.verification_status = 'pending' or o.discount_held) as menunggu_admin,
  o.diubah_di_pos,
  o.diubah_di_pos_at,
  o.metode_bayar,
  o.status_bayar,
  o.dibayar_rupiah,
  o.dibayar_at,
  (o.status_bayar = 'lunas')                              as terkunci_edit
from public.orders o
where public.pesanan_pos(o.created_at)
  and o.created_at >= now() - interval '14 days';

-- 2b. Item: hanya milik pesanan yang terlihat di v_pesanan ----------------------------------------------
create or replace view pos.v_item_pesanan as
select
  i.id,
  i.order_id,
  i.menu_id,
  i.name,
  i.unit_price,
  i.qty,
  i.line_total,
  i.original_unit_price,
  i.voucher_discount,
  i.options
from public.order_items i
where exists (select 1 from pos.v_pesanan p where p.id = i.order_id);

-- 2c. Pelanggan: 6 kolom lama + updated_at (TANPA created_at — keputusan Owner P5) ------------------------
create or replace view pos.v_pelanggan as
select
  c.id,
  c.name,
  c.phone,
  c.default_address,
  c.default_patokan,
  c.phone_verified,
  c.updated_at
from public.customers c;

-- 2d. Aturan ongkir + koordinat outlet utama (tanpa updated_by) -------------------------------------------
create or replace view pos.v_pengaturan_ongkir as
select
  p.mode,
  p.radius_gratis_km,
  p.tarif_dasar,
  p.batas_tarif_dasar_km,
  p.tarif_tambahan_per_km,
  p.kelipatan_km,
  p.batas_lurus_km,
  p.batas_rute_km,
  p.faktor_rute,
  p.updated_at,
  o.id  as outlet_id,
  o.lat as outlet_lat,
  o.lng as outlet_lng
from public.pengaturan_ongkir p
cross join public.outlet o
where p.id = 1 and o.utama;

revoke all on pos.v_pesanan, pos.v_item_pesanan, pos.v_pelanggan, pos.v_pengaturan_ongkir
  from public, anon, authenticated, service_role;

-- 3. pos_set_order_status ------------------------------------------------------------------------------
-- Galat: raise exception … errcode P0001, pesan berawalan kode: status_tidak_dikenal,
-- pesanan_tidak_ada, sebelum_go_live, transisi_ditolak, menunggu_admin, belum_lunas,
-- sudah_lunas_terkunci, pembayaran_berjalan.
create or replace function pos.pos_set_order_status(
  p_order_id     uuid,
  p_status       text,
  p_diubah_kasir boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_o       public.orders%rowtype;
  v_ke      text;
  v_tandai  boolean := false;
  v_dari_rk int;
  v_ke_rk   int;
  v_baru    public.orders%rowtype;
  v_berubah boolean;
begin
  -- 1. Nilai status dari POS (kosakata POS; 'dibatalkan' disimpan sebagai 'batal').
  if p_status is null or p_status not in ('diterima', 'diproses', 'siap_diambil', 'sedang_diantar', 'selesai', 'dibatalkan') then
    raise exception 'status_tidak_dikenal: %', coalesce(p_status, 'NULL') using errcode = 'P0001';
  end if;
  v_ke := case p_status when 'dibatalkan' then 'batal' else p_status end;

  -- 2. Kunci baris pesanan.
  select * into v_o from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'pesanan_tidak_ada: %', coalesce(p_order_id::text, 'NULL') using errcode = 'P0001';
  end if;

  -- 3. Hanya pesanan sesudah go-live.
  if not public.pesanan_pos(v_o.created_at) then
    raise exception 'sebelum_go_live: pesanan % dibuat sebelum go-live POS (atau go-live belum diisi)', v_o.order_code
      using errcode = 'P0001';
  end if;

  -- 4. Transisi (sama dengan sekarang = boleh, tanpa perubahan status).
  if v_ke <> v_o.status then
    if v_o.status in ('selesai', 'batal') then
      raise exception 'transisi_ditolak: % → % (status akhir)', v_o.status, v_ke using errcode = 'P0001';
    end if;
    if v_ke <> 'batal' then
      v_dari_rk := case v_o.status when 'baru' then 0 when 'diterima' then 1 when 'diproses' then 2
                                   when 'siap_diambil' then 3 when 'sedang_diantar' then 3 end;
      v_ke_rk   := case v_ke when 'diterima' then 1 when 'diproses' then 2
                             when 'siap_diambil' then 3 when 'sedang_diantar' then 3 when 'selesai' then 4 end;
      if v_ke_rk <= v_dari_rk then
        raise exception 'transisi_ditolak: % → % (hanya maju)', v_o.status, v_ke using errcode = 'P0001';
      end if;
      if v_ke = 'siap_diambil' and v_o.order_type not in ('takeaway', 'dinein') then
        raise exception 'transisi_ditolak: siap_diambil hanya untuk Pick Up / Dine-in' using errcode = 'P0001';
      end if;
      if v_ke = 'sedang_diantar' and v_o.order_type <> 'delivery' then
        raise exception 'transisi_ditolak: sedang_diantar hanya untuk Delivery' using errcode = 'P0001';
      end if;
    end if;

    -- 5. Menunggu verifikasi HP / resolusi diskon di admin website.
    if v_ke <> 'batal' and (v_o.verification_status = 'pending' or v_o.discount_held) then
      raise exception 'menunggu_admin: pesanan % menunggu verifikasi/resolusi diskon di admin website', v_o.order_code
        using errcode = 'P0001';
    end if;

    -- 6. Bayar online wajib lunas sebelum diproses.
    if v_ke in ('diproses', 'siap_diambil', 'sedang_diantar', 'selesai')
       and v_o.metode_bayar = 'online' and v_o.status_bayar <> 'lunas' then
      raise exception 'belum_lunas: pesanan % bayar online belum lunas', v_o.order_code using errcode = 'P0001';
    end if;
  end if;

  -- 7. Penanda "diubah kasir" (diabaikan bila tujuan batal).
  if coalesce(p_diubah_kasir, false) and v_ke <> 'batal' then
    if v_o.status_bayar = 'lunas' then
      raise exception 'sudah_lunas_terkunci: pesanan % sudah lunas, tidak boleh diubah', v_o.order_code
        using errcode = 'P0001';
    end if;
    if v_o.status_bayar = 'menunggu' then
      raise exception 'pembayaran_berjalan: pesanan % sedang dibayar online', v_o.order_code using errcode = 'P0001';
    end if;
    v_tandai := not v_o.diubah_di_pos;
  end if;

  -- 8. Tulis hanya bila ada yang berubah (kiriman ulang tak menggeser updated_at).
  v_berubah := v_ke <> v_o.status;
  if v_berubah or v_tandai then
    update public.orders
       set status           = v_ke,
           diubah_di_pos    = diubah_di_pos or v_tandai,
           diubah_di_pos_at = case when v_tandai then now() else diubah_di_pos_at end,
           metode_bayar     = case when v_tandai and metode_bayar = 'online' then 'bayar_di_tempat' else metode_bayar end,
           perlu_refund     = perlu_refund or (v_berubah and v_ke = 'batal' and status_bayar = 'lunas')
     where id = p_order_id
     returning * into v_baru;
  else
    v_baru := v_o;
  end if;

  return jsonb_build_object(
    'ok',            true,
    'order_id',      v_baru.id,
    'order_code',    v_baru.order_code,
    'status_lama',   v_o.status,
    'status_baru',   v_baru.status,
    'berubah',       v_berubah,
    'diubah_di_pos', v_baru.diubah_di_pos,
    'metode_bayar',  v_baru.metode_bayar,
    'updated_at',    v_baru.updated_at
  );
end;
$$;
revoke all on function pos.pos_set_order_status(uuid, text, boolean) from public, anon, authenticated, service_role;

commit;
