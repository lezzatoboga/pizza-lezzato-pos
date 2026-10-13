-- =====================================================================
-- 03_data_rekaan.sql — DIBUAT OTOMATIS oleh scripts/buat-paket-website-tiruan.mjs (repo website).
-- Data REKAAN seluruhnya (tak ada data pelanggan/pesanan sungguhan). Aman diulang: data rekaan lama
-- dihapus lewat penanda (PL-REKAAN%, "Pelanggan Rekaan%", voucher REKAAN%) lalu dibuat ulang.
-- Menu = src/lib/menu/data.ts (sumber seed awal) — harga/nama bisa beda dari menu live.
-- Pesanan dibuat lewat public.create_order (jalur yang sama dgn website), baris item persis seperti
-- server membuatnya (options + kunci teknis _format/_ukuran_key/_varian_key/_pilihan/_topping_ids).
-- go_live_at = 20 hari lalu. Jalankan sebagai postgres (superuser lokal).
-- =====================================================================
begin;

-- Sapu data rekaan lama (order_status_log hanya-tambah: barisnya tetap, tanpa FK — tak mengganggu).
delete from public.voucher_redemptions where order_id in (select id from public.orders where order_code like 'PL-REKAAN%');
delete from public.pembayaran where order_id in (select id from public.orders where order_code like 'PL-REKAAN%');
delete from public.order_items where order_id in (select id from public.orders where order_code like 'PL-REKAAN%');
delete from public.orders where order_code like 'PL-REKAAN%';
delete from public.alamat_pelanggan where customer_id in (select id from public.customers where name like 'Pelanggan Rekaan%');
delete from public.customers where name like 'Pelanggan Rekaan%';
delete from public.vouchers where code like 'REKAAN%';

-- Menu (58 item, 55 varian) — upsert.
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('ps1', 'paket-sendiri', 'paket-sendiri', 'package', 'Paket Andalan 1', 'Perpaduan sempurna untuk makan sendiri yang tetap lengkap.', null, null, 40000, array['1 Personal Pizza', '1 French Fries', '1 Jasmine Tea']::text[], '[{"key":"pizza","label":"Pilihan Pizza","options":["Meat Lovers","Chicken Mania"]}]'::jsonb, null, 0, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('ps2', 'paket-sendiri', 'paket-sendiri', 'package', 'Paket Manis 1', 'Manisnya dessert favorit, teman sempurna untuk pizza.', null, null, 40000, array['1 Personal Pizza', '1 Silky Pudding Chocolate', '1 Jasmine Tea']::text[], '[{"key":"pizza","label":"Pilihan Pizza","options":["Meat Lovers","Chicken Mania"]}]'::jsonb, null, 1, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('ps3', 'paket-sendiri', 'paket-sendiri', 'package', 'Paket Doyan Keju', 'Untuk pecinta keju, puas keju sepanjang waktu.', null, null, 41000, array['1 Personal Pizza', '1 Mac & Cheese']::text[], '[]'::jsonb, 'Pizza: Cheese Only', 2, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('ps4', 'paket-sendiri', 'paket-sendiri', 'package', 'Paket Santai 1', 'Santai, ringan, dan manisnya pas. Cocok untuk me time-mu.', null, null, 42000, array['1 Personal Pizza', 'Puff Pastry (2 pcs)', '1 Jasmine Tea']::text[], '[{"key":"pizza","label":"Pilihan Pizza","options":["Meat Lovers","Chicken Mania"]}]'::jsonb, null, 3, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('ps5', 'paket-sendiri', 'paket-sendiri', 'package', 'Paket Hangat', 'Hangatnya zuppa soup, teman pas untuk pizza favoritmu.', null, null, 43000, array['1 Personal Pizza', '1 Zuppa Soup']::text[], '[{"key":"pizza","label":"Pilihan Pizza","options":["Meat Lovers","Chicken Mania"]}]'::jsonb, null, 4, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('pb1', 'paket-berdua', 'paket-berdua', 'package', 'Paket Andalan 2', 'Perpaduan lengkap untuk menikmati momen santai berdua.', null, null, 62000, array['1 Medium Pizza', '1 French Fries', '2 Jasmine Tea']::text[], '[{"key":"pizza","label":"Pilihan Pizza","options":["Meat Lovers","Chicken Mania"]}]'::jsonb, null, 0, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('pb2', 'paket-berdua', 'paket-berdua', 'package', 'Paket Manis 2', 'Lengkapi kebersamaan dengan sentuhan dessert favorit.', null, null, 73000, array['1 Medium Pizza', '2 Silky Pudding', '2 Jasmine Tea']::text[], '[{"key":"pizza","label":"Pilihan Pizza","options":["Meat Lovers","Chicken Mania"]}]'::jsonb, null, 1, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('pb3', 'paket-berdua', 'paket-berdua', 'package', 'Paket Santai 2', 'Cocok untuk menemani obrolan panjang bersama.', null, null, 73000, array['1 Medium Pizza', 'Puff Pastry (4 pcs)', '2 Jasmine Tea']::text[], '[{"key":"pizza","label":"Pilihan Pizza","options":["Meat Lovers","Chicken Mania"]}]'::jsonb, null, 2, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('pb4', 'paket-berdua', 'paket-berdua', 'package', 'Paket Istimewa', 'Perpaduan gurih dan manis untuk momen yang lebih berkesan.', null, null, 73000, array['1 Medium Pizza', 'Puff Pastry (2 pcs)', '2 Silky Pudding']::text[], '[{"key":"pizza","label":"Pilihan Pizza","options":["Meat Lovers","Chicken Mania"]}]'::jsonb, null, 3, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('pk1', 'paket-keluarga', 'paket-keluarga', 'package', 'Paket Lengkap', 'Hidangan lengkap untuk menemani momen kebersamaan seluruh keluarga.', null, null, 163000, array['1 Large Pizza', '2 Spaghetti', '2 Silky Pudding Chocolate', '1 Puff Pastry (4 pcs)']::text[], '[{"key":"pizza","label":"Pilihan Pizza","options":["Meat Lovers","Chicken Mania"]},{"key":"spaghetti","label":"Pilihan Spaghetti","options":["Bolognese","Carbonara"]}]'::jsonb, null, 0, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('pk2', 'paket-keluarga', 'paket-keluarga', 'package', 'Paket Bahagia', 'Pilihan favorit keluarga pecinta menu creamy.', null, null, 157000, array['1 Large Pizza', '2 Mac & Cheese', '2 Silky Pudding', '1 Puff Pastry (4 pcs)']::text[], '[{"key":"pizza","label":"Pilihan Pizza","options":["Meat Lovers","Chicken Mania"]}]'::jsonb, null, 1, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('pk3', 'paket-keluarga', 'paket-keluarga', 'package', 'Paket Akrab', 'Pilihan sempurna untuk menikmati momen akrab bersama keluarga.', null, null, 136000, array['1 Pizza Large', '2 Zuppa Soup', '4 cup Jasmine Tea']::text[], '[{"key":"pizza","label":"Pilihan Pizza","options":["Meat Lovers","Chicken Mania"]}]'::jsonb, null, 2, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('pk4', 'paket-keluarga', 'paket-keluarga', 'package', 'Paket Ceria', 'Perpaduan gurih dan manis yang melengkapi waktu bahagia bersama keluarga.', null, null, 140000, array['1 Pizza Large', '2 cup Silky Pudding', '1 Puff Pastry (4 pcs)', '4 cup Jasmine Tea']::text[], '[{"key":"pizza","label":"Pilihan Pizza","options":["Meat Lovers","Chicken Mania"]}]'::jsonb, null, 3, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('beef1', 'pizza-beef', 'pizza-beef', 'sized', 'Seasoned Beef', 'Olahan daging sapi berbumbu dengan rasa gurih yang seimbang.', '🥩', null, null, '{}'::text[], '[]'::jsonb, null, 0, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('beef2', 'pizza-beef', 'pizza-beef', 'sized', 'Beef Sausage', 'Potongan sosis sapi dengan rasa gurih yang akrab di lidah.', '🥩', null, null, '{}'::text[], '[]'::jsonb, null, 1, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('beef3', 'pizza-beef', 'pizza-beef', 'sized', 'Beef Pepperoni', 'Irisan beef pepperoni dengan sentuhan saus BBQ yang smoky.', '🥩', null, null, '{}'::text[], '[]'::jsonb, null, 2, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('beef4', 'pizza-beef', 'pizza-beef', 'sized', 'Beef Black Pepper', 'Daging sapi giling berbumbu lada hitam, aromatik dan kaya rasa.', '🥩', null, null, '{}'::text[], '[]'::jsonb, null, 3, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('beef5', 'pizza-beef', 'pizza-beef', 'sized', 'Meat Lovers', 'Perpaduan olahan daging sapi berbumbu dan potongan sosis sapi.', '🥩', null, null, '{}'::text[], '[]'::jsonb, null, 4, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('beef6', 'pizza-beef', 'pizza-beef', 'sized', 'Beef Mushroom', 'Jamur kancing lembut melengkapi gurihnya olahan daging sapi.', '🥩', null, null, '{}'::text[], '[]'::jsonb, null, 5, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('beef7', 'pizza-beef', 'pizza-beef', 'sized', 'Beef Supreme', 'Daging sapi berbumbu, sosis sapi, jamur kancing & jagung manis.', '🥩', null, null, '{}'::text[], '[]'::jsonb, null, 6, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('chk1', 'pizza-chicken', 'pizza-chicken', 'sized', 'Seasoned Chicken', 'Daging ayam cincang berbumbu kari dengan aroma rempah khas.', '🍗', null, null, '{}'::text[], '[]'::jsonb, null, 0, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('chk2', 'pizza-chicken', 'pizza-chicken', 'sized', 'Chicken Sausage', 'Potongan sosis ayam dengan rasa gurih yang ringan.', '🍗', null, null, '{}'::text[], '[]'::jsonb, null, 1, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('chk3', 'pizza-chicken', 'pizza-chicken', 'sized', 'Black Pepper Chicken', 'Daging ayam cincang berbumbu lada hitam, kaya dan berani.', '🍗', null, null, '{}'::text[], '[]'::jsonb, null, 2, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('chk4', 'pizza-chicken', 'pizza-chicken', 'sized', 'Chicken Mania', 'Perpaduan daging ayam cincang berbumbu kari dan sosis ayam.', '🍗', null, null, '{}'::text[], '[]'::jsonb, null, 3, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('chk5', 'pizza-chicken', 'pizza-chicken', 'sized', 'Chicken Supreme', 'Ayam cincang kari, sosis sapi, jamur kancing & jagung manis.', '🍗', null, null, '{}'::text[], '[]'::jsonb, null, 4, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('umm1', 'pizza-umami', 'pizza-umami', 'sized', 'Cheese Only', 'Perpaduan keju mozzarella dan cheddar yang lembut.', '🧀', null, null, '{}'::text[], '[]'::jsonb, null, 0, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('umm2', 'pizza-umami', 'pizza-umami', 'sized', 'Cheese Beef', 'Keju mozzarella, cheddar, dan olahan daging sapi berbumbu.', '🧀', null, null, '{}'::text[], '[]'::jsonb, null, 1, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('umm3', 'pizza-umami', 'pizza-umami', 'sized', 'Tuna', 'Daging tuna dengan rasa gurih yang ringan.', '🧀', null, null, '{}'::text[], '[]'::jsonb, null, 2, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('umm4', 'pizza-umami', 'pizza-umami', 'sized', 'Tuna Corn', 'Daging tuna dan jagung manis, gurih berpadu manis.', '🧀', null, null, '{}'::text[], '[]'::jsonb, null, 3, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('umm5', 'pizza-umami', 'pizza-umami', 'sized', 'Mushroom', 'Jamur kancing sebagai bintang utama, ringan dan gurih umami.', '🧀', null, null, '{}'::text[], '[]'::jsonb, null, 4, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('sig1', 'pizza-signature', 'pizza-signature', 'simple', 'Kotak 4 Rasa', 'Satu kotak 30×30 cm berisi 4 rasa sekaligus: Meat Lovers, Chicken Mania, Beef Black Pepper, dan Cheese Only. Tidak perlu memilih topping — tinggal pesan, cocok untuk ramai-ramai.', '📦', null, 109000, '{}'::text[], '[]'::jsonb, null, 0, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('sd1', 'pendamping-zuppa', 'pendamping-zuppa', 'simple', 'Zuppa Soup', 'Creamy soup daging ayam, jagung, dan wortel dengan puff pastry renyah.', '🍲', null, 22000, '{}'::text[], '[]'::jsonb, null, 0, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('sd2', 'pendamping-zuppa', 'pendamping-zuppa', 'variant', 'Puff Pastry Chicken', 'Puff pastry renyah dengan isian olahan daging ayam yang gurih.', '🥐', null, null, '{}'::text[], '[]'::jsonb, null, 1, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('sd3', 'pendamping-zuppa', 'pendamping-zuppa', 'variant', 'Puff Pastry Chocolate', 'Puff pastry renyah dengan isian pasta cokelat yang manis.', '🥐', null, null, '{}'::text[], '[]'::jsonb, null, 2, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('sd4', 'pendamping-sides', 'pendamping-sides', 'simple', 'Choco Silky Pudding', 'Silky pudding cokelat dengan lapisan vla vanilla yang lembut.', '🍮', null, 12000, '{}'::text[], '[]'::jsonb, null, 0, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('sd5', 'pendamping-sides', 'pendamping-sides', 'simple', 'Chicken Strips', 'Filet dada ayam berbalut tepung crispy, renyah dan juicy.', '🍗', null, 25000, '{}'::text[], '[]'::jsonb, null, 1, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('sd6', 'pendamping-sides', 'pendamping-sides', 'simple', 'French Fries', 'Kentang goreng dengan tekstur renyah di luar, lembut di dalam.', '🍟', null, 12000, '{}'::text[], '[]'::jsonb, null, 2, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('ps01', 'favorit-pasta', 'favorit-pasta', 'simple', 'Mac & Cheese', 'Makaroni dengan saus keju spesial yang creamy dan cheesy.', '🍝', null, 24000, '{}'::text[], '[]'::jsonb, null, 0, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('ps02', 'favorit-pasta', 'favorit-pasta', 'simple', 'Spaghetti Bolognese', 'Spaghetti dengan saus daging sapi giling yang gurih.', '🍝', null, 27000, '{}'::text[], '[]'::jsonb, null, 1, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('ps03', 'favorit-pasta', 'favorit-pasta', 'simple', 'Spaghetti Carbonara', 'Spaghetti dengan saus carbonara yang creamy dan lembut.', '🍝', null, 27000, '{}'::text[], '[]'::jsonb, null, 2, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('rb1', 'favorit-ricebox', 'favorit-ricebox', 'simple', 'Chicken Crispy Rice Box', 'Nasi dengan chicken crispy renyah, disajikan dengan sayuran segar.', '🍱', null, 22000, '{}'::text[], '[{"key":"saus","label":"Pilihan Saus","options":["Sambal Matah","Saos Spicy","Saos BBQ","Saos Mentega"]}]'::jsonb, null, 0, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('rb2', 'favorit-ricebox', 'favorit-ricebox', 'simple', 'Dori Crispy Rice Box', 'Nasi dengan dori crispy yang renyah dan lembut.', '🍱', null, 24000, '{}'::text[], '[{"key":"saus","label":"Pilihan Saus","options":["Sambal Matah","Saos Spicy","Saos BBQ","Saos Mentega"]}]'::jsonb, null, 1, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('tea1', 'minuman-tea', 'tea', 'simple', 'Jasmine Tea', 'Teh melati dengan aroma harum dan rasa ringan.', '🍵', null, 7000, '{}'::text[], '[]'::jsonb, null, 0, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('tea2', 'minuman-tea', 'tea', 'simple', 'Teh Tarik', 'Perpaduan teh hitam dan susu yang creamy dan nikmat.', '🍵', null, 8000, '{}'::text[], '[]'::jsonb, null, 1, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('tea3', 'minuman-tea', 'tea', 'simple', 'Japanese Green Tea', 'Teh hijau dengan karakter rasa segar dan alami.', '🍵', null, 8000, '{}'::text[], '[]'::jsonb, null, 2, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('tea4', 'minuman-tea', 'tea', 'simple', 'Tea Yakult', 'Perpaduan teh hitam dan Yakult, bold dan fruity.', '🍵', null, 14000, '{}'::text[], '[]'::jsonb, null, 3, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('rf1', 'minuman-tea', 'refresh', 'simple', 'Ocean Blue Citrus', 'Rasa citrus segar dengan sentuhan blue curacao.', '🍹', null, 10000, '{}'::text[], '[]'::jsonb, null, 0, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('rf2', 'minuman-tea', 'refresh', 'simple', 'Strawberry Mint', 'Manisnya stroberi dan segarnya mint.', '🍹', null, 10000, '{}'::text[], '[]'::jsonb, null, 1, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('rf3', 'minuman-tea', 'refresh', 'simple', 'Kiwi Bliss', 'Rasa kiwi dan mint yang menyegarkan.', '🍹', null, 10000, '{}'::text[], '[]'::jsonb, null, 2, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('cf1', 'minuman-coffee', 'coffee', 'simple', 'Americano', 'Espresso dengan karakter rasa yang tegas.', '☕', null, 12000, '{}'::text[], '[]'::jsonb, null, 0, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('cf2', 'minuman-coffee', 'coffee', 'simple', 'Milk Coffee Classic', 'Espresso dan susu, rasa seimbang dan creamy.', '☕', null, 15000, '{}'::text[], '[]'::jsonb, null, 1, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('cf3', 'minuman-coffee', 'coffee', 'simple', 'Milk Coffee Aren', 'Espresso dan susu dengan manis karamel gula aren.', '☕', null, 17000, '{}'::text[], '[]'::jsonb, null, 2, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('cf4', 'minuman-coffee', 'coffee', 'simple', 'Milk Coffee Vanilla', 'Espresso dan susu dengan aroma vanilla lembut.', '☕', null, 20000, '{}'::text[], '[]'::jsonb, null, 3, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('cf5', 'minuman-coffee', 'coffee', 'simple', 'Milk Coffee Butterscotch', 'Espresso dan susu dengan nuansa karamel mentega.', '☕', null, 20000, '{}'::text[], '[]'::jsonb, null, 4, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('ch1', 'minuman-coffee', 'choco', 'simple', 'Creamy Chocolate Classic', 'Susu creamy dengan karakter rasa cokelat khas.', '🍫', null, 17000, '{}'::text[], '[]'::jsonb, null, 0, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('ch2', 'minuman-coffee', 'choco', 'simple', 'Creamy Chocolate Vanilla', 'Cokelat asli dengan sentuhan aroma vanilla lembut.', '🍫', null, 20000, '{}'::text[], '[]'::jsonb, null, 1, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('ch3', 'minuman-coffee', 'choco', 'simple', 'Creamy Chocolate Mint', 'Cokelat asli dengan sensasi mint yang menyegarkan.', '🍫', null, 20000, '{}'::text[], '[]'::jsonb, null, 2, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
insert into public.menu_items (id, category_slug, section_key, kind, name, description, emoji, image_url, base_price, package_items, package_choices, package_note, sort_order, active)
values ('ch4', 'minuman-coffee', 'choco', 'simple', 'Creamy Chocolate Butterscotch', 'Cokelat asli dengan nuansa karamel mentega yang rich.', '🍫', null, 20000, '{}'::text[], '[]'::jsonb, null, 3, true)
on conflict (id) do update set category_slug = excluded.category_slug, section_key = excluded.section_key, kind = excluded.kind, name = excluded.name, description = excluded.description, emoji = excluded.emoji, base_price = excluded.base_price, package_items = excluded.package_items, package_choices = excluded.package_choices, package_note = excluded.package_note, sort_order = excluded.sort_order, active = true;
delete from public.menu_item_variants where menu_item_id in ('ps1', 'ps2', 'ps3', 'ps4', 'ps5', 'pb1', 'pb2', 'pb3', 'pb4', 'pk1', 'pk2', 'pk3', 'pk4', 'beef1', 'beef2', 'beef3', 'beef4', 'beef5', 'beef6', 'beef7', 'chk1', 'chk2', 'chk3', 'chk4', 'chk5', 'umm1', 'umm2', 'umm3', 'umm4', 'umm5', 'sig1', 'sd1', 'sd2', 'sd3', 'sd4', 'sd5', 'sd6', 'ps01', 'ps02', 'ps03', 'rb1', 'rb2', 'tea1', 'tea2', 'tea3', 'tea4', 'rf1', 'rf2', 'rf3', 'cf1', 'cf2', 'cf3', 'cf4', 'cf5', 'ch1', 'ch2', 'ch3', 'ch4');
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef1', 'personal', 'Personal', 25000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef1', 'medium', 'Medium', 43000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef1', 'large', 'Large', 77000, 2);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef2', 'personal', 'Personal', 25000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef2', 'medium', 'Medium', 43000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef2', 'large', 'Large', 77000, 2);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef3', 'personal', 'Personal', 27000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef3', 'medium', 'Medium', 45000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef3', 'large', 'Large', 82000, 2);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef4', 'personal', 'Personal', 27000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef4', 'medium', 'Medium', 45000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef4', 'large', 'Large', 82000, 2);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef5', 'personal', 'Personal', 27000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef5', 'medium', 'Medium', 45000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef5', 'large', 'Large', 82000, 2);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef6', 'personal', 'Personal', 27000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef6', 'medium', 'Medium', 45000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef6', 'large', 'Large', 82000, 2);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef7', 'personal', 'Personal', 29000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef7', 'medium', 'Medium', 48000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('beef7', 'large', 'Large', 87000, 2);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('chk1', 'personal', 'Personal', 23000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('chk1', 'medium', 'Medium', 40000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('chk1', 'large', 'Large', 73000, 2);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('chk2', 'personal', 'Personal', 23000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('chk2', 'medium', 'Medium', 40000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('chk2', 'large', 'Large', 73000, 2);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('chk3', 'personal', 'Personal', 25000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('chk3', 'medium', 'Medium', 43000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('chk3', 'large', 'Large', 77000, 2);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('chk4', 'personal', 'Personal', 25000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('chk4', 'medium', 'Medium', 43000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('chk4', 'large', 'Large', 77000, 2);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('chk5', 'personal', 'Personal', 27000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('chk5', 'medium', 'Medium', 45000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('chk5', 'large', 'Large', 82000, 2);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('umm1', 'personal', 'Personal', 23000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('umm1', 'medium', 'Medium', 40000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('umm1', 'large', 'Large', 73000, 2);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('umm2', 'personal', 'Personal', 25000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('umm2', 'medium', 'Medium', 43000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('umm2', 'large', 'Large', 77000, 2);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('umm3', 'personal', 'Personal', 25000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('umm3', 'medium', 'Medium', 43000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('umm3', 'large', 'Large', 77000, 2);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('umm4', 'personal', 'Personal', 27000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('umm4', 'medium', 'Medium', 45000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('umm4', 'large', 'Large', 82000, 2);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('umm5', 'personal', 'Personal', 23000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('umm5', 'medium', 'Medium', 40000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('umm5', 'large', 'Large', 73000, 2);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('sd2', 'Mini (2 pcs)', 'Mini (2 pcs)', 14000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('sd2', 'Regular (4 pcs)', 'Regular (4 pcs)', 24000, 1);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('sd3', 'Mini (2 pcs)', 'Mini (2 pcs)', 14000, 0);
insert into public.menu_item_variants (menu_item_id, variant_key, label, price, sort_order) values ('sd3', 'Regular (4 pcs)', 'Regular (4 pcs)', 24000, 1);

-- Pengaturan ongkir rekaan (= angka contoh di KONTRAK-DATA-POS.md §1.5), mode aktif.
update public.pengaturan_ongkir set radius_gratis_km = 1, tarif_dasar = 3000, batas_tarif_dasar_km = 1.5,
  tarif_tambahan_per_km = 2000, kelipatan_km = 0.5, batas_lurus_km = 18, batas_rute_km = 27,
  faktor_rute = 1.5, mode = 'aktif' where id = 1;

-- Go-live rekaan: 20 hari lalu.
update public.pengaturan_pos set go_live_at = now() - interval '20 days' where id = 1;

-- Voucher rekaan: 10% item.
insert into public.vouchers (code, discount_percent, active, target) values ('REKAAN10', 10, true, 'item');

-- Pelanggan rekaan (HP +628000000000xx — bukan nomor sungguhan).
insert into public.customers (name, phone) values ('Pelanggan Rekaan 01', '+6280000000001');
insert into public.customers (name, phone) values ('Pelanggan Rekaan 02', '+6280000000002');
insert into public.customers (name, phone) values ('Pelanggan Rekaan 03', '+6280000000003');
insert into public.customers (name, phone) values ('Pelanggan Rekaan 04', '+6280000000004');
insert into public.customers (name, phone) values ('Pelanggan Rekaan 05', '+6280000000005');
insert into public.customers (name, phone) values ('Pelanggan Rekaan 06', '+6280000000006');
insert into public.customers (name, phone) values ('Pelanggan Rekaan 07', '+6280000000007');
insert into public.customers (name, phone) values ('Pelanggan Rekaan 08', '+6280000000008');
-- Pelanggan 01 punya alamat utama berpin (cermin ke customers.default_address/patokan oleh trigger).
insert into public.alamat_pelanggan (customer_id, label, alamat, patokan, lat, lng, utama, sumber)
select id, 'Rumah', 'Jl. Rekaan Satu No. 1, Pekanbaru', 'Dekat masjid rekaan', 0.515373, 101.40879, true, 'pelanggan'
from public.customers where phone = '+6280000000001';

-- Pesanan rekaan lewat create_order.
-- PL-REKAAN01: Delivery berongkir + voucher item 10%; pizza Large + 2 topping, paket berpilihan
select public.create_order(
  p_customer_id => (select id from public.customers where phone = '+6280000000001'),
  p_order_code => 'PL-REKAAN01', p_order_type => 'delivery',
  p_recipient_name => 'Pelanggan Rekaan 01', p_recipient_phone => '+6280000000001', p_kecamatan => null,
  p_address => 'Jl. Rekaan 1 No. 1, Pekanbaru', p_patokan => 'Patokan rekaan',
  p_note => null, p_voucher_code => 'REKAAN10',
  p_items => '[{"menu_id":"beef5","name":"Meat Lovers (Large) + Topping: Keju Mozzarella, Sosis Sapi","unit_price":110000,"qty":1,"options":{"ukuran":"Large","Topping Ekstra":"Keju Mozzarella, Sosis Sapi","_format":2,"_ukuran_key":"large","_topping_ids":["mozzarella","beef_sausage"]}},{"menu_id":"pk1","name":"Paket Lengkap (Meat Lovers, Carbonara)","unit_price":163000,"qty":1,"options":{"Pilihan Pizza":"Meat Lovers","Pilihan Spaghetti":"Carbonara","_format":2,"_pilihan":{"pizza":"Meat Lovers","spaghetti":"Carbonara"}}}]'::jsonb,
  p_ongkir => '{"alamat_lat":0.515373,"alamat_lng":101.40879,"jarak_lurus_km":4,"jarak_rute_km":5,"jarak_tagih_km":5,"metode_jarak":"rute","ongkir_rupiah":10000,"radius_gratis_km":1,"tarif_dasar":3000,"batas_tarif_dasar_km":1.5,"tarif_tambahan_per_km":2000,"kelipatan_km":0.5}'::jsonb);
update public.orders set created_at = now() - interval '40 minutes' where order_code = 'PL-REKAAN01';
-- PL-REKAAN02: Pick Up; Rice Box berpilihan saus ×2, teh ×2, catatan
select public.create_order(
  p_customer_id => (select id from public.customers where phone = '+6280000000002'),
  p_order_code => 'PL-REKAAN02', p_order_type => 'takeaway',
  p_recipient_name => 'Pelanggan Rekaan 02', p_recipient_phone => '+6280000000002', p_kecamatan => null,
  p_address => null, p_patokan => null,
  p_note => 'Saus dipisah ya', p_voucher_code => null,
  p_items => '[{"menu_id":"rb2","name":"Dori Crispy Rice Box (Saos BBQ)","unit_price":24000,"qty":2,"options":{"Pilihan Saus":"Saos BBQ","_format":2,"_pilihan":{"saus":"Saos BBQ"}}},{"menu_id":"tea1","name":"Jasmine Tea","unit_price":7000,"qty":2,"options":{"_format":2}}]'::jsonb,
  p_ongkir => null);
update public.orders set created_at = now() - interval '35 minutes' where order_code = 'PL-REKAAN02';
-- PL-REKAAN03: Dine-in; varian (Mini), paket, Pizza Kotak + topping
select public.create_order(
  p_customer_id => (select id from public.customers where phone = '+6280000000003'),
  p_order_code => 'PL-REKAAN03', p_order_type => 'dinein',
  p_recipient_name => 'Pelanggan Rekaan 03', p_recipient_phone => '+6280000000003', p_kecamatan => null,
  p_address => null, p_patokan => null,
  p_note => null, p_voucher_code => null,
  p_items => '[{"menu_id":"sd2","name":"Puff Pastry Chicken (Mini (2 pcs))","unit_price":14000,"qty":1,"options":{"varian":"Mini (2 pcs)","_format":2,"_varian_key":"Mini (2 pcs)"}},{"menu_id":"ps1","name":"Paket Andalan 1 (Chicken Mania)","unit_price":40000,"qty":1,"options":{"Pilihan Pizza":"Chicken Mania","_format":2,"_pilihan":{"pizza":"Chicken Mania"}}},{"menu_id":"sig1","name":"Kotak 4 Rasa + Topping: Keju Mozzarella","unit_price":123000,"qty":1,"options":{"Topping Ekstra":"Keju Mozzarella","_format":2,"_topping_ids":["mozzarella"]}}]'::jsonb,
  p_ongkir => null);
update public.orders set created_at = now() - interval '30 minutes' where order_code = 'PL-REKAAN03';
-- PL-REKAAN04: Delivery alur lama (ongkir NULL = dikonfirmasi WA)
select public.create_order(
  p_customer_id => (select id from public.customers where phone = '+6280000000004'),
  p_order_code => 'PL-REKAAN04', p_order_type => 'delivery',
  p_recipient_name => 'Pelanggan Rekaan 04', p_recipient_phone => '+6280000000004', p_kecamatan => null,
  p_address => 'Jl. Rekaan 4 No. 4, Pekanbaru', p_patokan => 'Patokan rekaan',
  p_note => null, p_voucher_code => null,
  p_items => '[{"menu_id":"chk4","name":"Chicken Mania (Medium)","unit_price":43000,"qty":1,"options":{"ukuran":"Medium","_format":2,"_ukuran_key":"medium"}}]'::jsonb,
  p_ongkir => null);
update public.orders set created_at = now() - interval '25 minutes' where order_code = 'PL-REKAAN04';
-- PL-REKAAN05: menunggu_admin: verifikasi HP pending
select public.create_order(
  p_customer_id => (select id from public.customers where phone = '+6280000000005'),
  p_order_code => 'PL-REKAAN05', p_order_type => 'delivery',
  p_recipient_name => 'Pelanggan Rekaan 05', p_recipient_phone => '+6280000000005', p_kecamatan => null,
  p_address => 'Jl. Rekaan 5 No. 5, Pekanbaru', p_patokan => 'Patokan rekaan',
  p_note => null, p_voucher_code => null,
  p_items => '[{"menu_id":"umm1","name":"Cheese Only (Personal)","unit_price":23000,"qty":1,"options":{"ukuran":"Personal","_format":2,"_ukuran_key":"personal"}},{"menu_id":"cf2","name":"Milk Coffee Classic","unit_price":15000,"qty":1,"options":{"_format":2}}]'::jsonb,
  p_ongkir => '{"alamat_lat":0.497386,"alamat_lng":101.40879,"jarak_lurus_km":2,"jarak_rute_km":2.5,"jarak_tagih_km":2.5,"metode_jarak":"rute","ongkir_rupiah":5000,"radius_gratis_km":1,"tarif_dasar":3000,"batas_tarif_dasar_km":1.5,"tarif_tambahan_per_km":2000,"kelipatan_km":0.5}'::jsonb);
update public.orders set created_at = now() - interval '20 minutes', verification_status = 'pending' where order_code = 'PL-REKAAN05';
-- PL-REKAAN06: menunggu_admin: diskon ditahan (mismatch)
select public.create_order(
  p_customer_id => (select id from public.customers where phone = '+6280000000006'),
  p_order_code => 'PL-REKAAN06', p_order_type => 'takeaway',
  p_recipient_name => 'Pelanggan Rekaan 06', p_recipient_phone => '+6280000000006', p_kecamatan => null,
  p_address => null, p_patokan => null,
  p_note => null, p_voucher_code => 'REKAAN10',
  p_items => '[{"menu_id":"pb1","name":"Paket Andalan 2 (Meat Lovers)","unit_price":62000,"qty":1,"options":{"Pilihan Pizza":"Meat Lovers","_format":2,"_pilihan":{"pizza":"Meat Lovers"}}}]'::jsonb,
  p_ongkir => null);
update public.orders set created_at = now() - interval '15 minutes', verification_status = 'mismatch', discount_held = true where order_code = 'PL-REKAAN06';
-- PL-REKAAN07: bayar online, belum_bayar
select public.create_order(
  p_customer_id => (select id from public.customers where phone = '+6280000000007'),
  p_order_code => 'PL-REKAAN07', p_order_type => 'takeaway',
  p_recipient_name => 'Pelanggan Rekaan 07', p_recipient_phone => '+6280000000007', p_kecamatan => null,
  p_address => null, p_patokan => null,
  p_note => null, p_voucher_code => null,
  p_items => '[{"menu_id":"beef1","name":"Seasoned Beef (Medium)","unit_price":43000,"qty":1,"options":{"ukuran":"Medium","_format":2,"_ukuran_key":"medium"}}]'::jsonb,
  p_ongkir => null);
update public.orders set created_at = now() - interval '12 minutes', metode_bayar = 'online' where order_code = 'PL-REKAAN07';
-- PL-REKAAN08: bayar online, menunggu (QRIS berjalan)
select public.create_order(
  p_customer_id => (select id from public.customers where phone = '+6280000000007'),
  p_order_code => 'PL-REKAAN08', p_order_type => 'delivery',
  p_recipient_name => 'Pelanggan Rekaan 07', p_recipient_phone => '+6280000000007', p_kecamatan => null,
  p_address => 'Jl. Rekaan 7 No. 7, Pekanbaru', p_patokan => 'Patokan rekaan',
  p_note => null, p_voucher_code => null,
  p_items => '[{"menu_id":"pk3","name":"Paket Akrab (Chicken Mania)","unit_price":136000,"qty":1,"options":{"Pilihan Pizza":"Chicken Mania","_format":2,"_pilihan":{"pizza":"Chicken Mania"}}}]'::jsonb,
  p_ongkir => '{"alamat_lat":0.533359,"alamat_lng":101.40879,"jarak_lurus_km":6,"jarak_rute_km":7.5,"jarak_tagih_km":7.5,"metode_jarak":"rute","ongkir_rupiah":15000,"radius_gratis_km":1,"tarif_dasar":3000,"batas_tarif_dasar_km":1.5,"tarif_tambahan_per_km":2000,"kelipatan_km":0.5}'::jsonb);
update public.orders set created_at = now() - interval '10 minutes', metode_bayar = 'online', status_bayar = 'menunggu' where order_code = 'PL-REKAAN08';
-- PL-REKAAN09: bayar online, LUNAS (terkunci_edit)
select public.create_order(
  p_customer_id => (select id from public.customers where phone = '+6280000000008'),
  p_order_code => 'PL-REKAAN09', p_order_type => 'takeaway',
  p_recipient_name => 'Pelanggan Rekaan 08', p_recipient_phone => '+6280000000008', p_kecamatan => null,
  p_address => null, p_patokan => null,
  p_note => null, p_voucher_code => null,
  p_items => '[{"menu_id":"pk2","name":"Paket Bahagia (Chicken Mania)","unit_price":157000,"qty":1,"options":{"Pilihan Pizza":"Chicken Mania","_format":2,"_pilihan":{"pizza":"Chicken Mania"}}}]'::jsonb,
  p_ongkir => null);
update public.orders set created_at = now() - interval '8 minutes', metode_bayar = 'online', status_bayar = 'lunas', dibayar_rupiah = total, dibayar_at = now(), gateway = 'midtrans', gateway_ref = 'REKAAN-TRX-09' where order_code = 'PL-REKAAN09';
-- PL-REKAAN10: options FORMAT LAMA (tanpa _format) — uji pemetaan nama
select public.create_order(
  p_customer_id => (select id from public.customers where phone = '+6280000000008'),
  p_order_code => 'PL-REKAAN10', p_order_type => 'takeaway',
  p_recipient_name => 'Pelanggan Rekaan 08', p_recipient_phone => '+6280000000008', p_kecamatan => null,
  p_address => null, p_patokan => null,
  p_note => null, p_voucher_code => null,
  p_items => '[{"menu_id":"chk4","name":"Chicken Mania (Medium) + Topping: Sosis Ayam","unit_price":52000,"qty":1,"options":{"ukuran":"Medium","Topping Ekstra":"Sosis Ayam"}},{"menu_id":"pk1","name":"Paket Lengkap (Meat Lovers, Bolognese)","unit_price":163000,"qty":1,"options":{"Pilihan Pizza":"Meat Lovers","Pilihan Spaghetti":"Bolognese"}}]'::jsonb,
  p_ongkir => null);
update public.orders set created_at = now() - interval '5 minutes' where order_code = 'PL-REKAAN10';
-- PL-REKAAN11: SEBELUM go-live → tak terlihat di v_pesanan; fungsi menolak (sebelum_go_live)
select public.create_order(
  p_customer_id => (select id from public.customers where phone = '+6280000000001'),
  p_order_code => 'PL-REKAAN11', p_order_type => 'takeaway',
  p_recipient_name => 'Pelanggan Rekaan 01', p_recipient_phone => '+6280000000001', p_kecamatan => null,
  p_address => null, p_patokan => null,
  p_note => null, p_voucher_code => null,
  p_items => '[{"menu_id":"tea2","name":"Teh Tarik","unit_price":8000,"qty":1,"options":{"_format":2}}]'::jsonb,
  p_ongkir => null);
update public.orders set created_at = now() - interval '25 days', status = 'selesai' where order_code = 'PL-REKAAN11';
-- PL-REKAAN12: sesudah go-live tapi > 14 hari → di luar jendela v_pesanan
select public.create_order(
  p_customer_id => (select id from public.customers where phone = '+6280000000002'),
  p_order_code => 'PL-REKAAN12', p_order_type => 'takeaway',
  p_recipient_name => 'Pelanggan Rekaan 02', p_recipient_phone => '+6280000000002', p_kecamatan => null,
  p_address => null, p_patokan => null,
  p_note => null, p_voucher_code => null,
  p_items => '[{"menu_id":"tea3","name":"Japanese Green Tea","unit_price":8000,"qty":1,"options":{"_format":2}}]'::jsonb,
  p_ongkir => null);
update public.orders set created_at = now() - interval '16 days', status = 'selesai' where order_code = 'PL-REKAAN12';

commit;

-- Ringkasan (harapan: menu 58, pesanan 12, terlihat di v_pesanan 10, go-live 20 hari lalu).
select
  (select count(*) from public.menu_items)                                         as menu,
  (select count(*) from public.orders where order_code like 'PL-REKAAN%')          as pesanan_rekaan,
  (select count(*) from pos.v_pesanan)                                             as terlihat_di_v_pesanan,
  (select count(*) from pos.v_item_pesanan)                                        as baris_item_terlihat,
  (select count(*) from pos.v_pesanan where menunggu_admin)                        as menunggu_admin,
  (select count(*) from pos.v_pesanan where terkunci_edit)                         as terkunci_edit,
  (select go_live_at from public.pengaturan_pos)                                   as go_live_at;
