-- =====================================================================
-- Pengetatan akses baca data transaksi & shift
--
-- Sebelumnya setiap pengguna yang login bisa membaca SEMUA transaksi,
-- item, shift, dan kas masuk/keluar lewat API — kasir bisa menjumlahkan
-- penjualan (termasuk shift lain/riwayat) dan mengakali hitung buta.
--
-- Aturan baca baru (disetujui Owner 2026-10-12):
--   Transaksi/item/addon:
--     - izin view_transaction_detail (Supervisor/Owner): semua;
--     - selain itu (Kasir): transaksi di shift aktif (open/counting),
--       transaksi aktif yang BELUM LUNAS dari shift mana pun (COD), dan
--       transaksi yang DIBATALKAN selama shift aktif berjalan (info &
--       slip BATAL setelah void).
--   Shift & kas masuk/keluar:
--     - izin view_finance_report: semua;
--     - selain itu: hanya shift aktif.
--   get_transaction_print_data & get_shift_summary memakai aturan yang
--   sama (fungsi SECURITY DEFINER melewati RLS, jadi dicek eksplisit).
--   Cetak ulang struk / void transaksi LUNAS dari shift sebelumnya
--   dilakukan oleh Supervisor/Owner.
--
-- Batas yang disadari: kasir tetap melihat total tiap transaksi di shift
-- berjalan (dibutuhkan untuk bayar & cetak), jadi penjumlahan manual dari
-- layar shift berjalan tidak bisa dicegah.
--
-- Grant tulis authenticated yang tidak terpakai dicabut: semua penulisan
-- lewat fungsi SECURITY DEFINER (create_transaction, pay_transaction,
-- set_transaction_courier, mark_kitchen_ticket_printed,
-- mark_receipt_printed, void_transaction, open_shift, add_cash_movement,
-- submit_cash_count, close_shift, update_platform_markup, plus trigger
-- touch_website_transaction).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Pembantu shift aktif (Fase 1: satu outlet; aman juga untuk banyak)
-- ---------------------------------------------------------------------
create or replace function public.active_shift_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.shifts where status in ('open', 'counting');
$$;

create or replace function public.active_shift_started_at()
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select min(opening_time) from public.shifts where status in ('open', 'counting');
$$;

-- Aturan lihat satu transaksi untuk fungsi SECURITY DEFINER. Harus sama
-- dengan policy tx_read di bawah.
create or replace function public.can_view_transaction(p_transaction_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.current_pos_user_id() is not null and exists (
    select 1 from public.transactions t
    where t.id = p_transaction_id
      and (
        public.has_permission('view_transaction_detail')
        or (t.status = 'active' and t.payment_status = 'unpaid')
        or t.shift_id in (select public.active_shift_ids())
        or (t.status = 'voided' and t.voided_at >= public.active_shift_started_at())
      )
  );
$$;

-- ---------------------------------------------------------------------
-- RLS baca
-- ---------------------------------------------------------------------
drop policy pos_users_read on public.transactions;
drop policy pos_users_read on public.transaction_items;
drop policy pos_users_read on public.transaction_item_addons;
drop policy pos_users_read on public.shifts;
drop policy pos_users_read on public.cash_movements;

create policy tx_read on public.transactions for select to authenticated
  using (
    (select public.current_pos_user_id()) is not null
    and (
      (select public.has_permission('view_transaction_detail'))
      or (status = 'active' and payment_status = 'unpaid')
      or shift_id in (select public.active_shift_ids())
      or (status = 'voided' and voided_at >= (select public.active_shift_started_at()))
    )
  );

-- Item & addon mengikuti transaksinya (RLS induk ikut berlaku di subquery).
create policy tx_items_read on public.transaction_items for select to authenticated
  using (exists (select 1 from public.transactions t where t.id = transaction_id));

create policy tx_addons_read on public.transaction_item_addons for select to authenticated
  using (exists (select 1 from public.transaction_items i where i.id = transaction_item_id));

create policy shifts_read on public.shifts for select to authenticated
  using (
    (select public.current_pos_user_id()) is not null
    and ((select public.has_permission('view_finance_report')) or status in ('open', 'counting'))
  );

create policy cash_movements_read on public.cash_movements for select to authenticated
  using (exists (select 1 from public.shifts s where s.id = shift_id));

-- ---------------------------------------------------------------------
-- get_transaction_print_data: data lengkap hanya untuk transaksi yang
-- boleh dilihat. Isi lama jadi fungsi internal transaction_print_data.
-- ---------------------------------------------------------------------
alter function public.get_transaction_print_data(uuid) rename to transaction_print_data;
revoke execute on function public.transaction_print_data(uuid) from public, anon, authenticated;

create function public.get_transaction_print_data(p_transaction_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if public.current_pos_user_id() is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;
  if not exists (select 1 from public.transactions where id = p_transaction_id) then
    raise exception 'TRANSAKSI_TIDAK_ADA: transaksi tidak ditemukan';
  end if;
  if not public.can_view_transaction(p_transaction_id) then
    raise exception 'TIDAK_BERIZIN: transaksi lunas dari shift sebelumnya hanya bisa dibuka Supervisor/Owner';
  end if;
  return public.transaction_print_data(p_transaction_id);
end;
$$;

-- ---------------------------------------------------------------------
-- get_shift_summary: shift yang sudah ditutup hanya untuk izin
-- view_finance_report. Isi lama jadi fungsi internal shift_summary_data,
-- dipakai submit_cash_count & close_shift (shift baru saja ditutup).
-- ---------------------------------------------------------------------
alter function public.get_shift_summary(uuid) rename to shift_summary_data;
revoke execute on function public.shift_summary_data(uuid) from public, anon, authenticated;

create function public.get_shift_summary(p_shift_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_status text;
begin
  if public.current_pos_user_id() is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;
  select status into v_status from public.shifts where id = p_shift_id;
  if v_status is null then
    raise exception 'SHIFT_TIDAK_ADA: shift tidak ditemukan';
  end if;
  if v_status = 'closed' and not public.has_permission('view_finance_report') then
    raise exception 'TIDAK_BERIZIN: ringkasan shift yang sudah ditutup hanya untuk izin laporan keuangan';
  end if;
  return public.shift_summary_data(p_shift_id);
end;
$$;

-- ---------------------------------------------------------------------
-- submit_cash_count & close_shift: sama seperti sebelumnya, hanya
-- ringkasan yang dikembalikan kini lewat shift_summary_data.
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

  return public.shift_summary_data(p_shift_id);
end;
$$;

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

  return public.shift_summary_data(p_shift_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Cabut grant tulis yang tidak terpakai (baca tetap)
-- ---------------------------------------------------------------------
revoke insert, update, delete on
  public.transactions,
  public.transaction_items,
  public.transaction_item_addons,
  public.shifts,
  public.cash_movements,
  public.marketplace_platforms,
  public.role_permissions
from authenticated;

-- ---------------------------------------------------------------------
-- Hak eksekusi
-- ---------------------------------------------------------------------
revoke all on function public.active_shift_ids() from public, anon;
revoke all on function public.active_shift_started_at() from public, anon;
revoke all on function public.can_view_transaction(uuid) from public, anon, authenticated;
revoke all on function public.get_transaction_print_data(uuid) from public, anon;
revoke all on function public.get_shift_summary(uuid) from public, anon;

-- active_shift_* dipakai policy RLS (dievaluasi sebagai pengguna login).
grant execute on function public.active_shift_ids() to authenticated;
grant execute on function public.active_shift_started_at() to authenticated;
grant execute on function public.get_transaction_print_data(uuid) to authenticated;
grant execute on function public.get_shift_summary(uuid) to authenticated;
