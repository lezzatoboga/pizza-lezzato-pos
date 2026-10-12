# Uji perangkat: tablet Android + 2 printer MP58SB

Daftar uji langkah demi langkah saat memegang tablet kasir dan dua printer thermal 58mm
Iware MP58SB (satu untuk dapur, satu untuk kasir). Isi kolom **Hasil** dengan ✅ (lolos) atau
❌ (gagal), dan tulis catatan singkat bila perlu.

Tanggal uji: ____________ Penguji: ____________ Tablet (merek/tipe, versi Android): ____________

> Data yang dibuat selama uji ikut masuk laporan penjualan. Setelah selesai, batalkan (void)
> transaksi uji dari akun Owner — transaksi batal tidak dihitung di laporan.

## Kalau ada yang gagal, laporkan

1. **Nomor langkah** (mis. 3.4) dan **akun/role** yang dipakai.
2. **Pesan di layar**, persis — paling mudah lewat tangkapan layar.
3. **Apa yang keluar dari printer** — foto kertasnya (termasuk kalau terpotong, kosong, atau
   hurufnya berantakan).
4. Untuk masalah cetak: printer mana (dapur/kasir), nyala/mati, jarak dari tablet, dan apakah
   langsung dicoba ulang berhasil.
5. Untuk masalah alur: nomor transaksi (PL-…), jam kejadian.

Jangan kirim PIN atau password apa pun dalam laporan.

---

## 1. Persiapan

### 1.1 Pasang APK debug

File APK debug (sudah di-build, memuat aplikasi dari `pizza-lezzato-pos.pages.dev`):

- `apk/pizza-lezzato-pos-debug.apk` (salinan siap pakai), atau
- `android/app/build/outputs/apk/debug/app-debug.apk` (hasil build terakhir).

APK hanya perlu di-build ulang kalau kode native (`android/`) berubah; perubahan tampilan &
logika cukup lewat hosting. Cara build ada di `docs/deploy.md`.

**Cara A — salin file**

1. Salin APK ke tablet (kabel USB → mode Transfer file, Google Drive, atau WhatsApp ke diri
   sendiri sebagai dokumen).
2. Buka file APK dari aplikasi **File/Files** di tablet.
3. Bila diminta, izinkan **"Instal aplikasi dari sumber ini"** untuk aplikasi File tersebut, lalu
   **Instal**.

**Cara B — lewat USB (adb)**

1. Di tablet: Setelan → Tentang tablet → ketuk **Nomor build** 7× → kembali → **Opsi developer**
   → aktifkan **USB debugging**.
2. Sambungkan kabel USB, di tablet pilih **Izinkan** untuk komputer ini.
3. Di laptop:

```bash
D:/AndroidStudio/SDK/platform-tools/adb.exe devices
```

```bash
D:/AndroidStudio/SDK/platform-tools/adb.exe install -r apk/pizza-lezzato-pos-debug.apk
```

| No  | Langkah                                         | Yang diharapkan                                                | Hasil | Catatan |
| --- | ----------------------------------------------- | -------------------------------------------------------------- | ----- | ------- |
| 1.1 | Pasang APK, buka aplikasi **Pizza Lezzato POS** | Layar login (pilih nama → PIN) tampil, orientasi mendatar      |       |         |
| 1.2 | Login sebagai Owner                             | Masuk ke layar Kasir; menu atas: Kasir, Transaksi, Shift, dst. |       |         |
| 1.3 | Biarkan tablet diam ±2 menit                    | Layar tidak mati sendiri selama aplikasi terbuka               |       |         |

### 1.2 Izin Bluetooth & pairing printer

1. Nyalakan kedua printer (isi kertas). Beri tanda fisik pada printer, mis. stiker **DAPUR** dan
   **KASIR**.
2. Tablet: Setelan → **Bluetooth** → nyalakan → **Pasangkan perangkat baru**.
3. Pilih printer (biasanya bernama `MP58…`, `BlueTooth Printer`, atau mirip). Bila diminta PIN
   pairing, coba **0000** lalu **1234**.
4. Ulangi untuk printer kedua. Catat nama/alamat masing-masing:
   - Printer DAPUR: ______________________
   - Printer KASIR: ______________________

| No  | Langkah                                                                                | Yang diharapkan                                                                 | Hasil | Catatan |
| --- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ----- | ------- |
| 1.4 | Pairing kedua printer di Setelan Bluetooth                                             | Keduanya muncul di "Perangkat tersambung/tersimpan"                             |       |         |
| 1.5 | Aplikasi → **Pengaturan → Printer**                                                    | Muncul permintaan izin **Perangkat di sekitar / Bluetooth** → pilih **Izinkan** |       |         |
| 1.6 | Ketuk **Muat ulang daftar printer**                                                    | Kedua printer tampil sebagai pilihan                                            |       |         |
| 1.7 | Di **Printer dapur** pilih printer DAPUR; di **Printer kasir** pilih printer KASIR     | Nama printer tampil di samping judul masing-masing (bukan "belum dipilih")      |       |         |
| 1.8 | Tutup aplikasi sepenuhnya (geser dari daftar aplikasi terbaru), buka lagi, cek Printer | Pilihan printer masih tersimpan                                                 |       |         |

Kalau izin pernah ditolak: Setelan → Aplikasi → Pizza Lezzato POS → Izin → **Perangkat di
sekitar** → Izinkan.

---

## 2. Tes printer (Pengaturan → Printer → Uji cetak)

| No  | Langkah                                            | Yang diharapkan                                                                                   | Hasil | Catatan |
| --- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ----- | ------- |
| 2.1 | **Tes tiket → dapur**                              | Kertas keluar di printer **DAPUR**                                                                |       |         |
| 2.2 | **Tes struk → kasir**                              | Kertas keluar di printer **KASIR**                                                                |       |         |
| 2.3 | Ketuk 2.1 lalu langsung 2.2 (berurutan cepat)      | Keduanya tercetak, tidak ada yang hilang                                                          |       |         |
| 2.4 | **Tes lebar kertas**                               | Baris angka 1–32 muat satu baris tanpa terpotong; huruf tebal, tinggi 2×, besar 2× tampil berbeda |       |         |
| 2.5 | **Tes jarak baris**                                | Lima blok A–E tercetak                                                                            |       |         |
| 2.6 | Matikan printer KASIR, ketuk **Tes struk → kasir** | Pesan gagal yang jelas di layar (aplikasi tidak macet); nyalakan lagi → tes ulang berhasil        |       |         |
| 2.7 | Catat waktu cetak yang tertulis di status (detik)  | Dapur: ____ dtk Kasir: ____ dtk                                                                   |       |         |

**2.5 — Pilihan jarak baris** (lingkari yang paling rapat tapi masih nyaman dibaca):

| Blok | Jarak                       | Pilihan |
| ---- | --------------------------- | ------- |
| A    | Default printer             |         |
| B    | 28 titik                    |         |
| C    | 26 titik (dipakai sekarang) |         |
| D    | 24 titik (paling rapat)     |         |

Blok **E** (26 titik + catatan huruf kecil): apakah catatan huruf kecilnya masih terbaca?
Ya / Tidak

### 2.8 Contoh struk dengan logo (Pengaturan → Template struk)

| No    | Langkah                                                                                    | Yang diharapkan                                                                                     | Hasil | Catatan |
| ----- | ------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------- | ----- | ------- |
| 2.8.1 | Pastikan logo sudah diupload (pratinjau logo tampil)                                       | Pratinjau hitam-putih logo terlihat jelas                                                           |       |         |
| 2.8.2 | **Cetak contoh struk**                                                                     | Struk contoh keluar di printer KASIR dengan logo di atas; nama toko tidak dicetak ulang di bawahnya |       |         |
| 2.8.3 | Bandingkan logo tercetak dengan pratinjau                                                  | Logo tajam, tidak terpotong, tidak terlalu gelap/pucat                                              |       |         |
| 2.8.4 | (Bila logo kurang jelas) coba **Ambang batas** lain atau **Dithering**, simpan, cetak lagi | Catat pengaturan yang paling bagus: ____________                                                    |       |         |

---

## 3. Alur transaksi

Pastikan shift sudah dibuka (menu **Shift** → Buka shift). Pakai akun Kasir untuk langkah 3.x
kecuali disebut lain.

| No   | Langkah                                                                        | Yang diharapkan                                                                                                                    | Hasil | Catatan |
| ---- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- | ----- | ------- |
| 3.1  | Kasir: dine-in, 1 pizza + extra topping + 1 minuman, catatan item → **Simpan** | Tiket dapur otomatis keluar di printer DAPUR: nomor transaksi, tipe, item, varian, topping, catatan, **tanpa harga**               |       |         |
| 3.2  | Buka **Transaksi**, transaksi 3.1 → **Bayar** (tunai, uang lebih)              | Layar LUNAS + kembalian benar                                                                                                      |       |         |
| 3.3  | Di layar LUNAS → **Cetak struk (Lunas)**                                       | Struk keluar di printer KASIR: logo, item + harga, TOTAL, **LUNAS**, kembalian, penutup                                            |       |         |
| 3.4  | Transaksi 3.1 di daftar                                                        | Chip **Terkunci** tampil; tombol struk jadi "Struk Lunas (ulang)"                                                                  |       |         |
| 3.5  | **Struk Lunas (ulang)**                                                        | Struk keluar dengan tanda **\*\*\* CETAK ULANG \*\*\***                                                                            |       |         |
| 3.6  | **Tiket ulang** (tiket dapur)                                                  | Tiket keluar di DAPUR dengan tanda **\*\*\* CETAK ULANG \*\*\***                                                                   |       |         |
| 3.7  | COD: take away, 2 item → **Simpan** (tidak dibayar)                            | Tiket dapur keluar; transaksi tampil "Belum bayar"                                                                                 |       |         |
| 3.8  | Transaksi 3.7 → **Struk Belum Lunas**                                          | Struk keluar dengan tulisan besar **BELUM LUNAS**; transaksi jadi **Terkunci**                                                     |       |         |
| 3.9  | Transaksi 3.7 → **Bayar** (mis. QRIS), lalu cetak struk lunas                  | Pembayaran tersimpan; struk keluar dengan **LUNAS**. Catat apakah tanda **CETAK ULANG** ikut tercetak: Ya / Tidak                  |       |         |
| 3.10 | Marketplace (mis. GoFood): isi kode pesanan → **Simpan**                       | Tiket dapur menampilkan nama platform dan kode pesanan besar; harga di layar sudah termasuk markup                                 |       |         |
| 3.11 | Simpan transaksi saat printer DAPUR mati                                       | Transaksi tetap tersimpan, muncul pesan "tiket dapur belum tercetak …"; nyalakan printer → **Tiket dapur** dari Transaksi berhasil |       |         |

---

## 4. Pembatalan (void)

| No  | Langkah                                                                                                      | Yang diharapkan                                                                                                | Hasil | Catatan |
| --- | ------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------- | ----- | ------- |
| 4.1 | Kasir: buat transaksi baru (tiket dapur keluar), **belum** cetak struk → **Batalkan** → alasan "Salah input" | Langsung dibatalkan tanpa PIN; **slip BATAL** otomatis keluar di printer DAPUR (nomor transaksi + alasan)      |       |         |
| 4.2 | Bila transaksi 4.1 sudah dibayar tunai                                                                       | Layar menyebut uang tunai yang harus dikembalikan ke pelanggan                                                 |       |         |
| 4.3 | Kasir: transaksi **Terkunci** (mis. 3.1) → **Batalkan** → alasan                                             | Muncul langkah persetujuan: pilih penyetuju (Owner) + PIN                                                      |       |         |
| 4.4 | Masukkan PIN Owner **salah**                                                                                 | Ditolak dengan sisa percobaan; transaksi belum batal                                                           |       |         |
| 4.5 | Masukkan PIN Owner **benar**                                                                                 | Dibatalkan; slip BATAL keluar di DAPUR; info refund tampil; di daftar tercatat alasan, jam, dan nama penyetuju |       |         |
| 4.6 | Alasan "Lainnya" tanpa keterangan                                                                            | Tombol batalkan tidak bisa ditekan sampai keterangan diisi                                                     |       |         |
| 4.7 | Transaksi yang **belum** pernah dicetak tiket dapurnya → batalkan                                            | Tidak ada slip BATAL (karena dapur belum menerima tiket)                                                       |       |         |

---

## 5. Delivery

| No  | Langkah                                                                                   | Yang diharapkan                                                                                                              | Hasil | Catatan |
| --- | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ----- | ------- |
| 5.1 | Admin toko → Delivery tanpa pelanggan/alamat → Simpan                                     | Ditolak: pelanggan & alamat wajib                                                                                            |       |         |
| 5.2 | Isi pelanggan, alamat, patokan; ongkir mode **manual** (mis. 10.000)                      | Ongkir tampil terpisah; total = item − diskon + ongkir                                                                       |       |         |
| 5.3 | Ganti ke mode **hitung jarak**, isi mis. 3,7 km                                           | Ongkir = jarak × tarif per km, dibulatkan ke atas per Rp1.000                                                                |       |         |
| 5.4 | Simpan **tanpa memilih kurir**                                                            | Sebelum simpan, tombol **Bayar** tidak aktif ("Pilih kurir untuk bayar sekarang"); **Simpan** tetap bisa, tiket dapur keluar |       |         |
| 5.5 | Di Transaksi → cetak struk transaksi 5.4 sebelum ada kurir                                | Diminta menentukan kurir dulu; struk tidak tercetak                                                                          |       |         |
| 5.6 | Pilih kurir (karyawan / freelance / Shopee Express / Maxim) → cetak **Struk Belum Lunas** | Struk berisi nama kurir, alamat, ongkir, BELUM LUNAS                                                                         |       |         |
| 5.7 | Saat kurir kembali → **Bayar** → cetak struk lunas                                        | Pembayaran tersimpan; struk LUNAS                                                                                            |       |         |
| 5.8 | Coba ganti kurir setelah lunas                                                            | Tidak bisa (kurir terkunci setelah pembayaran)                                                                               |       |         |

---

## 6. Penutup uji

| No  | Langkah                                          | Yang diharapkan                                                        | Hasil | Catatan |
| --- | ------------------------------------------------ | ---------------------------------------------------------------------- | ----- | ------- |
| 6.1 | Owner: batalkan semua transaksi uji yang tersisa | Semua transaksi uji berstatus batal                                    |       |         |
| 6.2 | Laporan → Ringkasan hari ini                     | Transaksi uji tidak dihitung di penjualan (muncul di "Dibatalkan")     |       |         |
| 6.3 | Shift → hitung uang → tutup shift (bila perlu)   | Kas seharusnya sesuai (refund tunai sudah tercatat sebagai kas keluar) |       |         |

Ringkasan untuk dilaporkan: jarak baris terpilih (2.5) ______, pengaturan logo (2.8.4) ______,
waktu cetak (2.7) ______, jawaban 3.9 (CETAK ULANG pada struk lunas setelah Belum Lunas) ______,
dan semua langkah ❌.

---

## 7. Setelah semua lolos: APK rilis bertanda tangan

APK rilis memakai **keystore** milik Pizza Lezzato. Keystore & password-nya **tidak boleh** masuk
repo atau dikirim ke chat, dan **wajib dicadangkan** (mis. flashdisk + penyimpanan cloud pribadi).
Kalau keystore hilang, aplikasi yang terpasang tidak bisa di-update — harus dihapus & dipasang
ulang.

Saat ini `android/app/build.gradle` belum punya konfigurasi tanda tangan, jadi APK rilis
ditandatangani manual dengan `apksigner` (langkah 7.3). Bila nanti ingin otomatis lewat
`keystore.properties`, itu perubahan kode kecil yang bisa dikerjakan terpisah.

### 7.1 Buat keystore (sekali saja — Owner)

Simpan di luar folder repo, mis. `D:\Lezzato\keystore\`:

```bash
"C:/Program Files/Android/Android Studio/jbr/bin/keytool.exe" -genkeypair -v -keystore D:/Lezzato/keystore/pizza-lezzato-pos.jks -alias pizzalezzato -keyalg RSA -keysize 2048 -validity 10000
```

Isi password (minimal 6 karakter, catat di tempat aman) dan data pemilik saat diminta.

### 7.2 Build APK rilis (belum bertanda tangan)

Pastikan APK memuat hosting (bukan server dev):

```bash
npm run android:sync
```

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/android-build.ps1 -Release
```

Hasil: `android/app/build/outputs/apk/release/app-release-unsigned.apk`.

### 7.3 Rapikan & tanda tangani (Owner — memakai keystore)

```bash
D:/AndroidStudio/SDK/build-tools/36.0.0/zipalign.exe -p -f 4 android/app/build/outputs/apk/release/app-release-unsigned.apk apk/pizza-lezzato-pos-aligned.apk
```

```bash
D:/AndroidStudio/SDK/build-tools/36.0.0/apksigner.bat sign --ks D:/Lezzato/keystore/pizza-lezzato-pos.jks --ks-key-alias pizzalezzato --out apk/pizza-lezzato-pos-1.0.apk apk/pizza-lezzato-pos-aligned.apk
```

```bash
D:/AndroidStudio/SDK/build-tools/36.0.0/apksigner.bat verify --print-certs apk/pizza-lezzato-pos-1.0.apk
```

Folder `apk/` dan file `*.apk` tidak ikut ke git.

### 7.4 Pasang di tablet

APK debug dan rilis ditandatangani berbeda, jadi **hapus dulu** aplikasi debug:

1. Tablet: tahan ikon Pizza Lezzato POS → **Uninstal** (atau
   `adb uninstall com.pizzalezzato.pos`).
2. Pasang `apk/pizza-lezzato-pos-1.0.apk` (cara 1.1).
3. Setelah dipasang ulang: login lagi, beri izin Bluetooth, dan **pilih ulang printer dapur &
   kasir** (pilihan printer tersimpan di aplikasi, ikut terhapus saat uninstal). Ulangi cepat
   langkah 2.1–2.2.

Untuk update berikutnya, naikkan `versionCode` (dan `versionName`) di
`android/app/build.gradle`, build & tanda tangani dengan **keystore yang sama**; tablet cukup
memasang APK baru tanpa uninstal.
