// Penyusun perintah ESC/POS untuk printer thermal 58mm (mis. Iware MP58SB).
// Lebar cetak 384 titik = 32 karakter font A per baris.

export const LINE_WIDTH = 32;

const ESC = 0x1b;
const GS = 0x1d;

// Printer memakai code page ASCII; ganti karakter non-ASCII yang umum.
const REPLACEMENTS: Record<string, string> = {
	'—': '-',
	'–': '-',
	'×': 'x',
	'…': '...',
	'“': '"',
	'”': '"',
	'‘': "'",
	'’': "'",
	'·': '-',
	'•': '*',
	'−': '-'
};

function toAscii(text: string): string {
	return text
		.replace(/[—–×…“”‘’·•−]/g, (c) => REPLACEMENTS[c] ?? '?')
		.normalize('NFKD')
		.replace(/[^\x20-\x7e\n]/g, '');
}

export class EscPos {
	private bytes: number[] = [];

	constructor() {
		this.raw(ESC, 0x40); // inisialisasi printer
	}

	raw(...values: number[]) {
		this.bytes.push(...values);
		return this;
	}

	text(value: string) {
		for (const ch of toAscii(value)) this.bytes.push(ch.charCodeAt(0));
		return this;
	}

	line(value = '') {
		return this.text(value).raw(0x0a);
	}

	align(position: 'left' | 'center' | 'right') {
		return this.raw(ESC, 0x61, position === 'left' ? 0 : position === 'center' ? 1 : 2);
	}

	bold(on: boolean) {
		return this.raw(ESC, 0x45, on ? 1 : 0);
	}

	// Ukuran huruf: 1 = normal, 2 = dua kali lebar & tinggi.
	size(width: 1 | 2, height: 1 | 2 = width) {
		return this.raw(GS, 0x21, ((width - 1) << 4) | (height - 1));
	}

	// Garis pemisah selebar kertas.
	rule(char = '-') {
		return this.line(char.repeat(LINE_WIDTH));
	}

	// Teks kiri & kanan dalam satu baris (mis. nama item + harga).
	pair(left: string, right: string, width = LINE_WIDTH) {
		const l = toAscii(left);
		const r = toAscii(right);
		const space = width - l.length - r.length;
		if (space >= 1) return this.line(l + ' '.repeat(space) + r);
		// Terlalu panjang: kiri di baris sendiri, kanan rata kanan di bawahnya.
		return this.line(l).line(' '.repeat(Math.max(0, width - r.length)) + r);
	}

	// Membungkus teks panjang ke beberapa baris dengan indentasi.
	wrap(value: string, indent = 0, width = LINE_WIDTH) {
		const pad = ' '.repeat(indent);
		const words = toAscii(value).split(/\s+/).filter(Boolean);
		let current = '';
		for (const word of words) {
			if ((pad + current + (current ? ' ' : '') + word).length > width && current) {
				this.line(pad + current);
				current = word;
			} else {
				current += (current ? ' ' : '') + word;
			}
		}
		if (current) this.line(pad + current);
		return this;
	}

	feed(lines = 1) {
		return this.raw(ESC, 0x64, lines);
	}

	// Gambar hitam-putih (raster GS v 0). data: baris-baris bit, MSB = titik kiri,
	// 1 = hitam; lebar dalam titik harus kelipatan 8.
	image(width: number, height: number, data: Uint8Array) {
		const widthBytes = width / 8;
		this.raw(GS, 0x76, 0x30, 0, widthBytes & 0xff, widthBytes >> 8, height & 0xff, height >> 8);
		for (const b of data) this.bytes.push(b);
		return this;
	}

	// Potong kertas (diabaikan printer tanpa pisau, seperti MP58SB).
	cut() {
		return this.feed(3).raw(GS, 0x56, 0x01);
	}

	toBytes(): Uint8Array {
		return Uint8Array.from(this.bytes);
	}
}

export function toBase64(bytes: Uint8Array): string {
	let binary = '';
	for (const b of bytes) binary += String.fromCharCode(b);
	return btoa(binary);
}
