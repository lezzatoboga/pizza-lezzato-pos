// Sinkron pelanggan dari database website ke tabel customers POS.
// Data pelanggan sensitif: TIDAK lewat anon key, tapi koneksi Postgres
// langsung dengan role SELECT-only pos_reader (secret WEBSITE_CUSTOMERS_DB_URL,
// Transaction pooler port 6543).
// Dipanggil oleh: pg_cron tiap 15 menit, atau tombol "Sinkron" (izin sync_menu).
import postgres from 'npm:postgres@3.4.5';
import { adminClient, corsHeaders, json } from '../_shared/http.ts';
import { authorizeSync } from '../_shared/sync-auth.ts';

type WebsiteCustomer = {
	id: string;
	name: string;
	phone: string;
	default_address: string | null;
	default_patokan: string | null;
	phone_verified: boolean | null;
};

async function readWebsiteCustomers(): Promise<WebsiteCustomer[]> {
	const url = Deno.env.get('WEBSITE_CUSTOMERS_DB_URL');
	if (!url) throw new Error('WEBSITE_CUSTOMERS_DB_URL belum diset');

	// Transaction pooler tidak mendukung prepared statement.
	const sql = postgres(url, { prepare: false, max: 1, ssl: 'require', connect_timeout: 15 });
	try {
		return await sql<WebsiteCustomer[]>`
			select id, name, phone, default_address, default_patokan, phone_verified
			from public.customers
		`;
	} finally {
		await sql.end({ timeout: 5 });
	}
}

Deno.serve(async (req) => {
	if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
	if (req.method !== 'POST') return json({ error: 'Metode tidak didukung' }, 405);

	const auth = await authorizeSync(req);
	if (auth instanceof Response) return auth;

	const admin = adminClient();

	try {
		let customers: WebsiteCustomer[];
		try {
			customers = await readWebsiteCustomers();
		} catch (e) {
			// Pesan driver bisa memuat detail koneksi — jangan teruskan apa adanya.
			console.error('sync-customers read:', (e as Error).message);
			throw new Error('Gagal membaca pelanggan dari database website');
		}

		const { data, error } = await admin.rpc('apply_customer_sync', {
			p_customers: customers,
			p_trigger: auth.trigger,
			p_triggered_by: auth.userId
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
