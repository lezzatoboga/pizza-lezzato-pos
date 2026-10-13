# Kontrak Data Website ↔ POS

Status: **Keputusan Owner 13 Okt 2026 sudah masuk** (bagian "Keputusan Owner"); Bagian 2 tetap
**usulan tertulis**: belum ada SQL, kode, role, atau grant yang dibuat/diubah. Urutan pengerjaan: Bagian 5.
Riwayat: draf 13 Okt (`e0cf981`) → keputusan Owner 13 Okt (`88e6b40`) → koreksi Owner 13 Okt:
project uji terpisah diganti lingkungan uji lokal gratis (Bagian 6).

Arsitektur yang sudah disepakati (dari Owner, ringkas):

- POS **menarik** pesanan dari database website tiap 30 detik lewat role `pos_reader` (SELECT
  saja). Website tidak mengirim apa pun ke POS.
- POS mengirim balik **status saja** lewat satu fungsi `pos_set_order_status`, dijalankan role baru
  `pos_status_writer` yang hanya punya EXECUTE pada fungsi itu.
- Status dari POS: `diterima`, `diproses`, `siap_diambil` (Pick Up), `sedang_diantar` (Delivery),
  `selesai`, `dibatalkan`. Setelah tanggal go-live, status pesanan hanya diubah dari POS.
- Perubahan item/ongkir oleh kasir (setelah konfirmasi WA) **tidak** ditulis balik ke website.
  Nominal voucher dari website tetap.
- Pembayaran sekarang di outlet / saat diantar. Midtrans menyusul; kontrak ini menyiapkan tempatnya.
  Pelanggan membayar **setelah total final**; refund manual (dashboard Midtrans/admin), **tidak**
  otomatis karena status `dibatalkan`.
- Aturan ongkir satu sumber: website menyimpan, POS membaca.
- `pos_reader` juga dipakai sinkron `customers` (sekarang dijeda di POS).

### Sumber fakta di Bagian 1

| Tanda | Arti |
|---|---|
| **[LIVE]** | Dibaca 13 Okt 2026 ±06.00 WIB dari database produksi: definisi kolom lewat OpenAPI PostgREST (nama, tipe, NOT NULL, default, PK/FK) dan **hitungan baris** (`count=exact`, tanpa isi baris). Tidak ada isi data pelanggan/pesanan yang dibaca. |
| **[REPO]** | Dari `supabase/migrations/*.sql` / `APPLY_*.sql` dan kode `src/` di `main` (`360035c`). CHECK constraint, trigger, grant, policy, dan status role **tidak terlihat lewat OpenAPI** — sesi ini tidak punya kredensial baca katalog (`pg_catalog`). Untuk mengonfirmasinya, Owner bisa menjalankan SELECT baca-saja di §1.7. |

---

## Keputusan Owner (13 Okt 2026)

Keputusan ini menang atas usulan awal di bawahnya; Bagian 2–5 sudah disesuaikan.

**Risiko**

| # | Keputusan |
|---|---|
| R1 / P6 | **Pilihan (a).** Pesanan yang diubah kasir di POS **tidak bisa dibayar online** — otomatis bayar di tempat. Pesanan yang **sudah lunas online dikunci** dari edit item/ongkir di POS; bila perlu perubahan → pesanan dibatalkan, pelanggan memesan ulang. Website tahu pesanan diubah kasir lewat **penanda** dari POS — tanpa jalur tulis item/total ke website (§2.2, §2.4). |
| R2 / P7 | Verifikasi HP & resolusi diskon **tetap di admin website**. View POS memuat **penanda menunggu verifikasi/resolusi**; POS menahan "Konfirmasi & Proses" sampai penanda hilang dan selalu memakai angka header terbaru. **Setelah `diproses`, diskon tak boleh diubah lagi di website** — ditegakkan di DB (§2.8). |
| R3 | **Kunci teknis di `options` dikerjakan sekarang** untuk pesanan baru (pesanan lama tak diubah). POS memakai kunci teknis bila ada; pemetaan nama hanya untuk pesanan lama (§2.9). |
| R4–R7 | Setuju dengan mitigasi yang diusulkan. |
| R8 | **Dine-in masih ditawarkan.** Statusnya seperti Pick Up (`siap_diambil`), tetapi label pelanggan Dine-in: **"Siap disajikan"**. |

**Jawaban pertanyaan**

1. Setuju: `batal` dipertahankan; `dibatalkan` dari POS dipetakan ke `batal`.
2. Setuju: transisi hanya maju; keluar dari `selesai`/`batal` ditolak. Koreksi salah tekan oleh Owner lewat SQL.
3. Go-live ditentukan nanti, bersamaan dengan go-live POS di outlet → **pengaturan di DB**, bukan nilai tertanam. Pesanan yang masih aktif saat go-live diselesaikan di admin panel.
4. Jendela 14 hari: cukup.
5. `customers.created_at` **tidak** dibuka untuk `pos_reader` (POS berhenti memakainya). **Tambah `customers.updated_at` + trigger** untuk sinkron inkremental.
6. (= R1) pilihan (a).
7. (= R2) tetap di admin website.
8. `refund_sebagian` belum perlu. Status `refund` diisi admin website.
9. Kalkulator ongkir POS di **backend POS (Edge Function)**. Penyelarasannya dikerjakan **terpisah** setelah jembatan berjalan — di pekerjaan ini cukup view pengaturan ongkir tersedia.
10. Setuju: koordinat outlet pindah ke DB sebagai satu sumber (menyiapkan cabang lain).
11. Belum perlu notifikasi WA otomatis; halaman pesanan cukup, kasir menghubungi pelanggan manual.

---

## Bagian 1 — Kondisi sekarang

### 1.1 Tabel `orders` (header pesanan) — 143 baris [LIVE]

PK `id uuid` (default `gen_random_uuid()`). Kode tampil ke pelanggan: `order_code` (unik [REPO]).
RLS aktif, tanpa policy publik; `anon`/`authenticated` tak punya akses (probe anon → 401 [LIVE]).
Semua tulis lewat `service_role` (server website) dan fungsi `SECURITY DEFINER`.

| Kolom | Tipe | Null? | Default | Arti |
|---|---|---|---|---|
| `id` | uuid | NOT NULL | `gen_random_uuid()` | PK. **Kunci yang dipakai POS.** |
| `order_code` | text | NOT NULL | — | Kode pesanan untuk manusia (unik). Dibuat server (`makeOrderCode`). |
| `customer_id` | uuid | null | — | FK → `customers.id` (`on delete set null`). Saat ini 0 pesanan tanpa pelanggan, tapi bisa NULL bila akun dihapus. |
| `order_type` | text | NOT NULL | — | **Nilai persis:** `delivery` \| `takeaway` \| `dinein` (CHECK [REPO]). `takeaway` **ditampilkan "Pick Up"** sejak 27 Sep — nilai DB tidak diubah. Live: delivery 112, takeaway 29, dinein 2. |
| `status` | text | NOT NULL | `baru` | CHECK `baru`/`diproses`/`selesai`/`batal` [REPO]. Lihat §1.3. |
| `subtotal` | integer | NOT NULL | — | Σ `unit_price × qty` semua item (harga final setelah diskon otomatis menu, termasuk topping ekstra). Rupiah bulat. |
| `discount` | integer | NOT NULL | 0 | Potongan **voucher item** (rupiah). = Σ `order_items.voucher_discount` saat dibuat. |
| `voucher_code` | text | null | — | FK → `vouchers.code`. Tetap terisi walau diskon dicabut (jejak audit). Live: 96 pesanan bervoucher. |
| `total` | integer | NOT NULL | — | `subtotal − discount + coalesce(ongkir_rupiah,0) − diskon_ongkir`. |
| `recipient_name` | text | NOT NULL | — | Nama penerima (boleh beda dari nama akun). |
| `recipient_phone` | text | NOT NULL | — | HP penerima, dinormalisasi E.164 (`+62…`) oleh `normalizePhone`. |
| `kecamatan` | text | null | — | FK → `kecamatan.name` (15 baris). **Sudah tidak diisi** sejak 13 Sep (live: hanya 3 pesanan lama terisi). |
| `address` | text | null | — | Alamat teks. Wajib (tak kosong) bila `delivery` (CHECK `orders_delivery_needs_address`). |
| `patokan` | text | null | — | Patokan/ancer-ancer (live: 76 terisi). |
| `note` | text | null | — | **Catatan pesanan** (satu untuk seluruh pesanan; live: 20 terisi). |
| `payment_method` | text | NOT NULL | `wa_confirm` | Tanpa CHECK. Live: 143/143 `wa_confirm` (= bayar di tempat/saat diantar, konfirmasi lewat WA). |
| `payment_status` | text | NOT NULL | `pending` | CHECK `pending`/`paid`/`cancelled` [REPO]. Live: 143/143 `pending` — **tidak pernah diubah** oleh kode mana pun. |
| `created_at` | timestamptz | NOT NULL | `now()` | Waktu pesanan dibuat. |
| `updated_at` | timestamptz | NOT NULL | `now()` | **Ada.** Diisi trigger `orders_set_updated_at` (BEFORE UPDATE → `now()`) [REPO]; bukti live: 122 pesanan yang ditutup lewat SQL 12 Okt ber-`updated_at` identik 19.54.01 (HANDOVER §3). |
| `verification_status` | text | NOT NULL | `not_required` | Verifikasi manual HP: `not_required`/`pending`/`verified`/`mismatch` (CHECK [REPO]). Live: 136/5/2/0. Internal admin. |
| `verified_at`, `verified_by` | timestamptz, uuid | null | — | Jejak verifikasi (FK `admin_users`). Internal. |
| `discount_held` | boolean | NOT NULL | false | Diskon voucher "ditahan" saat HP tak cocok, menunggu resolusi admin. Live: 0. |
| `resolved_at`, `resolved_by` | timestamptz, uuid | null | — | Jejak resolusi diskon (FK `admin_users`). Internal. |
| `alamat_lat`, `alamat_lng` | numeric | null | — | Pin peta pelanggan (Delivery dgn ongkir otomatis). |
| `jarak_lurus_km` | numeric | null | — | Jarak garis lurus outlet → pin. |
| `jarak_rute_km` | numeric | null | — | Jarak rute jalan ORS (null bila ORS gagal/dilewati). |
| `jarak_tagih_km` | numeric | null | — | Jarak yang ditagih = `min(rute, lurus × faktor_rute)`, atau `lurus × faktor_rute` bila tanpa rute. |
| `metode_jarak` | text | null | — | `rute` \| `estimasi_lurus` (CHECK [REPO]). Live: rute 54, estimasi_lurus 1, NULL 88 (pesanan lama / bukan Delivery). |
| `ongkir_rupiah` | integer | null | — | Ongkir otomatis. **NULL = alur lama** (ongkir dikonfirmasi lewat WA, tidak tersimpan). Live: 55 terisi. |
| `tarif_per_km_snapshot` | integer | null | — | Peninggalan tarif lama (sebelum 27 Sep). |
| `diskon_ongkir` | integer | NOT NULL | 0 | Potongan **voucher ongkir** (0 ≤ x ≤ ongkir). Live: 0 pesanan > 0. |
| `radius_gratis_km_snapshot`, `tarif_dasar_snapshot`, `batas_tarif_dasar_km_snapshot`, `tarif_tambahan_per_km_snapshot`, `kelipatan_km_snapshot` | numeric/integer | null | — | Salinan tarif saat pesan (audit; ongkir bisa dihitung ulang persis). |

Catatan "status area/konfirmasi": **tidak ada kolom status area**. Pesanan di luar area **ditolak
server** dan tidak pernah tersimpan; maka setiap Delivery yang berongkir otomatis pasti "di dalam
area". Konfirmasi WA tidak punya kolom; `ongkir_rupiah IS NULL` pada Delivery = ongkir belum pasti
(alur lama/mode mati).

Perubahan sesudah dibuat (penting untuk POS): `create_order` hanya INSERT. Sesudahnya `orders` bisa
berubah karena: status (admin panel / SQL Owner), verifikasi HP, dan **resolusi "Cabut Diskon"**
(`resolusi_diskon_tertahan`): `discount = 0`, `diskon_ongkir = 0`,
`total = subtotal + coalesce(ongkir_rupiah,0)`, baris `voucher_redemptions` dihapus — **tanpa**
mengubah `order_items.voucher_discount`. Semuanya menggeser `updated_at`.

### 1.2 Tabel `order_items` (item pesanan) — 274 baris [LIVE]

PK `id uuid` (default `gen_random_uuid()`); FK `order_id` → `orders.id` (`on delete cascade`).
**Tidak ada `updated_at`** dan tidak ada jalur kode yang meng-UPDATE baris item (hanya INSERT di
`create_order`).

| Kolom | Tipe | Null? | Default | Arti |
|---|---|---|---|---|
| `id` | uuid | NOT NULL | `gen_random_uuid()` | PK baris item. |
| `order_id` | uuid | NOT NULL | — | Pesanan induk. |
| `menu_id` | text | NOT NULL | — | = `menu_items.id` (mis. `sig1`, `pb4`, `rb2`). **Bukan FK** (item menu boleh dihapus kemudian). |
| `name` | text | NOT NULL | — | Nama saat pesan, sudah memuat pilihan, mis. `Nama Pizza (Medium)`, `Paket X (Meat Lovers)`, `... + Topping: Keju, Sosis`. |
| `unit_price` | integer | NOT NULL | — | **Harga satuan FINAL saat pesan**: sudah **termasuk diskon otomatis menu** (bila aktif) **dan** harga topping ekstra; **belum** dipotong voucher. |
| `qty` | integer | NOT NULL | — | Jumlah (1–50). |
| `options` | jsonb | NOT NULL | `{}` [REPO] | Pilihan item — format di bawah. |
| `line_total` | integer | null* | — | Kolom **GENERATED** `unit_price × qty` (OpenAPI melaporkannya nullable; live: 0 NULL). |
| `original_unit_price` | integer | null | — | Harga satuan **sebelum** diskon otomatis menu (+ topping). NULL = baris itu tidak sedang didiskon otomatis. Live: 0 baris terisi. |
| `voucher_discount` | integer | NOT NULL | 0 | Bagian potongan voucher item untuk baris ini (rupiah). Saat dibuat Σ = `orders.discount` persis (sisa pembulatan diserap baris eligible terakhir). Selalu 0 bila baris didiskon otomatis. Live: 169 baris > 0. **Tidak di-nol-kan saat "Cabut Diskon"** → POS harus memakai `orders.discount` sebagai angka berlaku. |

**Tidak ada catatan per item.** Catatan hanya `orders.note`.

**Format `options`** — objek datar `{ "<nama pilihan>": "<nilai teks>" }`, semua nilai string.
Kuncinya adalah **label tampilan**, bukan kunci teknis:

| Jenis menu (`menu_items.kind`) | Kunci di `options` | Nilai | Contoh |
|---|---|---|---|
| `sized` (pizza berukuran) | `ukuran` | `menu_item_variants.label`: `Personal` / `Medium` / `Large` | `{"ukuran":"Medium"}` |
| `variant` | `varian` | `menu_item_variants.variant_key` (live: `Mini (2 pcs)`, `Regular (4 pcs)`) | `{"varian":"Regular (4 pcs)"}` |
| `package` / `simple` dgn `package_choices` | `package_choices[].label` (live: `Pilihan Pizza`, `Pilihan Spaghetti`, `Pilihan Saus`) | salah satu `options[]` pilihan itu | `{"Pilihan Pizza":"Meat Lovers","Pilihan Spaghetti":"Carbonara"}` |
| Pizza + topping ekstra | tambahan `Topping Ekstra` | **label** topping digabung `", "` (urut katalog) | `{"ukuran":"Large","Topping Ekstra":"Keju, Sosis"}` |
| `simple` tanpa pilihan | — | — | `{}` |

Hitungan live per kunci: `ukuran` 129, `varian` 17, `Pilihan Pizza` 36, `Pilihan Saus` 9,
`Topping Ekstra` 20, kosong 82.

Topping ekstra: **qty per topping selalu 1** (topping ganda ditolak server; tiap topping paling
banyak sekali per baris). Harga topping **tidak disimpan terpisah** — sudah dijumlahkan ke
`unit_price` (dan ke `original_unit_price` bila ada). Harga per topping = `xtratopping_price` sesuai
ukuran (Pizza Kotak `sig1` memakai harga `large`, aturan di kode). Yang tersimpan adalah **label**
(`xtratopping.name`), **bukan** `xtratopping.id` → POS memetakan lewat nama.

Contoh satu pesanan (rekaan, data pribadi disamarkan):

```json
{
  "orders": {
    "id": "7f3c…-uuid", "order_code": "PL-XXXXXX", "order_type": "delivery", "status": "baru",
    "recipient_name": "B*** S***", "recipient_phone": "+62812****9012",
    "address": "Jl. ******** No. **", "patokan": "dekat ******", "note": "tanpa saus sambal",
    "subtotal": 113000, "discount": 11300, "voucher_code": "KODE10",
    "ongkir_rupiah": 5000, "diskon_ongkir": 0, "total": 106700,
    "jarak_tagih_km": 2.312, "metode_jarak": "rute", "payment_method": "wa_confirm", "payment_status": "pending"
  },
  "order_items": [
    { "menu_id": "…", "name": "Pizza X (Large) + Topping: Keju, Sosis", "unit_price": 89000, "qty": 1,
      "options": {"ukuran": "Large", "Topping Ekstra": "Keju, Sosis"}, "original_unit_price": null, "voucher_discount": 8900 },
    { "menu_id": "rb2", "name": "Rice Box Y (Saos BBQ)", "unit_price": 24000, "qty": 1,
      "options": {"Pilihan Saus": "Saos BBQ"}, "original_unit_price": null, "voucher_discount": 2400 }
  ]
}
```

### 1.3 Status pesanan sekarang

Nilai DB (CHECK [REPO]): `baru`, `diproses`, `selesai`, `batal`. Live 13 Okt: selesai 133, batal 10,
baru 0, diproses 0.

| Nilai | Label ke pelanggan (`ORDER_STATUS_LABEL`) | Arti | Siapa/apa yang mengubah |
|---|---|---|---|
| `baru` | Baru | Pesanan tersimpan, belum ditangani | Otomatis (default kolom) saat `create_order` |
| `diproses` | Diproses | Sedang dibuat | Admin panel `/admin/pesanan` (tombol "Proses ›" atau Koreksi ⋯) — Owner & Frontliner |
| `selesai` | Selesai | Pesanan tuntas | Admin panel ("Selesai ✓"); SQL Owner (12 Okt: 122 pesanan lama) |
| `batal` | Dibatalkan | Dibatalkan; tak masuk omzet (`v_rekap_harian`: `status <> 'batal'`); voucher **tidak** dilepas | Admin panel (⋯ → "Batalkan pesanan…") |

Jalur pengubah: (1) `POST /admin/api/pesanan/[kode]/status` → UPDATE bersyarat `dari` (409 bila sudah
berubah) atau RPC lama `ubah_status_pesanan(kode, status)`; (2) SQL Editor Owner. **Tidak ada**
otomasi yang mengubah status. **Tidak ada tabel riwayat status**; satu-satunya jejak adalah
`admin_audit` aksi `pesanan.status` (dari → ke, aktor) untuk perubahan lewat panel — perubahan lewat
SQL tidak tercatat. Pelanggan melihat label status di `/pesanan-saya` (lencana berwarna);
halaman `/pesanan/[kode]` tidak menampilkan status.

View yang memakai `status`: `v_orders_pending` (`baru`,`diproses`), `v_rekap_harian` (`batal`
dikecualikan), `v_pesanan`. Kode: `ORDER_STATUSES`, `ORDER_STATUS_LABEL`, `ORDER_STATUS_COLOR` di
`src/lib/order.ts`; tab Aktif admin = `baru`+`diproses`.

### 1.4 Tabel `customers` — 145 baris [LIVE]

| Kolom | Tipe | Null? | Default | Dibandingkan POS |
|---|---|---|---|---|
| `id` | uuid | NOT NULL | `gen_random_uuid()` | sama (uuid) |
| `name` | text | NOT NULL | — | sama |
| `phone` | text | NOT NULL | — | sama: E.164 `+62…`, **UNIQUE** [REPO] |
| `default_address` | text | null | — | sama. **Cermin** alamat utama dari `alamat_pelanggan` (trigger, sejak 30 Sep) |
| `default_patokan` | text | null | — | sama. Cermin juga |
| `phone_verified` | boolean | NOT NULL | false | sama |
| `created_at` | timestamptz | NOT NULL | `now()` | **ada di tabel, tetapi `pos_reader` TIDAK boleh membacanya** sejak Tahap 5a (30 Sep) |
| `phone_verified_at` | timestamptz | null | — | baru bagi POS; tak terbaca `pos_reader` |
| `phone_verified_by` | uuid | null | — | FK `admin_users`; tak terbaca `pos_reader` |
| `sesi_versi` | integer | NOT NULL | 1 | baru (Tahap 4a, "keluar dari semua perangkat"); tak terbaca `pos_reader` |

Perubahan relevan sejak POS terakhir sinkron (24 Sep):
- Tahap 5a (30 Sep): hak `pos_reader` dipersempit ke **6 kolom** (`id, name, phone, default_address,
  default_patokan, phone_verified`) — **`created_at` tidak termasuk**. Bila query sinkron POS
  memuat `created_at`, query itu akan gagal "permission denied". (HANDOVER §5 menyebut query POS
  sudah 6 kolom — perlu dicek di repo POS.)
- Daftar Alamat (30 Sep): pelanggan bisa punya ≤5 alamat (`alamat_pelanggan`, berpin). POS tetap
  melihat alamat utama lewat cermin `default_*`; `alamat_pelanggan` **dicabut** dari `pos_reader`.
  Pin (lat/lng) tidak ada di `customers` — untuk pesanan, pin ada di `orders.alamat_lat/lng`.
- **`customers` tidak punya `updated_at`** → sinkron pelanggan tidak bisa inkremental; POS harus
  membaca ulang semua (145 baris — murah) atau kita tambah kolom (lihat §2.3).
- Pelanggan bisa dihapus (Owner): baris hilang, `orders.customer_id` jadi NULL.

### 1.5 Pengaturan ongkir otomatis — `pengaturan_ongkir` (1 baris, `id = 1`) [LIVE]

| Kolom | Tipe | Nilai live | Dipakai untuk |
|---|---|---|---|
| `mode` | text | `aktif` | `mati` / `uji_admin` / `aktif` (CHECK [REPO]) |
| `radius_gratis_km` | numeric | 1 | jarak ≤ ini → Rp0 |
| `tarif_dasar` | integer | 3000 | jarak ≤ batas tarif dasar |
| `batas_tarif_dasar_km` | numeric | 1.5 | |
| `tarif_tambahan_per_km` | integer | 2000 | per langkah: `round(tambahan × kelipatan)` = Rp1.000 |
| `kelipatan_km` | numeric | 0.5 | |
| `batas_lurus_km` | numeric | 18 | jarak lurus ≥ ini → di luar area |
| `batas_rute_km` | numeric | 27 | jarak tagih ≥ ini → di luar area |
| `faktor_rute` | numeric | 1.5 | plafon = lurus × faktor; juga estimasi bila ORS gagal |
| `updated_at`, `updated_by` | timestamptz, uuid | 29 Sep 22.43 UTC | audit (FK `admin_users`) |

Akses: `anon` → 401 (tidak terbaca publishable key) [LIVE]. `pos_reader` → tidak punya grant [REPO].

**Yang dibutuhkan POS untuk ongkir yang SAMA dengan website** (rumus di
`src/lib/ongkir/kalkulasi.mjs` = fungsi SQL `ongkir_dari_tarif`):
1. Kedelapan parameter di atas (+ `mode`).
2. **Koordinat outlet** — saat ini **konstanta di kode** (`OUTLET_KOORDINAT` = 0.479399783…,
   101.408790032…), **tidak ada di DB**. Untuk "satu sumber", perlu dipindah/disalin ke DB (§2.7).
3. Algoritme persis: haversine R = 6371,0088 km; `lurus ≥ batas_lurus` → luar area (tanpa ORS);
   rute ORS profil `driving-car` (host `api.heigit.org`), `tagih = min(rute, lurus × faktor)`,
   ORS gagal/timeout 3 dtk → `tagih = lurus × faktor` (`estimasi_lurus`); `tagih` dibulatkan ke
   meter (3 desimal); `tagih ≥ batas_rute` → luar area; lalu tarif bertingkat dihitung dalam
   **meter bulat** (`≤` radius → 0; `≤` batas dasar → tarif dasar; selain itu tarif dasar +
   `ceil((m − batas_m) / kelipatan_m) × round(tambahan × kelipatan)`).
4. Catatan: jarak rute ORS bisa berbeda tipis antar-panggilan/hari; angka tersimpan di pesanan
   (`jarak_tagih_km` + 5 snapshot tarif) adalah acuan, bukan hasil hitung ulang POS.

### 1.6 Tabel menu yang dibaca POS lewat publishable key [LIVE + REPO]

| Tabel | Baris | Anon (publishable) | Kolom live |
|---|---|---|---|
| `menu_items` | 58 | 200 | id, category_slug, section_key, kind (`simple`/`package`/`sized`/`variant`), name, description, emoji, image_url, base_price, package_items text[], package_choices jsonb, package_note, sort_order, active, created_at, updated_at, recommended, discount_percent, discount_active |
| `menu_item_variants` | 55 | 200 | id uuid, menu_item_id (FK), variant_key, label, price, sort_order |
| `xtratopping` | 5 | 200 | id, name, active, sort_order, created_at, updated_at |
| `xtratopping_price` | 3 | 200 | variant_key (PK: personal/medium/large), price, updated_at |
| `menu_categories` | 13 | 200 | slug, label, sort_order, created_at, updated_at |
| `menu_sections` | 15 | 200 | key, category_slug (FK), label, sort_order, created_at, updated_at |

**Skema: tidak ada perubahan sejak 23 Sep.** Migrasi terakhir yang mengubah struktur tabel-tabel ini
semuanya bertanggal 23 Sep (`menu_discount`, `xtratopping`, `menu_items_anon_read`,
`menu_layout_order` — di-commit 24 Sep 00.18). Sesudahnya hanya:
- 28 Sep `revoke_tabel_sensitif` — **tidak** menyentuh tabel menu (anon tetap bisa baca; terbukti 200).
- 5 Okt `pizza_kotak` — **data saja**: label kategori/section `pizza-signature` → "Pizza Kotak" dan
  `sort_order` (Pizza Kotak 3 → Beef 4 → Chicken 5 → Umami 6). **Kunci tetap `pizza-signature`.**
- Perubahan isi oleh admin (harga, aktif, diskon, rekomendasi, foto) terjadi kapan saja — data, bukan skema.

Catatan: legacy anon key sudah dimatikan 29 Sep → POS wajib memakai **publishable key baru**
(HANDOVER §5.5).

### 1.7 Role `pos_reader` [REPO — konfirmasi live butuh SELECT Owner]

Menurut berkas SQL & catatan HANDOVER:
- Dibuat 24 Sep (`create role pos_reader with login`), `grant usage on schema public`.
- Policy RLS `"pos_reader read customers"` di `customers` (`for select to pos_reader using (true)`).
- Tahap 5a (30 Sep): `revoke select on customers`, lalu `grant select (id, name, phone,
  default_address, default_patokan, phone_verified)`.
- `alamat_pelanggan` & `customer_lokasi_default` (sudah dihapus 5 Okt): `revoke all`.
- Tidak punya grant ke `orders`, `order_items`, `pengaturan_ongkir`, menu.
- **28 Sep: diubah `NOLOGIN` + password baru** (password di password manager Owner) — dijalankan
  Owner di SQL Editor, tidak ada berkasnya di repo. POS saat ini tidak bisa login → sinkron dijeda.

SELECT baca-saja untuk Owner (opsional, untuk mengonfirmasi §1.7 dan CHECK/trigger; tidak mengubah apa pun):

```sql
select
  (select rolcanlogin from pg_roles where rolname = 'pos_reader')                   as pos_reader_bisa_login,
  (select rolconnlimit from pg_roles where rolname = 'pos_reader')                  as pos_reader_batas_koneksi,
  (select string_agg(table_name || '.' || column_name, ', ' order by table_name, column_name)
     from information_schema.column_privileges where grantee = 'pos_reader')        as pos_reader_kolom,
  (select string_agg(table_name || ':' || privilege_type, ', ')
     from information_schema.table_privileges where grantee = 'pos_reader')         as pos_reader_tabel,
  (select string_agg(tablename || ':' || policyname, ', ')
     from pg_policies where 'pos_reader' = any(roles))                              as pos_reader_policy,
  (select string_agg(tgname, ', ') from pg_trigger
     where tgrelid = 'public.orders'::regclass and not tgisinternal)                as trigger_orders,
  (select string_agg(conname || '=' || pg_get_constraintdef(oid), ' | ') from pg_constraint
     where conrelid = 'public.orders'::regclass and contype = 'c')                  as check_orders,
  exists (select 1 from pg_roles where rolname = 'pos_status_writer')               as pos_status_writer_ada,
  current_setting('server_version')                                                 as versi_postgres;
```

`versi_postgres` menentukan versi Postgres lingkungan uji lokal (Bagian 6); `supabase/config.toml`
repo ini menulis `major_version = 15`, tapi itu konfigurasi lokal, bukan bukti versi produksi.

---

## Bagian 2 — Usulan perubahan di sisi website (DITULIS SAJA, BELUM DIJALANKAN)

Prinsip: tambah, jangan ubah makna kolom yang ada. Objek **khusus POS** (view & fungsi) dikumpulkan di
**schema baru `pos`** yang **tidak** diekspos PostgREST, sehingga tak bisa dipanggil lewat REST
API/publishable key. Tabel yang **juga dibaca kode website** (pengaturan go-live, outlet, log status)
tetap di `public` (RLS aktif, tanpa akses `anon`/`authenticated`), karena kode website membaca DB
lewat PostgREST (`service_role`) dan tidak bisa menjangkau schema `pos`.

### 2.0 Tabel pengaturan baru (di `public`)

**`public.pengaturan_pos`** (singleton `id = 1`, CHECK `id = 1`):

| Kolom | Tipe | Isi |
|---|---|---|
| `go_live_at` | timestamptz **null** | **NULL = belum go-live** (nilai awal). Diisi Owner lewat SQL saat POS go-live di outlet. Pesanan `created_at >= go_live_at` = "pesanan POS". |
| `updated_at` | timestamptz | trigger |

Satu-satunya sumber tanggal go-live: dibaca fungsi POS, view POS, trigger kunci diskon, dan admin
panel (`service_role`). Fungsi bantu `public.pesanan_pos(p_created_at timestamptz) returns boolean`
(`go_live_at is not null and p_created_at >= go_live_at`) dipakai semua tempat itu supaya aturannya satu.

**`public.outlet`** (menyiapkan cabang lain):

| Kolom | Tipe | Isi |
|---|---|---|
| `id` | text PK | `lobak` |
| `nama` | text NOT NULL | "Pizza Lezzato Jl. Lobak" |
| `lat`, `lng` | **numeric** NOT NULL | nilai **persis** konstanta `OUTLET_KOORDINAT` sekarang. Bukan double: Supabase (SQL Editor & API) mengirim double hanya 15 digit — ditemukan saat 1A dijalankan 13 Okt, diperbaiki `APPLY_KONTRAK_POS_1A2` |
| `utama` | boolean NOT NULL | tepat satu baris `true` (unique index parsial) |
| `aktif` | boolean NOT NULL | |

Kode website membaca outlet utama bersama `pengaturan_ongkir` (`bacaPengaturanOngkir`); bila gagal
dibaca → perilaku sama dengan pengaturan ongkir gagal (checkout kembali ke alur lama, bukan memakai
angka cadangan diam-diam). Konstanta lama dihapus dari kode setelah DB terbukti dipakai. Belum ada
`outlet_id` di `orders` — ditambahkan saat cabang kedua benar-benar ada.

### 2.1 `pos_reader` diaktifkan kembali dengan akses seminimal mungkin — lewat view

View dimiliki `postgres` (bukan `security_invoker`), jadi `pos_reader` cukup diberi SELECT pada view —
tanpa hak pada tabel dasar; kolom internal tak pernah terlihat.

**`pos.v_pesanan`** — jendela: `public.pesanan_pos(created_at)` **dan** `created_at >= now() − 14 hari`
(go-live NULL → view kosong).

| Kelompok | Kolom |
|---|---|
| Identitas | `id`, `order_code`, `created_at`, `updated_at`, `status`, `order_type`, `customer_id` |
| Penerima & alamat | `recipient_name`, `recipient_phone`, `address`, `patokan`, `alamat_lat`, `alamat_lng`, `note` |
| Angka (selalu baca ulang yang terbaru) | `subtotal`, `discount`, `voucher_code`, `ongkir_rupiah`, `diskon_ongkir`, `total`, `jarak_tagih_km`, `metode_jarak` |
| **Penanda admin (R2)** | `verification_status`, `discount_held`, dan turunan **`menunggu_admin boolean`** = `verification_status = 'pending' or discount_held` |
| **Penanda POS (R1)** | `diubah_di_pos`, `diubah_di_pos_at` |
| Pembayaran (§2.4) | `metode_bayar`, `status_bayar`, `dibayar_rupiah`, `dibayar_at`, **`terkunci_edit boolean`** = `status_bayar = 'lunas'` |

Tidak dimuat: `verified_by/at`, `resolved_by/at`, `kecamatan`, `tarif_per_km_snapshot`, snapshot tarif,
`payment_method`/`payment_status` lama, `gateway_ref`.

**`pos.v_item_pesanan`** — `id, order_id, menu_id, name, unit_price, qty, line_total,
original_unit_price, voucher_discount, options` (dengan kunci teknis §2.9 untuk pesanan baru); hanya
item dari pesanan yang ada di `v_pesanan`.

**`pos.v_pelanggan`** — `id, name, phone, default_address, default_patokan, phone_verified,
updated_at` (§2.3). **Tanpa `created_at`** (keputusan P5).

**`pos.v_pengaturan_ongkir`** — 8 parameter tarif/area + `mode` + `updated_at` + `outlet_id`,
`outlet_lat`, `outlet_lng` dari outlet utama. Tanpa `updated_by`.

Langkah (SQL Owner, nanti — lihat Bagian 5 untuk urutan):

```sql
create schema if not exists pos;
revoke all on schema pos from public, anon, authenticated;
-- create view pos.v_pesanan / v_item_pesanan / v_pelanggan / v_pengaturan_ongkir ...
grant usage on schema pos to pos_reader;
grant select on pos.v_pesanan, pos.v_item_pesanan, pos.v_pelanggan, pos.v_pengaturan_ongkir to pos_reader;
-- WAJIB (ditemukan uji paket website tiruan 13 Okt): v_pesanan memanggil public.pesanan_pos(); Postgres memeriksa
-- hak EXECUTE fungsi di dalam view terhadap PENGGUNA view (bukan pemiliknya). Tetap jalan sesudah tahap 8.
grant execute on function public.pesanan_pos(timestamptz) to pos_reader;
alter role pos_reader set default_transaction_read_only = on;
alter role pos_reader set statement_timeout = '5s';
alter role pos_reader connection limit 3;
-- Tahap berikutnya, setelah POS pindah ke v_pelanggan:
revoke select (id, name, phone, default_address, default_patokan, phone_verified) on public.customers from pos_reader;
drop policy if exists "pos_reader read customers" on public.customers;
revoke usage on schema public from pos_reader;
-- alter role pos_reader login;  -- Owner, saat POS siap; password dari password manager
```

**Pola baca POS** (kontrak): tiap 30 dtk
`select … from pos.v_pesanan where updated_at > :kursor − interval '2 minutes' order by updated_at`
→ upsert by `id` (idempoten) → item `v_item_pesanan where order_id = any(:id_baru)` sekali per
pesanan. Jendela tumpang 2 menit karena `now()` = waktu mulai transaksi. Pelanggan:
`v_pelanggan where updated_at > :kursor − 2 menit`, plus **rekonsiliasi id penuh sehari sekali**
(pelanggan yang dihapus tak muncul di kueri inkremental). Indeks: `orders (updated_at)`,
`customers (updated_at)`.

**Kewajiban POS terhadap penanda** (kontrak, ditegakkan juga oleh fungsi §2.2):
- `menunggu_admin = true` → tombol "Konfirmasi & Proses" nonaktif; tampilkan "Menunggu admin
  website (verifikasi/diskon)". Begitu penanda hilang, pakai angka header **terbaru** (diskon bisa
  sudah dicabut).
- `terkunci_edit = true` → edit item/ongkir di POS dikunci; perubahan = batalkan pesanan, pelanggan
  memesan ulang.

### 2.2 Fungsi `pos.pos_set_order_status` + role `pos_status_writer`

```
pos.pos_set_order_status(p_order_id uuid, p_status text, p_diubah_kasir boolean default false) returns jsonb
```

Tetap **satu** fungsi untuk POS. Parameter ketiga opsional adalah **penanda saja** (R1) — tidak ada
jalur tulis item/total ke website.

**Nilai status di DB:** CHECK `orders.status` ditambah `diterima`, `siap_diambil`, `sedang_diantar`;
`batal` dipertahankan (POS `dibatalkan` → `batal`).

**Transisi yang diizinkan** (sama dengan sekarang → sukses tanpa perubahan status, aman diulang):

| Dari \ Ke | diterima | diproses | siap_diambil | sedang_diantar | selesai | batal |
|---|---|---|---|---|---|---|
| `baru` | ✓ | ✓ | ✓ P | ✓ D | ✓ | ✓ |
| `diterima` | = | ✓ | ✓ P | ✓ D | ✓ | ✓ |
| `diproses` | ✗ | = | ✓ P | ✓ D | ✓ | ✓ |
| `siap_diambil` | ✗ | ✗ | = | ✗ | ✓ | ✓ |
| `sedang_diantar` | ✗ | ✗ | ✗ | = | ✓ | ✓ |
| `selesai` | ✗ | ✗ | ✗ | ✗ | = | ✗ |
| `batal` | ✗ | ✗ | ✗ | ✗ | ✗ | = |

P = `order_type in ('takeaway','dinein')` (Dine-in: label pelanggan "Siap disajikan");
D = `delivery`. Lompat maju boleh; mundur & keluar dari status akhir ditolak (koreksi: Owner lewat SQL).

**Urutan pemeriksaan** (error = `raise exception … using errcode = 'P0001'`, pesan berawalan kode):
1. `p_status` ∉ 6 nilai POS → `status_tidak_dikenal` (`dibatalkan` → `batal`).
2. `select … for update` pesanan; tak ada → `pesanan_tidak_ada`.
3. `not public.pesanan_pos(created_at)` (termasuk go-live NULL) → `sebelum_go_live`.
4. Transisi tak ada di tabel / tipe tak cocok → `transisi_ditolak`.
5. **R2:** `menunggu_admin` dan tujuan ∉ {`batal`, sama} → `menunggu_admin`.
6. **Bayar online:** tujuan ∈ {`diproses`,`siap_diambil`,`sedang_diantar`,`selesai`} dan
   `metode_bayar = 'online'` dan `status_bayar <> 'lunas'` → `belum_lunas` (PKS: diproses setelah
   notifikasi bayar terverifikasi). Tidak berlaku untuk `bayar_di_tempat`.
7. **R1 — `p_diubah_kasir = true`:**
   - `status_bayar = 'lunas'` → `sudah_lunas_terkunci` (seluruh panggilan ditolak, status tak berubah);
   - `status_bayar = 'menunggu'` (QRIS sedang berjalan) → `pembayaran_berjalan` (kasir menunggu
     QR kedaluwarsa/gagal, atau pelanggan menyelesaikan bayar lalu pesanan dibatalkan);
   - selain itu: `diubah_di_pos = true` (lengket, tak pernah kembali false), `diubah_di_pos_at = now()`
     (hanya pertama kali), dan bila `metode_bayar = 'online'` → `metode_bayar = 'bayar_di_tempat'`.
   - Boleh dikirim bersama perubahan status **atau** dengan status yang sama (`=`).
   - Status tujuan `batal` mengabaikan penanda.
8. Ubah status (bila berbeda). Fungsi **tidak** menyentuh item, total, diskon, voucher, atau kolom bayar
   selain `metode_bayar` di langkah 7. `batal` tidak me-refund dan tidak melepas voucher; bila
   `status_bayar = 'lunas'` → `perlu_refund = true` (penanda untuk admin website, §2.4).

Kembalian: `{ok, order_id, order_code, status_lama, status_baru, berubah, diubah_di_pos,
metode_bayar, updated_at}`.

Keamanan: `security definer`, `set search_path = ''` (nama ditulis lengkap), pemilik `postgres`;
`revoke all on function … from public, anon, authenticated, service_role`;
`grant execute … to pos_status_writer`.

**Kontrak alur kasir (R1):** kasir mengonfirmasi lewat WA; bila ada perubahan item/ongkir, POS
**wajib** mengirim `p_diubah_kasir = true` paling lambat pada panggilan `diterima`. Pelanggan baru
bisa membayar online setelah `diterima` tanpa penanda (§2.4) — itulah "total final". Bila kasir
mengubah pesanan setelah `diterima` tetapi sebelum lunas: kirim ulang status yang sama dengan
penanda. Setelah lunas: POS mengunci edit (`terkunci_edit`); fungsi juga menolak penanda.

**Riwayat status:** tabel `public.order_status_log` (`id bigserial`, `order_id` **tanpa FK** + `order_code`
— log tetap ada walau pesanan dihapus, `dari`, `ke`, `sumber`, `waktu timestamptz default now()`), diisi **trigger AFTER UPDATE OF status pada `orders`**
(semua jalur tercatat tanpa mengubah kode lama). `sumber` dari `session_user` (tak terpengaruh
SECURITY DEFINER): `pos_status_writer` → `pos`; `authenticator` (PostgREST, kode website) → `website`;
lainnya (SQL Editor) → `sql`. Siapa admin-nya tetap tercatat di `admin_audit` seperti sekarang.
Hanya bisa ditambah (UPDATE/DELETE dicabut dari semua role, pola `admin_audit`). Perubahan
`diubah_di_pos` juga dicatat (baris dengan `dari = ke`, `sumber = pos`, kolom `catatan = 'diubah_kasir'`).

**Role:**

```sql
create role pos_status_writer nologin noinherit connection limit 2;  -- login & password: Owner, tahap 7 (go-live masih NULL → fungsi menolak semua)
alter role pos_status_writer set statement_timeout = '5s';
grant usage on schema pos to pos_status_writer;
grant execute on function pos.pos_set_order_status(uuid, text, boolean) to pos_status_writer;
-- tanpa grant tabel/view apa pun; tanpa usage schema public
```

Koneksi lewat pooler Supabase memakai user `pos_status_writer.<project-ref>`. Password hanya di
secret POS + password manager Owner; masuk `docs/CHECKLIST-ROTASI-KUNCI.md`.

### 2.3 `updated_at` + trigger

- `orders.updated_at` + trigger **sudah ada**; tambah indeks `orders (updated_at)`.
- `order_items`: tidak perlu (tak pernah di-UPDATE). Bila kelak item bisa diubah di website, wajib
  menyentuh `orders.updated_at` induknya.
- **`customers.updated_at`** (keputusan P5): `timestamptz not null default now()` + trigger
  `customers_set_updated_at` (BEFORE UPDATE, memakai `public.set_updated_at()` yang sudah ada) +
  indeks. Baris lama terisi waktu ALTER dijalankan (sekali baca penuh oleh POS — memang perlu).
  Ikut tergeser oleh: ubah nama/HP, cermin alamat utama (trigger `alamat_pelanggan` → `default_*`),
  verifikasi HP, `sesi_versi` — semuanya tidak berbahaya. Kode website tidak perlu berubah.

### 2.4 Kolom pembayaran (disiapkan untuk Midtrans, boleh kosong dulu)

a. Ringkasan di `orders` (kolom baru; `payment_method`/`payment_status` lama tak diubah maknanya —
   peninggalan, `wa_confirm` = bayar di tempat):

| Kolom | Tipe | Default | Isi |
|---|---|---|---|
| `metode_bayar` | text NOT NULL | `'bayar_di_tempat'` | CHECK `bayar_di_tempat` \| `online`. Diubah ke `bayar_di_tempat` oleh fungsi POS bila diubah kasir (§2.2 langkah 7). |
| `status_bayar` | text NOT NULL | `'belum_bayar'` | CHECK `belum_bayar` \| `menunggu` \| `lunas` \| `gagal` \| `kedaluwarsa` \| `refund` (tanpa `refund_sebagian`, P8) |
| `dibayar_rupiah` | integer null | — | nominal diterima gateway (≥ 0) |
| `dibayar_at` | timestamptz null | — | waktu notifikasi lunas terverifikasi |
| `gateway` | text null | — | mis. `midtrans` |
| `gateway_ref` | text null | — | `transaction_id` percobaan yang lunas (tidak dimuat di view POS) |
| `perlu_refund` | boolean NOT NULL | false | true bila `lunas` lalu `batal`; **penanda saja** |
| `diubah_di_pos` | boolean NOT NULL | false | penanda R1 (§2.2) |
| `diubah_di_pos_at` | timestamptz null | — | kapan penanda pertama kali dikirim |

   143 pesanan lama: default saja, tanpa UPDATE data. Kolom bayar **hanya ditulis server website**
   (webhook Midtrans; `refund` diisi **admin website** — P8). POS hanya membaca.

b. Tabel `public.pembayaran` (internal website, tak terbaca POS): `id uuid`, `order_id`, `gateway`,
   `gateway_order_id` (unik — idempotensi), `gateway_ref`, `nominal`, `status`, `payload_mentah
   jsonb`, `signature_ok`, `perlu_tinjau` (nominal ≠ tersimpan), `dibuat_at`, `diubah_at`. Disimpan
   ≥ 24 bulan (PKS). Fungsi webhook memperbarui ringkasan (a) → `orders.updated_at` bergeser → POS
   melihat "dibayar" lewat kursor yang sama.

c. **Syarat membuat tagihan online** (server website, dalam satu transaksi dengan `select … for
   update` pesanan — sehingga balapan dengan penanda POS selalu punya satu pemenang): `metode_bayar =
   'online'`, `status = 'diterima'`, `diubah_di_pos = false`, `menunggu_admin = false`,
   `status_bayar in ('belum_bayar','gagal','kedaluwarsa')`. Nominal = `orders.total` saat itu
   (dihitung ulang server). Pesanan sebelum go-live: tidak bisa bayar online.

d. Tabel & kolom ini dibuat di pekerjaan ini (kosong); **alur Midtrans (Proyek B) menyusul** —
   detail Tahap B di HANDOVER §5 poin 4.

### 2.5 Panel admin website setelah go-live

> **Ditambahkan saat menulis SQL (13 Okt, `APPLY_KONTRAK_POS_1B`):** selain penolakan di route admin,
> trigger DB `orders_jaga_status_pos` menolak perubahan status pesanan POS dari **kode website**
> (`session_user = authenticator`) dengan `status_dikelola_pos`; SQL Editor Owner & fungsi POS tetap bisa.
> Tidur selama `go_live_at` NULL. Bila kelak website perlu mengubah status pesanan POS (mis. batal
> otomatis QR kedaluwarsa di Proyek B), trigger ini disesuaikan di pekerjaan itu.

- Pesanan POS (`pesanan_pos(created_at)`): tombol Proses/Selesai, Koreksi, Batalkan & dropdown detail
  **disembunyikan** → "Status dikelola dari POS". Server (`POST /admin/api/pesanan/[kode]/status`,
  RPC `ubah_status_pesanan`) **menolak** juga (403) — selalu di server. Pesanan sebelum go-live:
  perilaku sekarang (pesanan aktif saat go-live diselesaikan di panel — P3).
- Lencana & tab mengenali 3 status baru; tab Aktif = `baru`, `diterima`, `diproses`, `siap_diambil`,
  `sedang_diantar` (juga `v_orders_pending`). Lencana "Diubah kasir" bila `diubah_di_pos`; lencana
  "Perlu refund" bila `perlu_refund` (Owner mengisi `refund` setelah transfer manual).
- Verifikasi HP & resolusi diskon **tetap di panel** (R2). Tombol "Cabut Diskon"/"Konfirmasi Sah"
  disembunyikan untuk pesanan POS berstatus `diproses` atau sesudahnya (§2.8); DB menolak juga.
- Darurat (POS mati): Owner mengubah status lewat SQL (`ubah_status_pesanan` versi baru yang mengenal
  nilai baru) — tercatat `sumber = sql`.

### 2.6 Status di halaman pesanan pelanggan

| Nilai DB | Label pelanggan | Teks kecil (usulan) |
|---|---|---|
| `baru` | Menunggu konfirmasi | Pesananmu sudah kami terima di sistem. |
| `diterima` | Diterima toko | Toko sudah mengonfirmasi pesananmu. |
| `diproses` | Sedang disiapkan | Pesananmu sedang dibuat. |
| `siap_diambil` — Pick Up | Siap diambil | Silakan ambil di outlet. |
| `siap_diambil` — **Dine-in** | **Siap disajikan** | Pesananmu segera disajikan. |
| `sedang_diantar` | Sedang diantar | Kurir sedang menuju alamatmu. |
| `selesai` | Selesai | Terima kasih! |
| `batal` | Dibatalkan | Hubungi kami lewat WhatsApp bila ada pertanyaan. |

Label bergantung pada `order_type` → `ORDER_STATUS_LABEL` di `src/lib/order.ts` menjadi fungsi
`labelStatus(status, orderType)` (satu sumber, dipakai pelanggan & admin). Tampil di `/pesanan-saya`
(sudah ada) dan **ditambahkan** di `/pesanan/[kode]`. Lencana berteks. Tanpa pembaruan otomatis &
tanpa WA otomatis (P11). Untuk pesanan online: status bayar tampil terpisah; bila `diubah_di_pos`
→ "Pesanan disesuaikan toko — bayar di tempat".

### 2.7 Akses POS ke aturan ongkir: `pos.v_pengaturan_ongkir` lewat `pos_reader`

Alasan (tetap): `pengaturan_ongkir` tertutup untuk anon; POS sudah butuh `pos_reader`; satu jalur
pengamanan; view memuat koordinat outlet (§2.0) tanpa `updated_by`. Sesuai P9 kalkulator berjalan di
**backend POS (Edge Function)** yang memegang koneksi `pos_reader` — cocok. Penyelarasan rumus
kalkulator POS dikerjakan **terpisah** setelah jembatan berjalan; di pekerjaan ini cukup view tersedia
dan website sudah membaca koordinat outlet dari DB.

### 2.8 Kunci diskon setelah `diproses` (R2)

Ditegakkan **di DB**, bukan hanya di tombol:

- Trigger `orders_kunci_diskon` (BEFORE UPDATE pada `orders`): bila `public.pesanan_pos(old.created_at)`
  **dan** `old.status in ('diproses','siap_diambil','sedang_diantar','selesai','batal')` **dan** salah
  satu dari `discount`, `diskon_ongkir`, `total`, `subtotal`, `ongkir_rupiah`, `discount_held`,
  `voucher_code` berubah → `raise exception 'diskon_terkunci'`. Berlaku untuk semua jalur (RPC
  `resolusi_diskon_tertahan`, `verifikasi_pesanan`, SQL), termasuk `service_role`.
- Koreksi darurat Owner: `set local lezzato.buka_kunci_diskon = 'ya'` di transaksi SQL Editor
  (trigger membaca `current_setting(..., true)`); tidak pernah dipakai kode website.
- Pesanan sebelum go-live: tidak terkena (perilaku sekarang dipertahankan).
- Pelengkap: fungsi POS menolak `diproses`+ selama `menunggu_admin` (§2.2 langkah 5), jadi dalam alur
  normal penanda sudah hilang sebelum kunci berlaku. Antara `baru`/`diterima` admin masih bisa
  mencabut diskon; POS membaca angka header terbaru.

### 2.9 Kunci teknis di `options` (R3) — pesanan baru saja

Ditambahkan **server** di `resolveOrderItems()` (`src/lib/orders/service.ts`) setelah harga diselesaikan
— **tidak** di `priceIndex`, keranjang, atau klien, sehingga logika harga/topping (`toppingTierFor`
membaca `options.ukuran`) tak berubah. Kunci berawalan `_` (tak bentrok dengan label tampilan):

| Kunci | Tipe JSON | Ada bila | Isi |
|---|---|---|---|
| `_format` | number | semua item baru | `2` (pesanan lama tak punya kunci ini → POS memakai pemetaan nama) |
| `_ukuran_key` | string | `kind = 'sized'` | `menu_item_variants.variant_key`: `personal`/`medium`/`large` |
| `_varian_key` | string | `kind = 'variant'` | `menu_item_variants.variant_key` |
| `_pilihan` | object | item dengan `package_choices` | `{ "<choice.key>": "<nilai opsi persis dari package_choices.options>" }`, mis. `{"pizza":"Meat Lovers","spaghetti":"Carbonara"}`, `{"saus":"Saos BBQ"}` |
| `_topping_ids` | array of string | ada topping ekstra | `xtratopping.id` urut katalog, mis. `["keju","sosis"]` |

Contoh item baru: `{"ukuran":"Large","Topping Ekstra":"Keju, Sosis","_format":2,"_ukuran_key":"large","_topping_ids":["keju","sosis"]}`.

Catatan:
- Kunci lama (label) tetap ada → tampilan & laporan lama tak berubah. `options` tak ditampilkan di
  admin/pelanggan (memakai `name`); view Owner `v_order_items` akan ikut memperlihatkan kunci `_` (tak
  apa). Tipe TS `options` menjadi `Record<string, unknown>` di jalur server.
- Opsi pilihan paket tak punya id terpisah di `package_choices`; nilainya sendiri adalah kunci. Edit
  pilihan paket dari admin masih ditunda (HANDOVER §5 poin 6) — saat dibuat, nilai opsi harus
  diperlakukan sebagai kunci (ubah nama = opsi baru).
- `create_order` tidak berubah (menyimpan `options` apa adanya). Pesanan lama tidak diubah.

---

## Bagian 3 — Risiko & pertanyaan (status setelah keputusan 13 Okt)

| # | Risiko | Status |
|---|---|---|
| R1 | Total berubah di POS vs bayar online | **Diputuskan (a)** — penanda `diubah_di_pos`, tagihan online hanya setelah `diterima` tanpa penanda, kunci edit setelah lunas (§2.2, §2.4) |
| R2 | Cabut Diskon sesudah POS membaca | **Diputuskan** — penanda `menunggu_admin`, fungsi menahan proses, kunci diskon di DB (§2.8) |
| R3 | `options` berbasis label | **Diputuskan** — kunci teknis untuk pesanan baru (§2.9) |
| R4 | Kredensial Postgres langsung | Mitigasi disetujui: view saja, jendela 14 hari, read-only, `statement_timeout`, batas koneksi, schema `pos` tak terekspos, rotasi di checklist |
| R5 | Urutan nilai status baru | Mitigasi disetujui → Bagian 5 (SQL → kode → POS) |
| R6 | Kursor `updated_at` | Mitigasi disetujui: jendela tumpang 2 menit + upsert idempoten |
| R7 | ORS beda hasil | Mitigasi disetujui: angka tersimpan = acuan; penyelarasan kalkulator terpisah (P9) |
| R8 | Dine-in | **Diputuskan** — `siap_diambil`, label "Siap disajikan" |

Risiko sisa yang baru terlihat dari keputusan:
- **R9 — Penanda tidak dikirim POS.** Bila kasir mengubah pesanan tapi POS lupa mengirim
  `p_diubah_kasir`, pelanggan bisa membayar total lama. Website tak bisa mendeteksinya (sesuai
  keputusan: tanpa jalur tulis item/total). Mitigasi: kewajiban di sisi POS — setiap edit item/ongkir
  di POS otomatis memanggil fungsi dengan penanda **sebelum** perubahan disimpan di POS (gagal →
  edit dibatalkan). Dicatat di kontrak; diuji di sisi POS.
- **R10 — QRIS berjalan saat kasir ingin mengubah.** Fungsi menolak (`pembayaran_berjalan`); kasir
  menunggu QR kedaluwarsa. Batas waktu QR diputuskan saat Proyek B (HANDOVER §5 poin 4).
- **R11 — Uji POS terhadap produksi.** Sebelum go-live view kosong dan fungsi menolak semua
  (`sebelum_go_live`), jadi di produksi POS hanya bisa menguji jalur penolakan. ~~Project Supabase
  uji terpisah~~ **tidak bisa** (koreksi Owner 13 Okt: paket gratis maks. 2 project aktif, keduanya
  terpakai; tidak berlangganan). **Pengganti: lingkungan uji lokal gratis di laptop — Bagian 6.**
  Yang tetap hanya bisa dibuktikan di produksi diuji lewat prosedur aman Bagian 6.4.
- **R12 — Lingkungan lokal tidak stabil / disk C: penuh.** Docker Desktop kadang macet (pulih
  setelah restart laptop) dan C: tinggal ±2,9 GB. Mitigasi di Bagian 6.2: data Docker dipindah ke
  D: lebih dulu, dan ada jalur cadangan tanpa Docker.

Pertanyaan terbuka: **tidak ada** yang menghalangi Bagian 5. Yang ditentukan belakangan: nilai
`go_live_at` (bersama go-live outlet), batas waktu QR & alur Midtrans (Proyek B), penyelarasan
kalkulator ongkir POS.

Belum terverifikasi live (lihat SELECT §1.7): status `NOLOGIN` & grant `pos_reader`, CHECK, trigger
`orders` — Owner menjalankan SELECT itu di Tahap 1 Bagian 5.

---

## Bagian 4 — Rencana uji (PGlite `uji-sql/` + uji kode) — belum dijalankan

SQL: `supabase/APPLY_KONTRAK_POS_1.sql` (skema), `APPLY_KONTRAK_POS_2.sql` (role & grant), masing-masing
dengan `ROLLBACK_…`. Uji `uji-sql/uji-kontrak-pos.mjs`: `siapkanDb()` (semua migrasi) → tanam data
uji → APPLY **dua kali** → periksa. Diakhiri SELECT bukti (SQL Editor tak menampilkan `notice`).
Keterbatasan PGlite: satu pengguna — login/password/pooler tak bisa diuji; hak akses diuji dengan
`set role`, dan `session_user` dengan `set session authorization` (PGlite berjalan sebagai superuser).

Data uji: pesanan Delivery, Pick Up, Dine-in sebelum & sesudah `go_live_at`, dengan/tanpa voucher,
berongkir & tanpa, satu `discount_held`, satu `verification_status = 'pending'`, satu `metode_bayar =
'online'` di tiap `status_bayar`; item dengan `options` lama & baru; pelanggan dengan alamat utama.

**SQL (PGlite)**

| # | Uji | Harapan |
|---|---|---|
| 1 | APPLY_1 & APPLY_2 dua kali | tanpa error; data pesanan/pelanggan **persis sama** kecuali kolom baru berisi default; `customers.updated_at` terisi untuk semua baris |
| 2 | `pengaturan_pos` & `outlet` | singleton; `go_live_at` NULL; tepat satu outlet utama; koordinat = konstanta kode **persis** |
| 3 | `set role pos_reader`: SELECT tiap view `pos.*` | berhasil; kolom persis daftar §2.1 (tanpa `created_at` pelanggan, tanpa `gateway_ref`, tanpa `updated_by`) |
| 4 | `pos_reader`: SELECT `public.orders`, `order_items`, `alamat_pelanggan`, `pengaturan_ongkir`, `pengaturan_pos`, `outlet`, `order_status_log`, `admin_users` | `permission denied` (customers 6 kolom: masih boleh di APPLY_2 tahap transisi, ditolak setelah langkah pencabutan) |
| 5 | `pos_reader`: tulis apa pun; execute fungsi POS | ditolak |
| 6 | Jendela `v_pesanan` | go-live NULL → 0 baris; sesudah diisi: hanya pesanan ≥ go-live & ≤ 14 hari; item hanya milik pesanan terlihat |
| 7 | `menunggu_admin`, `terkunci_edit` di view | benar untuk tiap kombinasi `verification_status`/`discount_held`/`status_bayar` |
| 8 | `v_pengaturan_ongkir` | = `pengaturan_ongkir` + outlet utama, tanpa `updated_by` |
| 9 | `set role pos_status_writer`: SELECT tabel/view apa pun | ditolak; hanya execute fungsi |
| 10 | Tabel transisi §2.2 tiap sel × tipe pesanan | ✓/✗/= sesuai; `=` → `berubah=false`, `updated_at` tak bergeser bila tanpa penanda |
| 11 | `dibatalkan` → `batal`; nilai asing/NULL/huruf besar | `batal`; `status_tidak_dikenal` |
| 12 | Sebelum go-live; go-live NULL; id tak ada | `sebelum_go_live`; `sebelum_go_live`; `pesanan_tidak_ada` |
| 13 | `menunggu_admin` | `diterima`/`diproses`/… ditolak `menunggu_admin`; `batal` & `=` boleh |
| 14 | Online belum lunas | `diproses`+ ditolak `belum_lunas`; `diterima`/`batal` boleh; `bayar_di_tempat` tak terkena |
| 15 | `p_diubah_kasir` | belum_bayar/gagal/kedaluwarsa → penanda true, `metode_bayar` online→bayar_di_tempat, `diubah_di_pos_at` hanya pertama kali; `menunggu` → `pembayaran_berjalan`; `lunas` → `sudah_lunas_terkunci` & status tak berubah; penanda tak bisa kembali false; dikirim dgn `=` berhasil |
| 16 | `batal` pada pesanan lunas | `perlu_refund = true`; kolom bayar lain tak berubah |
| 17 | Fungsi tak menyentuh kolom lain | `total`, `discount`, item, `voucher_redemptions`, kolom bayar (selain aturan 15/16) persis sama |
| 18 | `order_status_log` | satu baris per perubahan nyata; `sumber` = `pos` (session `pos_status_writer`), `website` (`authenticator`), `sql` (lainnya); baris `diubah_kasir`; UPDATE/DELETE ditolak semua role |
| 19 | Kunci diskon (§2.8) | pesanan POS `diproses`+: `resolusi_diskon_tertahan` & UPDATE langsung `discount/total/discount_held/...` (juga `service_role`) → `diskon_terkunci`; status `baru`/`diterima` → boleh; pesanan sebelum go-live → boleh; dengan `lezzato.buka_kunci_diskon='ya'` → boleh |
| 20 | `customers.updated_at` | bergeser saat ubah nama, saat cermin alamat utama dari `alamat_pelanggan`, saat verifikasi HP (trigger menggeser pada setiap UPDATE, juga tanpa perubahan nilai — sama dengan `orders`; POS toleran) |
| 21 | CHECK status | nilai lama + 3 baru diterima; lainnya ditolak; `v_rekap_harian` tetap mengecualikan `batal`; `v_orders_pending` memuat status aktif baru |
| 22 | Kolom bayar | default utk baris lama; CHECK menolak nilai asing & `refund_sebagian` |
| 23 | `anon`/`authenticated`/`service_role` | tak bisa usage schema `pos` / execute fungsi POS; `pengaturan_pos`/`outlet` tak terbaca anon |
| 24 | `search_path` fungsi | tabel `orders` palsu di schema lain + `set search_path` tak memengaruhi fungsi |
| 25 | Kunci baris | definisi fungsi memuat `for update` (dua koneksi bersamaan tak bisa di PGlite → diuji sungguhan di L5, Bagian 6) |
| 26 | ROLLBACK_2 lalu ROLLBACK_1 | objek baru hilang; ROLLBACK_1 **membatalkan diri** bila ada pesanan berstatus baru, `metode_bayar = 'online'`, atau baris `pembayaran` (pesan jelas) |

**Kode website** (setelah SQL, sebelum deploy)

| # | Uji | Di mana |
|---|---|---|
| K1 | Kunci teknis `options` untuk sized/variant/paket/saus/topping/Pizza Kotak; harga & nama item **tak berubah** dibanding sebelum | uji unit offline baru `scripts/uji-opsi-teknis.mjs` + regresi pesanan di dev (jam sepi) |
| K2 | `labelStatus` 7 status × 3 tipe (Dine-in "Siap disajikan") | uji unit offline |
| K3 | Admin panel: pesanan sebelum go-live tetap bisa diubah; tab Aktif memuat status baru; lencana Diubah kasir/Perlu refund. Jalur "sesudah go-live" (tombol tersembunyi, server 403, Cabut Diskon ditolak dari `diproses`) diuji dengan pesanan uji + `go_live_at` diisi **sementara** dan **dipulihkan ke NULL di `finally`** — perlu izin Owner, jam sepi, snapshot sebelum/sesudah (pola §1 poin 12 HANDOVER) | `regresi-status-pesanan` diperluas (dev server, DB live) |
| K4 | Koordinat outlet dari DB: ongkir sama persis dengan konstanta lama | `uji-logika-ongkir` + `uji-ongkir` (dev) |
| K5 | `/pesanan/[kode]` & `/pesanan-saya` menampilkan semua status | browser (HP & laptop) |
| K6 | regresi-prod setelah deploy | jam sepi |

**Lapisan uji** (rinci di Bagian 6): PGlite (#1–#26, kontrak SQL, kapan saja, juga sesi cloud) →
**Postgres lokal "DB website tiruan"** (L1–L8: login sungguhan, banyak koneksi) → **jembatan POS
lokal** (P1–P8: alur sukses ujung ke ujung) → **produksi terbatas** (X1–X5: hanya yang tak bisa
ditiru lokal, dengan pengaman).

---

## Bagian 5 — Rencana urutan pengerjaan

Urutan wajib (R5): **SQL menambah nilai/kolom → deploy kode website yang mengenalnya → baru POS
diizinkan membaca & mengirim.** Setiap tahap dimulai hanya setelah tahap sebelumnya selesai dan
(bila tertulis) disetujui Owner. "Sesi website" = sesi Claude Code repo ini (laptop; sesi cloud hanya
untuk pekerjaan offline). "Sesi POS" = sesi di repo POS.

| Tahap | Isi | Pelaksana | Uji PGlite | Jam sepi 22.00–10.00 | Selesai bila |
|---|---|---|---|---|---|
| 0 | Keputusan Owner (dokumen ini) | Owner | — | — | ✓ 13 Okt |
| 1 | SELECT baca-saja §1.7: konfirmasi `pos_reader` NOLOGIN, grant, CHECK & trigger `orders` | Owner (SQL Editor) | tidak | tidak (baca saja) | hasil cocok dengan §1; bila beda → dokumen diperbarui dulu |
| 2 | Tulis `APPLY_KONTRAK_POS_1.sql` + ROLLBACK + salinan migrasi: CHECK status +3, kolom `orders` (bayar, `perlu_refund`, `diubah_di_pos*`), tabel `pembayaran` (kosong), `customers.updated_at` + trigger, indeks, `pengaturan_pos` (go-live NULL), `outlet`, `pesanan_pos()`, `order_status_log` + trigger (SECURITY DEFINER, `sumber` dari `session_user`), trigger kunci diskon, `ubah_status_pesanan` & `v_orders_pending` versi baru, schema `pos` + 4 view + fungsi `pos_set_order_status` (belum ada role yang bisa memanggilnya) | Sesi website | **ya** (Bagian 4 #1–#26 yang tak butuh role login) | tidak (offline) | uji lolos; **Owner menyetujui SQL** |
| 3 | Jalankan `APPLY_KONTRAK_POS_1.sql` | **Owner** | sudah (tahap 2) | **ya** (ALTER `orders`/`customers` mengunci tabel sebentar; trigger baru aktif) | SELECT bukti di akhir berkas cocok; lalu sesi website: `regresi-prod` + `regresi-status-pesanan` (jam sepi) membuktikan website lama tak terpengaruh (go-live NULL → semua aturan POS tidur) |
| 4 | Kode website (branch): 3 status baru + `labelStatus` (Dine-in "Siap disajikan"), status di `/pesanan/[kode]`, panel admin sadar go-live (sembunyikan & tolak 403, lencana Diubah kasir/Perlu refund, Cabut Diskon tersembunyi dari `diproses`), kunci teknis `options` (§2.9), koordinat outlet dari DB, tab Aktif | Sesi website | tidak (kode); uji K1–K5 | uji yang menulis DB live: ya; deploy: **ya** | Owner menyetujui screenshot/prototipe → merge → deploy jam sepi → K6 + `pindai-bundle` |
| 5 | `APPLY_KONTRAK_POS_2.sql` + ROLLBACK: `pos_status_writer` (**NOLOGIN**), grant view ke `pos_reader`, pengaturan role (read-only, timeout, batas koneksi). Akses lama `pos_reader` ke 6 kolom `customers` **tetap** (transisi) | Sesi website (tulis) → **Owner** (jalankan) | **ya** | tidak wajib (hanya role/grant, tak menyentuh data pelanggan; tak ada yang bisa login) | SELECT bukti: hak persis Bagian 4 #3–#9, #23 |
| 6a | Siapkan lingkungan uji lokal (Bagian 6.2): **Owner** memindahkan lokasi disk Docker Desktop ke D: (Settings → Resources → Advanced → Disk image location) dan memastikan Docker jalan (restart laptop bila macet); **sesi website** membuat paket "DB website tiruan" `uji-sql/tiruan/` (urutan migrasi + `APPLY_KONTRAK_POS_1/2` + stub peran Supabase bila perlu + data rekaan dibuat lewat `create_order` sungguhan + kata sandi **uji lokal** untuk `pos_reader`/`pos_status_writer`, tak pernah kata sandi produksi) | Owner (Docker, disk) + sesi website (paket) | paket diuji di PGlite dulu | tidak (lokal) | L1–L8 lolos di Postgres lokal |
| 6b | Jembatan POS dikembangkan **lokal** (Bagian 6.3): Edge Function `supabase functions serve` di stack lokal POS, koneksi langsung ke DB website tiruan; tarik `v_pesanan`/`v_item_pesanan` (kursor + tumpang 2 menit), patuhi `menunggu_admin` & `terkunci_edit`, kirim status + `p_diubah_kasir` (R9: otomatis saat edit), kunci teknis `options` dgn cadangan pemetaan nama, sinkron pelanggan via `v_pelanggan` **tanpa `created_at`** + rekonsiliasi harian, menu lewat **publishable key baru**. Docker macet → jalur cadangan tanpa Docker (6.2) | Sesi POS | — | tidak (tak menyentuh produksi) | P1–P8 lolos (sukses & setiap kode error §2.2) |
| 7 | Aktifkan login `pos_reader` **dan** `pos_status_writer` (password dari password manager) + secret koneksi di POS, **saat `go_live_at` masih NULL**; sinkron pelanggan POS dilanjutkan. Uji produksi X1–X2 (Bagian 6.4): baca view lewat pooler, panggil fungsi → harus `sebelum_go_live` (tak ada yang berubah) | **Owner** (role & secret) + sesi POS | tidak | tidak (baca saja; panggilan fungsi ditolak tanpa menulis) | POS membaca `v_pelanggan`/`v_pengaturan_ongkir` produksi lewat pooler; fungsi menjawab `sebelum_go_live`; `pos_reader` ditolak di tabel dasar |
| 8 | Cabut akses lama `pos_reader` ke `public.customers` (6 kolom, policy, usage `public`) | Sesi website (tulis) → **Owner** | **ya** (#4 bagian kedua) | tidak wajib | sinkron POS tetap jalan lewat view |
| 8b | **Uji produksi terbatas X3–X5** (Bagian 6.4): `go_live_at` diisi **sementara** + pesanan uji bertanda → POS menarik & mengirim status sampai `batal` → `go_live_at` dipulihkan ke NULL di `finally`. Boleh digabung dengan pagi go-live (tahap 9) | Owner (SQL `go_live_at`, izin) + sesi POS + sesi website (pantau & bersihkan) | tidak | **ya** + izin Owner khusus | semua cek X3–X5 lolos; `go_live_at` NULL lagi (atau langsung nilai go-live); sisa data uji hanya baris log yang memang tak bisa dihapus |
| 9 | **Go-live** di outlet: Owner mengisi `pengaturan_pos.go_live_at` (SQL; login kedua role sudah aktif sejak tahap 7). Pesanan baru sejak saat itu masuk POS; pesanan aktif sebelumnya diselesaikan di panel admin (P3) | **Owner** + sesi POS (pantau) + sesi website (pantau `order_status_log`, panel) | tidak (nilai saja) | **ya** — sebelum toko buka (≤ 09.30 WIB), tanggal ditentukan bersama go-live POS | pesanan pertama sesudah go-live terbaca POS dan statusnya kembali ke website (`sumber = pos`); pelanggan melihat label baru |
| 10 | Menyusul, terpisah: penyelarasan kalkulator ongkir POS (Edge Function, P9); Proyek B Midtrans (mengisi kolom bayar & `pembayaran`, syarat §2.4c); hapus konstanta outlet dari kode | Sesi POS / sesi website | sesuai pekerjaannya | sesuai pekerjaannya | dokumen terpisah |

**Saklar darurat** (tanpa deploy): Owner mengosongkan `pengaturan_pos.go_live_at` (SQL) → `v_pesanan`
kosong, fungsi POS menolak semua (`sebelum_go_live`), kunci diskon tidur, dan panel admin kembali
mengelola **semua** pesanan (aturan "pesanan POS" bergantung pada nilai ini). Lebih keras: `alter role
pos_reader nologin; alter role pos_status_writer nologin;`. Mengisi kembali `go_live_at` dengan nilai
semula memulihkan keadaan.

**Rollback per tahap:** 3 → `ROLLBACK_KONTRAK_POS_1.sql` (menolak bila sudah ada data berstatus baru /
bayar online — §4 #26); 4 → `wrangler rollback` ke versi sebelum tahap 4 (kode lama aman dengan skema
tahap 3 selama go-live NULL); 5/8 → ROLLBACK_2 / grant ulang; 7/8b/9 → saklar darurat.

---

## Bagian 6 — Lingkungan uji gratis (pengganti project uji terpisah)

Koreksi Owner 13 Okt: project Supabase uji terpisah **tidak bisa** (paket gratis maks. 2 project
aktif — website & POS sudah terpakai; tidak berlangganan). Bagian ini menggantikannya.

### 6.1 Kondisi laptop (dicek 13 Okt ±06.30 WIB, baca saja)

- Docker Desktop 29.7.2 terpasang; daemon **tidak berjalan** saat dicek. Data Docker
  (`docker_data.vhdx`) **5,65 GB di C:**. Docker kadang macet, biasanya pulih setelah restart
  laptop (Owner); catatan 28 Sep: Docker Desktop sempat tak mau jalan sama sekali.
- **C: sisa ±2,9 GB (98%)**, D: ±108 GB kosong.
- Supabase CLI 2.116.0 tersedia (`npx supabase`).
- WSL Ubuntu: **PostgreSQL 18.6**, cluster `main` port 5434 **online** (dipakai latihan pemulihan
  28 Sep) — tanpa Docker.
- Versi Postgres produksi belum diketahui → `versi_postgres` di SELECT §1.7 (tahap 1).

### 6.2 Penilaian usulan Owner & rekomendasi

**Usulan Owner — Supabase lokal lewat Docker (`supabase start`) — LAYAK**, dengan tiga penyesuaian:

1. **DB website tiruan = database kedua** (`website_tiruan`) di dalam Postgres stack lokal **POS**,
   bukan di database `postgres` milik POS: kedua sistem punya tabel bernama sama di `public`
   (`customers`, dst.). Satu stack saja (dua `supabase start` dengan port berbeda mungkin, tetapi
   dua kali RAM & disk). Peran Supabase (`anon`, `authenticated`, `service_role`, `authenticator`)
   berlaku se-cluster → migrasi website jalan tanpa stub; `pg_cron` hanya bisa di database `postgres`
   → di `website_tiruan` dipakai stub (pola PGlite). `[db] major_version` stack lokal disamakan dengan
   produksi.
2. **Syarat disk (wajib, sebelum `supabase start` pertama):** Owner memindahkan lokasi disk Docker
   ke D: (Docker Desktop → Settings → Resources → Advanced → *Disk image location*). Image Supabase
   beberapa GB; dengan C: 2,9 GB, C: bisa penuh (mengulang kejadian 6 Okt). Layanan yang tak dipakai
   dikecualikan: `supabase start -x studio,imgproxy,logflare,vector,realtime,…` (daftar akhir
   ditentukan sesi POS sesuai kebutuhan POS; **Edge Runtime wajib**).
3. **Jalur cadangan tanpa Docker** (bila Docker macet & restart tidak menolong): Postgres 18 di WSL
   menampung `website_tiruan` (+ stub peran Supabase seperti latihan pemulihan 28 Sep) dan, bila
   perlu, `pos_tiruan`. Inti jembatan POS ditulis terpisah dari `Deno.serve` sehingga bisa dijalankan
   sebagai skrip Deno biasa terhadap Postgres WSL. Menguji kontrak DB sepenuhnya; **tidak** menguji
   Edge Runtime & penjadwal. Sesi website memakai jalur ini untuk L1–L8 tanpa menunggu Docker. Beda
   versi (18 vs produksi) dicatat; untuk SQL kontrak ini (plpgsql, view, grant) risikonya kecil, dan
   L1 diulang di jalur Docker bila tersedia.

| Kebutuhan | Docker lokal | WSL cadangan | Catatan |
|---|---|---|---|
| Edge Function jembatan | ✓ `supabase functions serve` | ✗ (skrip Deno) | penjadwal 30 dtk lokal dipicu skrip/loop; penjadwal produksi → X3 |
| `pos_reader`/`pos_status_writer` LOGIN + kata sandi, grant, read-only, `statement_timeout`, batas koneksi | ✓ sungguhan | ✓ sungguhan | yang tak bisa di PGlite |
| Koneksi langsung | ✓ dari jaringan Docker (host `db`: `db:5432/website_tiruan` — bukan `supabase_db_<id>`, ditolak DNS Deno), dari laptop `localhost:54322` | ✓ `localhost:5434` | |
| Pooler (Supavisor) | ragu — pooler lokal opsional (`[db.pooler]`), format user & TLS berbeda dari produksi | ✗ | produksi: user `pos_reader.<project-ref>`, TLS, mode transaksi port 6543 → klien **tanpa prepared statement**. Lokal memakai klien & opsi yang sama; pembuktian di produksi X1–X2 (aman) |
| Banyak koneksi bersamaan (`for update`, balapan penanda vs tagihan online) | ✓ | ✓ | menutup batasan PGlite #25 |
| Bentuk data pesanan | rekaan lewat `create_order` sungguhan, item JSON dari logika `resolveOrderItems` (fixture diekspor kode website) | sama | tanpa data pelanggan sungguhan |
| Kode website (panel admin, halaman pelanggan) terhadap DB tiruan | ✗ | ✗ | dev server website memakai DB produksi → K3 & X4 |

**Alternatif yang ditolak:** project Supabase kedua (batas paket gratis); branching Supabase
(berbayar); menguji di project POS produksi (data uji bercampur dengan POS sungguhan); schema `uji`
di DB website produksi (data rekaan & grant ganda di produksi, risiko salah sasaran); PGlite sebagai
server (`pglite-socket` — satu koneksi, tanpa login sungguhan).

**Aturan lingkungan lokal:** tidak ada secret produksi (kata sandi **uji lokal** saja, di berkas lokal
yang di-`.gitignore`); tidak ada data pelanggan sungguhan (tidak menyalin dump/cadangan produksi);
temp/cache di `D:\kerja-tmp\`; Docker macet → restart laptop, **jangan** reset/hapus data Docker
tanpa izin Owner; `supabase stop` setelah selesai; laporkan ruang C:/D: sebelum/sesudah.

### 6.3 Uji lokal

**L — DB website tiruan** (sesi website; jalur WSL atau Docker; bagian dari tahap 6a)

| # | Uji | Harapan |
|---|---|---|
| L1 | APPLY_1/2 pada database bersih hasil migrasi (Postgres sungguhan) | sama dengan PGlite #1 |
| L2 | Login `pos_reader` (kata sandi uji) | 4 view terbaca; tabel dasar ditolak; tulis ditolak (`default_transaction_read_only`); kueri lambat dihentikan `statement_timeout`; koneksi ke-4 ditolak |
| L3 | Login `pos_status_writer` | hanya execute fungsi; SELECT apa pun ditolak; koneksi ke-3 ditolak |
| L4 | `order_status_log.sumber` | `pos` dari login `pos_status_writer` sungguhan |
| L5 | Balapan | dua koneksi bersamaan pada pesanan sama → berurutan, hasil konsisten; penanda kasir vs "buat tagihan online" (§2.4c, disimulasikan SQL) → tepat satu menang |
| L6 | Kunci diskon | `resolusi_diskon_tertahan` sebagai `service_role` setelah `diproses` → `diskon_terkunci` |
| L7 | Saklar `go_live_at` | NULL ↔ nilai → view kosong/terisi & fungsi menolak/menerima seketika |
| L8 | Kursor | transaksi panjang yang commit belakangan tetap tertangkap jendela tumpang 2 menit |

**P — jembatan POS** (sesi POS; stack lokal POS + `website_tiruan`; tahap 6b)

| # | Uji | Harapan |
|---|---|---|
| P1 | Tarik pesanan (Delivery/Pick Up/Dine-in, bervoucher, berongkir, `options` lama & baru) | tersimpan benar di POS lokal; tarik ulang tak menggandakan |
| P2 | `options` | kunci teknis dipakai; pesanan tanpa `_format` dipetakan lewat nama |
| P3 | Alur sukses status | diterima → diproses → siap_diambil / sedang_diantar → selesai; tercermin di view & log |
| P4 | Penanda kasir (R9) | edit item di POS memanggil fungsi dgn `p_diubah_kasir` **sebelum** menyimpan; gagal → edit dibatalkan; online → bayar di tempat |
| P5 | Kunci edit | pesanan `lunas` (diisi SQL di tiruan) → edit terkunci; fungsi menolak penanda |
| P6 | `menunggu_admin` | "Konfirmasi & Proses" nonaktif; setelah penanda hilang angka header terbaru dipakai |
| P7 | Galat & jaringan | semua kode galat §2.2 berpesan jelas untuk kasir; jaringan putus → kirim ulang aman (idempoten) |
| P8 | Pelanggan & ongkir | sinkron inkremental via `updated_at` + rekonsiliasi id harian; `v_pengaturan_ongkir` terbaca (kalkulator menyusul, P9) |

### 6.4 Yang hanya bisa diuji di produksi, dan caranya

| # | Uji | Tahap | Pengaman |
|---|---|---|---|
| X1 | `pos_reader` lewat pooler produksi (format user, TLS, mode transaksi, tanpa prepared statement): baca `v_pelanggan`, `v_pengaturan_ongkir`; `v_pesanan` kosong | 7 | baca saja; kapan saja |
| X2 | `pos_status_writer` lewat pooler memanggil fungsi (uuid acak → `pesanan_tidak_ada`; pesanan lama → `sebelum_go_live`) | 7 | go-live NULL → fungsi menolak sebelum menulis apa pun; kapan saja |
| X3 | Penjadwal Edge Function produksi (30 dtk) & secret POS | 8b | — |
| X4 | Pesanan dari checkout website sungguhan (kode baru, kunci teknis) tiba di POS ≤ 1 menit; status kembali; `/pesanan/[kode]` & panel admin ("Status dikelola dari POS") benar | 8b | prosedur di bawah |
| X5 | Penanda kasir pada pesanan uji → `diubah_di_pos`, log `sumber = pos` | 8b | prosedur di bawah |

Kunci diskon, balapan, dan pembayaran online **tidak** diuji di produksi (cukup L5–L6/PGlite;
pembayaran online baru ada di Proyek B).

**Prosedur aman tahap 8b** (jendela sesingkat mungkin, ±15 menit):
1. Jam sepi 22.00–10.00 **dan** izin Owner khusus untuk pekerjaan ini; jam dicek dengan Node; 0 pesanan
   sungguhan 15 menit terakhir.
2. Snapshot: `pengaturan_pos`, `pengaturan_ongkir`, menu, jumlah pesanan per status,
   `voucher_redemptions`.
3. Owner (SQL): `go_live_at = now()` → hanya pesanan **sesudah** detik ini yang terlihat POS.
4. Pesanan uji bertanda dari website produksi: akun pelanggan uji "Uji POS" (nomor uji), **Pick Up**
   (tanpa ORS), tanpa voucher, catatan "UJI POS — JANGAN DIBUAT". POS menampilkan lencana UJI bila
   penanda cocok.
5. POS: tarik → `diterima` (+ penanda kasir) → `diproses` → `siap_diambil` → **`batal`** (tak masuk
   omzet). Cek halaman pelanggan & panel admin.
6. `finally` (selalu, juga bila gagal): Owner mengembalikan `go_live_at` ke NULL — atau langsung ke nilai
   go-live bila ini pagi go-live; pesanan sungguhan yang sempat masuk selama jendela tetap utuh,
   kembali dikelola panel admin (saklar) dan dilaporkan; pesanan & pelanggan uji dihapus **hanya lewat
   penanda** (Owner, SQL); data uji di POS dihapus sesi POS. Baris `order_status_log`/`admin_audit`
   pesanan uji tetap ada (hanya-tambah, tanpa FK) — dicatat di HANDOVER.
7. Snapshot sesudah = sebelum, kecuali sisa yang dicatat.

Catatan: server website menerima pesanan kapan saja (tidak ada pemeriksaan jam toko di
`/api/orders`), jadi pesanan sungguhan bisa masuk di jendela uji — karena itu jendela pendek, jam
sepi, dan saklar `go_live_at` dipulihkan di `finally`.
