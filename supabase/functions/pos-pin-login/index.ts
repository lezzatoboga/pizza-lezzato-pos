// Login PIN: verifikasi PIN di database, lalu terbitkan sesi Supabase Auth
// untuk auth user milik pos_user (dibuat otomatis saat login pertama).
import { adminClient, anonClient, corsHeaders, json } from '../_shared/http.ts';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PIN_RE = /^[0-9]{4,6}$/;

// Email internal, tidak pernah dipakai mengirim email.
const authEmailFor = (posUserId: string) => `pos-${posUserId}@pos.pizzalezzato.com`;

type VerifyResult =
	| { status: 'ok'; pos_user_id: string; auth_user_id: string | null }
	| { status: 'invalid'; attempts_left?: number }
	| { status: 'locked'; locked_until: string };

Deno.serve(async (req) => {
	if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
	if (req.method !== 'POST') return json({ error: 'Metode tidak didukung' }, 405);

	let body: { user_id?: unknown; pin?: unknown };
	try {
		body = await req.json();
	} catch {
		return json({ error: 'Permintaan tidak valid' }, 400);
	}
	const userId = typeof body.user_id === 'string' ? body.user_id : '';
	const pin = typeof body.pin === 'string' ? body.pin : '';
	if (!UUID_RE.test(userId) || !PIN_RE.test(pin)) {
		return json({ error: 'PIN salah' }, 401);
	}

	const admin = adminClient();

	const { data: verify, error: verifyError } = await admin.rpc('verify_pos_user_pin', {
		p_user_id: userId,
		p_pin: pin
	});
	if (verifyError) {
		console.error('verify_pos_user_pin:', verifyError);
		return json({ error: 'Gagal memverifikasi PIN' }, 500);
	}

	const result = verify as VerifyResult;
	if (result.status === 'locked') {
		return json({ error: 'Terlalu banyak percobaan. Akun terkunci sementara.', locked_until: result.locked_until }, 423);
	}
	if (result.status !== 'ok') {
		return json({ error: 'PIN salah', attempts_left: result.attempts_left ?? null }, 401);
	}

	const email = authEmailFor(userId);

	// Login pertama: buat auth user. Kalau sudah ada (mis. login sebelumnya
	// gagal di tengah jalan), abaikan — generateLink di bawah mengembalikan id-nya.
	if (!result.auth_user_id) {
		const { error } = await admin.auth.admin.createUser({
			email,
			email_confirm: true,
			app_metadata: { pos_user_id: userId }
		});
		if (error && error.code !== 'email_exists') {
			console.error('createUser:', error);
			return json({ error: 'Gagal menyiapkan sesi' }, 500);
		}
	}

	const { data: link, error: linkError } = await admin.auth.admin.generateLink({
		type: 'magiclink',
		email
	});
	if (linkError || !link) {
		console.error('generateLink:', linkError);
		return json({ error: 'Gagal menyiapkan sesi' }, 500);
	}

	if (result.auth_user_id !== link.user.id) {
		const { error } = await admin.from('pos_users').update({ auth_user_id: link.user.id }).eq('id', userId);
		if (error) {
			console.error('link auth_user_id:', error);
			return json({ error: 'Gagal menyiapkan sesi' }, 500);
		}
	}

	const { data: otp, error: otpError } = await anonClient().auth.verifyOtp({
		token_hash: link.properties.hashed_token,
		type: 'email'
	});
	if (otpError || !otp.session) {
		console.error('verifyOtp:', otpError);
		return json({ error: 'Gagal menyiapkan sesi' }, 500);
	}

	return json({
		access_token: otp.session.access_token,
		refresh_token: otp.session.refresh_token
	});
});
