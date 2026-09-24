// Konversi logo ke gambar hitam-putih untuk printer thermal 58mm.
// Alur: RGBA → abu-abu (transparan dianggap putih) → potong area kosong
// (bounding box) → perkecil agar muat maks. lebar × tinggi → ambang batas
// atau dithering → dikemas 1 bit/titik (format raster ESC/POS GS v 0).
// Semua fungsi murni (tanpa canvas) supaya hasilnya sama di mana pun.

export const MAX_LOGO_WIDTH = 384; // lebar cetak penuh kertas 58mm
export const MAX_LOGO_HEIGHT = 240;

export type Gray = { width: number; height: number; data: Float32Array }; // 0 hitam … 255 putih

export type LogoOptions = {
	maxWidth: number; // titik, maks. 384
	maxHeight: number; // titik
	mode: 'threshold' | 'dither';
	threshold: number; // 0–255; lebih tinggi = lebih banyak hitam
};

export const DEFAULT_LOGO_OPTIONS: LogoOptions = {
	maxWidth: 256,
	maxHeight: 160,
	mode: 'threshold',
	threshold: 160
};

export type MonoImage = {
	width: number; // kelipatan 8
	height: number;
	bits: Uint8Array; // 1 byte per titik: 1 = hitam
};

export function toGray(rgba: Uint8ClampedArray | Uint8Array, width: number, height: number): Gray {
	const data = new Float32Array(width * height);
	for (let i = 0; i < width * height; i++) {
		const a = rgba[i * 4 + 3] / 255;
		const lum = 0.299 * rgba[i * 4] + 0.587 * rgba[i * 4 + 1] + 0.114 * rgba[i * 4 + 2];
		data[i] = lum * a + 255 * (1 - a);
	}
	return { width, height, data };
}

// Kotak terkecil yang memuat semua titik tidak-putih (+ sedikit jarak).
export function contentBox(gray: Gray, whiteLevel = 240, padding = 2) {
	let minX = gray.width,
		minY = gray.height,
		maxX = -1,
		maxY = -1;
	for (let y = 0; y < gray.height; y++) {
		for (let x = 0; x < gray.width; x++) {
			if (gray.data[y * gray.width + x] < whiteLevel) {
				if (x < minX) minX = x;
				if (x > maxX) maxX = x;
				if (y < minY) minY = y;
				if (y > maxY) maxY = y;
			}
		}
	}
	if (maxX < 0) return { x: 0, y: 0, width: gray.width, height: gray.height }; // gambar kosong
	const x = Math.max(0, minX - padding);
	const y = Math.max(0, minY - padding);
	return {
		x,
		y,
		width: Math.min(gray.width, maxX + padding + 1) - x,
		height: Math.min(gray.height, maxY + padding + 1) - y
	};
}

// Perkecil dengan rata-rata area (hasil halus tanpa bergantung canvas).
function resizeArea(
	gray: Gray,
	box: { x: number; y: number; width: number; height: number },
	outW: number,
	outH: number
): Gray {
	const out = new Float32Array(outW * outH);
	const sx = box.width / outW;
	const sy = box.height / outH;
	for (let oy = 0; oy < outH; oy++) {
		const y0 = box.y + oy * sy;
		const y1 = y0 + sy;
		for (let ox = 0; ox < outW; ox++) {
			const x0 = box.x + ox * sx;
			const x1 = x0 + sx;
			let sum = 0;
			let weight = 0;
			for (let y = Math.floor(y0); y < Math.ceil(y1); y++) {
				const wy = Math.min(y + 1, y1) - Math.max(y, y0);
				for (let x = Math.floor(x0); x < Math.ceil(x1); x++) {
					const w = (Math.min(x + 1, x1) - Math.max(x, x0)) * wy;
					sum += gray.data[y * gray.width + x] * w;
					weight += w;
				}
			}
			out[oy * outW + ox] = weight ? sum / weight : 255;
		}
	}
	return { width: outW, height: outH, data: out };
}

export function convertLogo(gray: Gray, options: LogoOptions): MonoImage {
	const maxW = Math.min(options.maxWidth, MAX_LOGO_WIDTH);
	const maxH = Math.min(options.maxHeight, MAX_LOGO_HEIGHT);
	const box = contentBox(gray);

	// Muat dalam maxW × maxH, jaga proporsi; tidak diperbesar.
	const scale = Math.min(maxW / box.width, maxH / box.height, 1);
	const w = Math.max(1, Math.round(box.width * scale));
	const h = Math.max(1, Math.round(box.height * scale));
	const small = resizeArea(gray, box, w, h);

	// Lebar raster harus kelipatan 8: tambahkan putih di kiri-kanan (logo tetap di tengah).
	const width = Math.ceil(w / 8) * 8;
	const offset = Math.floor((width - w) / 2);
	const bits = new Uint8Array(width * h);

	if (options.mode === 'threshold') {
		for (let y = 0; y < h; y++)
			for (let x = 0; x < w; x++)
				bits[y * width + x + offset] = small.data[y * w + x] < options.threshold ? 1 : 0;
	} else {
		// Floyd–Steinberg; titik ambang tetap bisa digeser.
		const buf = Float32Array.from(small.data);
		for (let y = 0; y < h; y++) {
			for (let x = 0; x < w; x++) {
				const i = y * w + x;
				const black = buf[i] < options.threshold;
				bits[y * width + x + offset] = black ? 1 : 0;
				const err = buf[i] - (black ? 0 : 255);
				if (x + 1 < w) buf[i + 1] += (err * 7) / 16;
				if (y + 1 < h) {
					if (x > 0) buf[i + w - 1] += (err * 3) / 16;
					buf[i + w] += (err * 5) / 16;
					if (x + 1 < w) buf[i + w + 1] += err / 16;
				}
			}
		}
	}

	return { width, height: h, bits };
}

// 8 titik per byte, bit paling kiri = MSB (sesuai GS v 0).
export function packBits(image: MonoImage): Uint8Array {
	const rowBytes = image.width / 8;
	const out = new Uint8Array(rowBytes * image.height);
	for (let y = 0; y < image.height; y++)
		for (let x = 0; x < image.width; x++)
			if (image.bits[y * image.width + x]) out[y * rowBytes + (x >> 3)] |= 0x80 >> (x & 7);
	return out;
}

export function unpackBits(width: number, height: number, packed: Uint8Array): MonoImage {
	const rowBytes = width / 8;
	const bits = new Uint8Array(width * height);
	for (let y = 0; y < height; y++)
		for (let x = 0; x < width; x++)
			bits[y * width + x] = packed[y * rowBytes + (x >> 3)] & (0x80 >> (x & 7)) ? 1 : 0;
	return { width, height, bits };
}
