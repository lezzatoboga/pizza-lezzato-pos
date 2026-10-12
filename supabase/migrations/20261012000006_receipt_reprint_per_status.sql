-- =====================================================================
-- Tanda CETAK ULANG di struk per status (keputusan Owner 2026-10-12)
--
-- Struk Lunas yang dicetak setelah struk Belum Lunas BUKAN cetak ulang
-- (dokumen dengan status berbeda). CETAK ULANG hanya kalau struk dengan
-- STATUS YANG SAMA sudah pernah dicetak. Aplikasi membandingkan status
-- struk terakhir yang dicetak (receipt_printed_status, sudah diisi
-- mark_receipt_printed) dengan status bayar saat ini. Status tidak bisa
-- kembali dari Lunas ke Belum Lunas, jadi "status terakhir sama" =
-- "struk berstatus ini sudah pernah dicetak". Tiket dapur tidak berubah.
--
-- CATATAN: kalau nanti pembayaran online (mis. Midtrans) atau jembatan
-- pesanan memperkenalkan pembatalan pembayaran / refund (Lunas → Belum
-- Lunas), aturan ini perlu ditinjau ulang — kemungkinan beralih ke
-- penghitung cetak per status (receipt_unpaid_print_count /
-- receipt_paid_print_count).
--
-- Perubahan: fungsi internal transaction_print_data (isi lama
-- get_transaction_print_data, lihat 20261012000003) ikut mengembalikan
-- receipt_printed_status. create or replace mempertahankan hak akses
-- (tetap tertutup untuk anon/authenticated; dipanggil lewat
-- get_transaction_print_data yang memeriksa hak lihat). Tidak ada data
-- yang diubah.
-- =====================================================================

create or replace function public.transaction_print_data(p_transaction_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tx     public.transactions;
  v_result jsonb;
begin
  if public.current_pos_user_id() is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;

  select * into v_tx from public.transactions where id = p_transaction_id;
  if v_tx.id is null then
    raise exception 'TRANSAKSI_TIDAK_ADA: transaksi tidak ditemukan';
  end if;

  select jsonb_build_object(
    'id', v_tx.id,
    'outlet_id', v_tx.outlet_id,
    'transaction_number', v_tx.transaction_number,
    'created_at', v_tx.created_at,
    'channel', v_tx.channel,
    'sales_type', v_tx.sales_type,
    'status', v_tx.status,
    'platform_name', (select name from public.marketplace_platforms where id = v_tx.marketplace_platform_id),
    'customer_name', v_tx.customer_name,
    'delivery_address', v_tx.delivery_address,
    'delivery_patokan', v_tx.delivery_patokan,
    'notes', v_tx.notes,
    'cashier_name', (select name from public.pos_users where id = v_tx.cashier_id),
    'courier_type', v_tx.courier_type,
    'courier_name', case v_tx.courier_type
        when 'karyawan' then (select name from public.pos_users where id = v_tx.courier_user_id)
        when 'freelance' then (select name from public.couriers where id = v_tx.courier_id)
        when 'shopee_express' then 'Shopee Express'
        when 'maxim' then 'Maxim'
      end,
    'subtotal', v_tx.subtotal,
    'discount_code', v_tx.discount_code,
    'discount_amount', v_tx.discount_amount,
    'manual_discount_type', v_tx.manual_discount_type,
    'manual_discount_value', v_tx.manual_discount_value,
    'manual_discount_amount', v_tx.manual_discount_amount,
    'shipping_cost', v_tx.shipping_cost,
    'total', v_tx.total,
    'payment_status', v_tx.payment_status,
    'payment_method_name', (select name from public.payment_methods where id = v_tx.payment_method_id),
    'payment_is_cash', (select is_cash from public.payment_methods where id = v_tx.payment_method_id),
    'bank_name', (select bank_name from public.bank_accounts where id = v_tx.bank_account_id),
    'amount_paid', v_tx.amount_paid,
    'change_amount', v_tx.change_amount,
    'kitchen_ticket_print_count', v_tx.kitchen_ticket_print_count,
    'receipt_print_count', v_tx.receipt_print_count,
    'receipt_printed_status', v_tx.receipt_printed_status,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'item_type', i.item_type,
        'qty', i.qty,
        'product_name', i.product_name_snapshot,
        'variant_name', i.variant_name_snapshot,
        'unit_price', i.unit_price,
        'subtotal_item', i.subtotal_item,
        'notes', i.notes,
        'package_items', i.package_items_snapshot,
        'package_choices', i.package_choices_snapshot,
        'package_note', i.package_note_snapshot,
        'addons', coalesce((
          select jsonb_agg(jsonb_build_object(
            'name', a.addon_name_snapshot, 'qty', a.qty, 'unit_price', a.unit_price
          ) order by a.created_at, a.id)
          from public.transaction_item_addons a
          where a.transaction_item_id = i.id
        ), '[]')
      ) order by i.created_at, i.id)
      from public.transaction_items i
      where i.transaction_id = v_tx.id
    ), '[]')
  ) into v_result;

  return v_result;
end;
$$;
