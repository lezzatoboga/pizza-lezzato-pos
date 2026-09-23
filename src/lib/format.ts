const rupiahFormat = new Intl.NumberFormat('id-ID', {
	style: 'currency',
	currency: 'IDR',
	maximumFractionDigits: 0
});

export const rupiah = (value: number) => rupiahFormat.format(value);

export const timeOf = (iso: string) =>
	new Date(iso).toLocaleTimeString('id-ID', {
		hour: '2-digit',
		minute: '2-digit',
		timeZone: 'Asia/Jakarta'
	});

// Tanggal bisnis (YYYY-MM-DD) di zona Asia/Jakarta, sama dengan transaction_date di database.
export const jakartaToday = () =>
	new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Jakarta' }).format(new Date());

// Pesan error RPC berformat "KODE: pesan" — tampilkan pesannya saja.
export function friendlyError(error: unknown): string {
	const message = (error as { message?: string })?.message ?? String(error);
	return message.replace(/^[A-Z_]+:\s*/, '');
}
