// Jembatan pesanan website → POS (keputusan Owner 13 Okt 2026, kontrak §2.1–§2.2).
// Dipanggil: pg_cron tiap 30 detik (x-cron-secret), tombol "Cek pesanan" dan
// setelah aksi kasir (sesi pengguna POS mana pun).
//   1. kirim antrean status (web_status_outbox) — berurutan per pesanan;
//   2. tarik pos.v_pesanan (kursor updated_at − 2 menit, upsert idempoten),
//      item hanya untuk pesanan baru;
//   3. apply_web_orders di DB POS.
// Saklar go-live (docs/SOP-SAKLAR-GO-LIVE.md):
//   - go_live_at website kosong → view kosong. Bila POS masih punya pesanan web
//     dalam jendela 14 hari view, berarti saklar dimatikan → inactive_reason
//     'sebelum_go_live' (banner di semua halaman); status dari POS ditolak (gagal).
//   - saklar menyala lagi → web_resend_after_golive mengantre status terakhir per
//     pesanan (hanya maju, sekali; yang ditolak masuk daftar Owner).
// Mode cek (body {"mode":"cek"}, khusus Owner): uji X1–X2 tanpa mengubah data.
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { adminClient, corsHeaders, json } from '../_shared/http.ts';
import { plain, setOrderStatus, websiteDb, type Sql } from '../_shared/web-bridge.ts';

type Outbox = { id: number; web_order_id: string; status: string; diubah_kasir: boolean };
type Admin = ReturnType<typeof adminClient>;

// Pemicu sah: cron (userId null) atau pengguna POS yang login.
async function authorize(req: Request): Promise<{ userId: string | null } | Response> {
	const cronSecret = Deno.env.get('SYNC_MENU_CRON_SECRET');
	const given = req.headers.get('x-cron-secret');
	if (given)
		return cronSecret && given === cronSecret
			? { userId: null }
			: json({ error: 'Tidak diizinkan' }, 401);

	const authHeader = req.headers.get('Authorization') ?? '';
	if (!authHeader.startsWith('Bearer ')) return json({ error: 'Tidak diizinkan' }, 401);
	const user = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
		global: { headers: { Authorization: authHeader } },
		auth: { persistSession: false, autoRefreshToken: false }
	});
	const { data } = await user.rpc('current_pos_user_id');
	return data ? { userId: data as string } : json({ error: 'Tidak diizinkan' }, 403);
}

async function sendOutbox(
	admin: Admin,
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
	admin: Admin,
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

// View kosong padahal POS punya pesanan web yang seharusnya masih terlihat
// (dalam jendela 14 hari view) → saklar go-live dimatikan.
async function hasRecentWebOrders(admin: Admin): Promise<boolean> {
	const since = new Date(Date.now() - (14 * 86_400_000 - 10 * 60_000)).toISOString();
	const { count, error } = await admin
		.from('web_orders')
		.select('id', { count: 'exact', head: true })
		.gt('web_created_at', since);
	if (error) throw new Error(error.message);
	return (count ?? 0) > 0;
}

// ---------------------------------------------------------------- mode cek (X1–X2)
// Hanya pembacaan + panggilan yang pasti ditolak website (id acak, status asing).
// Tidak menulis apa pun, di website maupun di POS.

type Check = { kode: string; uji: string; harapan: string; hasil: string; lolos: boolean };

// Pesan driver bisa memuat alamat koneksi — buang sebelum ditampilkan.
const clean = (m: string) => m.replace(/postgres(ql)?:\/\/\S+/gi, '[url]').slice(0, 200);

async function probe(
	kode: string,
	uji: string,
	harapan: string,
	run: () => Promise<string>,
	expect: (ok: boolean, text: string) => boolean
): Promise<Check> {
	try {
		const hasil = await run();
		return { kode, uji, harapan, hasil, lolos: expect(true, hasil) };
	} catch (e) {
		const hasil = clean((e as Error).message ?? String(e));
		return { kode, uji, harapan, hasil, lolos: expect(false, hasil) };
	}
}

async function connectionChecks(): Promise<Check[]> {
	const r = websiteDb('reader');
	const w = websiteDb('writer');
	if (!r || !w)
		return [
			{
				kode: 'X0',
				uji: 'Secret koneksi',
				harapan: 'terpasang',
				hasil: 'WEBSITE_POS_READER_DB_URL / WEBSITE_POS_STATUS_DB_URL kosong',
				lolos: false
			}
		];
	const randomId = crypto.randomUUID();
	const succeeds = (ok: boolean) => ok;
	const denied = (ok: boolean, t: string) => !ok && /permission denied/i.test(t);
	const rejectedWith = (code: string) => (ok: boolean, t: string) => !ok && t.startsWith(code);
	const count = async (q: PromiseLike<unknown>, unit: string) =>
		`${((await q) as { n: number }[])[0].n} ${unit}`;
	try {
		return [
			await probe(
				'X1',
				'pos_reader: login lewat pooler (TLS)',
				'berhasil, read-only',
				async () => {
					const [x] =
						await r`select current_user as u, current_setting('transaction_read_only') as ro`;
					return `login ${x.u}, read-only ${x.ro}`;
				},
				(ok, t) => ok && t.endsWith('read-only on')
			),
			await probe(
				'X1',
				'pos_reader: baca v_pesanan',
				'terbaca (kosong selama go-live belum diisi)',
				() => count(r`select count(*)::int as n from pos.v_pesanan`, 'baris'),
				succeeds
			),
			await probe(
				'X1',
				'pos_reader: baca v_item_pesanan',
				'terbaca',
				() => count(r`select count(*)::int as n from pos.v_item_pesanan`, 'baris'),
				succeeds
			),
			await probe(
				'X1',
				'pos_reader: baca v_pelanggan',
				'terbaca',
				() => count(r`select count(*)::int as n from pos.v_pelanggan`, 'pelanggan'),
				succeeds
			),
			await probe(
				'X1',
				'pos_reader: baca v_pengaturan_ongkir',
				'1 baris dengan koordinat outlet',
				async () => {
					const rows = await r`select outlet_lat from pos.v_pengaturan_ongkir`;
					return `${rows.length} baris${rows[0]?.outlet_lat != null ? ', koordinat ada' : ''}`;
				},
				(ok, t) => ok && t === '1 baris, koordinat ada'
			),
			await probe(
				'X1',
				'pos_reader: tabel dasar public.orders',
				'ditolak',
				async () => {
					await r`select 1 from public.orders limit 1`;
					return 'TERBACA (seharusnya ditolak)';
				},
				denied
			),
			await probe(
				'X1',
				'pos_reader: fungsi status',
				'ditolak',
				async () => {
					await r`select pos.pos_set_order_status(${randomId}::uuid, 'diterima')`;
					return 'DIIZINKAN (seharusnya ditolak)';
				},
				denied
			),
			await probe(
				'X2',
				'pos_status_writer: id pesanan acak',
				'pesanan_tidak_ada',
				async () => {
					await w`select pos.pos_set_order_status(${randomId}::uuid, 'diterima')`;
					return 'DITERIMA (seharusnya ditolak)';
				},
				rejectedWith('pesanan_tidak_ada')
			),
			await probe(
				'X2',
				'pos_status_writer: status asing',
				'status_tidak_dikenal',
				async () => {
					await w`select pos.pos_set_order_status(${randomId}::uuid, 'uji_status_asing')`;
					return 'DITERIMA (seharusnya ditolak)';
				},
				rejectedWith('status_tidak_dikenal')
			),
			await probe(
				'X2',
				'pos_status_writer: SELECT view',
				'ditolak',
				async () => {
					await w`select 1 from pos.v_pesanan limit 1`;
					return 'TERBACA (seharusnya ditolak)';
				},
				denied
			)
		];
	} finally {
		await Promise.allSettled([r.end({ timeout: 5 }), w.end({ timeout: 5 })]);
	}
}

async function isOwner(admin: Admin, userId: string): Promise<boolean> {
	const { data } = await admin
		.from('pos_users')
		.select('active, roles(code)')
		.eq('id', userId)
		.maybeSingle();
	const role = (data?.roles as unknown as { code: string } | null)?.code;
	return !!data?.active && role === 'owner';
}

Deno.serve(async (req) => {
	if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
	if (req.method !== 'POST') return json({ error: 'Metode tidak didukung' }, 405);
	const auth = await authorize(req);
	if (auth instanceof Response) return auth;
	const body = await req.json().catch(() => null);

	const admin = adminClient();
	if (body?.mode === 'cek') {
		// Khusus Owner, dicek di server; tanpa lease dan tanpa menulis apa pun.
		if (!auth.userId || !(await isOwner(admin, auth.userId)))
			return json({ error: 'Cek koneksi website khusus Owner' }, 403);
		const checks = await connectionChecks();
		return json({ ok: checks.every((c) => c.lolos), checks });
	}

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
		const switchedOff = outbox.inactive || (pulled.viewEmpty && (await hasRecentWebOrders(admin)));

		// Saklar menyala lagi → kirim ulang status terakhir yang tertolak selama mati.
		let resend: Record<string, number> | null = null;
		if (!switchedOff && !pulled.viewEmpty) {
			const { data, error } = await admin.rpc('web_resend_after_golive');
			if (error) throw new Error(error.message);
			resend = data as Record<string, number>;
			if (resend.queued > 0) resend = { ...resend, ...(await sendOutbox(admin, writer)) };
		}

		report.ok = true;
		report.view_empty = pulled.viewEmpty;
		report.orders_cursor = pulled.cursor;
		if (switchedOff) report.inactive_reason = 'sebelum_go_live';
		else if (!pulled.viewEmpty || outbox.sent > 0) report.inactive_reason = null;
		return json({
			ok: true,
			outbox,
			...pulled.applied,
			view_empty: pulled.viewEmpty,
			switched_off: switchedOff,
			resend
		});
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
