-- =====================================================================
-- FIXTURE pengembangan jembatan pesanan website — HANYA untuk database
-- lokal/uji. JANGAN dijalankan ke Supabase produksi.
--
-- Isi:
--   1. Menu rekaan (lewat apply_menu_sync) yang cocok dengan pesanan fixture.
--   2. dev_web_fixture_orders(): pesanan website rekaan berbentuk persis
--      baris pos.v_pesanan + pos.v_item_pesanan (docs/KONTRAK-DATA-POS.md
--      §2.1 & §2.9). Data pribadi rekaan.
--
-- Pesanan:
--   F-DLV  Delivery, format baru (_format 2): pizza Large + 2 topping,
--          Rice Box dgn pilihan saus, voucher, ongkir 5.000
--   F-PCK  Pick Up, format LAMA (pemetaan nama): pizza Medium + topping,
--          paket dgn 2 pilihan
--   F-DIN  Dine-in: menu tak dikenal + topping tak dikenal (peringatan),
--          menunggu_admin = true
--   F-ONL  Delivery online LUNAS (terkunci_edit)
-- =====================================================================

select public.apply_menu_sync($menu${
  "products": [
    {"id":"chk5","name":"Chicken Supreme","category_slug":"pizza","kind":"sized","active":true,"sort_order":1},
    {"id":"sig1","name":"Pizza Kotak Beef","category_slug":"pizza-signature","kind":"simple","base_price":89000,"active":true,"sort_order":2},
    {"id":"rb2","name":"Rice Box Chicken","category_slug":"rice-box","kind":"simple","base_price":24000,"active":true,"sort_order":3},
    {"id":"tea1","name":"Lemon Tea","category_slug":"minuman","kind":"simple","base_price":12000,"active":true,"sort_order":4},
    {"id":"pb1","name":"Paket Berdua","category_slug":"paket","kind":"package","base_price":125000,"active":true,"sort_order":5,
     "package_items":["1 Medium Pizza","1 Spaghetti"],
     "package_choices":[{"key":"pizza","label":"Pilihan Pizza","options":["Meat Lovers","Chicken Supreme"]},
                        {"key":"spaghetti","label":"Pilihan Spaghetti","options":["Carbonara","Bolognese"]}]}
  ],
  "variants": [
    {"id":"a0000000-0000-0000-0000-000000000001","menu_item_id":"chk5","variant_key":"personal","label":"Personal","price":45000,"sort_order":1},
    {"id":"a0000000-0000-0000-0000-000000000002","menu_item_id":"chk5","variant_key":"medium","label":"Medium","price":85000,"sort_order":2},
    {"id":"a0000000-0000-0000-0000-000000000003","menu_item_id":"chk5","variant_key":"large","label":"Large","price":110000,"sort_order":3}
  ],
  "toppings": [
    {"id":"keju","name":"Keju","active":true,"sort_order":1},
    {"id":"sosis","name":"Sosis","active":true,"sort_order":2}
  ],
  "topping_prices": [
    {"variant_key":"personal","price":6000},
    {"variant_key":"medium","price":9000},
    {"variant_key":"large","price":12000}
  ],
  "categories": [
    {"slug":"pizza","label":"Pizza","sort_order":1},
    {"slug":"pizza-signature","label":"Pizza Kotak","sort_order":2},
    {"slug":"rice-box","label":"Rice Box","sort_order":3},
    {"slug":"paket","label":"Paket","sort_order":4},
    {"slug":"minuman","label":"Minuman","sort_order":5}
  ]
}$menu$::jsonb, 'manual') is not null as menu_fixture;

create or replace function public.dev_web_fixture_orders()
returns jsonb
language sql
as $fx$
  select jsonb_build_array(
    -- F-DLV: Delivery, format baru
    jsonb_build_object(
      'header', jsonb_build_object(
        'id', 'b0000000-0000-0000-0000-000000000001', 'order_code', 'PL-FDLV01',
        'created_at', now() - interval '3 minutes', 'updated_at', now() - interval '3 minutes',
        'status', 'baru', 'order_type', 'delivery', 'customer_id', null,
        'recipient_name', 'Rina Uji', 'recipient_phone', '+6281200000001',
        'address', 'Jl. Contoh No. 1', 'patokan', 'pagar hijau',
        'alamat_lat', 0.4801, 'alamat_lng', 101.4102, 'note', 'tanpa saus sambal',
        'subtotal', 158000, 'discount', 15800, 'voucher_code', 'HEMAT10',
        'ongkir_rupiah', 5000, 'diskon_ongkir', 0, 'total', 147200,
        'jarak_tagih_km', 2.312, 'metode_jarak', 'rute',
        'verification_status', 'not_required', 'discount_held', false, 'menunggu_admin', false,
        'diubah_di_pos', false, 'diubah_di_pos_at', null,
        'metode_bayar', 'bayar_di_tempat', 'status_bayar', 'belum_bayar',
        'dibayar_rupiah', null, 'dibayar_at', null, 'terkunci_edit', false),
      'items', jsonb_build_array(
        jsonb_build_object('id', 'c0000000-0000-0000-0000-000000000011', 'order_id', 'b0000000-0000-0000-0000-000000000001',
          'menu_id', 'chk5', 'name', 'Chicken Supreme (Large) + Topping: Keju, Sosis', 'unit_price', 134000, 'qty', 1,
          'line_total', 134000, 'original_unit_price', null, 'voucher_discount', 13400,
          'options', '{"ukuran":"Large","Topping Ekstra":"Keju, Sosis","_format":2,"_ukuran_key":"large","_topping_ids":["keju","sosis"]}'::jsonb),
        jsonb_build_object('id', 'c0000000-0000-0000-0000-000000000012', 'order_id', 'b0000000-0000-0000-0000-000000000001',
          'menu_id', 'rb2', 'name', 'Rice Box Chicken (Saos BBQ)', 'unit_price', 24000, 'qty', 1,
          'line_total', 24000, 'original_unit_price', null, 'voucher_discount', 2400,
          'options', '{"Pilihan Saus":"Saos BBQ","_format":2,"_pilihan":{"saus":"Saos BBQ"}}'::jsonb)
      )
    ),
    -- F-PCK: Pick Up, format LAMA
    jsonb_build_object(
      'header', jsonb_build_object(
        'id', 'b0000000-0000-0000-0000-000000000002', 'order_code', 'PL-FPCK02',
        'created_at', now() - interval '2 minutes', 'updated_at', now() - interval '2 minutes',
        'status', 'baru', 'order_type', 'takeaway', 'customer_id', null,
        'recipient_name', 'Budi Uji', 'recipient_phone', '+6281200000002',
        'address', null, 'patokan', null, 'alamat_lat', null, 'alamat_lng', null, 'note', null,
        'subtotal', 219000, 'discount', 0, 'voucher_code', null,
        'ongkir_rupiah', null, 'diskon_ongkir', 0, 'total', 219000,
        'jarak_tagih_km', null, 'metode_jarak', null,
        'verification_status', 'not_required', 'discount_held', false, 'menunggu_admin', false,
        'diubah_di_pos', false, 'diubah_di_pos_at', null,
        'metode_bayar', 'bayar_di_tempat', 'status_bayar', 'belum_bayar',
        'dibayar_rupiah', null, 'dibayar_at', null, 'terkunci_edit', false),
      'items', jsonb_build_array(
        jsonb_build_object('id', 'c0000000-0000-0000-0000-000000000021', 'order_id', 'b0000000-0000-0000-0000-000000000002',
          'menu_id', 'chk5', 'name', 'Chicken Supreme (Medium) + Topping: Keju', 'unit_price', 94000, 'qty', 1,
          'line_total', 94000, 'original_unit_price', null, 'voucher_discount', 0,
          'options', '{"ukuran":"Medium","Topping Ekstra":"Keju"}'::jsonb),
        jsonb_build_object('id', 'c0000000-0000-0000-0000-000000000022', 'order_id', 'b0000000-0000-0000-0000-000000000002',
          'menu_id', 'pb1', 'name', 'Paket Berdua (Meat Lovers, Carbonara)', 'unit_price', 125000, 'qty', 1,
          'line_total', 125000, 'original_unit_price', null, 'voucher_discount', 0,
          'options', '{"Pilihan Pizza":"Meat Lovers","Pilihan Spaghetti":"Carbonara"}'::jsonb)
      )
    ),
    -- F-DIN: Dine-in, menu & topping tak dikenal, menunggu admin
    jsonb_build_object(
      'header', jsonb_build_object(
        'id', 'b0000000-0000-0000-0000-000000000003', 'order_code', 'PL-FDIN03',
        'created_at', now() - interval '1 minute', 'updated_at', now() - interval '1 minute',
        'status', 'baru', 'order_type', 'dinein', 'customer_id', null,
        'recipient_name', 'Sari Uji', 'recipient_phone', '+6281200000003',
        'address', null, 'patokan', null, 'alamat_lat', null, 'alamat_lng', null, 'note', 'meja dekat jendela',
        'subtotal', 160000, 'discount', 16000, 'voucher_code', 'BARU10',
        'ongkir_rupiah', null, 'diskon_ongkir', 0, 'total', 144000,
        'jarak_tagih_km', null, 'metode_jarak', null,
        'verification_status', 'pending', 'discount_held', false, 'menunggu_admin', true,
        'diubah_di_pos', false, 'diubah_di_pos_at', null,
        'metode_bayar', 'bayar_di_tempat', 'status_bayar', 'belum_bayar',
        'dibayar_rupiah', null, 'dibayar_at', null, 'terkunci_edit', false),
      'items', jsonb_build_array(
        jsonb_build_object('id', 'c0000000-0000-0000-0000-000000000031', 'order_id', 'b0000000-0000-0000-0000-000000000003',
          'menu_id', 'zz9', 'name', 'Pizza Musim Hujan (Large)', 'unit_price', 99000, 'qty', 1,
          'line_total', 99000, 'original_unit_price', null, 'voucher_discount', 9900,
          'options', '{"ukuran":"Large"}'::jsonb),
        jsonb_build_object('id', 'c0000000-0000-0000-0000-000000000032', 'order_id', 'b0000000-0000-0000-0000-000000000003',
          'menu_id', 'chk5', 'name', 'Chicken Supreme (Personal) + Topping: Jamur', 'unit_price', 61000, 'qty', 1,
          'line_total', 61000, 'original_unit_price', null, 'voucher_discount', 6100,
          'options', '{"ukuran":"Personal","Topping Ekstra":"Jamur"}'::jsonb)
      )
    ),
    -- F-ONL: Delivery online, sudah lunas (terkunci_edit)
    jsonb_build_object(
      'header', jsonb_build_object(
        'id', 'b0000000-0000-0000-0000-000000000004', 'order_code', 'PL-FONL04',
        'created_at', now() - interval '30 seconds', 'updated_at', now() - interval '30 seconds',
        'status', 'baru', 'order_type', 'delivery', 'customer_id', null,
        'recipient_name', 'Andi Uji', 'recipient_phone', '+6281200000004',
        'address', 'Jl. Uji No. 4', 'patokan', null, 'alamat_lat', 0.4799, 'alamat_lng', 101.4088, 'note', null,
        'subtotal', 101000, 'discount', 0, 'voucher_code', null,
        'ongkir_rupiah', 3000, 'diskon_ongkir', 0, 'total', 104000,
        'jarak_tagih_km', 1.2, 'metode_jarak', 'rute',
        'verification_status', 'not_required', 'discount_held', false, 'menunggu_admin', false,
        'diubah_di_pos', false, 'diubah_di_pos_at', null,
        'metode_bayar', 'online', 'status_bayar', 'lunas',
        'dibayar_rupiah', 104000, 'dibayar_at', now() - interval '20 seconds', 'terkunci_edit', true),
      'items', jsonb_build_array(
        jsonb_build_object('id', 'c0000000-0000-0000-0000-000000000041', 'order_id', 'b0000000-0000-0000-0000-000000000004',
          'menu_id', 'sig1', 'name', 'Pizza Kotak Beef + Topping: Keju', 'unit_price', 101000, 'qty', 1,
          'line_total', 101000, 'original_unit_price', null, 'voucher_discount', 0,
          'options', '{"Topping Ekstra":"Keju","_format":2,"_topping_ids":["keju"]}'::jsonb)
      )
    )
  );
$fx$;
