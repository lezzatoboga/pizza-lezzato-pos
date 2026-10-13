// Sinkron pelanggan dari database website ke tabel customers POS.
// Data pelanggan sensitif: TIDAK lewat anon key, tapi koneksi Postgres
// langsung dengan role SELECT-only pos_reader (secret WEBSITE_POS_READER_DB_URL,
// sama dengan jembatan pesanan) ke view pos.v_pelanggan (kontrak §2.1/§2.3):
//   - inkremental: updated_at > kursor − 2 menit;
//   - rekonsiliasi id penuh sehari sekali (atau bila kursor kosong).
// Dipanggil oleh: pg_cron tiap 15 menit, atau tombol "Sinkron" (izin sync_menu).
// Selama saklar jeda aktif (sync_settings.customers_paused) fungsi ini tidak
// menyentuh website dan tidak mencatat kegagalan.
import { adminClient, corsHeaders, json } from '../_shared/http.ts';
import { authorizeSync } from '../_shared/sync-auth.ts';
import { plain, websiteDb } from '../_shared/web-bridge.ts';

type WebsiteCustomer = {
	id: string;
	name: string;
	phone: string;
	default_address: string | null;
	default_patokan: string | null;
	phone_verified: boolean | null;
	updated_at: string;
};

async function readWebsiteCustomers(cursor: string | null): Promise<WebsiteCustomer[]> {
	const sql = websiteDb('reader');
	if (!sql) throw new Error('WEBSITE_POS_READER_DB_URL belum diset');
	try {
		return plain(
			await sql<WebsiteCustomer[]>`
				select id, name, phone, default_address, default_patokan, phone_verified, updated_at
				from pos.v_pelanggan
				where ${cursor}::timestamptz is null or updated_at > ${cursor}::timestamptz - interval '2 minutes'
			`
		);
	} finally {
		await sql.end({ timeout: 5 });
	}
}

const jakartaToday = () =>
	new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Jakarta' }).format(new Date());

Deno.serve(async (req) => {
	if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
	if (req.method !== 'POST') return json({ error: 'Metode tidak didukung' }, 405);

	const auth = await authorizeSync(req);
	if (auth instanceof Response) return auth;

	const admin = adminClient();

	const { data: settings, error: settingsError } = await admin
		.from('sync_settings')
		.select('customers_paused, customers_cursor, customers_reconciled_on')
		.maybeSingle();
	if (settingsError) return json({ error: settingsError.message }, 500);
	if (settings?.customers_paused) {
		return json({ ok: true, paused: true, customers: 0, skipped: 0 });
	}

	try {
		// Rekonsiliasi penuh sekali per hari (WIB) atau saat kursor belum ada.
		const full = !settings?.customers_cursor || settings.customers_reconciled_on !== jakartaToday();
		let customers: WebsiteCustomer[];
		try {
			customers = await readWebsiteCustomers(full ? null : settings!.customers_cursor);
		} catch (e) {
			// Pesan driver bisa memuat detail koneksi — jangan teruskan apa adanya.
			console.error('sync-customers read:', (e as Error).message);
			throw new Error('Gagal membaca pelanggan dari database website');
		}

		const { data, error } = await admin.rpc('apply_customer_sync', {
			p_customers: customers,
			p_trigger: auth.trigger,
			p_triggered_by: auth.userId,
			p_full: full,
			p_cursor: customers.reduce<string | null>(
				(max, c) => (!max || c.updated_at > max ? c.updated_at : max),
				null
			)
		});
		if (error) throw new Error(error.message);

		return json({ ok: true, ...data });
	} catch (e) {
		const message = (e as Error).message;
		console.error('sync-customers:', message);
		await admin.from('menu_sync_runs').insert({
			kind: 'customers',
			trigger: auth.trigger,
			triggered_by: auth.userId,
			status: 'failed',
			error: message
		});
		return json({ error: message }, 500);
	}
});
