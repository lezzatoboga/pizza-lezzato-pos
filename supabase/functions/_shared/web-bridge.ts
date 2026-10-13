// Jembatan pesanan website ↔ POS: koneksi ke database website dan pemanggilan
// pos.pos_set_order_status (docs/KONTRAK-DATA-POS.md §2.1–§2.2).
//
// Koneksi Postgres langsung (pooler mode transaksi → tanpa prepared statement):
//   WEBSITE_POS_READER_DB_URL  role pos_reader         — SELECT view schema pos
//   WEBSITE_POS_STATUS_DB_URL  role pos_status_writer  — EXECUTE pos_set_order_status
// Lokal: diarahkan ke database website_tiruan (paket supabase/website-tiruan/).
import postgres from 'npm:postgres@3.4.5';

export type Sql = ReturnType<typeof postgres>;

export function websiteDb(kind: 'reader' | 'writer'): Sql | null {
	const url = Deno.env.get(
		kind === 'reader' ? 'WEBSITE_POS_READER_DB_URL' : 'WEBSITE_POS_STATUS_DB_URL'
	);
	if (!url) return null;
	const ssl = Deno.env.get('WEBSITE_DB_SSL') === 'disable' ? false : 'require';
	return postgres(url, { prepare: false, max: 1, ssl, connect_timeout: 10, idle_timeout: 5 });
}

// Kode galat dari fungsi website (pesan berawalan kode, errcode P0001).
const RULE_ERRORS = new Set([
	'status_tidak_dikenal',
	'pesanan_tidak_ada',
	'sebelum_go_live',
	'transisi_ditolak',
	'menunggu_admin',
	'belum_lunas',
	'sudah_lunas_terkunci',
	'pembayaran_berjalan'
]);

export type StatusResult =
	| { ok: true; result: Record<string, unknown> }
	| { ok: false; code: string; message: string; rule: boolean };

export async function setOrderStatus(
	sql: Sql,
	orderId: string,
	status: string,
	diubahKasir: boolean
): Promise<StatusResult> {
	try {
		const [row] = await sql`
			select pos.pos_set_order_status(${orderId}::uuid, ${status}, ${diubahKasir}) as r
		`;
		return { ok: true, result: row.r as Record<string, unknown> };
	} catch (e) {
		const message = (e as Error).message ?? String(e);
		const code = /^([a-z_]+)\b/.exec(message)?.[1] ?? '';
		const rule = (e as { code?: string }).code === 'P0001' && RULE_ERRORS.has(code);
		return { ok: false, code: rule ? code : 'jaringan', message, rule };
	}
}

// Pesan untuk kasir per kode galat.
export const STATUS_ERROR_TEXT: Record<string, string> = {
	pembayaran_berjalan:
		'Pelanggan sedang membayar online (QRIS berjalan). Tunggu pembayaran selesai/kedaluwarsa — perubahan tidak disimpan.',
	sudah_lunas_terkunci: 'Pesanan sudah lunas online dan terkunci — perubahan tidak disimpan.',
	menunggu_admin: 'Pesanan menunggu verifikasi admin website — perubahan belum bisa dikirim.',
	sebelum_go_live:
		'Jembatan website belum/tidak aktif (go-live) — kelola pesanan di panel admin website.',
	transisi_ditolak: 'Status pesanan di website tidak mengizinkan perubahan ini.',
	pesanan_tidak_ada: 'Pesanan tidak ditemukan di website.',
	belum_lunas: 'Pembayaran online belum lunas.',
	status_tidak_dikenal: 'Status tidak dikenal website.',
	jaringan: 'Website tidak terjangkau — perubahan tidak disimpan. Coba lagi.'
};

// JSON polos (numeric → string/number apa adanya, Date → ISO).
export function plain<T>(rows: T): T {
	return JSON.parse(JSON.stringify(rows));
}
