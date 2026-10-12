-- =====================================================================
-- Kunci idempoten untuk create_transaction (keputusan Owner 2026-10-12)
--
-- Masalah: kalau jaringan putus SETELAH server menyimpan transaksi tapi
-- SEBELUM jawaban sampai ke tablet, kasir bisa menekan Simpan lagi dan
-- tercipta transaksi ganda.
--
-- Solusi: tablet mengirim client_request_id (UUID) per keranjang. ID yang
-- sama dipakai ulang selama kasir mencoba lagi dengan keranjang yang sama;
-- ID baru dibuat setelah keranjang dikosongkan atau isinya berubah.
-- Kalau ID sudah pernah dipakai, server mengembalikan transaksi yang sudah
-- ada (duplicate = true) — tidak membuat baru. Aplikasi hanya mencetak
-- tiket dapur kalau kitchen_ticket_print_count = 0, jadi pengiriman ulang
-- tidak mencetak tiket dua kali.
--
-- Isi lama create_transaction dipindah ke fungsi internal
-- create_transaction_core (tanpa perubahan); create_transaction kini
-- pembungkus. Transaksi lama: client_request_id kosong (tidak diubah).
--
-- pay_transaction sudah aman tanpa perubahan: baris dikunci (FOR UPDATE)
-- dan bayar kedua ditolak SUDAH_LUNAS; kas tunai dihitung dari baris
-- transaksi (shift_cash_figures), tidak dicatat terpisah.
-- =====================================================================

alter table public.transactions
  add column client_request_id uuid;

comment on column public.transactions.client_request_id is
  'Kunci idempoten dari tablet (satu per keranjang) — mencegah transaksi ganda saat Simpan dikirim ulang.';

create unique index transactions_client_request_id_uq
  on public.transactions (client_request_id) where client_request_id is not null;

alter function public.create_transaction(jsonb) rename to create_transaction_core;
revoke execute on function public.create_transaction_core(jsonb) from public, anon, authenticated;

create function public.create_transaction(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key    uuid;
  v_tx     public.transactions;
  v_result jsonb;
begin
  if public.current_pos_user_id() is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;

  begin
    v_key := nullif(p_payload ->> 'client_request_id', '')::uuid;
  exception when invalid_text_representation then
    raise exception 'PERMINTAAN_TIDAK_VALID: client_request_id harus UUID';
  end;

  if v_key is not null then
    -- Dua kiriman dengan kunci sama diproses bergiliran.
    perform pg_advisory_xact_lock(hashtextextended(v_key::text, 0));
    select * into v_tx from public.transactions where client_request_id = v_key;
    if v_tx.id is not null then
      return jsonb_build_object(
        'id', v_tx.id,
        'transaction_number', v_tx.transaction_number,
        'total', v_tx.total,
        'duplicate', true,
        'kitchen_ticket_print_count', v_tx.kitchen_ticket_print_count
      );
    end if;
  end if;

  v_result := public.create_transaction_core(p_payload - 'client_request_id');

  if v_key is not null then
    update public.transactions
    set client_request_id = v_key
    where id = (v_result ->> 'id')::uuid;
  end if;

  return v_result || jsonb_build_object('duplicate', false, 'kitchen_ticket_print_count', 0);
end;
$$;

revoke all on function public.create_transaction(jsonb) from public, anon;
grant execute on function public.create_transaction(jsonb) to authenticated;
