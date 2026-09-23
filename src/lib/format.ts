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

// Cermin fungsi database normalize_phone: nomor HP → E.164 (default +62).
// null kalau tidak valid.
export function normalizePhone(input: string): string | null {
	let digits = input.replace(/\D/g, '');
	if (digits.startsWith('0')) digits = '62' + digits.slice(1);
	else if (digits.startsWith('8')) digits = '62' + digits;
	return /^[1-9][0-9]{7,14}$/.test(digits) ? '+' + digits : null;
}

// +6281378099099 → +62 813-7809-9099
export function formatPhone(phone: string): string {
	if (!phone.startsWith('+62')) return phone;
	const local = phone.slice(3);
	return `+62 ${local.slice(0, 3)}-${local.slice(3, 7)}-${local.slice(7)}`.replace(/-$/, '');
}
