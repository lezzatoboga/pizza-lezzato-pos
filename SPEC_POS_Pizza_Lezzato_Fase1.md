# Spesifikasi POS Pizza Lezzato — Fase 1

Disusun 23 September 2026

## 1. Ringkasan & Ruang Lingkup

**Tujuan Fase 1**: mencatat transaksi penjualan dari kasir, terintegrasi dengan order dari website (pizzalezzato.com) dan marketplace (input manual).

**Tidak termasuk di Fase 1**: modul HPP/inventori, integrasi otomatis ke aplikasi marketplace, modul rekonsiliasi penuh, laporan performa kasir per shift — semua ini direncanakan untuk fase berikutnya.

**Tech stack**: Svelte + Supabase (project Supabase terpisah dari website, dibangun menggunakan Claude Code).

## 2. Arsitektur Integrasi (POS ↔ Website)

Prinsip utama: **dua database terpisah** (POS dan website) demi keamanan dan kuota — POS tidak pernah diakses langsung dari sisi publik, dan sebaliknya.

- **Order baru**: website → Edge Function (jembatan API tervalidasi) → POS. Hanya data yang dibutuhkan untuk fulfillment yang dikirim (item, qty, catatan, tipe penjualan, kontak).
- **Update status pesanan**: POS → Edge Function → website, supaya customer bisa lihat status terbaru.
- **Data produk/menu**: POS membaca langsung dari database website via REST API bawaan Supabase + Row Level Security (RLS, SELECT-only) — karena data ini memang sudah publik, tidak perlu jembatan API seketat data order.
- POS menyimpan **cache lokal** data produk supaya tetap bisa beroperasi normal meski koneksi ke database website sedang bermasalah; cache disinkron ulang secara berkala.

## 3. Struktur Database (POS)

### 3.1 Referensi produk (cache dari website)

**products\_cache**: id, name, category, active, last\_synced\_at

**product\_variants\_cache** (ukuran — wajib, pilih satu): id, product\_id, name, price

**product\_addons\_cache** (extra topping — opsional, bisa pilih banyak): id, product\_id, name, price

### 3.2 Pengaturan

**payment\_methods**: id, name (Cash / Transfer Bank / QRIS), active

**marketplace\_platforms**: id, name (GoFood / GrabFood / ShopeeFood), markup\_percent, active

### 3.3 Transaksi

**transactions**: id, transaction\_number, transaction\_date, channel (admin\_toko / website / marketplace), sales\_type (dine\_in / take\_away / delivery), marketplace\_platform\_id, payment\_method\_id, source\_order\_id, discount\_code, discount\_amount, markup\_percent\_applied, subtotal, total, cashier\_id, shift\_id, kitchen\_ticket\_printed\_at, receipt\_printed\_status, receipt\_printed\_at, is\_locked, created\_at

**transaction\_items**: id, transaction\_id, product\_id, product\_name\_snapshot, variant\_name\_snapshot, variant\_price\_snapshot, qty, subtotal\_item

**transaction\_item\_addons**: id, transaction\_item\_id, addon\_name\_snapshot, addon\_price\_snapshot

_Catatan desain_: nama & harga disimpan sebagai snapshot di setiap item transaksi, supaya perubahan harga di kemudian hari tidak mengubah data transaksi historis.

### 3.4 Shift & rekonsiliasi kas

**shifts**: id, cashier\_id, opening\_balance, opening\_time, closing\_time, closing\_cash\_counted, expected\_cash, cash\_difference, status, notes

**cash\_movements**: id, shift\_id, type (masuk / keluar), amount, description, created\_at

Formula:

- `expected_cash = opening_balance + penjualan tunai − pengeluaran + pemasukan lain`
- `selisih = closing_cash_counted − expected_cash`

### 3.5 Pengguna, role & hak akses

**roles**: id, name (Owner, Supervisor, Kasir)

**permissions**: id, code, label (contoh: view\_sales\_report, view\_finance\_report, edit\_markup, void\_transaction)

**role\_permissions**: role\_id, permission\_code, granted

**pos\_users**: id, name, role\_id, pin (di-hash), active

## 4. Aturan Bisnis Utama

- **Channel** (sumber input order): Admin toko / Website / Marketplace
- **Tipe penjualan** (cara produk sampai ke customer): Dine-in / Take away / Delivery — otomatis ter-set ke Delivery kalau channel = Marketplace
- **Diskon & voucher**: sumber kebenaran ada di website; hanya berlaku untuk channel Website. Channel Admin toko dan Marketplace tidak punya diskon sama sekali.
- **Markup marketplace**: persentase tetap per platform (setting di marketplace\_platforms), dengan opsi override manual oleh kasir per transaksi untuk kondisi tertentu (misal ada promo khusus platform).
- **Rekonsiliasi marketplace**: data transaksi tersimpan detail (tanggal, platform, harga jual, item) supaya nanti gampang dicocokkan dengan laporan resmi marketplace dan mutasi rekening. Modul rekonsiliasi penuh (bandingkan 3 angka: POS vs laporan resmi vs uang masuk rekening) direncanakan fase berikutnya.
- **Varian produk**: menu, harga, dan varian sepenuhnya mengikuti website — POS tidak menjual item di luar yang ada di website.

## 5. Modul Laporan Penjualan

Dua bentuk laporan, memakai filter yang sama:

- **Ringkasan**: angka agregat sesuai filter & pengelompokan
- **Detail**: daftar transaksi satu per satu, bisa drill-down ke item — berguna untuk audit dan rekonsiliasi marketplace

**Filter tersedia**: rentang tanggal, channel, platform marketplace, tipe penjualan, metode pembayaran, produk/kategori, kasir

**Grouping**: tanggal, channel, platform, produk, kasir (bisa kombinasi)

**Metrik**: total penjualan, jumlah transaksi, rata-rata nilai transaksi, total diskon terpakai, total markup marketplace, jumlah item terjual

**Ekspor**: Excel/CSV, sesuai filter yang sedang aktif

## 6. Modul Cetak (Tiket & Struk)

**Tiket** (work order ke dapur): dicetak otomatis saat transaksi disimpan. Isi: nomor transaksi, waktu, tipe penjualan, daftar item + varian ukuran + extra topping + catatan. Tanpa harga. Dicetak ke printer di dapur.

**Struk** (bukti transaksi ke customer), dicetak ke printer di kasir, dua status:

- **Belum Lunas** — dicetak kalau ditekan sebelum pembayaran diinput
- **Lunas** — dicetak setelah pembayaran diinput

**Penguncian transaksi**: begitu struk (status apa pun) pernah dicetak, `is_locked = true` — tombol void/batal otomatis nonaktif untuk role Kasir. Hanya role dengan izin `void_transaction` (Owner, atau Supervisor kalau diberi izin) yang bisa membatalkan, dan pembatalan ini tercatat sebagai jejak audit (siapa, kapan, alasan) — bukan dihapus dari database.

**Hardware**: printer thermal 58mm Iware MP58SB (ESC/POS command, Bluetooth), 2 unit — 1 di dapur, 1 di kasir.

**Implementasi teknis**: menggunakan **RawBT** (aplikasi Android, gratis) sebagai jembatan cetak — aplikasi POS mengirim perintah ESC/POS ke RawBT, yang meneruskannya ke printer via Bluetooth Classic (SPP), karena Web Bluetooth API browser tidak mendukung protokol ini secara langsung. Perlu pairing Bluetooth manual satu kali di awal setup per printer.

## 7. Role & Hak Akses (Default Awal)

Hak akses diatur **per-role** (bukan per-individu), lewat halaman pengaturan izin yang bisa diubah Owner kapan saja tanpa perlu ubah kode aplikasi.

| Hak akses                      | Owner | Supervisor  | Kasir                         |
| ------------------------------ | ----- | ----------- | ----------------------------- |
| Lihat laporan ringkasan        | Ya    | Ya          | Bisa diatur                   |
| Lihat laporan detail transaksi | Ya    | Ya          | Bisa diatur                   |
| Ekspor laporan                 | Ya    | Ya          | Bisa diatur                   |
| Ubah setting markup/diskon     | Ya    | Bisa diatur | Biasanya tidak                |
| Void/batalkan transaksi        | Ya    | Bisa diatur | Tidak (setelah struk dicetak) |

## 8. Autentikasi & Sesi

- Login kasir memakai **PIN** (di-hash), konsisten dengan pola yang sudah dipakai di sistem absensi Pizza Lezzato
- Sesi tetap aktif sampai kasir logout manual (tidak perlu re-entry PIN tiap transaksi)

## 9. Di Luar Ruang Lingkup Fase 1

- Integrasi otomatis ke aplikasi resmi marketplace (saat ini input manual oleh kasir)
- Modul rekonsiliasi marketplace penuh
- Laporan performa kasir per shift
- Modul HPP/inventori (kemungkinan terhubung ke Workbook PL yang sudah ada)
