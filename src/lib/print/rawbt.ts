// Kirim data ESC/POS ke aplikasi RawBT di Android. RawBT meneruskannya ke
// printer Bluetooth, tapi tidak mengabarkan balik apakah kertas keluar.
//
// Dua cara memanggil RawBT dari halaman web:
//   intent : intent:base64,<data>#Intent;scheme=rawbt;package=…;end;
//            Format yang dianjurkan Chrome Android untuk membuka aplikasi lain
//            (skema custom biasa sering diabaikan diam-diam oleh Chrome).
//   scheme : rawbt:base64,<data>  (skema custom; cadangan untuk perbandingan)
import { toBase64 } from './escpos';

export type RawBTMethod = 'intent' | 'scheme';

const RAWBT_PACKAGE = 'ru.a402d.rawbtprinter';

export function isAndroid(): boolean {
	return /android/i.test(navigator.userAgent);
}

export function rawbtUrl(bytes: Uint8Array, method: RawBTMethod = 'intent'): string {
	const data = 'base64,' + toBase64(bytes);
	return method === 'intent'
		? `intent:${data}#Intent;scheme=rawbt;package=${RAWBT_PACKAGE};end;`
		: `rawbt:${data}`;
}

// Mengirim perintah cetak. Hasil: true kalau halaman sempat berpindah ke
// aplikasi lain (RawBT terbuka) dalam beberapa detik — dipakai untuk diagnosis,
// bukan jaminan kertas keluar.
export function sendToRawBT(bytes: Uint8Array, method: RawBTMethod = 'intent'): Promise<boolean> {
	return new Promise((resolve) => {
		let left = false;
		const onLeave = () => {
			left = true;
		};
		const onVisibility = () => {
			if (document.hidden) left = true;
		};
		window.addEventListener('blur', onLeave);
		window.addEventListener('pagehide', onLeave);
		document.addEventListener('visibilitychange', onVisibility);

		window.location.href = rawbtUrl(bytes, method);

		setTimeout(() => {
			window.removeEventListener('blur', onLeave);
			window.removeEventListener('pagehide', onLeave);
			document.removeEventListener('visibilitychange', onVisibility);
			resolve(left);
		}, 3000);
	});
}
