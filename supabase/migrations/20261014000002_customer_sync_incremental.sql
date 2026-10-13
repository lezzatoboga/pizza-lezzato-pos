-- =====================================================================
-- Sinkron pelanggan lewat pos.v_pelanggan (kontrak data §2.1/§2.3, P8)
--
-- Sebelumnya: baca penuh public.customers website tiap 15 menit (role
-- pos_reader lama, secret WEBSITE_CUSTOMERS_DB_URL). Sekarang:
--   * inkremental: v_pelanggan where updated_at > kursor − 2 menit;
--   * rekonsiliasi id penuh sehari sekali (zona Asia/Jakarta) atau bila
--     kursor kosong: pelanggan POS yang sumbernya sudah tidak ada di website
--     DILEPAS (source_customer_id → null), tidak dihapus — riwayat transaksi
--     tetap utuh dan kasir masih bisa memilihnya sebagai pelanggan lokal.
--   * pencocokan: id website (source_customer_id) dulu, lalu nomor HP —
--     pelanggan yang ganti nomor di website tidak menjadi baris ganda.
-- Saklar jeda (sync_settings.customers_paused) tetap berlaku.
-- =====================================================================

alter table public.sync_settings
  add column customers_cursor        timestamptz,
  add column customers_reconciled_on date;

drop function public.apply_customer_sync(jsonb, text, uuid);

create function public.apply_customer_sync(
  p_customers    jsonb,
  p_trigger      text,
  p_triggered_by uuid default null,
  p_full         boolean default false,
  p_cursor       timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_total    integer;
  v_valid    integer;
  v_detached integer := 0;
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
  where source_id is not null and phone is not null and nullif(name, '') is not null
  order by phone, source_id;

  select count(*) into v_valid from _valid_customers;

  -- 1. Sudah tertaut ke id website: perbarui (nomor ikut berubah bila tidak
  --    dipakai pelanggan POS lain).
  update public.customers c
  set name = v.name,
      phone = case when exists (select 1 from public.customers o
                                where o.phone = v.phone and o.id <> c.id)
                   then c.phone else v.phone end,
      default_address = v.default_address,
      default_patokan = v.default_patokan,
      phone_verified = v.phone_verified,
      last_synced_at = now()
  from _valid_customers v
  where c.source_customer_id = v.source_id;

  -- 2. Belum tertaut: upsert lewat nomor HP (pelanggan lokal dengan nomor
  --    sama ditautkan ke id website).
  insert into public.customers as c
    (source_customer_id, name, phone, default_address, default_patokan, phone_verified, last_synced_at)
  select source_id, name, phone, default_address, default_patokan, phone_verified, now()
  from _valid_customers v
  where not exists (select 1 from public.customers t where t.source_customer_id = v.source_id)
  on conflict (phone) do update set
    source_customer_id = excluded.source_customer_id,
    name = excluded.name,
    default_address = excluded.default_address,
    default_patokan = excluded.default_patokan,
    phone_verified = excluded.phone_verified,
    last_synced_at = excluded.last_synced_at;

  -- 3. Rekonsiliasi penuh: lepas tautan yang sumbernya hilang di website.
  if p_full then
    update public.customers c
    set source_customer_id = null
    where c.source_customer_id is not null
      and not exists (select 1 from _src_customers s where s.source_id = c.source_customer_id);
    get diagnostics v_detached = row_count;
  end if;

  update public.sync_settings
  set customers_cursor = coalesce(greatest(customers_cursor, p_cursor), p_cursor, customers_cursor),
      customers_reconciled_on = case when p_full then (now() at time zone 'Asia/Jakarta')::date
                                     else customers_reconciled_on end,
      updated_at = now()
  where id;

  insert into public.menu_sync_runs (kind, trigger, triggered_by, status, customers)
  values ('customers', p_trigger, p_triggered_by, 'success', v_valid);

  return jsonb_build_object('customers', v_valid, 'skipped', v_total - v_valid,
                            'full', p_full, 'detached', v_detached);
end;
$$;

revoke execute on function public.apply_customer_sync(jsonb, text, uuid, boolean, timestamptz)
  from public, anon, authenticated;
grant execute on function public.apply_customer_sync(jsonb, text, uuid, boolean, timestamptz)
  to service_role;
