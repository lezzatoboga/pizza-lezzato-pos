-- =====================================================================
-- WEBSITE TIRUAN MINI untuk pengembangan lokal tahap A — HANYA database
-- lokal. JANGAN dijalankan ke Supabase produksi (POS maupun website).
--
-- Meniru antarmuka kontrak (docs/KONTRAK-DATA-POS.md):
--   pos.v_pesanan, pos.v_item_pesanan (§2.1) dan pos.pos_set_order_status
--   (§2.2: tabel transisi, menunggu_admin, belum_lunas, penanda diubah_kasir,
--   sebelum_go_live). Bukan pengganti paket website_tiruan resmi (tahap 6a,
--   dibuat sesi website) — tahap B menguji terhadap paket resmi itu.
-- Role pos_reader / pos_status_writer memakai kata sandi UJI LOKAL.
-- Setelah dijalankan: select pos.stub_seed_fixture();  (butuh web-orders-fixture.sql)
-- =====================================================================

create schema if not exists pos;

create table if not exists pos.stub_settings (
  id boolean primary key default true check (id),
  go_live_at timestamptz
);
insert into pos.stub_settings (go_live_at) values (now() - interval '1 day')
on conflict (id) do nothing;

create table if not exists pos.stub_orders (
  id uuid primary key,
  order_code text not null,
  created_at timestamptz not null,
  updated_at timestamptz not null default now(),
  status text not null,
  order_type text not null,
  customer_id uuid,
  recipient_name text, recipient_phone text, address text, patokan text,
  alamat_lat numeric, alamat_lng numeric, note text,
  subtotal integer, discount integer, voucher_code text, ongkir_rupiah integer,
  diskon_ongkir integer, total integer, jarak_tagih_km numeric, metode_jarak text,
  verification_status text not null default 'not_required',
  discount_held boolean not null default false,
  diubah_di_pos boolean not null default false,
  diubah_di_pos_at timestamptz,
  metode_bayar text not null default 'bayar_di_tempat',
  status_bayar text not null default 'belum_bayar',
  dibayar_rupiah integer, dibayar_at timestamptz,
  perlu_refund boolean not null default false
);

create table if not exists pos.stub_items (
  id uuid primary key,
  order_id uuid not null references pos.stub_orders (id) on delete cascade,
  menu_id text, name text, unit_price integer, qty integer, line_total integer,
  original_unit_price integer, voucher_discount integer, options jsonb
);

create table if not exists pos.stub_status_log (
  id bigserial primary key, order_id uuid, dari text, ke text, catatan text,
  waktu timestamptz not null default now()
);

create or replace function pos.stub_pesanan_pos(p_created_at timestamptz)
returns boolean language sql stable security definer set search_path = '' as $$
  select go_live_at is not null and p_created_at >= go_live_at from pos.stub_settings
$$;

create or replace view pos.v_pesanan as
select o.id, o.order_code, o.created_at, o.updated_at, o.status, o.order_type, o.customer_id,
       o.recipient_name, o.recipient_phone, o.address, o.patokan, o.alamat_lat, o.alamat_lng, o.note,
       o.subtotal, o.discount, o.voucher_code, o.ongkir_rupiah, o.diskon_ongkir, o.total,
       o.jarak_tagih_km, o.metode_jarak, o.verification_status, o.discount_held,
       (o.verification_status = 'pending' or o.discount_held) as menunggu_admin,
       o.diubah_di_pos, o.diubah_di_pos_at, o.metode_bayar, o.status_bayar, o.dibayar_rupiah, o.dibayar_at,
       (o.status_bayar = 'lunas') as terkunci_edit
from pos.stub_orders o
where pos.stub_pesanan_pos(o.created_at) and o.created_at >= now() - interval '14 days';

create or replace view pos.v_item_pesanan as
select i.id, i.order_id, i.menu_id, i.name, i.unit_price, i.qty, i.line_total,
       i.original_unit_price, i.voucher_discount, i.options
from pos.stub_items i
where i.order_id in (select id from pos.v_pesanan);

create or replace function pos.pos_set_order_status(p_order_id uuid, p_status text, p_diubah_kasir boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_o      pos.stub_orders;
  v_to     text := case when p_status = 'dibatalkan' then 'batal' else p_status end;
  v_from   text;
  v_pick   boolean;
  v_ok     boolean;
  v_flag   boolean := coalesce(p_diubah_kasir, false);
begin
  if p_status is null or p_status not in ('diterima','diproses','siap_diambil','sedang_diantar','selesai','dibatalkan') then
    raise exception 'status_tidak_dikenal: %', p_status using errcode = 'P0001';
  end if;
  select * into v_o from pos.stub_orders where id = p_order_id for update;
  if v_o.id is null then
    raise exception 'pesanan_tidak_ada: %', p_order_id using errcode = 'P0001';
  end if;
  if not pos.stub_pesanan_pos(v_o.created_at) then
    raise exception 'sebelum_go_live: pesanan sebelum go-live' using errcode = 'P0001';
  end if;

  v_from := v_o.status;
  v_pick := v_o.order_type in ('takeaway', 'dinein');
  v_ok := v_from = v_to or case
    when v_from in ('selesai', 'batal') then false
    when v_to = 'batal' or v_to = 'selesai' then true
    when v_to = 'diterima' then v_from = 'baru'
    when v_to = 'diproses' then v_from in ('baru', 'diterima')
    when v_to = 'siap_diambil' then v_pick and v_from in ('baru', 'diterima', 'diproses')
    when v_to = 'sedang_diantar' then not v_pick and v_from in ('baru', 'diterima', 'diproses')
    else false end;
  if not v_ok then
    raise exception 'transisi_ditolak: % → %', v_from, v_to using errcode = 'P0001';
  end if;

  if (v_o.verification_status = 'pending' or v_o.discount_held) and v_to not in ('batal', v_from) then
    raise exception 'menunggu_admin: menunggu verifikasi admin website' using errcode = 'P0001';
  end if;
  if v_to in ('diproses','siap_diambil','sedang_diantar','selesai') and v_o.metode_bayar = 'online'
     and v_o.status_bayar <> 'lunas' then
    raise exception 'belum_lunas: pembayaran online belum lunas' using errcode = 'P0001';
  end if;

  if v_flag and v_to <> 'batal' then
    if v_o.status_bayar = 'lunas' then
      raise exception 'sudah_lunas_terkunci: pesanan sudah lunas' using errcode = 'P0001';
    elsif v_o.status_bayar = 'menunggu' then
      raise exception 'pembayaran_berjalan: pembayaran online sedang berjalan' using errcode = 'P0001';
    end if;
    update pos.stub_orders
    set diubah_di_pos = true,
        diubah_di_pos_at = coalesce(diubah_di_pos_at, now()),
        metode_bayar = case when metode_bayar = 'online' then 'bayar_di_tempat' else metode_bayar end,
        updated_at = now()
    where id = v_o.id;
    insert into pos.stub_status_log (order_id, dari, ke, catatan) values (v_o.id, v_from, v_from, 'diubah_kasir');
  end if;

  if v_to <> v_from then
    update pos.stub_orders
    set status = v_to, updated_at = now(),
        perlu_refund = perlu_refund or (v_to = 'batal' and status_bayar = 'lunas')
    where id = v_o.id;
    insert into pos.stub_status_log (order_id, dari, ke) values (v_o.id, v_from, v_to);
  end if;

  select * into v_o from pos.stub_orders where id = p_order_id;
  return jsonb_build_object('ok', true, 'order_id', v_o.id, 'order_code', v_o.order_code,
    'status_lama', v_from, 'status_baru', v_o.status, 'berubah', v_to <> v_from,
    'diubah_di_pos', v_o.diubah_di_pos, 'metode_bayar', v_o.metode_bayar, 'updated_at', v_o.updated_at);
end;
$$;

-- Isi website tiruan dari fixture (supabase/dev/web-orders-fixture.sql).
create or replace function pos.stub_seed_fixture()
returns integer language plpgsql as $$
declare
  v_o jsonb; h jsonb; v_n integer := 0;
begin
  for v_o in select * from jsonb_array_elements(public.dev_web_fixture_orders()) loop
    h := v_o -> 'header';
    insert into pos.stub_orders (id, order_code, created_at, updated_at, status, order_type, customer_id,
      recipient_name, recipient_phone, address, patokan, alamat_lat, alamat_lng, note,
      subtotal, discount, voucher_code, ongkir_rupiah, diskon_ongkir, total, jarak_tagih_km, metode_jarak,
      verification_status, discount_held, diubah_di_pos, metode_bayar, status_bayar, dibayar_rupiah, dibayar_at)
    values ((h->>'id')::uuid, h->>'order_code', (h->>'created_at')::timestamptz, now(), h->>'status', h->>'order_type',
      nullif(h->>'customer_id','')::uuid, h->>'recipient_name', h->>'recipient_phone', h->>'address', h->>'patokan',
      (h->>'alamat_lat')::numeric, (h->>'alamat_lng')::numeric, h->>'note',
      (h->>'subtotal')::int, (h->>'discount')::int, h->>'voucher_code', (h->>'ongkir_rupiah')::int,
      (h->>'diskon_ongkir')::int, (h->>'total')::int, (h->>'jarak_tagih_km')::numeric, h->>'metode_jarak',
      h->>'verification_status', (h->>'discount_held')::boolean, false, h->>'metode_bayar', h->>'status_bayar',
      (h->>'dibayar_rupiah')::int, (h->>'dibayar_at')::timestamptz)
    on conflict (id) do nothing;
    insert into pos.stub_items (id, order_id, menu_id, name, unit_price, qty, line_total, original_unit_price, voucher_discount, options)
    select (i->>'id')::uuid, (i->>'order_id')::uuid, i->>'menu_id', i->>'name', (i->>'unit_price')::int, (i->>'qty')::int,
           (i->>'line_total')::int, (i->>'original_unit_price')::int, (i->>'voucher_discount')::int, i->'options'
    from jsonb_array_elements(v_o -> 'items') i
    on conflict (id) do nothing;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- Role website (kata sandi UJI LOKAL — bukan kata sandi produksi).
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'pos_reader') then
    create role pos_reader login password 'uji-lokal-reader' connection limit 3;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'pos_status_writer') then
    create role pos_status_writer login password 'uji-lokal-writer' noinherit connection limit 2;
  end if;
end;
$$;
alter role pos_reader set default_transaction_read_only = on;
alter role pos_reader set statement_timeout = '5s';
alter role pos_status_writer set statement_timeout = '5s';

revoke all on schema pos from public;
revoke all on all tables in schema pos from public;
revoke all on function pos.pos_set_order_status(uuid, text, boolean) from public;
grant usage on schema pos to pos_reader, pos_status_writer;
grant select on pos.v_pesanan, pos.v_item_pesanan to pos_reader;
grant execute on function pos.pos_set_order_status(uuid, text, boolean) to pos_status_writer;
grant execute on function pos.stub_pesanan_pos(timestamptz) to pos_reader;
