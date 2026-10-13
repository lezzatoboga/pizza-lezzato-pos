# Paket database website tiruan — untuk sesi POS

Paket ini membuat **tiruan database website Pizza Lezzato** di Supabase lokal milik repo POS, supaya
jembatan pesanan POS bisa dikembangkan dan diuji **tanpa menyentuh produksi**. Isinya: skema website
yang sama dengan produksi (termasuk schema `pos`), data **rekaan**, dan peran `pos_reader` /
`pos_status_writer` dengan kata sandi **uji lokal**.

- Acuan aturan & keputusan: [KONTRAK-DATA-POS.md](KONTRAK-DATA-POS.md) (salinan dari repo website).
- Versi paket & sidik jari berkas: [VERSI.txt](VERSI.txt).
- Dibuat oleh sesi website (`scripts/buat-paket-website-tiruan.mjs`). **Jangan mengedit `01_`, `02_`, dan `03_`
  secara manual** — minta paket baru dari sesi website bila skema/kontrak berubah.

## Isi paket

| Berkas | Isi | Kapan dijalankan |
|---|---|---|
| `00_HANYA_postgres_biasa.sql` | peran tiruan Supabase (`anon`, `authenticated`, `service_role`, `authenticator`) | **hanya** jalur cadangan tanpa Docker — LEWATI di Supabase lokal |
| `01_skema_website.sql` | 59 migrasi website (urut) = skema produksi + tiruan `pg_cron` | sekali, di database kosong |
| `02_peran_pos_lokal.sql` | **persis** `APPLY_KONTRAK_POS_2_PERAN.sql` produksi (hak & pengaturan peran tahap 5) + LOGIN & kata sandi uji lokal | sesudah `01`; aman diulang |
| `03_data_rekaan.sql` | menu (58 item dari kode), pengaturan ongkir, go-live 20 hari lalu, 8 pelanggan & 12 pesanan rekaan | sesudah `01`; **aman diulang** (reset data rekaan) |
| `04_cek_pemasangan.sql` | satu baris bukti pemasangan | sesudah `03` |
| `05_alat_uji.sql` | potongan SQL meniru kejadian sisi website (bayar lunas, verifikasi admin, saklar go-live, …) | sesuai kebutuhan uji |
| `KONTRAK-DATA-POS.md` | kontrak data website ↔ POS (keputusan Owner, view, fungsi, kode galat, format `options`) | bacaan wajib |
| `VERSI.txt` | commit website asal paket, tanggal, sidik jari | — |

## Aturan

- **Hanya untuk lingkungan lokal.** Kata sandi `lokal-pos-reader-uji` / `lokal-pos-status-writer-uji`
  bukan kata sandi produksi dan tidak boleh dipakai di produksi. Kredensial produksi hanya dari Owner.
- Semua data **rekaan**: nama "Pelanggan Rekaan NN", HP `+62800000000NN`, alamat "Jl. Rekaan …",
  kode pesanan `PL-REKAANNN`. Jangan memasukkan data sungguhan ke database ini.
- Pasang di **database terpisah `website_tiruan`**, bukan database POS (`postgres`): kedua sistem punya
  tabel bernama sama di schema `public` (mis. `customers`).
- Peran Postgres berlaku se-cluster: `pos_reader`/`pos_status_writer` juga ada di stack lokal POS, tapi
  hanya punya hak di `website_tiruan`.

## Prasyarat

- Docker Desktop dengan lokasi disk di D: (sudah dipindah Owner). Docker macet → restart laptop; jangan
  reset/hapus data Docker tanpa izin Owner.
- Supabase CLI; stack lokal repo POS dengan **`[db] major_version = 17`** di `supabase/config.toml`
  (produksi website: Postgres 17.6). Edge Runtime menyala.
- `psql` (atau lewat `docker exec`, lihat langkah 3).

## Pemasangan (Supabase lokal di repo POS)

1. Di repo POS: `supabase start` (layanan yang tak dipakai boleh dikecualikan dengan `-x`).
2. Buat database tiruan (kata sandi `postgres` lokal bawaan Supabase CLI = `postgres`):

   ```bash
   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -c "create database website_tiruan"
   ```

3. Jalankan berkas **01 → 02 → 03** (lewati 00), berhenti pada galat pertama:

   ```bash
   psql "postgresql://postgres:postgres@127.0.0.1:54322/website_tiruan" -v ON_ERROR_STOP=1 -f 01_skema_website.sql
   ```

   (ulangi untuk `02_peran_pos_lokal.sql` dan `03_data_rekaan.sql`). Tanpa `psql` di Windows:
   `docker exec -i supabase_db_<project_id> psql -U postgres -d website_tiruan -v ON_ERROR_STOP=1 < 01_skema_website.sql`.
   **Jangan** memakai `--single-transaction` (beberapa migrasi punya `begin/commit` sendiri).
4. Jalankan `04_cek_pemasangan.sql` — harapannya ada di kepala berkas (menu 58, pesanan 12, v_pesanan 10,
   outlet `0.47939978361032837`, menunggu_admin 2, terkunci_edit 1, format_lama 1, …).

Jalur cadangan tanpa Docker (Postgres biasa, mis. WSL): buat database `website_tiruan`, lalu **00 → 01 → 02 → 03 → 04**.

## Koneksi untuk jembatan POS (lokal)

| Peran | Dari laptop | Dari Edge Function (di dalam Docker) |
|---|---|---|
| `pos_reader` | `postgresql://pos_reader:lokal-pos-reader-uji@127.0.0.1:54322/website_tiruan` | `postgresql://pos_reader:lokal-pos-reader-uji@db:5432/website_tiruan` |
| `pos_status_writer` | `postgresql://pos_status_writer:lokal-pos-status-writer-uji@127.0.0.1:54322/website_tiruan` | `postgresql://pos_status_writer:lokal-pos-status-writer-uji@db:5432/website_tiruan` |

- Dari Edge Function **pakai host `db`** (alias jaringan Docker Supabase lokal), **bukan**
  `supabase_db_<project_id>`: nama bergaris bawah ditolak resolver DNS Deno (masukan sesi POS, tahap B).
  Nama kontainer `supabase_db_<project_id>` tetap benar untuk `docker exec` (langkah 3).

- Simpan URL di berkas env lokal Edge Function (tidak di-commit). URL produksi kelak berbeda: lewat
  **pooler** Supabase (`<peran>.<project-ref>`, TLS, mode transaksi port 6543) — klien harus **tanpa
  prepared statement**; pakai klien & opsi yang sama sejak uji lokal.
- `pos_reader` hanya boleh membaca `pos.v_pesanan`, `pos.v_item_pesanan`, `pos.v_pelanggan`,
  `pos.v_pengaturan_ongkir` (read-only, kueri maks. 5 dtk, transaksi menganggur maks. 30 dtk, maks. 3 koneksi).
- `pos_status_writer` hanya boleh `select pos.pos_set_order_status(<id>, <status>, <diubah_kasir>)`
  (kueri maks. 5 dtk, menunggu kunci baris maks. 3 dtk, menganggur maks. 30 dtk, maks. 2 koneksi) —
  **tidak bisa SELECT apa pun**; id pesanan diambil dari `v_pesanan` lewat `pos_reader`.
- Pengaturan itu **per peran** (sama dengan produksi). Galat `55P03` (*lock timeout*), `57014`
  (*statement timeout*) dan koneksi terputus = **kirim ulang** (fungsi idempoten), bukan penolakan kontrak.
- Produksi kelak: secret POS `WEBSITE_POS_READER_DB_URL` & `WEBSITE_POS_STATUS_DB_URL` (diisi Owner, tahap 7).

## Ringkasan kontrak (detail: KONTRAK-DATA-POS.md)

- Kursor: `select … from pos.v_pesanan where updated_at > :kursor - interval '2 minutes' order by updated_at`
  → upsert by `id`; item dibaca sekali per pesanan dari `v_item_pesanan` (§2.1).
- Status dari POS: `diterima`, `diproses`, `siap_diambil` (Pick Up/Dine-in), `sedang_diantar` (Delivery),
  `selesai`, `dibatalkan` (tersimpan sebagai `batal`). Hanya maju; status sama = aman diulang (§2.2).
- Kode galat (awalan pesan): `status_tidak_dikenal`, `pesanan_tidak_ada`, `sebelum_go_live`,
  `transisi_ditolak`, `menunggu_admin`, `belum_lunas`, `sudah_lunas_terkunci`, `pembayaran_berjalan`.
- `menunggu_admin = true` → tahan "Konfirmasi & Proses"; pakai angka header terbaru setelahnya.
  `terkunci_edit = true` (lunas) → kunci edit item/ongkir. Edit oleh kasir → kirim `p_diubah_kasir = true`
  **sebelum** menyimpan edit (Keputusan Owner R1, risiko R9).
- `options` item: pakai kunci teknis bila ada `_format: 2` (`_ukuran_key`, `_varian_key`, `_pilihan`,
  `_topping_ids`); pesanan tanpa `_format` → petakan lewat nama (§2.9).

## Data rekaan (12 pesanan, go-live 20 hari lalu)

| Kode | Skenario | Uji POS |
|---|---|---|
| PL-REKAAN01 | Delivery berongkir + voucher 10%; pizza Large + 2 topping; paket berpilihan | P1, P2, P3 (sedang_diantar), P4 |
| PL-REKAAN02 | Pick Up; Rice Box saus ×2, teh ×2; catatan | P1, P3 (siap_diambil) |
| PL-REKAAN03 | Dine-in; varian Mini; paket; Pizza Kotak + topping | P1, P2 |
| PL-REKAAN04 | Delivery alur lama (ongkir NULL) | P1 |
| PL-REKAAN05 | menunggu_admin: verifikasi HP pending | P6 (+ `05_alat_uji.sql` B) |
| PL-REKAAN06 | menunggu_admin: diskon ditahan | P6 (+ C, angka berubah) |
| PL-REKAAN07 | bayar online, belum bayar | P4 (→ bayar di tempat), `belum_lunas` |
| PL-REKAAN08 | bayar online, menunggu (QRIS) | `pembayaran_berjalan` (+ E) |
| PL-REKAAN09 | bayar online, lunas | P5 (`terkunci_edit`, `sudah_lunas_terkunci`) |
| PL-REKAAN10 | `options` format lama (tanpa `_format`) | P2 (pemetaan nama) |
| PL-REKAAN11 | dibuat sebelum go-live | tak terlihat; fungsi → `sebelum_go_live` |
| PL-REKAAN12 | sesudah go-live, > 14 hari | di luar jendela `v_pesanan` |

Reset semua data rekaan: jalankan ulang `03_data_rekaan.sql`. Riwayat status (`public.order_status_log`)
hanya bisa ditambah, jadi barisnya tetap — tidak mengganggu.

## Yang TIDAK bisa diuji di sini (hanya di produksi, dengan izin Owner — Bagian 6.4 kontrak)

- Koneksi pooler produksi (format user, TLS, mode transaksi) — X1–X2.
- Penjadwal Edge Function produksi — X3. Pesanan dari checkout website sungguhan — X4.
- Menu di paket berasal dari kode website (sumber seed awal), **bukan menu live** — nama/harga bisa beda.
  Menu live tetap dibaca POS lewat publishable key seperti sekarang.
- Website (halaman/admin) tidak berjalan di lingkungan ini; ongkir ORS tidak dipanggil.

## Memperbarui paket

Sesi website menjalankan `node scripts/buat-paket-website-tiruan.mjs` lalu menguji ulang. Owner
mengganti **seluruh** folder di repo POS dengan folder baru, lalu sesi POS memasang ulang database
(`drop database website_tiruan; create database website_tiruan;` → 01 → 02 → 03 → 04).
Bandingkan `VERSI.txt` untuk tahu paket mana yang terpasang. Bila hanya `02_` yang berubah (mis. paket
14 Okt: pengaturan per peran + `lock_timeout`/`idle_in_transaction_session_timeout`), cukup jalankan ulang
`02_peran_pos_lokal.sql` lalu `04_cek_pemasangan.sql` — data tak tersentuh; sambungan lama perlu dibuka ulang.
