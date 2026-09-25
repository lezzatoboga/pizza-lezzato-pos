import type { CapacitorConfig } from '@capacitor/cli';

// APK = "cangkang" yang memuat aplikasi dari hosting (Cloudflare Pages), jadi
// perubahan tampilan cukup di-deploy ke hosting tanpa build APK ulang.
// APK perlu di-build ulang hanya kalau plugin native / izin Android berubah.
//
// CAP_SERVER_URL mengganti alamat yang dimuat saat `npx cap sync`, mis. untuk
// uji dengan server dev di laptop:  CAP_SERVER_URL=http://192.168.1.10:5173
const serverUrl = process.env.CAP_SERVER_URL ?? 'https://pizza-lezzato-pos.pages.dev';

const config: CapacitorConfig = {
	appId: 'com.pizzalezzato.pos',
	appName: 'Pizza Lezzato POS',
	// Dipakai hanya sebagai cadangan; halaman utama dimuat dari serverUrl.
	webDir: 'build',
	server: {
		url: serverUrl,
		// Izinkan http:// hanya untuk uji server dev lokal.
		cleartext: serverUrl.startsWith('http://')
	}
};

export default config;
