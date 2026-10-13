// Pesanan uji produksi (kontrak Bagian 6.4, tahap D): catatan "UJI POS — JANGAN
// DIBUAT" atau akun pelanggan "Uji POS". Dipakai lencana UJI & tiket dapur.
export function isTestOrder(note: string | null | undefined, name?: string | null): boolean {
	return /uji\s*pos/i.test(`${note ?? ''} ${name ?? ''}`);
}
