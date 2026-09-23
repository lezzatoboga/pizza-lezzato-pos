-- =====================================================================
-- Rekening bank tujuan transfer (untuk rekonsiliasi per rekening).
--   * payment_methods.requires_bank_account: metode yang wajib memilih
--     rekening tujuan (Transfer Bank).
--   * transactions.bank_account_id: wajib untuk metode tersebut, harus
--     kosong untuk metode lain — dijaga di pay_transaction.
-- =====================================================================

create table public.bank_accounts (
  id          uuid primary key default gen_random_uuid(),
  bank_name   text not null,
  active      boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create trigger bank_accounts_updated_at before update on public.bank_accounts
  for each row execute function public.set_updated_at();

alter table public.bank_accounts enable row level security;
grant select, insert, update, delete on public.bank_accounts to service_role;
grant select on public.bank_accounts to authenticated;
create policy pos_users_read on public.bank_accounts for select to authenticated
  using ((select public.current_pos_user_id()) is not null);

insert into public.bank_accounts (bank_name, sort_order) values
  ('Mandiri', 1),
  ('BSI',     2),
  ('BRI',     3);

alter table public.payment_methods
  add column requires_bank_account boolean not null default false;

update public.payment_methods set requires_bank_account = true where code = 'transfer';

alter table public.transactions
  add column bank_account_id uuid references public.bank_accounts (id);

create index transactions_bank_account_idx on public.transactions (bank_account_id);

-- ---------------------------------------------------------------------
-- pay_transaction: + rekening tujuan
-- ---------------------------------------------------------------------
drop function public.pay_transaction(uuid, uuid, bigint);

create or replace function public.pay_transaction(
  p_transaction_id uuid,
  p_payment_method_id uuid,
  p_amount_paid bigint default null,
  p_bank_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := public.current_pos_user_id();
  v_tx       public.transactions;
  v_method   public.payment_methods;
  v_bank_id  uuid;
  v_shift_id uuid;
  v_paid     bigint;
begin
  if v_user is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;

  select * into v_tx from public.transactions where id = p_transaction_id for update;
  if v_tx.id is null then
    raise exception 'TRANSAKSI_TIDAK_ADA: transaksi tidak ditemukan';
  end if;
  if v_tx.status <> 'active' then
    raise exception 'TRANSAKSI_BATAL: transaksi sudah dibatalkan';
  end if;
  if v_tx.payment_status = 'paid' then
    raise exception 'SUDAH_LUNAS: transaksi % sudah dibayar', v_tx.transaction_number;
  end if;

  select * into v_method from public.payment_methods where id = p_payment_method_id and active;
  if v_method.id is null then
    raise exception 'METODE_TIDAK_VALID: pilih metode pembayaran';
  end if;

  if v_method.requires_bank_account then
    select id into v_bank_id from public.bank_accounts where id = p_bank_account_id and active;
    if v_bank_id is null then
      raise exception 'REKENING_WAJIB: pilih rekening bank tujuan transfer';
    end if;
  elsif p_bank_account_id is not null then
    raise exception 'REKENING_TIDAK_BERLAKU: rekening bank hanya untuk %', 'Transfer Bank';
  end if;

  select id into v_shift_id
  from public.shifts
  where outlet_id = v_tx.outlet_id and status = 'open';
  if v_shift_id is null then
    raise exception 'SHIFT_BELUM_DIBUKA: buka shift terlebih dahulu';
  end if;

  if v_method.is_cash then
    if p_amount_paid is null or p_amount_paid < v_tx.total then
      raise exception 'UANG_KURANG: uang diterima kurang dari total';
    end if;
    v_paid := p_amount_paid;
  else
    v_paid := v_tx.total;
  end if;

  update public.transactions
  set payment_status = 'paid',
      payment_method_id = v_method.id,
      bank_account_id = v_bank_id,
      amount_paid = v_paid,
      change_amount = v_paid - v_tx.total,
      paid_at = now(),
      shift_id = v_shift_id
  where id = v_tx.id
  returning * into v_tx;

  return jsonb_build_object(
    'id', v_tx.id,
    'transaction_number', v_tx.transaction_number,
    'total', v_tx.total,
    'amount_paid', v_tx.amount_paid,
    'change_amount', v_tx.change_amount
  );
end;
$$;

revoke execute on function public.pay_transaction(uuid, uuid, bigint, uuid) from public, anon;
grant execute on function public.pay_transaction(uuid, uuid, bigint, uuid) to authenticated;
