import { supabase } from '$lib/supabase/client';
import type {
	Menu,
	Outlet,
	PaymentMethod,
	Platform,
	Product,
	SavedTransaction,
	Shift,
	Variant
} from './types';

function unwrap<T>(result: { data: T | null; error: { message: string } | null }): T {
	if (result.error) throw new Error(result.error.message);
	return result.data as T;
}

export async function loadMenu(): Promise<Menu> {
	// Urutan kategori/section/produk disusun di menu-order.ts; varian & topping
	// cukup diurutkan sort_order masing-masing di sini.
	const [products, variants, toppings, prices, categories, sections] = await Promise.all([
		supabase
			.from('products_cache')
			.select('id, name, category, section_key, kind, base_price, sort_order')
			.eq('active', true),
		supabase
			.from('product_variants_cache')
			.select('id, product_id, variant_key, label, price, sort_order')
			.order('sort_order')
			.order('label'),
		supabase
			.from('xtratopping_cache')
			.select('id, name, sort_order')
			.eq('active', true)
			.order('sort_order')
			.order('name'),
		supabase.from('xtratopping_price_cache').select('variant_key, price'),
		supabase.from('menu_categories_cache').select('slug, label, sort_order'),
		supabase.from('menu_sections_cache').select('key, category_slug, label, sort_order')
	]);

	const variantsByProduct = new Map<string, Variant[]>();
	for (const v of unwrap(variants) as Variant[]) {
		const list = variantsByProduct.get(v.product_id) ?? [];
		list.push(v);
		variantsByProduct.set(v.product_id, list);
	}

	return {
		categories: unwrap(categories),
		sections: unwrap(sections),
		products: (unwrap(products) as Omit<Product, 'variants'>[]).map((p) => ({
			...p,
			variants: variantsByProduct.get(p.id) ?? []
		})),
		toppings: unwrap(toppings),
		toppingPrices: Object.fromEntries(
			(unwrap(prices) as { variant_key: string; price: number }[]).map((p) => [
				p.variant_key,
				p.price
			])
		)
	};
}

export type PosContext = {
	outlet: Outlet;
	shift: Shift | null;
	paymentMethods: PaymentMethod[];
	platforms: Platform[];
};

// Fase 1: satu outlet aktif (outlet utama).
export async function loadContext(): Promise<PosContext> {
	const [outlets, methods, platforms] = await Promise.all([
		supabase
			.from('outlets')
			.select('id, code, name')
			.eq('active', true)
			.order('created_at')
			.limit(1),
		supabase
			.from('payment_methods')
			.select('id, code, name, is_cash')
			.eq('active', true)
			.order('sort_order'),
		supabase
			.from('marketplace_platforms')
			.select('id, code, name, markup_percent')
			.eq('active', true)
			.order('sort_order')
	]);

	const outlet = (unwrap(outlets) as Outlet[])[0];
	if (!outlet) throw new Error('Outlet belum diatur');

	const shift = unwrap(
		await supabase
			.from('shifts')
			.select('id, outlet_id, cashier_id, opening_balance, opening_time, status')
			.eq('outlet_id', outlet.id)
			.eq('status', 'open')
			.maybeSingle()
	) as Shift | null;

	return {
		outlet,
		shift,
		paymentMethods: unwrap(methods),
		platforms: (unwrap(platforms) as Platform[]).map((p) => ({
			...p,
			markup_percent: Number(p.markup_percent)
		}))
	};
}

export async function openShift(outletId: string, openingBalance: number): Promise<Shift> {
	return unwrap(
		await supabase.rpc('open_shift', { p_outlet_id: outletId, p_opening_balance: openingBalance })
	) as Shift;
}

export type TransactionPayload = {
	outlet_id: string;
	channel: 'admin_toko' | 'marketplace';
	sales_type: string;
	marketplace_platform_id?: string;
	markup_percent?: number;
	shipping_cost?: number;
	customer_name?: string;
	customer_phone?: string;
	notes?: string;
	items: {
		product_id: string;
		variant_id: string | null;
		qty: number;
		notes?: string;
		toppings: { id: string; qty: number }[];
	}[];
};

export async function createTransaction(payload: TransactionPayload): Promise<SavedTransaction> {
	return unwrap(
		await supabase.rpc('create_transaction', { p_payload: payload })
	) as SavedTransaction;
}

export type PaymentResult = SavedTransaction & { amount_paid: number; change_amount: number };

export async function payTransaction(
	transactionId: string,
	paymentMethodId: string,
	amountPaid: number | null
): Promise<PaymentResult> {
	return unwrap(
		await supabase.rpc('pay_transaction', {
			p_transaction_id: transactionId,
			p_payment_method_id: paymentMethodId,
			p_amount_paid: amountPaid
		})
	) as PaymentResult;
}

export type TransactionRow = {
	id: string;
	transaction_number: string;
	created_at: string;
	channel: string;
	sales_type: string;
	total: number;
	payment_status: 'unpaid' | 'paid';
	change_amount: number | null;
	status: 'active' | 'voided';
	customer_name: string | null;
	payment_methods: { name: string } | null;
	marketplace_platforms: { name: string } | null;
	transaction_items: {
		product_name_snapshot: string;
		variant_name_snapshot: string | null;
		qty: number;
		transaction_item_addons: { addon_name_snapshot: string; qty: number }[];
	}[];
};

export async function loadTransactions(date: string): Promise<TransactionRow[]> {
	return unwrap(
		await supabase
			.from('transactions')
			.select(
				`id, transaction_number, created_at, channel, sales_type, total, payment_status,
				 change_amount, status, customer_name,
				 payment_methods(name), marketplace_platforms(name),
				 transaction_items(product_name_snapshot, variant_name_snapshot, qty,
				   transaction_item_addons(addon_name_snapshot, qty))`
			)
			.eq('transaction_date', date)
			.order('created_at', { ascending: false })
	) as unknown as TransactionRow[];
}

export type MenuSyncRun = { created_at: string; status: string; error: string | null };

export async function lastMenuSync(): Promise<MenuSyncRun | null> {
	return unwrap(
		await supabase
			.from('menu_sync_runs')
			.select('created_at, status, error')
			.order('created_at', { ascending: false })
			.limit(1)
			.maybeSingle()
	);
}

export async function syncMenuNow(): Promise<{
	products: number;
	variants: number;
	toppings: number;
}> {
	const { data, error } = await supabase.functions.invoke('sync-menu', {
		method: 'POST',
		body: {}
	});
	if (error) {
		const context = (error as { context?: Response }).context;
		const body = context ? await context.json().catch(() => null) : null;
		throw new Error(body?.error ?? 'Sinkron menu gagal. Periksa koneksi internet.');
	}
	return data;
}
