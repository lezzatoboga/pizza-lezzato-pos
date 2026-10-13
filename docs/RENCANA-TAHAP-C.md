# Rencana Tahap C — jembatan pesanan website ke produksi (sisi POS)

Status: **rencana, belum dijalankan** (14 Okt 2026). Tahap C = tahap 7 kontrak
(`docs/KONTRAK-DATA-POS.md` Bagian 5): kode POS masuk produksi, login `pos_reader` dan
`pos_status_writer` diaktifkan, uji X1–X2 — **dengan `go_live_at` tetap KOSONG**. Pesanan
website belum masuk ke POS di tahap ini.

Tanda pelaksana: **[Owner]** dijalankan Owner sendiri · **[POS]** dikerjakan sesi POS
(Claude) · **[Website]** sesi website / Owner di project website.

---

## 0. Prasyarat — menunggu sisi website (tahap 3–5 kontrak)

Tahap C baru boleh dimulai bila semua ini **sudah selesai di produksi website**:

| # | Tahap kontrak | Isi | Pelaksana |
|---|---|---|---|
| 0.1 | 3 | `APPLY_KONTRAK_POS_1.sql` dijalankan: schema `pos`, 4 view, `pos_set_order_status`, `pengaturan_pos.go_live_at` = NULL, `customers.updated_at` | [Website] → [Owner] |
| 0.2 | 4 | Kode website yang mengenal 3 status baru, kunci teknis `options`, panel admin sadar go-live — sudah di-deploy | [Website] → [Owner] |
| 0.3 | 5 | `APPLY_KONTRAK_POS_2.sql`: peran & hak akses. **Wajib memuat** `grant execute on function public.pesanan_pos(timestamptz) to pos_reader` (temuan uji paket 13 Okt) | [Website] → [Owner] |
| 0.4 | — | Paket website tiruan di repo POS = versi skema yang dijalankan di produksi (bandingkan `VERSI.txt`). Kalau skema berubah: paket baru → sesi POS mengulang uji tahap B | [Website] / [POS] |

Sesi POS **tidak** menjalankan apa pun di database website.

---

## 1. Urutan kerja tahap C

Urutan ini penting: aplikasi kasir (Cloudflare Pages) langsung ter-deploy begitu `main`
di-push, dan halaman Transaksi versi baru membaca tabel `web_orders`. Karena itu **migrasi
database harus masuk lebih dulu** daripada `git push`.

| Langkah | Apa | Pelaksana |
|---|---|---|
| C1 | **Pra-cek baca-saja di Supabase POS** (SQL Editor): `select order_status, count(*) from transactions group by 1;` — tidak boleh ada nilai `siap` (migrasi mengganti daftar status). `select customers_paused from sync_settings;` → `true`. | [Owner] |
| C2 | **Merge** branch `jembatan-pesanan-web` ke `main` di laptop (fast-forward, tanpa push). | [POS] |
| C3 | **Cek & push migrasi POS:** `npx supabase migration list` → harus tersisa 3 migrasi baru: `20261014000001_web_orders`, `20261014000002_customer_sync_incremental`, `20261014000003_web_bridge_golive_resend`. Lalu `npx supabase db push --dry-run`, kemudian `npx supabase db push`. Aman untuk aplikasi lama: hanya menambah tabel/kolom/fungsi; sinkron pelanggan masih dijeda. | [Owner] |
| C4 | **Deploy Edge Function:** `npx supabase functions deploy web-orders-sync web-order-edit sync-customers`. Sebelum secret baru dipasang, fungsi ini hanya menjawab "belum dikonfigurasi"; `sync-customers` tidak jalan selama dijeda. | [Owner] |
| C5 | **`git push` main** → Cloudflare Pages men-deploy aplikasi kasir. APK **tidak** perlu dibuat ulang (tidak ada perubahan kode Android). | [Owner] |
| C6 | **Aktifkan login kedua peran** di database website (tahap 7 kontrak), kata sandi dari password manager: `alter role pos_reader login password '…';` dan `alter role pos_status_writer login password '…';`. `go_live_at` **tetap NULL**. | [Owner] |
| C7 | **Pasang secret baru di Supabase POS** — sebaiknya lewat Dashboard (Edge Functions → Secrets), supaya kata sandi tidak tersimpan di riwayat terminal: `WEBSITE_POS_READER_DB_URL` dan `WEBSITE_POS_STATUS_DB_URL`. Formatnya **pooler mode transaksi**: `postgresql://<peran>.<ref-project-website>:<kata-sandi>@<host-pooler>:6543/postgres`. `WEBSITE_DB_SSL` **tidak** dipasang (TLS wajib = bawaan). | [Owner] |
| C8 | **Uji X1–X2** (lihat bagian 2): Pengaturan → Sinkron → Cek koneksi website. | [Owner] menekan tombol / [POS] membaca hasil |
| C9 | **Lanjutkan sinkron pelanggan:** Pengaturan → Sinkron → Aktifkan. Run pertama = rekonsiliasi penuh lewat `v_pelanggan`. Cek: jumlah pelanggan tersinkron ≈ jumlah pelanggan website; indikator bilah atas tidak lagi "Pelanggan dijeda". | [Owner] (di aplikasi) |
| C10 | **Jadwal cron 30 detik** untuk `web-orders-sync`: migrasi kecil `…_web_orders_sync_schedule.sql` (pola sama dengan jadwal menu, memakai Vault `project_url` & `sync_menu_cron_secret` yang sudah ada). Dibuat [POS] setelah C8 lolos, di-push [Owner]. Ini sekaligus membuktikan X3 (penjadwal) lebih awal — `last_run_at` di `web_bridge_state` bergerak tiap 30 detik. | [POS] tulis → [Owner] `db push` |
| C11 | **Hapus secret lama** `WEBSITE_CUSTOMERS_DB_URL` — setelah C9 sukses minimal satu hari (termasuk satu rekonsiliasi harian). | [Owner] |
| C12 | **Tahap 8 kontrak:** cabut akses lama `pos_reader` ke `public.customers` (6 kolom, policy, usage `public`). Setelahnya cek sinkron pelanggan masih sukses. | [Website] → [Owner] |

Pembalikan bila ada masalah:
- **Aplikasi kasir:** rollback deployment di Cloudflare Pages ke versi sebelumnya.
- **Jembatan:** hapus kedua secret baru (fungsi kembali "belum dikonfigurasi"), atau
  `alter role … nologin` di website.
- **Pelanggan:** tombol Jeda di Pengaturan → Sinkron.
- **Migrasi POS:** hanya menambah, jadi tidak perlu dibalik.

---

## 2. Uji X1–X2 (produksi, aman)

Selama `go_live_at` NULL, fungsi website menolak **sebelum menulis apa pun**, dan semua bacaan
bersifat baca-saja.

| # | Uji | Cara | Harapan |
|---|---|---|---|
| X1a | `pos_reader` lewat pooler (TLS, mode transaksi, tanpa prepared statement) | "Cek pesanan" di menu Pesanan Web | Sukses; "Jembatan website belum aktif (go-live belum diisi di website)" |
| X1b | `v_pelanggan` terbaca | C9 (sinkron pelanggan) | Sukses, jumlah wajar |
| X1c | `v_pesanan`, `v_item_pesanan`, `v_pengaturan_ongkir` terbaca; sesi read-only; tabel dasar `public.orders` dan fungsi status **ditolak** untuk `pos_reader` | mode cek | terbaca / ditolak |
| X2a | `pos_status_writer` → uuid acak | mode cek | `pesanan_tidak_ada` |
| X2b | `pos_status_writer` → status asing | mode cek | `status_tidak_dikenal` |
| X2c | `pos_status_writer` → SELECT view | mode cek | ditolak |

**Mode cek** (disetujui Owner 14 Okt, sudah dibuat): **Pengaturan → Sinkron → Cek koneksi
website**. Hanya Owner — diperiksa di server (peran Owner, akun aktif); pengguna lain dan cron
ditolak 403. Isinya hanya pembacaan dan panggilan yang pasti ditolak website (id acak, status
asing): tidak menulis apa pun di website maupun di POS, tidak memakai lease sinkron. Hasilnya
10 baris lulus/gagal di layar. Kata sandi tidak perlu diketik di terminal.

Uji "pesanan lama sebelum go-live" (`sebelum_go_live`) **tidak** dijalankan di produksi
(keputusan bersama sesi website) — jalur itu sudah terbukti di paket website tiruan (tahap B).

---

## 3. Yang terlihat di aplikasi kasir selama `go_live_at` masih kosong

- **Menu baru "Pesanan Web"** untuk semua pengguna yang login, isinya kosong, dengan keterangan:
  - sebelum secret dipasang (C5–C7): "Belum pernah dicek". Kalau tombol "Cek pesanan" ditekan,
    keterangan menjadi "Gagal cek terakhir: Jembatan website belum dikonfigurasi…" — wajar,
    tidak perlu ditindaklanjuti kasir;
  - setelah C7: **"Jembatan website belum aktif (go-live belum diisi di website)."**
- Tidak ada bunyi, banner merah, atau lencana angka (karena tidak ada pesanan website).
- **Kasir tidak perlu berbuat apa pun.** Pesanan website tetap diurus admin di panel admin
  website seperti sekarang.
- Transaksi biasa (admin toko, marketplace), struk, dan tiket dapur **tidak berubah**. Tiket dapur
  sudah mencetak tipe pesanan besar untuk semua kanal.
- Bilah atas: setelah C9, "Pelanggan dijeda" hilang dan pencarian pelanggan memakai data website
  terbaru.
- Halaman Transaksi: tidak ada perubahan yang terlihat. Lencana "Lunas online · belum tercatat di
  POS" baru muncul kalau kelak ada pesanan website lunas online.

---

## 4. Sebelum tahap D (uji produksi terbatas X3–X5) — catatan untuk keputusan Owner

1. **Lencana UJI** — kontrak Bagian 6.4 langkah 4: pesanan bercatatan "UJI POS — JANGAN DIBUAT"
   (atau akun "Uji POS") diberi lencana **UJI** di Pesanan Web, dan tiket dapur mencetak
   **PESANAN UJI / JANGAN DIBUAT**. **Sudah dibuat** (14 Okt).
2. **Perbaikan dari SOP saklar** — **sudah dibuat** (14 Okt), lihat
   `docs/SOP-SAKLAR-GO-LIVE.md`: banner merah "jembatan mati" langsung muncul; status terakhir
   dikirim ulang otomatis sekali saat saklar menyala lagi (hanya maju); yang ditolak masuk daftar
   Owner di Pengaturan → Sinkron.
3. **Pencatatan pembayaran online otomatis** — backlog Proyek B, tidak menghalangi go-live
   selama pembayaran online belum aktif.
