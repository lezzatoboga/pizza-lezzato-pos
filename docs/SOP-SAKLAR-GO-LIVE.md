# SOP Saklar Go-Live Jembatan Pesanan Website

Untuk **Owner** dan **admin website**. Berlaku setelah go-live jembatan pesanan (pesanan website
masuk otomatis ke POS kasir). Diperbarui 14 Okt 2026: tanda "jembatan mati" langsung muncul, dan
status dikirim ulang otomatis saat saklar menyala lagi.

## Apa itu saklar go-live

Satu nilai di database website: `pengaturan_pos.go_live_at` (waktu go-live).

- **Terisi** → jembatan **menyala**: pesanan website masuk ke POS, dan status dari kasir
  (Diproses, Siap, Selesai, Batal) dikirim balik ke website.
- **Kosong** → jembatan **mati**: POS tidak menerima apa pun dari website dan website menolak
  semua status dari POS. Panel admin website kembali mengurus **semua** pesanan.

Saklar ini hanya diubah oleh **Owner** lewat SQL Editor Supabase **website**.

> Catat dulu nilai `go_live_at` yang sekarang **sebelum** mengosongkannya. Saat menyalakan lagi,
> isi dengan **nilai yang sama persis** — jangan `now()`. Kalau diisi waktu baru, pesanan yang
> sudah ada di POS dianggap "sebelum go-live": tidak bisa lagi menerima status dari POS dan
> tidak pernah diperbarui lagi.

---

## A. Saat saklar DIMATIKAN (darurat)

### Langkah Owner

1. Catat nilai sekarang:
   `select go_live_at from public.pengaturan_pos where id = 1;`
2. Matikan: `update public.pengaturan_pos set go_live_at = null where id = 1;`
3. Kabari kasir dan admin (telepon/WA). Aplikasi kasir juga menampilkan **banner merah
   "Jembatan website DIMATIKAN"** di semua halaman dalam ±30 detik.

### Yang terjadi pada pesanan di POS

| Keadaan | Apa yang terjadi |
|---|---|
| Pesanan website yang **sudah ada** di POS | Tetap ada. Tidak dihapus, tidak dibatalkan. Kasir masih bisa Konfirmasi, Siap, Selesai, **Bayar**, Batalkan, dan cetak. |
| **Status** yang dikirim kasir selama mati | Ditolak website, ditandai "ditolak: jembatan website tidak aktif". **Saat saklar menyala lagi, status terakhir per pesanan dikirim ulang otomatis** (bagian B). |
| **Ubah pesanan** (edit item/ongkir) | Ditolak, dengan pesan "Jembatan website belum/tidak aktif". |
| Pesanan website **baru** | **Tidak masuk ke POS.** Tidak ada bunyi atau notifikasi. |
| Pembatalan oleh admin di website | Tidak sampai ke POS selama mati (sampai saat saklar menyala lagi). |

### Siapa mengurus apa selama mati

| Urusan | Dikerjakan di | Oleh |
|---|---|---|
| Membuat makanan, mencetak tiket dapur | POS (pesanan yang sudah ada) | Kasir |
| **Menerima pembayaran** dan mencatatnya | **POS** — supaya uang tercatat di laporan & shift | Kasir |
| Status pesanan yang **sudah ada di POS** | Kasir **tetap menekan tombol di POS** (Konfirmasi, Siap, Selesai). Status terakhir terkirim ke website otomatis saat saklar menyala lagi. | Kasir |
| Kabar ke pelanggan selama mati (bila perlu) | Panel admin website — **hanya maju** (mis. diproses → siap), jangan Selesai/Batal kalau kasir belum | Admin |
| Pesanan website **baru** | **Panel admin website** — admin meneruskan isi pesanan ke kasir (WA/telepon) | Admin → kasir |
| Membatalkan pesanan | Kasir di POS ("Batalkan"); pembatalan ikut terkirim saat saklar menyala lagi | Kasir (dikabari admin) |

**Pesanan baru selama mati** yang dimasak dan dibayar di toko: kasir mencatatnya di POS sebagai
pesanan biasa (kanal admin toko), dengan catatan kode pesanan website (`PL-…`) agar mudah dicocokkan.

> **Aturan penting untuk admin:** pesanan website yang **dibuat selama mati** harus sudah
> **Selesai** atau **Batal** di panel admin sebelum saklar dinyalakan lagi — kalau masih aktif,
> pesanan itu masuk ke POS sebagai pesanan baru dan menjadi **ganda** dengan catatan manual kasir.
> Setelah saklar menyala, panel admin **tidak bisa** lagi mengubah status pesanan POS ("Status
> dikelola dari POS").

---

## B. Saat saklar DINYALAKAN lagi

### Sebelum menyalakan (admin + kasir)

1. **Admin:** pesanan website yang **dibuat selama mati** sudah **Selesai** atau **Batal** di panel.
2. **Kasir:** semua pembayaran yang diterima selama mati sudah dicatat di POS, dan tombol status
   (Siap/Selesai/Batalkan) untuk pesanan yang sudah ada sudah ditekan sesuai keadaan sebenarnya.

### Langkah Owner

3. Nyalakan dengan nilai **lama** (dari langkah A1):
   `update public.pengaturan_pos set go_live_at = '<nilai lama>' where id = 1;`
4. Kabari kasir dan admin bahwa jembatan menyala lagi.

### Yang terjadi otomatis (dalam ±30 detik)

- Banner merah hilang; POS mengambil lagi data pesanan dari website.
- **Kirim ulang status:** untuk setiap pesanan yang statusnya ditolak selama mati, POS mengirim
  **hanya status terakhirnya** (mis. kalau kasir menekan Diproses lalu Siap, yang dikirim hanya
  Siap), **sekali saja**, mengikuti aturan website (hanya maju):
  - status website **sama** dengan POS → tidak dikirim;
  - website **sudah lebih maju** (mis. admin sudah Siap) → tidak dikirim; kasir melanjutkan biasa;
  - website **Selesai/Batal** tetapi POS berakhir **berbeda** (mis. POS Selesai, website Batal) →
    tidak dikirim, masuk **daftar Owner**;
  - kiriman ulang yang **ditolak** website → **tidak dicoba lagi**, masuk **daftar Owner**.
- Pesanan yang **dibatalkan admin** selama mati:
  - **belum dibayar** di POS → dibatalkan otomatis di POS ("Dibatalkan di website"). Kalau tiket
    dapur sudah tercetak, slip **BATAL** tercetak otomatis;
  - **sudah dibayar** (di POS atau lunas online) → **tidak** dibatalkan otomatis, muncul peringatan
    untuk kasir (urus pengembalian dana).
- Pesanan website yang dibuat selama mati dan sudah **Selesai/Batal** di panel hanya dicatat —
  tidak menjadi transaksi baru di POS.

### Merapikan (Owner, dibantu kasir)

1. **Daftar Owner** — bila ada, muncul banner "… status pesanan web ditolak website setelah saklar
   go-live menyala lagi" (khusus Owner). Buka **Pengaturan → Sinkron → Perlu diselesaikan manual**.
   Untuk tiap baris, samakan keadaannya:
   - POS benar (mis. pesanan memang selesai & dibayar) tetapi website berbeda → minta sesi
     website/Owner memperbaiki status di database website;
   - website benar (mis. pesanan memang batal) → batalkan transaksi di POS (dan urus uangnya
     bila sudah dibayar).

   Lalu tekan **Tandai selesai**.
2. **Peringatan "dibatalkan di website, tetapi sudah dibayar"** → Owner/Supervisor memutuskan
   pengembalian dana, lalu membatalkan transaksi di POS bila perlu.
3. **Pesanan ganda** (dicatat manual selama mati **dan** masuk lagi setelah menyala) → batalkan
   salah satunya (alasan: pesanan dobel). Pilih yang **belum dibayar**.
4. Buka **Pesanan Web → Aktif**: pesanan yang sudah diantar/diambil tetapi belum ditutup →
   **Bayar** (bila belum) lalu **Selesai**.

---

## Yang terlihat di aplikasi kasir

- **Saklar mati:** banner merah "Jembatan website DIMATIKAN" di semua halaman (±30 detik setelah
  saklar dikosongkan), dan keterangan merah di halaman Pesanan Web. Daftar Pesanan Web tetap berisi
  pesanan lama; tidak ada pesanan baru.
- Pada pesanan yang statusnya ditolak selama mati: "Status … ditolak website: jembatan website
  tidak aktif". Tanda ini hilang sendiri setelah saklar menyala dan status dikirim ulang.
- **Khusus Owner:** banner kuning bila ada baris di daftar "Perlu diselesaikan manual".

Catatan: banner merah muncul segera bila POS masih punya pesanan website dari 14 hari terakhir.
Kalau belum ada sama sekali (mis. sebelum go-live pertama), halaman Pesanan Web menampilkan
"Jembatan website belum aktif".

## Lebih keras dari saklar (jarang dipakai)

Kalau perlu memutus POS sama sekali dari database website, Owner menjalankan di website:
`alter role pos_reader nologin; alter role pos_status_writer nologin;`

Akibatnya:
- Kasir melihat "Gagal cek terakhir: …" di halaman Pesanan Web (tanpa banner merah).
- Sinkron pelanggan ikut gagal.
- Karena `go_live_at` tetap terisi, panel admin **tetap tidak bisa** mengubah status pesanan POS.
- Status yang dikirim kasir **tetap mengantre** dan terkirim sendiri paling lambat ±10 menit
  setelah login dipulihkan (`… login;`).

Untuk keadaan darurat biasa, cukup saklar `go_live_at`.
