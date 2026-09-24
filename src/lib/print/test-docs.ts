// Dokumen contoh untuk uji printer (Pengaturan → Printer).
// Isi mengikuti draf format tiket dapur & struk yang disepakati.
import { COMPACT_LINE_SPACING, EscPos, LINE_WIDTH } from './escpos';

function stamp(doc: EscPos, label: string) {
	const time = new Date().toLocaleTimeString('id-ID', { hour: '2-digit', minute: '2-digit' });
	doc.align('center').bold(true).line(`*** TES CETAK: ${label} ***`).bold(false).line(time);
	doc.align('left');
}

export function testKitchenTicket(): Uint8Array {
	const doc = new EscPos();
	stamp(doc, 'TIKET DAPUR');
	doc.rule('=');
	doc.pair('PL-260925-0012', '14:32');
	doc.align('center').size(2).bold(true).line('DELIVERY').size(1).bold(false).align('left');
	doc.line('Admin toko - Budi');
	doc.rule();
	doc.size(1, 2).bold(true).line('2x Chicken Supreme').size(1).bold(false);
	doc.line('   MEDIUM');
	doc.line('   + Keju Mozzarella x2');
	doc.line('   "potong 8"');
	doc.size(1, 2).bold(true).line('1x Paket Andalan 2').size(1).bold(false);
	doc.line('   - 1 Medium Pizza');
	doc.line('   - 1 French Fries');
	doc.line('   - 2 Jasmine Tea');
	doc.bold(true).line('   Pilihan Pizza: MEAT LOVERS').bold(false);
	doc.rule();
	doc.wrap('Catatan: bel rusak, telepon dulu sebelum sampai');
	doc.rule('=');
	return doc.cut().toBytes();
}

export function testReceipt(): Uint8Array {
	const doc = new EscPos();
	stamp(doc, 'STRUK');
	doc.align('center').size(2).bold(true).line('PIZZA LEZZATO').size(1).bold(false);
	doc.line('Jl. Lobak 103 A, Pekanbaru');
	doc.line('WA 081378099099');
	doc.line('pizzalezzato.com');
	doc.align('left').rule('=');
	doc.line('PL-260925-0012');
	doc.pair('25/09/26 14:32', 'Kasir: Sari');
	doc.line('Delivery - Budi');
	doc.wrap('Jl. Melati 5 (depan masjid)');
	doc.rule();
	doc.line('2x Chicken Supreme (M)');
	doc.line('   + Keju Mozzarella x2');
	doc.pair('', 'Rp206.000');
	doc.line('1x Paket Andalan 2');
	doc.line('   Pilihan Pizza: Meat Lovers');
	doc.pair('', 'Rp62.000');
	doc.rule();
	doc.pair('Subtotal', 'Rp268.000');
	doc.pair('Diskon (langganan)', '-Rp26.800');
	doc.pair('Ongkir', 'Rp10.000');
	doc.bold(true).pair('TOTAL', 'Rp251.200').bold(false);
	doc.rule();
	doc.pair('Tunai', 'Rp300.000');
	doc.pair('Kembali', 'Rp48.800');
	doc.align('center').size(2).bold(true).line('LUNAS').size(1).bold(false);
	doc.feed(1).line('Pilihan Ibu Bijak,').line('Kesukaan Anak Hebat!');
	return doc.cut().toBytes();
}

// Penggaris 32 karakter + contoh gaya huruf, untuk memastikan lebar & perintah.
export function testWidth(): Uint8Array {
	const doc = new EscPos();
	stamp(doc, 'LEBAR KERTAS');
	doc.line('12345678901234567890123456789012');
	doc.line('|' + '-'.repeat(LINE_WIDTH - 2) + '|');
	doc.bold(true).line('Tebal (bold)').bold(false);
	doc.size(1, 2).line('Tinggi 2x').size(1);
	doc.size(2).line('Besar 2x').size(1);
	doc.align('center').line('Rata tengah').align('right').line('Rata kanan').align('left');
	doc.pair('Kiri', 'Kanan');
	return doc.cut().toBytes();
}

// Blok teks yang sama dicetak dengan beberapa jarak baris untuk dibandingkan
// panjang kertas & keterbacaannya. Ukuran huruf tetap normal.
export function testLineSpacing(): Uint8Array {
	const doc = new EscPos(null);
	stamp(doc, 'JARAK BARIS');
	const sample = (d: EscPos) => {
		d.line('1x Paket Andalan 2');
		d.line('   Pilihan Pizza: Meat Lovers');
		d.pair('Subtotal', 'Rp268.000');
		d.bold(true).pair('TOTAL', 'Rp251.200').bold(false);
	};
	const variants: [string, number | null][] = [
		['A. DEFAULT PRINTER', null],
		['B. 28 titik', 28],
		['C. 26 titik (usulan)', 26],
		['D. 24 titik (paling rapat)', 24]
	];
	for (const [label, dots] of variants) {
		doc.lineSpacing(null).rule('=').bold(true).line(label).bold(false);
		doc.lineSpacing(dots);
		sample(doc);
	}
	// Font kecil (font B) hanya untuk baris kurang penting: pemisah & catatan.
	doc.lineSpacing(null).rule('=').bold(true).line('E. 26 + catatan kecil').bold(false);
	doc.lineSpacing(COMPACT_LINE_SPACING);
	doc.line('1x Paket Andalan 2');
	doc.font('B').line('   Catatan: potong 8, saus dipisah').line('-'.repeat(42)).font('A');
	doc.bold(true).pair('TOTAL', 'Rp251.200').bold(false);
	return doc.lineSpacing(null).cut().toBytes();
}
