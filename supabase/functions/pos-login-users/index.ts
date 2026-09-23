// Daftar nama pengguna aktif untuk layar login (langkah "pilih nama").
// Hanya id, nama, dan nama role — tidak ada data sensitif.
import { adminClient, corsHeaders, json } from '../_shared/http.ts';

Deno.serve(async (req) => {
	if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
	if (req.method !== 'GET' && req.method !== 'POST') return json({ error: 'Metode tidak didukung' }, 405);

	const { data, error } = await adminClient()
		.from('pos_users')
		.select('id, name, roles(name)')
		.eq('active', true)
		.order('name');

	if (error) {
		console.error('pos-login-users:', error);
		return json({ error: 'Gagal memuat daftar pengguna' }, 500);
	}

	const users = data.map((u) => ({
		id: u.id,
		name: u.name,
		role: (u.roles as unknown as { name: string } | null)?.name ?? ''
	}));
	return json({ users });
});
