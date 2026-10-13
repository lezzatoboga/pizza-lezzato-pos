// Jembatan pesanan website → POS (keputusan Owner 13 Okt 2026, kontrak §2.1–§2.2).
// Dipanggil: pg_cron tiap 30 detik (x-cron-secret), tombol "Cek pesanan" dan
// setelah aksi kasir (sesi pengguna POS mana pun).
//   1. kirim antrean status (web_status_outbox) — berurutan per pesanan;
//   2. tarik pos.v_pesanan (kursor updated_at − 2 menit, upsert idempoten),
//      item hanya untuk pesanan baru;
//   3. apply_web_orders di DB POS.
// go_live_at website kosong → view kosong (bukan galat); fungsi status menjawab
// sebelum_go_live → antrean berhenti & aplikasi menampilkan banner.
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { adminClient, corsHeaders, json } from '../_shared/http.ts';
import { plain, setOrderStatus, websiteDb, type Sql } from '../_shared/web-bridge.ts';

type Outbox = { id: number; web_order_id: string; status: string; diubah_kasir: boolean };

async function authorize(req: Request): Promise<Response | null> {
	const cronSecret = Deno.env.get('SYNC_MENU_CRON_SECRET');
	const given = req.headers.get('x-cron-secret');
	if (given)
		return cronSecret && given === cronSecret ? null : json({ error: 'Tidak diizinkan' }, 401);

	const authHeader = req.headers.get('Authorization') ?? '';
	if (!authHeader.startsWith('Bearer ')) return json({ error: 'Tidak diizinkan' }, 401);
	const user = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
		global: { headers: { Authorization: authHeader } },
		auth: { persistSession: false, autoRefreshToken: false }
	});
	const { data } = await user.rpc('current_pos_user_id');
	return data ? null : json({ error: 'Tidak diizinkan' }, 403);
}

async function sendOutbox(
	admin: ReturnType<typeof adminClient>,
	writer: Sql
): Promise<{ sent: number; failed: number; retry: number; inactive: boolean }> {
	let sent = 0;
	let failed = 0;
	let retry = 0;
	let inactive = false;
	// web_outbox_due memberi satu baris (tertua) per pesanan; ulangi supaya rangkaian
	// status (diproses → siap → selesai) terkirim dalam satu run, tetap berurutan.
	for (let round = 0; round < 6; round++) {
		const { data, error } = await admin.rpc('web_outbox_due', { p_limit: 20 });
		if (error) throw new Error(error.message);
		const rows = (data ?? []) as Outbox[];
		if (!rows.length) break;
		const before = sent + failed;
		const stop = await sendRows(rows);
		if (stop || sent + failed === before) break;
	}
	return { sent, failed, retry, inactive };

	// true = berhenti (website tak terjangkau).
	async function sendRows(rows: Outbox[]): Promise<boolean> {
		for (const row of rows) {
			const res = await setOrderStatus(writer, row.web_order_id, row.status, row.diubah_kasir);
			if (res.ok) {
				await admin.rpc('web_outbox_mark', { p_id: row.id, p_outcome: 'ok', p_result: res.result });
				sent++;
			} else if (res.rule && res.code !== 'menunggu_admin') {
				await admin.rpc('web_outbox_mark', {
					p_id: row.id,
					p_outcome: 'failed',
					p_error: res.code
				});
				failed++;
				if (res.code === 'sebelum_go_live') inactive = true;
			} else {
				await admin.rpc('web_outbox_mark', {
					p_id: row.id,
					p_outcome: 'retry',
					p_error: res.code === 'jaringan' ? res.message.slice(0, 300) : res.code
				});
				retry++;
				if (res.code === 'jaringan') return true; // website tak terjangkau: sisanya menunggu run berikutnya
			}
		}
		return false;
	}
}

async function pullOrders(
	admin: ReturnType<typeof adminClient>,
	reader: Sql,
	cursor: string | null
): Promise<{ applied: Record<string, number>; cursor: string | null; viewEmpty: boolean }> {
	const headers = plain(
		await reader`
			select * from pos.v_pesanan
			where ${cursor}::timestamptz is null or updated_at > ${cursor}::timestamptz - interval '2 minutes'
			order by updated_at
			limit 500
		`
	) as Record<string, unknown>[];

	const ids = headers.map((h) => h.id as string);
	let known = new Set<string>();
	if (ids.length) {
		const { data, error } = await admin.from('web_orders').select('id').in('id', ids);
		if (error) throw new Error(error.message);
		known = new Set((data ?? []).map((r) => r.id as string));
	}
	const fresh = ids.filter((id) => !known.has(id));
	const items = fresh.length
		? (plain(
				await reader`select * from pos.v_item_pesanan where order_id = any(${fresh}::uuid[])`
			) as Record<string, unknown>[])
		: [];

	let applied: Record<string, number> = { created: 0, updated: 0, voided: 0 };
	if (headers.length) {
		const payload = headers.map((h) => ({
			header: h,
			items: known.has(h.id as string) ? undefined : items.filter((i) => i.order_id === h.id)
		}));
		const { data, error } = await admin.rpc('apply_web_orders', { p_orders: payload });
		if (error) throw new Error(error.message);
		applied = data as Record<string, number>;
	}

	const [{ ada }] = await reader`select exists (select 1 from pos.v_pesanan) as ada`;
	const newCursor = headers.length ? (headers[headers.length - 1].updated_at as string) : cursor;
	return { applied, cursor: newCursor, viewEmpty: !ada };
}

Deno.serve(async (req) => {
	if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
	if (req.method !== 'POST') return json({ error: 'Metode tidak didukung' }, 405);
	const denied = await authorize(req);
	if (denied) return denied;

	const admin = adminClient();
	const { data: token, error: leaseError } = await admin.rpc('web_bridge_lease', { p_seconds: 60 });
	if (leaseError) return json({ error: leaseError.message }, 500);
	if (!token) return json({ ok: true, busy: true });

	const reader = websiteDb('reader');
	const writer = websiteDb('writer');
	const report: Record<string, unknown> = { ok: false };
	try {
		if (!reader || !writer) {
			report.error = 'Jembatan website belum dikonfigurasi (secret koneksi kosong)';
			return json({ ok: false, error: report.error });
		}
		const { data: state } = await admin.from('web_bridge_state').select('orders_cursor').single();

		const outbox = await sendOutbox(admin, writer);
		const pulled = await pullOrders(admin, reader, state?.orders_cursor ?? null);

		report.ok = true;
		report.view_empty = pulled.viewEmpty;
		report.orders_cursor = pulled.cursor;
		if (outbox.inactive) report.inactive_reason = 'sebelum_go_live';
		else if (!pulled.viewEmpty || outbox.sent > 0) report.inactive_reason = null;
		return json({ ok: true, outbox, ...pulled.applied, view_empty: pulled.viewEmpty });
	} catch (e) {
		const message = (e as Error).message;
		console.error('web-orders-sync:', message);
		report.error = message.slice(0, 500);
		return json({ ok: false, error: 'Gagal sinkron pesanan website' }, 500);
	} finally {
		await admin.rpc('web_bridge_release', { p_token: token, p_report: report });
		await Promise.allSettled([reader?.end({ timeout: 5 }), writer?.end({ timeout: 5 })]);
	}
});
