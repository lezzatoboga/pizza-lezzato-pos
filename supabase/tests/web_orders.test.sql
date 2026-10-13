-- Uji jembatan pesanan website (tahap A, sisi POS).
-- Jalankan SETELAH semua migrasi + supabase/dev/web-orders-fixture.sql, di DB uji
-- dengan stub auth (auth.uid() membaca test.uid) — lihat runner di laporan tahap A.
-- Baris "harus …" menyebut hasil yang diharapkan.

select public.create_pos_user('Kasir Uji','kasir','1111') is not null as kasir;
select public.create_pos_user('Owner Uji','owner','3333') is not null as owner;
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000a2');
update public.pos_users set auth_user_id = '00000000-0000-0000-0000-0000000000a1' where name = 'Kasir Uji';
update public.pos_users set auth_user_id = '00000000-0000-0000-0000-0000000000a2' where name = 'Owner Uji';
create function wtx(code text) returns uuid language sql security definer as $$ select transaction_id from public.web_orders where order_code = code $$;
create function wid(code text) returns uuid language sql security definer as $$ select id from public.web_orders where order_code = code $$;
grant execute on function wtx(text), wid(text) to authenticated, service_role;
create function fx(code text) returns jsonb language sql as $$
  select o from jsonb_array_elements(public.dev_web_fixture_orders()) o where o -> 'header' ->> 'order_code' = code $$;
grant execute on function fx(text) to service_role;

\echo '=== 1. Tarik pertama (service_role): 4 pesanan baru'
set role service_role;
select public.apply_web_orders(public.dev_web_fixture_orders()) as hasil_harus_created_4;
reset role;
select order_code, web_status, menunggu_admin, terkunci_edit, transaction_id is not null as ada_transaksi
from public.web_orders order by order_code;

\echo '--- total POS = total website (harus sama semua), shift kosong, status diterima'
select w.order_code, t.sales_type, t.subtotal, t.discount_amount, t.shipping_cost, t.total,
       (w.header ->> 'total')::bigint as total_web, t.total = (w.header ->> 'total')::bigint as sama,
       t.shift_id is null as tanpa_shift, t.order_status, t.web_order_code = w.order_code as kode_ok,
       w.header_notice
from public.web_orders w join public.transactions t on t.id = w.transaction_id order by w.order_code;

\echo '--- pemetaan item (kunci teknis / nama / gagal → peringatan)'
select w.order_code, i.product_name_snapshot, i.variant_name_snapshot, i.unit_price, i.qty, i.subtotal_item,
       (select string_agg(a.addon_name_snapshot || '@' || a.unit_price, ',') from public.transaction_item_addons a where a.transaction_item_id = i.id) as topping,
       (select string_agg(c ->> 'label' || '=' || (c ->> 'value'), ',') from jsonb_array_elements(i.package_choices_snapshot) c) as pilihan,
       i.mapping_warning
from public.web_orders w join public.transaction_items i on i.transaction_id = w.transaction_id
order by w.order_code, i.created_at;

\echo '--- antrean: 4 x diterima'
select w.order_code, o.status, o.sent_at is null as belum_kirim from public.web_status_outbox o join public.web_orders w on w.id = o.web_order_id order by o.id;

\echo '=== 2. Tarik ulang identik: tidak menggandakan'
set role service_role;
select public.apply_web_orders(public.dev_web_fixture_orders()) as hasil_harus_updated_4;
reset role;
select count(*) as transaksi_harus_4 from public.transactions where channel = 'website';
select count(*) as antrean_harus_4 from public.web_status_outbox;

\echo '=== 3. Admin website mencabut diskon F-DLV (sebelum diproses) → angka POS ikut header terbaru'
set role service_role;
select public.apply_web_orders(jsonb_build_array(jsonb_build_object('header',
  (fx('PL-FDLV01') -> 'header') || '{"discount":0,"voucher_code":null,"total":163000}'::jsonb))) is not null;
reset role;
select discount_amount as diskon_harus_0, discount_code, total as total_harus_163000 from public.transactions where id = wtx('PL-FDLV01');

\echo '=== 3b. Ongkir diubah kasir (penanda diterima) → admin ubah header: ongkir kasir dipertahankan, diskon ikut header'
set role service_role;
select public.web_mark_flag_ok(wid('PL-FDLV01'), '{"ok":true,"diubah_di_pos":true}') is null as penanda_dlv;
reset role;
set role authenticated;
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select public.edit_web_order(wtx('PL-FDLV01'), '{"lines":[{"ref":"c0000000-0000-0000-0000-000000000011","qty":1},{"ref":"c0000000-0000-0000-0000-000000000012","qty":1}],"shipping_cost":8000}') as edit_ongkir;
reset role;
set role service_role;
select public.apply_web_orders(jsonb_build_array(jsonb_build_object('header',
  (fx('PL-FDLV01') -> 'header') || '{"discount":0,"voucher_code":null,"ongkir_rupiah":6000,"total":164000}'::jsonb))) is not null;
reset role;
select shipping_cost as ongkir_harus_8000, discount_amount as diskon_harus_0, total as total_harus_166000 from public.transactions where id = wtx('PL-FDLV01');

\echo '=== 4. Kasir: Konfirmasi & Proses'
set role authenticated;
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select count(*) as kasir_lihat_pesanan_web_harus_4 from public.web_orders;
select public.confirm_web_order(wtx('PL-FDIN03'));
select public.confirm_web_order(wtx('PL-FDLV01'));
select (public.open_shift((select id from public.outlets limit 1), 100000)).status as buka_shift;
select public.confirm_web_order(wtx('PL-FDLV01')) as konfirmasi_dlv;
select public.confirm_web_order(wtx('PL-FDLV01'));
select public.open_web_order(wid('PL-FPCK02')) is not null as buka_pck;
reset role;
select order_code, opened_at is not null as dibuka from public.web_orders order by order_code;
select t.order_status, t.shift_id is not null as shift_terisi, t.cashier_id is not null as kasir_terisi from public.transactions t where t.id = wtx('PL-FDLV01');

\echo '=== 5. Edit kasir'
set role authenticated;
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select public.edit_web_order(wtx('PL-FDLV01'), '{"lines":[]}');
select public.edit_web_order(wtx('PL-FPCK02'), '{"lines":[{"ref":"c0000000-0000-0000-0000-000000000021","qty":2}]}');
reset role;
\echo '--- penanda diterima website (Edge Function web-order-edit)'
set role service_role;
select public.web_mark_flag_ok(wid('PL-FPCK02'), '{"ok":true,"diubah_di_pos":true,"metode_bayar":"bayar_di_tempat"}') is not null;
select public.web_mark_flag_ok(wid('PL-FONL04'), '{"ok":true}') is not null;
reset role;
set role authenticated;
set test.uid = '00000000-0000-0000-0000-0000000000a1';
\echo '--- PCK: pizza jadi 2, paket dihapus, tambah 2 Lemon Tea (harga POS 12.000)'
select public.edit_web_order(wtx('PL-FPCK02'),
  '{"lines":[{"ref":"c0000000-0000-0000-0000-000000000021","qty":2}],"new_items":[{"product_id":"tea1","qty":2}]}') as edit_pck;
select public.edit_web_order(wtx('PL-FONL04'), '{"lines":[]}');
select public.edit_web_order(wtx('PL-FPCK02'), '{"lines":[],"new_items":[]}');
reset role;
select i.product_name_snapshot, i.qty, i.unit_price, i.subtotal_item, i.source_line_ref is not null as dari_website
from public.transaction_items i where i.transaction_id = wtx('PL-FPCK02') order by i.created_at;
select subtotal as subtotal_harus_212000, total, last_edited_by is not null as tercatat_editor,
       original_order_snapshot -> 'header' ->> 'total' as total_asli_tetap
from public.transactions where id = wtx('PL-FPCK02');

\echo '=== 6. Siap & Selesai'
set role authenticated;
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select public.ready_web_order(wtx('PL-FDLV01')) as siap_dlv;
select public.finish_web_order(wtx('PL-FDLV01'));
select public.set_transaction_courier(wtx('PL-FDLV01'), '{"type":"maxim"}') ->> 'type' as kurir;
select public.pay_transaction(wtx('PL-FDLV01'), (select id from public.payment_methods where code = 'cash'), 200000) ->> 'change_amount' as kembalian;
select public.finish_web_order(wtx('PL-FDLV01')) as selesai_dlv;
reset role;
select w.order_code, o.status, o.created_by is not null as oleh_kasir from public.web_status_outbox o join public.web_orders w on w.id = o.web_order_id where w.order_code = 'PL-FDLV01' order by o.id;

\echo '=== 7. Dibatalkan di website'
set role authenticated;
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select public.mark_kitchen_ticket_printed(wtx('PL-FPCK02')) as tiket_pck;
reset role;
set role service_role;
select public.apply_web_orders(jsonb_build_array(
  jsonb_build_object('header', (fx('PL-FPCK02') -> 'header') || '{"status":"batal"}'::jsonb),
  jsonb_build_object('header', (fx('PL-FDLV01') -> 'header') || '{"status":"batal","discount":0,"voucher_code":null,"total":163000}'::jsonb),
  -- lunas online (belum tercatat di POS): peringatan saja, tidak di-void
  jsonb_build_object('header', (fx('PL-FONL04') -> 'header') || '{"status":"batal"}'::jsonb)
)) as hasil_harus_voided_1;
reset role;
select w.order_code, t.status, t.void_source, t.void_reason, t.voided_by is null as tanpa_kasir,
       w.void_slip_pending, w.cancel_notice is not null as ada_peringatan
from public.web_orders w join public.transactions t on t.id = w.transaction_id
where w.order_code in ('PL-FPCK02', 'PL-FDLV01', 'PL-FONL04') order by w.order_code;
select count(*) as antrean_dibatalkan_dari_website_harus_0 from public.web_status_outbox o where o.status = 'dibatalkan';

\echo '=== 8. Void oleh kasir (F-DIN) → antre dibatalkan'
set role authenticated;
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select public.void_transaction(wtx('PL-FDIN03'), 'pelanggan_batal') ->> 'status' as void_din_harus_voided;
reset role;
select w.order_code, o.status from public.web_status_outbox o join public.web_orders w on w.id = o.web_order_id where o.status = 'dibatalkan';

\echo '=== 9. Antrean: satu baris berikutnya per pesanan, coba ulang, gagal permanen'
set role service_role;
select string_agg(w.order_code || ':' || o.status, ', ' order by o.id) as due from public.web_outbox_due(20) o join public.web_orders w on w.id = o.web_order_id;
select public.web_outbox_mark((select min(id) from public.web_status_outbox where web_order_id = wid('PL-FDLV01')), 'ok', '{"ok":true,"berubah":true}') is not null;
select public.web_outbox_mark((select min(id) from public.web_status_outbox where web_order_id = wid('PL-FONL04')), 'retry', null, 'timeout') is not null;
select public.web_outbox_mark((select min(id) from public.web_status_outbox where web_order_id = wid('PL-FDIN03')), 'failed', null, 'menunggu_admin') is not null;
select string_agg(w.order_code || ':' || o.status, ', ' order by o.id) as due_setelah from public.web_outbox_due(20) o join public.web_orders w on w.id = o.web_order_id;
reset role;
select w.order_code, o.status, o.attempts, o.sent_at is not null as terkirim, o.failed_at is not null as gagal, o.next_attempt_at > now() as menunggu_jeda
from public.web_status_outbox o join public.web_orders w on w.id = o.web_order_id order by o.id;

\echo '=== 10. Lease: run kedua ditolak selama run pertama berjalan'
set role service_role;
select public.web_bridge_lease(60) is not null as lease_1, public.web_bridge_lease(60) is null as lease_2_ditolak;
select public.web_bridge_release((select lease_token from public.web_bridge_state), '{"ok":true,"view_empty":false,"orders_cursor":"2026-10-14T00:00:00Z"}') is not null;
select public.web_bridge_lease(60) is not null as lease_lagi;
reset role;
select last_ok_at is not null as ok_tercatat, view_empty, orders_cursor from public.web_bridge_state;

\echo '=== 11. Hak akses'
set role authenticated;
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select public.apply_web_orders('[]');
select public.web_mark_flag_ok(wid('PL-FDLV01'), '{}');
reset role;
set role anon;
select count(*) from public.web_orders;
reset role;

\echo '=== 12. Data cetak: kode pesanan & PERIKSA'
set role authenticated;
set test.uid = '00000000-0000-0000-0000-0000000000a2';
select x ->> 'web_order_code' as kode, (select string_agg(coalesce(i ->> 'mapping_warning', '-'), ' | ') from jsonb_array_elements(x -> 'items') i) as peringatan
from (select public.get_transaction_print_data(wtx('PL-FDIN03')) x) s;
reset role;

\echo '=== 13. Saklar go-live: kirim ulang status terakhir setelah menyala lagi'
-- Selama mati: semua status yang antre ditolak sebelum_go_live.
update public.web_status_outbox set failed_at = now(), last_error = 'sebelum_go_live'
where sent_at is null and failed_at is null;
-- Keadaan website saat menyala lagi (diperbarui tarik terakhir):
--   F-DLV  website diproses, POS selesai      → kirim ulang 'selesai'
--   F-DIN  website selesai, POS dibatalkan    → konflik status akhir → daftar Owner
--   F-ONL  website = status POS               → tidak dikirim
update public.web_orders set web_status = 'diproses' where order_code = 'PL-FDLV01';
update public.web_orders set web_status = 'selesai' where order_code = 'PL-FDIN03';
update public.web_orders w set web_status = t.order_status from public.transactions t
where t.id = w.transaction_id and w.order_code = 'PL-FONL04';
select w.order_code, t.status, t.order_status, w.web_status from public.web_orders w
join public.transactions t on t.id = w.transaction_id where w.order_code in ('PL-FDLV01', 'PL-FDIN03', 'PL-FONL04') order by 1;
set role authenticated;
set test.uid = '00000000-0000-0000-0000-0000000000a2';
select public.web_resend_after_golive();
reset role;
set role service_role;
select public.web_resend_after_golive() as hasil_harus_queued1_manual1_skipped1;
select public.web_resend_after_golive() as ulang_harus_kosong;
select string_agg(w.order_code || ':' || o.status, ', ') as due_harus_FDLV_selesai from public.web_outbox_due(20) o join public.web_orders w on w.id = o.web_order_id;
reset role;
select w.order_code, o.status, o.resend, o.failed_at is not null as gagal, o.last_error
from public.web_status_outbox o join public.web_orders w on w.id = o.web_order_id where o.resend order by o.id;
select count(*) as sebelum_go_live_belum_ditangani_harus_0 from public.web_status_outbox
where last_error = 'sebelum_go_live' and superseded_at is null;
\echo '--- kiriman ulang ditolak website → gagal permanen, tidak antre lagi, masuk daftar Owner'
set role service_role;
select public.web_outbox_mark((select id from public.web_status_outbox where resend and failed_at is null), 'failed', null, 'transisi_ditolak') is not null;
select count(*) as due_harus_0 from public.web_outbox_due(20);
reset role;
select w.order_code, o.status, o.last_error from public.web_status_outbox o join public.web_orders w on w.id = o.web_order_id
where o.resend and o.failed_at is not null and o.resolved_at is null and o.last_error <> 'sebelum_go_live' order by o.id;
\echo '--- hanya Owner yang menandai selesai'
set role authenticated;
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select public.web_resend_resolve((select min(id) from public.web_status_outbox where resend and failed_at is not null));
set test.uid = '00000000-0000-0000-0000-0000000000a2';
select public.web_resend_resolve(o.id) from public.web_status_outbox o where o.resend and o.failed_at is not null and o.resolved_at is null;
select count(*) as daftar_owner_harus_0 from public.web_status_outbox where resend and failed_at is not null and resolved_at is null;
reset role;
