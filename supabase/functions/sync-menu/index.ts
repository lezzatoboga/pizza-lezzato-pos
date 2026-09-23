// Sinkron menu dari database website ke cache POS.
// Dipanggil oleh: pg_cron tiap 15 menit (header x-cron-secret), atau
// tombol "Sinkron menu" oleh pengguna dengan izin sync_menu.
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { adminClient, corsHeaders, json } from '../_shared/http.ts';
import { authorizeSync } from '../_shared/sync-auth.ts';

function websiteClient() {
	const url = Deno.env.get('WEBSITE_SUPABASE_URL');
	const key = Deno.env.get('WEBSITE_SUPABASE_ANON_KEY');
	if (!url || !key) throw new Error('WEBSITE_SUPABASE_URL / WEBSITE_SUPABASE_ANON_KEY belum diset');
	return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

Deno.serve(async (req) => {
	if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
	if (req.method !== 'POST') return json({ error: 'Metode tidak didukung' }, 405);

	const auth = await authorizeSync(req);
	if (auth instanceof Response) return auth;

	const admin = adminClient();

	try {
		const web = websiteClient();
		const [products, variants, toppings, toppingPrices, categories, sections] = await Promise.all([
			// Termasuk paket (kind = 'package'); dipisah di apply_menu_sync.
			web
				.from('menu_items')
				.select(
					'id, name, category_slug, section_key, kind, base_price, active, sort_order, package_items, package_choices, package_note'
				),
			web.from('menu_item_variants').select('id, menu_item_id, variant_key, label, price, sort_order'),
			web.from('xtratopping').select('id, name, active, sort_order'),
			web.from('xtratopping_price').select('variant_key, price'),
			web.from('menu_categories').select('slug, label, sort_order'),
			web.from('menu_sections').select('key, category_slug, label, sort_order')
		]);

		const failed = [products, variants, toppings, toppingPrices, categories, sections].find(
			(r) => r.error
		);
		if (failed?.error) throw new Error(`Gagal membaca database website: ${failed.error.message}`);

		const { data, error } = await admin.rpc('apply_menu_sync', {
			p_payload: {
				products: products.data,
				variants: variants.data,
				toppings: toppings.data,
				topping_prices: toppingPrices.data,
				categories: categories.data,
				sections: sections.data
			},
			p_trigger: auth.trigger,
			p_triggered_by: auth.userId
		});
		if (error) throw new Error(error.message);

		return json({ ok: true, ...data });
	} catch (e) {
		const message = (e as Error).message;
		console.error('sync-menu:', message);
		await admin.from('menu_sync_runs').insert({
			kind: 'menu',
			trigger: auth.trigger,
			triggered_by: auth.userId,
			status: 'failed',
			error: message
		});
		return json({ error: message }, 500);
	}
});
