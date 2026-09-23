// Otorisasi fungsi sinkron (sync-menu, sync-customers):
//   - pg_cron: header x-cron-secret = SYNC_MENU_CRON_SECRET
//   - manual : sesi pengguna POS dengan izin sync_menu
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { json } from './http.ts';

export type SyncTrigger = { trigger: 'cron' | 'manual'; userId: string | null };

// Mengembalikan pemicu sinkron, atau Response penolakan.
export async function authorizeSync(req: Request): Promise<SyncTrigger | Response> {
	const cronSecret = Deno.env.get('SYNC_MENU_CRON_SECRET');
	const givenSecret = req.headers.get('x-cron-secret');
	if (givenSecret) {
		if (cronSecret && givenSecret === cronSecret) return { trigger: 'cron', userId: null };
		return json({ error: 'Tidak diizinkan' }, 401);
	}

	const authHeader = req.headers.get('Authorization') ?? '';
	if (!authHeader.startsWith('Bearer ')) return json({ error: 'Tidak diizinkan' }, 401);

	const userClient = createClient(
		Deno.env.get('SUPABASE_URL')!,
		Deno.env.get('SUPABASE_ANON_KEY')!,
		{
			global: { headers: { Authorization: authHeader } },
			auth: { persistSession: false, autoRefreshToken: false }
		}
	);
	const [{ data: allowed }, { data: userId }] = await Promise.all([
		userClient.rpc('has_permission', { p_code: 'sync_menu' }),
		userClient.rpc('current_pos_user_id')
	]);
	if (!allowed || !userId) return json({ error: 'Anda tidak punya izin sinkron' }, 403);
	return { trigger: 'manual', userId: userId as string };
}
