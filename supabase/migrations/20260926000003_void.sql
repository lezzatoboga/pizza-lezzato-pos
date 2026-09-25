-- =====================================================================
-- Void (pembatalan) transaksi
--
-- Izin:
--   * void_unlocked_transaction: transaksi BELUM terkunci (struk belum
--     dicetak) DAN termasuk shift yang sedang berjalan.
--   * void_transaction: kapan saja, termasuk transaksi terkunci.
-- Kalau kasir yang login tidak berizin, Supervisor/Owner menyetujui dengan
-- memilih nama + PIN di tablet yang sama (kunci PIN bertingkat berlaku).
--
-- Status balikan (bukan error) supaya hitungan PIN salah tetap tersimpan:
--   voided | approval_required | pin_invalid | pin_locked
--
-- Uang:
--   * Tunai, dibayar di shift yang sedang berjalan: otomatis keluar dari
--     penjualan tunai shift (hanya transaksi aktif yang dihitung).
--   * Tunai, dibayar di shift yang sudah ditutup: kas keluar "Refund void …"
--     dicatat di shift yang sedang berjalan (wajib ada shift terbuka).
--   * Non-tunai: hanya dicatat batal; pengembalian dana di luar POS.
-- Ditolak selama shift outlet berstatus 'counting' (sedang ditutup).
-- =====================================================================

alter table public.transactions
  add column void_requested_by uuid references public.pos_users (id);

comment on column public.transactions.voided_by is
  'Pengguna yang memberi otorisasi pembatalan (kasir sendiri, atau Supervisor/Owner lewat PIN).';
comment on column public.transactions.void_requested_by is
  'Pengguna yang sedang login saat pembatalan diajukan.';

-- ---------------------------------------------------------------------
-- Izin void untuk pengguna tertentu (bukan hanya yang sedang login).
-- ---------------------------------------------------------------------
create or replace function public.user_has_permission(p_user_id uuid, p_code text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select rp.granted
    from public.pos_users u
    join public.role_permissions rp on rp.role_id = u.role_id
    where u.id = p_user_id and u.active and rp.permission_code = p_code
  ), false);
$$;

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
          and p_tx.shift_id is not distinct from p_open_shift_id
          and p_open_shift_id is not null
          and public.user_has_permission(p_user_id, 'void_unlocked_transaction'));
$$;

-- Daftar penyetuju untuk dialog persetujuan (berizin void_transaction).
create or replace function public.list_void_approvers()
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
  return query
    select u.id, u.name
    from public.pos_users u
    where u.active and public.user_has_permission(u.id, 'void_transaction')
    order by u.name;
end;
$$;

-- Nama semua pengguna (untuk menampilkan siapa yang membatalkan, dsb.).
-- Tabel pos_users tidak dibaca langsung dari tablet karena berisi hash PIN.
create or replace function public.list_pos_user_names()
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
  return query select u.id, u.name from public.pos_users u order by u.name;
end;
$$;

-- ---------------------------------------------------------------------
-- Void
-- p_reason_code: salah_input | pelanggan_batal | pesanan_dobel | lainnya
-- ---------------------------------------------------------------------
create or replace function public.void_transaction(
  p_transaction_id uuid,
  p_reason_code text,
  p_reason_detail text default null,
  p_approver_id uuid default null,
  p_approver_pin text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user        uuid := public.current_pos_user_id();
  v_tx          public.transactions;
  v_open_shift  uuid;
  v_authorizer  uuid;
  v_pin         jsonb;
  v_reason      text;
  v_detail      text := nullif(trim(p_reason_detail), '');
  v_method      public.payment_methods;
  v_refund_cash bigint := 0;
begin
  if v_user is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;

  v_reason := case p_reason_code
    when 'salah_input' then 'Salah input'
    when 'pelanggan_batal' then 'Pelanggan batal'
    when 'pesanan_dobel' then 'Pesanan dobel'
    when 'lainnya' then 'Lainnya'
  end;
  if v_reason is null then
    raise exception 'ALASAN_WAJIB: pilih alasan pembatalan';
  end if;
  if p_reason_code = 'lainnya' and v_detail is null then
    raise exception 'ALASAN_WAJIB: isi keterangan alasan pembatalan';
  end if;
  if v_detail is not null then
    v_reason := v_reason || ': ' || v_detail;
  end if;

  select * into v_tx from public.transactions where id = p_transaction_id for update;
  if v_tx.id is null then
    raise exception 'TRANSAKSI_TIDAK_ADA: transaksi tidak ditemukan';
  end if;
  if v_tx.status <> 'active' then
    raise exception 'SUDAH_DIBATALKAN: transaksi % sudah dibatalkan', v_tx.transaction_number;
  end if;

  if exists (select 1 from public.shifts where outlet_id = v_tx.outlet_id and status = 'counting') then
    raise exception 'SHIFT_SEDANG_DITUTUP: shift sedang ditutup, pembatalan belum bisa dilakukan';
  end if;

  select id into v_open_shift
  from public.shifts
  where outlet_id = v_tx.outlet_id and status = 'open';

  -- ---------------- Otorisasi ----------------
  if public.user_can_void(v_user, v_tx, v_open_shift) then
    v_authorizer := v_user;
  elsif p_approver_id is null then
    return jsonb_build_object(
      'status', 'approval_required',
      'reason', case when v_tx.is_locked
        then 'Struk sudah dicetak: perlu persetujuan Supervisor/Owner.'
        else 'Transaksi dari shift lain: perlu persetujuan Supervisor/Owner.' end
    );
  else
    v_pin := public.verify_pos_user_pin(p_approver_id, p_approver_pin);
    if v_pin ->> 'status' = 'locked' then
      return jsonb_build_object('status', 'pin_locked', 'locked_until', v_pin -> 'locked_until');
    elsif v_pin ->> 'status' <> 'ok' then
      return jsonb_build_object('status', 'pin_invalid', 'attempts_left', v_pin -> 'attempts_left');
    end if;
    if not public.user_can_void(p_approver_id, v_tx, v_open_shift) then
      raise exception 'TIDAK_BERIZIN: penyetuju tidak punya izin membatalkan transaksi ini';
    end if;
    v_authorizer := p_approver_id;
  end if;

  -- ---------------- Pengembalian uang tunai ----------------
  if v_tx.payment_status = 'paid' then
    select * into v_method from public.payment_methods where id = v_tx.payment_method_id;
    if v_method.is_cash and v_tx.shift_id is distinct from v_open_shift then
      if v_open_shift is null then
        raise exception 'SHIFT_BELUM_DIBUKA: buka shift dulu untuk mencatat pengembalian uang tunai';
      end if;
      insert into public.cash_movements (shift_id, type, amount, description, created_by)
      values (v_open_shift, 'keluar', v_tx.total, 'Refund void ' || v_tx.transaction_number, v_user);
      v_refund_cash := v_tx.total;
    elsif v_method.is_cash then
      v_refund_cash := v_tx.total;
    end if;
  end if;

  update public.transactions
  set status = 'voided',
      voided_by = v_authorizer,
      void_requested_by = v_user,
      voided_at = now(),
      void_reason = v_reason
  where id = v_tx.id;

  return jsonb_build_object(
    'status', 'voided',
    'transaction_number', v_tx.transaction_number,
    'paid', v_tx.payment_status = 'paid',
    'payment_method_name', v_method.name,
    'refund_cash', v_refund_cash,
    'refund_recorded_as_cash_out', v_refund_cash > 0 and v_tx.shift_id is distinct from v_open_shift,
    'kitchen_ticket_printed', v_tx.kitchen_ticket_print_count > 0
  );
end;
$$;

revoke execute on function public.user_has_permission(uuid, text) from public, anon, authenticated;
revoke execute on function public.user_can_void(uuid, public.transactions, uuid) from public, anon, authenticated;
revoke execute on function public.list_void_approvers() from public, anon;
revoke execute on function public.list_pos_user_names() from public, anon;
revoke execute on function public.void_transaction(uuid, text, text, uuid, text) from public, anon;
grant execute on function public.list_void_approvers() to authenticated;
grant execute on function public.list_pos_user_names() to authenticated;
grant execute on function public.void_transaction(uuid, text, text, uuid, text) to authenticated;
