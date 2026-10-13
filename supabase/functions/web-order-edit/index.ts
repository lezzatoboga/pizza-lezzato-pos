// Edit pesanan website oleh kasir (aturan kontrak R1/R9, keputusan Owner 13 Okt):
//   1. kirim penanda diubah_kasir ke website LANGSUNG (bukan lewat antrean);
//   2. hanya bila website menerima, simpan edit di POS (RPC edit_web_order,
//      dengan sesi kasir — izin & jejak editor tetap berlaku).
// Ditolak (pembayaran_berjalan / sudah_lunas_terkunci / …) atau website tak
// terjangkau → edit TIDAK disimpan, kasir mendapat pesan jelas.
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { adminClient, corsHeaders, json } from '../_shared/http.ts';
import { setOrderStatus, STATUS_ERROR_TEXT, websiteDb } from '../_shared/web-bridge.ts';

Deno.serve(async (req) => {
	if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
	if (req.method !== 'POST') return json({ error: 'Metode tidak didukung' }, 405);

	const authHeader = req.headers.get('Authorization') ?? '';
	if (!authHeader.startsWith('Bearer ')) return json({ error: 'Tidak diizinkan' }, 401);
	const user = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
		global: { headers: { Authorization: authHeader } },
		auth: { persistSession: false, autoRefreshToken: false }
	});
	const { data: userId } = await user.rpc('current_pos_user_id');
	if (!userId) return json({ error: 'Sesi tidak valid' }, 403);

	const body = await req.json().catch(() => null);
	const transactionId = body?.transaction_id as string | undefined;
	if (!transactionId || typeof body?.payload !== 'object') {
		return json({ error: 'Permintaan tidak valid' }, 400);
	}

	const admin = adminClient();
	const { data: order, error } = await admin
		.from('web_orders')
		.select('id, terkunci_edit, diubah_di_pos, transactions(order_status, status, is_locked)')
		.eq('transaction_id', transactionId)
		.maybeSingle();
	if (error) return json({ error: error.message }, 500);
	if (!order) return json({ error: 'Pesanan website tidak ditemukan' }, 404);
	const tx = order.transactions as unknown as {
		order_status: string;
		status: string;
		is_locked: boolean;
	};
	if (order.terkunci_edit) return json({ error: STATUS_ERROR_TEXT.sudah_lunas_terkunci }, 409);
	if (tx.status !== 'active' || !['baru', 'diterima'].includes(tx.order_status) || tx.is_locked) {
		return json(
			{ error: 'Pesanan sudah dikonfirmasi/terkunci — perubahan hanya lewat pembatalan' },
			409
		);
	}

	// Penanda dikirim setiap edit (aman diulang; status tujuan 'diterima' = '=' bila sudah diterima).
	const writer = websiteDb('writer');
	if (!writer) return json({ error: 'Jembatan website belum dikonfigurasi' }, 503);
	try {
		let res = await setOrderStatus(writer, order.id, 'diterima', true);
		// Galat sementara (sibuk 55P03, timeout 57014, koneksi putus): coba sekali lagi —
		// aman, fungsi website idempoten. Masih gagal → 503, edit tidak disimpan.
		if (!res.ok && !res.rule) {
			await new Promise((r) => setTimeout(r, 1000));
			res = await setOrderStatus(writer, order.id, 'diterima', true);
		}
		if (!res.ok) {
			return json(
				{ error: STATUS_ERROR_TEXT[res.code] ?? res.message, code: res.code },
				res.rule ? 409 : 503
			);
		}
		const { error: flagError } = await admin.rpc('web_mark_flag_ok', {
			p_order_id: order.id,
			p_result: res.result
		});
		if (flagError) return json({ error: flagError.message }, 500);
	} finally {
		await writer.end({ timeout: 5 });
	}

	const { data, error: editError } = await user.rpc('edit_web_order', {
		p_transaction_id: transactionId,
		p_payload: body.payload
	});
	if (editError) return json({ error: editError.message }, 400);
	return json({ ok: true, ...(data as Record<string, unknown>) });
});
