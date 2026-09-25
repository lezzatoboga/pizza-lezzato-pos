# Deploy: hosting web & aplikasi Android

POS berjalan sebagai aplikasi web statis (SvelteKit + adapter-static) yang di-hosting di
Cloudflare Pages. Tablet kasir memakai APK Android (Capacitor) yang **memuat aplikasi dari
hosting** dan menambahkan plugin printer Bluetooth. Perubahan tampilan/logika cukup di-deploy
ke hosting; APK hanya perlu di-build ulang kalau kode native (`android/`) atau izin berubah.

## Cloudflare Pages

Workers & Pages → Create → Pages → Connect to Git → pilih repo `pizza-lezzato-pos`.

| Pengaturan | Nilai |
| --- | --- |
| Project name | `pizza-lezzato-pos` (menjadi `pizza-lezzato-pos.pages.dev`) |
| Production branch | `main` |
| Framework preset | SvelteKit (atau None) |
| Build command | `npm run build` |
| Build output directory | `build` |

Environment variables (Production & Preview):

| Nama | Nilai |
| --- | --- |
| `NODE_VERSION` | `22` |
| `PUBLIC_SUPABASE_URL` | Project URL Supabase POS |
| `PUBLIC_SUPABASE_ANON_KEY` | anon key Supabase POS (kunci publik, sama dengan `.env` lokal) |

Tidak perlu aturan redirect: tanpa `404.html`, Pages otomatis menyajikan `index.html` untuk
semua alamat (mode SPA). Setiap `git push` ke `main` otomatis di-deploy.

Kalau nama project berbeda dari `pizza-lezzato-pos`, ubah alamat default di
`capacitor.config.ts` lalu build ulang APK.

## APK Android

Prasyarat: Android Studio (sudah termasuk Android SDK & JDK). Buat `android/local.properties`
(tidak di-commit) berisi lokasi SDK, mis. `sdk.dir=D\:\\AndroidStudio\\SDK` (backslash wajib ganda).

`npm run android:debug` menjalankan `scripts/android-build.ps1`, yang memakai JDK bawaan Android
Studio dan mengatasi error Gradle "Unable to establish loopback connection" pada akun Windows
yang folder TEMP-nya mengandung spasi. Gradle wrapper memakai 9.1 karena JDK bawaan Android
Studio adalah JDK 25.

```bash
# Salin konfigurasi & aset web ke proyek Android
npm run android:sync

# APK debug (untuk uji) → android/app/build/outputs/apk/debug/app-debug.apk
npm run android:debug
```

Uji tanpa hosting — APK memuat server dev di laptop (tablet & laptop di WiFi yang sama):

```bash
npm run dev -- --host
CAP_SERVER_URL=http://<ip-laptop>:5173 npm run android:sync
npm run android:debug
```

Setelah uji selesai, jalankan `npm run android:sync` lagi (tanpa `CAP_SERVER_URL`) sebelum build
berikutnya supaya APK kembali memuat hosting.

Pasang ke tablet: salin file APK lalu buka dari File Manager (izinkan "Instal dari sumber ini"),
atau lewat kabel USB dengan USB debugging aktif: `adb install -r <file.apk>`.

APK rilis bertanda tangan (keystore) dibuat terpisah; file keystore & password-nya **tidak boleh**
masuk repo (`*.jks`, `*.keystore`, `keystore.properties` sudah di `.gitignore`).
