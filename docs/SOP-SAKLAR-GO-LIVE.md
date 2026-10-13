# SOP Saklar Go-Live Jembatan Pesanan Website

Untuk **Owner** dan **admin website**. Berlaku setelah go-live jembatan pesanan (pesanan website
masuk otomatis ke POS kasir).

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
3. **Kabari kasir dan admin** (telepon/WA). Jangan menunggu tanda di aplikasi — lihat catatan
   di bagian "Yang terlihat di aplikasi kasir".

### Yang terjadi pada pesanan di POS

| Keadaan | Apa yang terjadi |
|---|---|
| Pesanan website yang **sudah ada** di POS | Tetap ada. Tidak dihapus, tidak dibatalkan. Kasir masih bisa Konfirmasi, Siap, Selesai, **Bayar**, Batalkan, dan cetak. |
| **Status** yang dikirim kasir selama mati | Ditolak website dan ditandai **gagal** ("jembatan website tidak aktif"). Status itu **tidak dikirim ulang otomatis** saat saklar menyala lagi. |
| **Ubah pesanan** (edit item/ongkir) | Ditolak, dengan pesan "Jembatan website belum/tidak aktif". |
| Pesanan website **baru** | **Tidak masuk ke POS.** Tidak ada bunyi atau notifikasi. |
| Pembatalan oleh admin di website | Tidak sampai ke POS selama mati. |

### Siapa mengurus apa selama mati

| Urusan | Dikerjakan di | Oleh |
|---|---|---|
| Membuat makanan, mencetak tiket dapur | POS (pesanan yang sudah ada) | Kasir |
| **Menerima pembayaran** dan mencatatnya | **POS** — supaya uang tercatat di laporan & shift | Kasir |
| Status yang dilihat pelanggan (diproses, siap, diantar, selesai) | **Panel admin website** | Admin |
| Pesanan website **baru** | **Panel admin website** — admin meneruskan isi pesanan ke kasir (WA/telepon) | Admin → kasir |
| Membatalkan pesanan | Di **kedua** tempat: admin di panel, kasir di POS ("Batalkan") | Admin + kasir |

**Pesanan baru selama mati** yang dimasak dan dibayar di toko: kasir mencatatnya di POS sebagai
pesanan biasa (kanal admin toko), dengan catatan kode pesanan website (`PL-…`) agar mudah dicocokkan.

> **Aturan penting untuk admin:** sebelum saklar dinyalakan lagi, **semua** pesanan website yang
> diurus selama mati harus sudah berstatus **Selesai** atau **Batal** di panel admin. Setelah
> saklar menyala, panel admin **tidak bisa** lagi mengubah status pesanan POS ("Status dikelola
> dari POS").

---

## B. Saat saklar DINYALAKAN lagi

### Sebelum menyalakan (admin + kasir)

1. **Admin:** pastikan setiap pesanan website yang dibuat atau diurus selama mati sudah
   **Selesai** atau **Batal** di panel admin (lihat aturan penting di atas).
   - Pesanan baru selama mati yang **masih aktif** saat saklar menyala akan masuk ke POS sebagai
     pesanan baru. Kalau kasir sudah mencatatnya manual, transaksinya jadi **ganda** — selesaikan
     atau batalkan dulu di panel.
2. **Kasir:** pastikan semua pembayaran yang diterima selama mati sudah dicatat di POS.

### Langkah Owner

3. Nyalakan dengan nilai **lama** (dari langkah A1):
   `update public.pengaturan_pos set go_live_at = '<nilai lama>' where id = 1;`
4. Kabari kasir dan admin bahwa jembatan menyala lagi.

### Yang terjadi otomatis (dalam ±30 detik)

- POS mengambil lagi data pesanan dari website, dan jembatan berfungsi normal kembali.
- Pesanan yang **dibatalkan admin** selama mati:
  - **belum dibayar** di POS → dibatalkan otomatis di POS ("Dibatalkan di website"). Kalau tiket
    dapur sudah tercetak, slip **BATAL** tercetak otomatis;
  - **sudah dibayar** (di POS atau lunas online) → **tidak** dibatalkan otomatis, muncul peringatan
    untuk kasir (urus pengembalian dana).
- Pesanan yang **diselesaikan admin** selama mati tetap aktif di POS sampai kasir
  menyelesaikannya.
- Pesanan website yang dibuat selama mati dan sudah **Selesai/Batal** di panel hanya dicatat —
  tidak menjadi transaksi baru di POS.

### Merapikan transaksi POS (kasir, dibantu Owner/Supervisor)

Buka menu **Pesanan Web** → tab **Aktif**, lalu periksa satu per satu pesanan yang punya tanda
**"Status … ditolak website: jembatan website tidak aktif"**:

1. **Sudah diantar/diambil & dibayar** → pastikan **Bayar** sudah tercatat, lalu tekan
   **Selesai**. Kalau di website masih belum Selesai, tekan Selesai di POS akan mengirimnya
   sekarang.
2. **Belum dibayar tapi pesanan sudah diterima pelanggan** → terima/catat pembayaran
   (**Bayar**), lalu **Selesai**.
3. **Dibatalkan pelanggan** tapi masih aktif di POS → **Batalkan** di POS (alasan: pelanggan
   batal).
4. **Peringatan "dibatalkan di website, tetapi sudah dibayar"** → Owner/Supervisor memutuskan
   pengembalian dana, lalu membatalkan transaksi di POS bila perlu.
5. **Pesanan ganda** (dicatat manual selama mati **dan** masuk lagi setelah menyala) → batalkan
   salah satunya (alasan: pesanan dobel). Pilih yang **belum dibayar**.
6. Pesanan yang sudah **Selesai di POS** selama mati tetapi di website belum selesai → status di
   website tidak ikut terbarui. Laporkan ke admin/Owner (lihat catatan terakhir).

Setelah selesai, tab **Aktif** hanya berisi pesanan yang memang sedang berjalan.

---

## Yang terlihat di aplikasi kasir

- Selama saklar **mati**, daftar Pesanan Web tetap berisi pesanan lama dan tidak ada pesanan baru.
- Baris status di atas daftar baru berubah merah ("Jembatan dimatikan dari website — kelola
  pesanan aktif di panel admin website.") **setelah** ada status yang ditolak website. Sebelum
  itu masih tertulis "Dicek jam …". Karena itu **langkah A3 (mengabari kasir) wajib**.
- Pada pesanan yang statusnya ditolak, detailnya menampilkan "Status … ditolak website: jembatan
  website tidak aktif".

## Lebih keras dari saklar (jarang dipakai)

Kalau perlu memutus POS sama sekali dari database website, Owner menjalankan di website:
`alter role pos_reader nologin; alter role pos_status_writer nologin;`

Akibatnya:
- Kasir melihat "Gagal cek terakhir: …".
- Sinkron pelanggan ikut gagal.
- Karena `go_live_at` tetap terisi, panel admin **tetap tidak bisa** mengubah status pesanan POS.
- Status yang dikirim kasir **tetap mengantre** dan terkirim sendiri paling lambat ±10 menit
  setelah login dipulihkan (`… login;`).

Untuk keadaan darurat biasa, cukup saklar `go_live_at`.

## Catatan terakhir

- Status yang ditandai **gagal** selama saklar mati tidak dikirim ulang otomatis. Kalau pesanan
  sudah Selesai di POS, status di website tertinggal, dan setelah saklar menyala admin tidak
  bisa mengubahnya dari panel. Karena itu admin harus menuntaskan status di panel **sebelum**
  saklar dinyalakan lagi.
- Rencana perbaikan (menunggu persetujuan Owner): POS mengirim ulang status terakhir otomatis
  saat saklar menyala lagi, dan menampilkan tanda "jembatan mati" segera tanpa menunggu ada
  status yang ditolak.
