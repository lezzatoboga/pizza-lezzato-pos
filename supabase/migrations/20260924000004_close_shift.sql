-- =====================================================================
-- Kas masuk/keluar + tutup shift dengan hitung buta
--
-- Alur tutup shift (dua langkah, supaya hitungan kasir tidak dipengaruhi
-- angka sistem):
--   1. submit_cash_count  : open → counting. Hitungan per pecahan disimpan
--                           dan terkunci; expected_cash & selisih dihitung.
--                           Selama counting, transaksi/pembayaran/kas baru
--                           ditolak (fungsi-fungsi itu hanya mencari shift
--                           berstatus 'open').
--   2. close_shift        : counting → closed. Catatan wajib bila selisih ≠ 0.
--
-- expected_cash = saldo awal + penjualan tunai − kas keluar + kas masuk
-- Penjualan tunai = total transaksi aktif yang dibayar tunai di shift ini.
-- Selama shift masih open, ringkasan tidak menampilkan angka penjualan
-- (hitung buta).
-- =====================================================================

alter table public.shifts
  add column cash_denominations jsonb,
  add column counted_at         timestamptz,
  add column counted_by         uuid references public.pos_users (id);

comment on column public.shifts.cash_denominations is
  'Hasil hitung uang fisik per pecahan: {"100000": 3, "50000": 2, ...}.';

alter table public.shifts drop constraint shifts_status;
alter table public.shifts drop constraint shifts_closed_complete;

alter table public.shifts
  add constraint shifts_status check (status in ('open', 'counting', 'closed')),
  add constraint shifts_counted_complete check (
    status = 'open'
    or (closing_cash_counted is not null and expected_cash is not null
        and cash_difference is not null and counted_at is not null)
  ),
  add constraint shifts_closed_complete check (
    status <> 'closed' or (closing_time is not null and closed_by is not null)
  ),
  add constraint shifts_difference_noted check (
    status <> 'closed' or cash_difference = 0 or nullif(trim(notes), '') is not null
  );

-- Shift yang sedang dihitung juga menghalangi pembukaan shift baru.
drop index public.shifts_one_open_per_outlet;
create unique index shifts_one_active_per_outlet
  on public.shifts (outlet_id) where status in ('open', 'counting');

-- ---------------------------------------------------------------------
-- Pecahan uang yang diterima
-- ---------------------------------------------------------------------
create or replace function public.cash_denomination_total(p_denominations jsonb)
returns bigint
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_allowed constant bigint[] := array[100000, 50000, 20000, 10000, 5000, 2000, 1000, 500, 200, 100];
  v_key   text;
  v_count integer;
  v_total bigint := 0;
begin
  if p_denominations is null or jsonb_typeof(p_denominations) <> 'object' then
    raise exception 'HITUNGAN_TIDAK_VALID: hasil hitung uang kosong';
  end if;

  for v_key in select jsonb_object_keys(p_denominations) loop
    if v_key !~ '^[0-9]+$' or not (v_key::bigint = any (v_allowed)) then
      raise exception 'HITUNGAN_TIDAK_VALID: pecahan % tidak dikenal', v_key;
    end if;
    v_count := (p_denominations ->> v_key)::integer;
    if v_count is null or v_count < 0 or v_count > 100000 then
      raise exception 'HITUNGAN_TIDAK_VALID: jumlah lembar pecahan % tidak valid', v_key;
    end if;
    v_total := v_total + v_key::bigint * v_count;
  end loop;

  return v_total;
end;
$$;

-- ---------------------------------------------------------------------
-- Kas masuk / keluar (semua kasir boleh)
-- ---------------------------------------------------------------------
create or replace function public.add_cash_movement(
  p_outlet_id uuid,
  p_type text,
  p_amount bigint,
  p_description text
)
returns public.cash_movements
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := public.current_pos_user_id();
  v_shift_id uuid;
  v_row      public.cash_movements;
begin
  if v_user is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;
  if p_type is null or p_type not in ('masuk', 'keluar') then
    raise exception 'TIPE_TIDAK_VALID: pilih kas masuk atau kas keluar';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'JUMLAH_TIDAK_VALID: jumlah harus lebih dari 0';
  end if;
  if nullif(trim(p_description), '') is null then
    raise exception 'KETERANGAN_WAJIB: isi keterangan kas';
  end if;

  select id into v_shift_id from public.shifts where outlet_id = p_outlet_id and status = 'open';
  if v_shift_id is null then
    raise exception 'SHIFT_BELUM_DIBUKA: tidak ada shift yang terbuka';
  end if;

  insert into public.cash_movements (shift_id, type, amount, description, created_by)
  values (v_shift_id, p_type, p_amount, trim(p_description), v_user)
  returning * into v_row;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- Angka kas shift (internal)
-- ---------------------------------------------------------------------
create or replace function public.shift_cash_figures(p_shift_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'opening_balance', s.opening_balance,
    'cash_sales', coalesce((
      select sum(t.total)
      from public.transactions t
      join public.payment_methods m on m.id = t.payment_method_id
      where t.shift_id = s.id and t.status = 'active'
        and t.payment_status = 'paid' and m.is_cash
    ), 0),
    'cash_in', coalesce((
      select sum(amount) from public.cash_movements where shift_id = s.id and type = 'masuk'
    ), 0),
    'cash_out', coalesce((
      select sum(amount) from public.cash_movements where shift_id = s.id and type = 'keluar'
    ), 0)
  )
  from public.shifts s
  where s.id = p_shift_id;
$$;

-- ---------------------------------------------------------------------
-- Langkah 1: simpan hitungan uang (hitung buta)
-- ---------------------------------------------------------------------
create or replace function public.submit_cash_count(p_shift_id uuid, p_denominations jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := public.current_pos_user_id();
  v_shift    public.shifts;
  v_fig      jsonb;
  v_counted  bigint;
  v_expected bigint;
begin
  if v_user is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;

  select * into v_shift from public.shifts where id = p_shift_id for update;
  if v_shift.id is null then
    raise exception 'SHIFT_TIDAK_ADA: shift tidak ditemukan';
  end if;
  if v_shift.status <> 'open' then
    raise exception 'SHIFT_SUDAH_DIHITUNG: hitungan kas shift ini sudah disimpan';
  end if;

  v_counted := public.cash_denomination_total(p_denominations);
  v_fig := public.shift_cash_figures(p_shift_id);
  v_expected := (v_fig ->> 'opening_balance')::bigint
              + (v_fig ->> 'cash_sales')::bigint
              - (v_fig ->> 'cash_out')::bigint
              + (v_fig ->> 'cash_in')::bigint;

  update public.shifts
  set status = 'counting',
      cash_denominations = p_denominations,
      closing_cash_counted = v_counted,
      expected_cash = v_expected,
      cash_difference = v_counted - v_expected,
      counted_at = now(),
      counted_by = v_user
  where id = p_shift_id;

  return public.get_shift_summary(p_shift_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Langkah 2: tutup shift
-- ---------------------------------------------------------------------
create or replace function public.close_shift(p_shift_id uuid, p_notes text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := public.current_pos_user_id();
  v_shift public.shifts;
begin
  if v_user is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;

  select * into v_shift from public.shifts where id = p_shift_id for update;
  if v_shift.id is null then
    raise exception 'SHIFT_TIDAK_ADA: shift tidak ditemukan';
  end if;
  if v_shift.status = 'open' then
    raise exception 'BELUM_DIHITUNG: simpan hitungan uang di laci terlebih dahulu';
  end if;
  if v_shift.status = 'closed' then
    raise exception 'SHIFT_SUDAH_DITUTUP: shift ini sudah ditutup';
  end if;
  if v_shift.cash_difference <> 0 and nullif(trim(p_notes), '') is null then
    raise exception 'CATATAN_WAJIB: ada selisih kas, isi catatan penjelasan';
  end if;

  update public.shifts
  set status = 'closed',
      closing_time = now(),
      closed_by = v_user,
      notes = nullif(trim(p_notes), '')
  where id = p_shift_id;

  return public.get_shift_summary(p_shift_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Ringkasan shift
-- Saat shift masih 'open': tanpa angka penjualan & kas (hitung buta).
-- ---------------------------------------------------------------------
create or replace function public.get_shift_summary(p_shift_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_shift  public.shifts;
  v_result jsonb;
  v_fig    jsonb;
begin
  if public.current_pos_user_id() is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;

  select * into v_shift from public.shifts where id = p_shift_id;
  if v_shift.id is null then
    raise exception 'SHIFT_TIDAK_ADA: shift tidak ditemukan';
  end if;

  v_result := jsonb_build_object(
    'shift', jsonb_build_object(
      'id', v_shift.id,
      'status', v_shift.status,
      'opening_balance', v_shift.opening_balance,
      'opening_time', v_shift.opening_time,
      'closing_time', v_shift.closing_time,
      'opened_by', (select name from public.pos_users where id = v_shift.cashier_id),
      'counted_by', (select name from public.pos_users where id = v_shift.counted_by),
      'closed_by', (select name from public.pos_users where id = v_shift.closed_by),
      'notes', v_shift.notes
    ),
    'transaction_count', (
      select count(*) from public.transactions where shift_id = v_shift.id and status = 'active'
    ),
    'unpaid', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id, 'transaction_number', transaction_number,
        'total', total, 'created_at', created_at) order by created_at)
      from public.transactions
      where shift_id = v_shift.id and status = 'active' and payment_status = 'unpaid'
    ), '[]'),
    'cash_movements', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id, 'type', c.type, 'amount', c.amount, 'description', c.description,
        'created_at', c.created_at, 'created_by', u.name) order by c.created_at)
      from public.cash_movements c
      left join public.pos_users u on u.id = c.created_by
      where c.shift_id = v_shift.id
    ), '[]')
  );

  if v_shift.status = 'open' then
    return v_result;
  end if;

  v_fig := public.shift_cash_figures(v_shift.id);

  return v_result || jsonb_build_object(
    'cash', v_fig || jsonb_build_object(
      'expected', v_shift.expected_cash,
      'counted', v_shift.closing_cash_counted,
      'difference', v_shift.cash_difference,
      'denominations', v_shift.cash_denominations
    ),
    'sales_total', coalesce((
      select sum(total) from public.transactions
      where shift_id = v_shift.id and status = 'active' and payment_status = 'paid'
    ), 0),
    'by_payment', coalesce((
      select jsonb_agg(x order by x ->> 'sort') from (
        select jsonb_build_object(
          'method', m.name,
          'bank', b.bank_name,
          'count', count(*),
          'total', sum(t.total),
          'sort', lpad(m.sort_order::text, 3, '0') || coalesce(lpad(b.sort_order::text, 3, '0'), '')
        ) as x
        from public.transactions t
        join public.payment_methods m on m.id = t.payment_method_id
        left join public.bank_accounts b on b.id = t.bank_account_id
        where t.shift_id = v_shift.id and t.status = 'active' and t.payment_status = 'paid'
        group by m.name, m.sort_order, b.bank_name, b.sort_order
      ) q
    ), '[]'),
    'by_channel', coalesce((
      select jsonb_agg(x order by x ->> 'sort') from (
        select jsonb_build_object(
          'channel', t.channel,
          'platform', p.name,
          'count', count(*),
          'total', sum(t.total),
          'sort', t.channel || coalesce(lpad(p.sort_order::text, 3, '0'), '')
        ) as x
        from public.transactions t
        left join public.marketplace_platforms p on p.id = t.marketplace_platform_id
        where t.shift_id = v_shift.id and t.status = 'active' and t.payment_status = 'paid'
        group by t.channel, p.name, p.sort_order
      ) q
    ), '[]')
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Hak eksekusi
-- ---------------------------------------------------------------------
revoke execute on function public.cash_denomination_total(jsonb) from public, anon, authenticated;
revoke execute on function public.shift_cash_figures(uuid) from public, anon, authenticated;

revoke execute on function public.add_cash_movement(uuid, text, bigint, text) from public, anon;
revoke execute on function public.submit_cash_count(uuid, jsonb) from public, anon;
revoke execute on function public.close_shift(uuid, text) from public, anon;
revoke execute on function public.get_shift_summary(uuid) from public, anon;
grant execute on function public.add_cash_movement(uuid, text, bigint, text) to authenticated;
grant execute on function public.submit_cash_count(uuid, jsonb) to authenticated;
grant execute on function public.close_shift(uuid, text) to authenticated;
grant execute on function public.get_shift_summary(uuid) to authenticated;
