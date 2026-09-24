// Kop & penutup struk dari Pengaturan → Template struk.
// Dipakai contoh cetak di Pengaturan dan (nanti) struk sungguhan.
import type { ReceiptSettings } from '$lib/pos/data';
import { EscPos, fromBase64 } from './escpos';

export function writeReceiptHeader(doc: EscPos, settings: ReceiptSettings) {
	doc.align('center');
	const hasLogo = !!(settings.logo_data && settings.logo_width && settings.logo_height);
	if (hasLogo) {
		doc.image(settings.logo_width!, settings.logo_height!, fromBase64(settings.logo_data!));
	}
	// Logo sudah memuat nama toko: nama hanya dicetak kalau belum ada logo.
	if (!hasLogo && settings.store_name)
		doc.size(2, 2).bold(true).wrap(settings.store_name, 0, 16).size(1).bold(false);
	if (settings.address) doc.wrap(settings.address);
	if (settings.whatsapp) doc.line(`WA ${settings.whatsapp}`);
	if (settings.website) doc.line(settings.website);
	doc.align('left');
	return doc;
}

export function writeReceiptFooter(doc: EscPos, settings: ReceiptSettings) {
	if (settings.footer) doc.feed(1).align('center').wrap(settings.footer).align('left');
	return doc;
}
