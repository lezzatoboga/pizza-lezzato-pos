// Kirim data ESC/POS ke aplikasi RawBT di Android lewat skema URL
// "rawbt:base64,<data>". RawBT meneruskannya ke printer Bluetooth.
// RawBT tidak mengabarkan balik apakah kertas benar-benar keluar.
import { toBase64 } from './escpos';

export function isAndroid(): boolean {
	return /android/i.test(navigator.userAgent);
}

export function sendToRawBT(bytes: Uint8Array): void {
	window.location.href = 'rawbt:base64,' + toBase64(bytes);
}
