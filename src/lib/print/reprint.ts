// Kapan struk diberi tanda "CETAK ULANG" (keputusan Owner 2026-10-12):
// hanya kalau struk dengan STATUS YANG SAMA sudah pernah dicetak.
//   Belum Lunas → Belum Lunas : cetak ulang
//   Belum Lunas → Lunas       : BUKAN cetak ulang (dokumen status berbeda)
//   Lunas → Lunas             : cetak ulang
// receipt_printed_status = status struk terakhir yang dicetak. Status tidak
// bisa kembali dari Lunas ke Belum Lunas, jadi "terakhir sama" berarti
// "sudah pernah dicetak dengan status ini". Kalau nanti ada pembatalan
// pembayaran/refund (Lunas → Belum Lunas), aturan ini perlu ditinjau ulang
// (lihat migrasi 20261012000006). Tiket dapur tetap memakai hitungan cetaknya.

export type ReceiptPrintedStatus = 'belum_lunas' | 'lunas' | null;

export function isReceiptReprint(data: {
	receipt_print_count: number;
	receipt_printed_status: ReceiptPrintedStatus;
	payment_status: 'paid' | 'unpaid';
}): boolean {
	if (data.receipt_print_count <= 0 || !data.receipt_printed_status) return false;
	const current = data.payment_status === 'paid' ? 'lunas' : 'belum_lunas';
	return data.receipt_printed_status === current;
}
