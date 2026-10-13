# Catatan: jembatan pesanan website ↔ POS

Status: **perencanaan** (dilanjutkan 13 Okt 2026). Kontrak data: `docs/KONTRAK-DATA-POS.md`
(salinan dari repo website — sumber kebenaran di sana). Pekerjaan di sisi website dikerjakan di
project website, bukan dari repo POS; kebutuhan dari website ditulis sebagai permintaan untuk
Owner. Pengembangan POS dilakukan terhadap Supabase **lokal** (Bagian 6 kontrak).

## Keputusan Owner 13 Okt 2026

### Jawaban B1–B7 (final, disesuaikan dengan kontrak)

1. **Penarikan pesanan:** POS menarik pesanan setiap **30 detik** dari view schema `pos` lewat
   `pos_reader`, ditambah tombol **"Cek pesanan"**.
2. **Status yang dikirim** lewat `pos_set_order_status`:
   - pesanan masuk ke POS → `diterima`;
   - **Konfirmasi & Proses** → `diproses`;
   - tombol **"Siap"**: Pick Up dan Dine-in → `siap_diambil` (website menampilkan "Siap
     disajikan" untuk dine-in); Delivery → `sedang_diantar`. Label tombol menyesuaikan tipe
     pesanan;
   - **"Selesai"** lewat **tombol** kasir, tidak otomatis saat lunas;
   - void → `dibatalkan` (dipetakan website ke `batal`).
3. **Ongkir:** memakai angka tersimpan dari website. Kalau kasir mengubah ongkir atau item, itu
   dihitung sebagai **edit kasir**.
4. **Item tambahan dari kasir** memakai harga normal POS.
5. **Shift:** pesanan tetap masuk dan tampil walau shift belum dibuka; **Konfirmasi & Proses**
   menunggu shift dibuka.
6. **Go-live:** tanggal go-live **tidak** diatur di Pengaturan POS — sumbernya `go_live_at` di
   website. POS mengikuti apa yang dikembalikan view dan fungsi status.
7. **Notifikasi:** bunyi **berulang** sampai pesanan dibuka kasir.

### Aturan tambahan dari kontrak

- **Edit kasir:** sebelum menyimpan perubahan item/ongkir, POS **wajib** mengirim penanda
  `diubah_kasir` lewat `pos_set_order_status`. Kalau ditolak (`pembayaran_berjalan` /
  `sudah_lunas_terkunci`), edit tidak boleh disimpan dan kasir mendapat pesan yang jelas. Pesanan
  dengan `terkunci_edit` tidak bisa diedit sama sekali.
- **`menunggu_admin`:** selama penanda ini ada, tombol Konfirmasi & Proses ditahan, dengan
  keterangan "menunggu verifikasi admin website". Selalu pakai angka diskon/total dari header
  terbaru.
- **Item:** pakai kunci teknis di `options` (`_ukuran_key`, `_topping_ids`, dll.) bila ada;
  pemetaan berbasis nama hanya untuk pesanan lama. Kalau gagal dipetakan, tampilkan teks aslinya
  dengan tanda peringatan — jangan ditebak.
- **Tiket dapur:** tipe pesanan (DELIVERY / PICK UP / DINE-IN) tercetak jelas dan besar — dine-in
  perlu persiapan alat makan.
- **Sinkron pelanggan:** kolom `created_at` tidak dipakai lagi; pakai `customers.updated_at` untuk
  sinkron inkremental. Saklar jeda tetap dipakai sampai `pos_reader` aktif.
- **Aturan CETAK ULANG:** tinjau ulang terhadap pembayaran online (lihat bagian di bawah).
- **Kalkulator ongkir POS:** **tidak** termasuk tahap ini.

## Hal yang perlu ditinjau ulang saat jembatan/pembayaran online dikerjakan

### Tanda CETAK ULANG pada struk

Aturan sekarang (keputusan Owner 2026-10-12): struk diberi tanda **CETAK ULANG** hanya kalau
struk dengan **status yang sama** sudah pernah dicetak (Belum Lunas → Belum Lunas, Lunas →
Lunas). Struk Lunas setelah struk Belum Lunas **tidak** bertanda. Tiket dapur memakai hitungan
cetaknya sendiri.

Implementasinya membandingkan status struk terakhir yang dicetak (`receipt_printed_status`)
dengan status bayar saat ini (`src/lib/print/reprint.ts`, migrasi `20261012000006`). Ini benar
karena status bayar di POS tidak bisa kembali dari Lunas ke Belum Lunas.

**Kalau pembayaran online (mis. Midtrans) atau jembatan pesanan memperkenalkan pembatalan
pembayaran atau refund** (Lunas → Belum Lunas), aturan ini harus ditinjau ulang dan kemungkinan
beralih ke penghitung cetak per status (`receipt_unpaid_print_count` / `receipt_paid_print_count`
di `transactions`, diisi oleh `mark_receipt_printed`).

## Temuan uji paket website tiruan (13 Okt 2026)

- **`pos_reader` wajib punya `grant execute on function public.pesanan_pos(timestamptz)`.**
  `pos.v_pesanan` memanggil `public.pesanan_pos()`, dan Postgres memeriksa hak EXECUTE fungsi di
  dalam view terhadap **pengguna** view (bukan pemiliknya). Tanpa grant ini `v_pesanan` gagal
  dibaca (galat *permission denied*). Sudah ada di paket
  (`supabase/website-tiruan/02_peran_pos_lokal.sql`) dan di kontrak §2.1; grant ini tetap
  berlaku sesudah tahap 8.
- **Perbandingan dengan website tiruan mini tahap A** (`supabase/dev/website-stub.sql`, dihapus 14 Okt 2026): di sana
  muncul *permission denied for table stub_settings* dan diselesaikan dengan cara yang sama seperti paket resmi — fungsi
  go-live dibuat `SECURITY DEFINER` (agar bisa membaca pengaturan go-live yang tidak boleh dibaca
  `pos_reader`) **dan** `pos_reader` diberi EXECUTE pada fungsi itu. Bedanya hanya nama
  (`pos.stub_pesanan_pos` vs `public.pesanan_pos`) dan paket resmi juga mencabut EXECUTE dari
  `public`/`anon`/`authenticated` lebih dulu. Tahap B mengikuti paket resmi; website tiruan mini
  tidak dipakai lagi.

## Tahap B — uji lokal terhadap paket website tiruan (13 Okt 2026)

Paket `supabase/website-tiruan/` (website 41e0503) dipasang ke database terpisah
`website_tiruan` di Supabase lokal (Postgres 17) mengikuti README; Edge Function lokal
terhubung sebagai `pos_reader` / `pos_status_writer` (kata sandi uji lokal). P1–P8 dan uji
tambahan POS lolos dari keadaan bersih (86 pemeriksaan).

Perubahan dari uji ini:

- **Sinkron pelanggan pindah ke `pos.v_pelanggan`** (migrasi `20261014000002`): inkremental
  `updated_at > kursor − 2 menit`, rekonsiliasi id penuh sekali sehari (WIB). Pelanggan yang
  hilang di website **dilepas** (tidak dihapus); pencocokan id website dulu, lalu nomor HP.
  Koneksinya memakai secret yang sama dengan jembatan, **`WEBSITE_POS_READER_DB_URL`** —
  secret lama `WEBSITE_CUSTOMERS_DB_URL` tidak dipakai lagi (dihapus Owner di tahap C).
  Saklar jeda tetap berlaku.
- **Rangkaian status terkirim dalam satu run** (diproses → siap → selesai), tetap berurutan
  per pesanan; sebelumnya satu langkah per 30 detik.
- **Pesanan lunas online yang dibatalkan di website tidak di-void otomatis** — hanya peringatan
  (keputusan 4: yang sudah dibayar hanya diberi peringatan), walau pembayaran online belum
  tercatat di POS.

Catatan:

- Dari Edge Function lokal, host database = **`db`** (bukan
  `supabase_db_<project_id>`, ditolak Deno — README paket sudah diperbaiki di 3f547ec).
- Saat saklar go-live dikosongkan, status yang sedang antre ditandai **gagal
  (`sebelum_go_live`)**. Perilaku saat saklar menyala lagi: lihat
  `docs/SOP-SAKLAR-GO-LIVE.md` (kirim ulang otomatis status terakhir, 14 Okt 2026).

## Galat sementara (kontrak 8374a77, 14 Okt 2026)

Pengaturan peran sama dengan produksi (`APPLY_KONTRAK_POS_2`): `pos_status_writer`
`lock_timeout` 3 dtk, `statement_timeout` 5 dtk, transaksi menganggur 30 dtk, maks. 2 koneksi.
Galat berikut **bukan penolakan pesanan**:

| Galat | Kode di POS | Sinkron (antrean) | Edit kasir |
|---|---|---|---|
| 55P03 lock timeout (pesanan dikunci transaksi lain) | `sibuk` | antre ulang (jeda 30 dtk → 10 mnt); pesanan lain di run yang sama tetap dikirim | coba sekali lagi otomatis; masih gagal → "Pesanan sedang diproses di website…", tidak disimpan |
| 57014 statement timeout | `timeout` | antre ulang; sisa antrean menunggu run berikutnya | idem, "Website lambat menjawab…" |
| koneksi ditolak/terputus (termasuk diputus server) | `jaringan` | antre ulang; sisa antrean menunggu run berikutnya | idem, "Website tidak terjangkau…" |

Hanya kode aturan kontrak (P0001 + awalan kode §2.2) yang membuat status gagal permanen.
Fungsi website idempoten, jadi kiriman ulang aman (diuji: tercatat sekali di `order_status_log`).

## Backlog Proyek B — pembayaran online (Midtrans)

Keputusan Owner 13 Okt 2026 (setelah tahap A): untuk pesanan yang **sudah lunas online**
(`status_bayar = lunas` di website), POS **menyembunyikan** tombol **Bayar** dan **Struk Belum
Lunas** — ini hanya penutup sementara. Saat pembayaran online aktif, yang harus dikerjakan:

- **Pencatatan pembayaran otomatis:** begitu `status_bayar` website = `lunas`, POS mencatat
  pembayaran **otomatis** dengan metode **"Online/website"** (nominal dari `dibayar_rupiah`,
  waktu dari `dibayar_at`), tanpa tindakan kasir. Tanpa ini:
  - aturan "Selesai hanya kalau lunas" membuat pesanan lunas online **tidak bisa diselesaikan**;
  - laporan penjualan menghitungnya sebagai **belum lunas**.
- **Jenis struk untuk pesanan lunas online:** struk Lunas yang menyebut pembayaran online
  (metode, waktu bayar) — ditentukan bersama tinjauan aturan CETAK ULANG di atas.

## Backlog (dibahas bersama kontrak data)

### Ongkir: satu sumber aturan

Kalkulator ongkir POS saat ini sederhana: **jarak × satu tarif per km** (Pengaturan → Tarif
ongkir), dibulatkan ke atas per Rp1.000. Website sedang membuat ongkir otomatis dengan **tarif
bertingkat** dan **faktor rute**. Keduanya perlu diselaraskan:

- **Satu sumber aturan ongkir:** website menyimpan aturan (tarif bertingkat, faktor rute), POS
  membaca — tidak ada dua pengaturan tarif yang bisa berbeda.
- Pesanan website membawa ongkir yang sudah dihitung; kasir hanya meninjau/mengoreksi.
- Untuk pesanan kasir (admin toko), POS menghitung dengan aturan yang sama (dibaca dari website
  atau disinkronkan ke POS), lalu kalkulator jarak × tarif tunggal di POS dipensiunkan.
- Sampai saat itu, Pengaturan → Tarif ongkir di POS tetap dipakai apa adanya.
