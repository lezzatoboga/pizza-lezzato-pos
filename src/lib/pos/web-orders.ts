// Pesanan website (jembatan, docs/JEMBATAN-PESANAN.md). Data ditarik Edge
// Function web-orders-sync ke tabel web_orders + transaksi POS channel 'website';
// aksi kasir lewat RPC (confirm/ready/finish) dan Edge Function web-order-edit.
import { supabase } from '$lib/supabase/client';
import type { CourierValue } from './types';

function unwrap<T>(result: { data: T | null; error: { message: string } | null }): T {
	if (result.error) throw new Error(result.error.message);
	return result.data as T;
}

async function invokeError(error: unknown, fallback: string): Promise<Error> {
	const context = (error as { context?: Response }).context;
	const body = context ? await context.json().catch(() => null) : null;
	return new Error(body?.error ?? fallback);
}

export type WebOrderType = 'delivery' | 'takeaway' | 'dinein';

export const ORDER_TYPE_LABEL: Record<WebOrderType, string> = {
	delivery: 'Delivery',
	takeaway: 'Pick Up',
	dinein: 'Dine-in'
};

// Header pesanan website (baris pos.v_pesanan).
export type WebHeader = {
	id: string;
	order_code: string;
	created_at: string;
	status: string;
	order_type: WebOrderType;
	recipient_name: string;
	recipient_phone: string;
	address: string | null;
	patokan: string | null;
	alamat_lat: number | string | null;
	alamat_lng: number | string | null;
	note: string | null;
	subtotal: number;
	discount: number;
	voucher_code: string | null;
	ongkir_rupiah: number | null;
	diskon_ongkir: number;
	total: number;
	jarak_tagih_km: number | string | null;
};

// Item pesanan website (baris pos.v_item_pesanan).
export type WebItem = {
	id: string;
	menu_id: string;
	name: string;
	unit_price: number;
	qty: number;
	options: Record<string, unknown>;
};

export type WebTxItem = {
	id: string;
	item_type: 'product' | 'package';
	product_id: string;
	product_name_snapshot: string;
	variant_id: string | null;
	variant_name_snapshot: string | null;
	unit_price: number;
	qty: number;
	subtotal_item: number;
	notes: string | null;
	source_line_ref: string | null;
	mapping_warning: string | null;
	package_choices_snapshot: { key: string; label: string; value: string }[] | null;
	transaction_item_addons: {
		addon_id: string;
		addon_name_snapshot: string;
		qty: number;
		unit_price: number;
	}[];
};

export type WebOrderStatus =
	'baru' | 'diterima' | 'diproses' | 'siap_diambil' | 'sedang_diantar' | 'selesai';

export type WebTransaction = {
	id: string;
	transaction_number: string;
	sales_type: 'dine_in' | 'take_away' | 'delivery';
	order_status: WebOrderStatus;
	status: 'active' | 'voided';
	payment_status: 'paid' | 'unpaid';
	subtotal: number;
	discount_amount: number;
	discount_code: string | null;
	shipping_cost: number;
	total: number;
	is_locked: boolean;
	shift_id: string | null;
	kitchen_ticket_print_count: number;
	receipt_print_count: number;
	receipt_printed_status: 'belum_lunas' | 'lunas' | null;
	courier_type: CourierValue['type'] | null;
	courier_user_id: string | null;
	courier_id: string | null;
	void_reason: string | null;
	voided_at: string | null;
	void_source: 'pos' | 'website';
	last_edited_at: string | null;
	original_order_snapshot: { header: WebHeader; items: WebItem[] } | null;
	transaction_items: WebTxItem[];
};

export type OutboxRow = {
	id: number;
	status: string;
	created_at: string;
	sent_at: string | null;
	failed_at: string | null;
	last_error: string | null;
	attempts: number;
	next_attempt_at: string;
};

export type WebOrder = {
	id: string;
	order_code: string;
	order_type: WebOrderType;
	web_status: string;
	header: WebHeader;
	items: WebItem[];
	menunggu_admin: boolean;
	terkunci_edit: boolean;
	diubah_di_pos: boolean;
	metode_bayar: string | null;
	status_bayar: string | null;
	first_seen_at: string;
	opened_at: string | null;
	header_notice: string | null;
	cancel_notice: string | null;
	void_slip_pending: boolean;
	transaction_id: string | null;
	transactions: WebTransaction | null;
	web_status_outbox: OutboxRow[];
};

const ORDER_SELECT = `id, order_code, order_type, web_status, header, items, menunggu_admin, terkunci_edit,
	diubah_di_pos, metode_bayar, status_bayar, first_seen_at, opened_at, header_notice, cancel_notice,
	void_slip_pending, transaction_id,
	transactions(id, transaction_number, sales_type, order_status, status, payment_status, subtotal,
		discount_amount, discount_code, shipping_cost, total, is_locked, shift_id, kitchen_ticket_print_count,
		receipt_print_count, receipt_printed_status, courier_type, courier_user_id, courier_id,
		void_reason, voided_at, void_source, last_edited_at, original_order_snapshot,
		transaction_items(id, item_type, product_id, product_name_snapshot, variant_id, variant_name_snapshot,
			unit_price, qty, subtotal_item, notes, source_line_ref, mapping_warning, package_choices_snapshot,
			created_at, transaction_item_addons(addon_id, addon_name_snapshot, qty, unit_price))),
	web_status_outbox(id, status, created_at, sent_at, failed_at, last_error, attempts, next_attempt_at)`;

function sortChildren(o: WebOrder): WebOrder {
	o.web_status_outbox?.sort((a, b) => a.id - b.id);
	o.transactions?.transaction_items?.sort((a, b) =>
		String((a as unknown as { created_at: string }).created_at).localeCompare(
			String((b as unknown as { created_at: string }).created_at)
		)
	);
	return o;
}

// Pesanan 3 hari terakhir (RLS menyaring sesuai izin).
export async function loadWebOrders(): Promise<WebOrder[]> {
	const since = new Date(Date.now() - 3 * 86_400_000).toISOString();
	const rows = unwrap(
		await supabase
			.from('web_orders')
			.select(ORDER_SELECT)
			.gte('first_seen_at', since)
			.order('first_seen_at', { ascending: false })
			.limit(150)
	) as unknown as WebOrder[];
	return rows.map(sortChildren);
}

export type BridgeState = {
	last_run_at: string | null;
	last_ok_at: string | null;
	last_error: string | null;
	view_empty: boolean;
	inactive_reason: string | null;
};

export async function loadBridgeState(): Promise<BridgeState | null> {
	return unwrap(
		await supabase
			.from('web_bridge_state')
			.select('last_run_at, last_ok_at, last_error, view_empty, inactive_reason')
			.maybeSingle()
	) as BridgeState | null;
}

// Ringkasan untuk notifikasi di semua halaman.
export type WebAlerts = {
	unopened: { id: string; order_code: string; order_type: WebOrderType }[];
	voidSlips: { id: string; order_code: string; transaction_id: string | null }[];
	notices: number;
};

export async function loadWebAlerts(): Promise<WebAlerts> {
	const [unopened, slips, notices] = await Promise.all([
		supabase
			.from('web_orders')
			.select('id, order_code, order_type')
			.is('opened_at', null)
			.order('first_seen_at'),
		supabase
			.from('web_orders')
			.select('id, order_code, transaction_id')
			.eq('void_slip_pending', true),
		supabase
			.from('web_orders')
			.select('id', { count: 'exact', head: true })
			.not('cancel_notice', 'is', null)
	]);
	return {
		unopened: unwrap(unopened) as WebAlerts['unopened'],
		voidSlips: unwrap(slips) as WebAlerts['voidSlips'],
		notices: notices.count ?? 0
	};
}

export async function syncWebOrders(): Promise<Record<string, unknown>> {
	const { data, error } = await supabase.functions.invoke('web-orders-sync', {
		method: 'POST',
		body: {}
	});
	if (error)
		throw await invokeError(error, 'Gagal mengecek pesanan website. Periksa koneksi internet.');
	return data as Record<string, unknown>;
}

export async function openWebOrder(id: string): Promise<void> {
	unwrap(await supabase.rpc('open_web_order', { p_order_id: id }));
}

export async function confirmWebOrder(transactionId: string): Promise<void> {
	unwrap(await supabase.rpc('confirm_web_order', { p_transaction_id: transactionId }));
}

export async function readyWebOrder(transactionId: string): Promise<void> {
	unwrap(await supabase.rpc('ready_web_order', { p_transaction_id: transactionId }));
}

export async function finishWebOrder(transactionId: string): Promise<void> {
	unwrap(await supabase.rpc('finish_web_order', { p_transaction_id: transactionId }));
}

export async function voidSlipDone(id: string): Promise<void> {
	unwrap(await supabase.rpc('web_void_slip_done', { p_order_id: id }));
}

export type WebEditPayload = {
	lines: { ref: string; qty: number }[];
	new_items: {
		item_type: 'product' | 'package';
		product_id: string;
		variant_id: string | null;
		qty: number;
		notes?: string;
		toppings: { id: string; qty: number }[];
		choices?: Record<string, string>;
	}[];
	shipping_cost?: number;
};

export async function editWebOrder(transactionId: string, payload: WebEditPayload): Promise<void> {
	const { error } = await supabase.functions.invoke('web-order-edit', {
		method: 'POST',
		body: { transaction_id: transactionId, payload }
	});
	if (error) throw await invokeError(error, 'Perubahan tidak tersimpan. Periksa koneksi internet.');
}

// ---------------------------------------------------------------- tampilan

export const STATUS_LABEL: Record<WebOrderStatus, string> = {
	baru: 'Baru',
	diterima: 'Diterima',
	diproses: 'Diproses',
	siap_diambil: 'Siap',
	sedang_diantar: 'Sedang diantar',
	selesai: 'Selesai'
};

// Label tombol "Siap" sesuai tipe pesanan.
export const READY_LABEL: Record<WebOrderType, string> = {
	takeaway: 'Siap diambil',
	dinein: 'Siap disajikan',
	delivery: 'Antar sekarang'
};

export function statusText(o: WebOrder): string {
	const tx = o.transactions;
	if (!tx) return o.web_status === 'batal' ? 'Dibatalkan' : o.web_status;
	if (tx.status === 'voided')
		return tx.void_source === 'website' ? 'Dibatalkan di website' : 'Dibatalkan';
	if (tx.order_status === 'siap_diambil' && o.order_type === 'dinein') return 'Siap disajikan';
	if (tx.order_status === 'siap_diambil') return 'Siap diambil';
	return STATUS_LABEL[tx.order_status];
}

// Status pengiriman ke website (antrean).
export function outboxState(o: WebOrder): 'ok' | 'menunggu' | 'gagal' {
	if (o.web_status_outbox.some((r) => r.failed_at && r.last_error !== 'dibatalkan di website'))
		return 'gagal';
	if (o.web_status_outbox.some((r) => !r.sent_at && !r.failed_at)) return 'menunggu';
	return 'ok';
}

export const OUTBOX_ERROR_TEXT: Record<string, string> = {
	sebelum_go_live: 'jembatan website tidak aktif',
	transisi_ditolak: 'status ditolak website',
	pesanan_tidak_ada: 'pesanan tidak ada di website',
	belum_lunas: 'pembayaran online belum lunas',
	sudah_lunas_terkunci: 'pesanan sudah lunas online',
	pembayaran_berjalan: 'pembayaran online sedang berjalan',
	status_tidak_dikenal: 'status tidak dikenal'
};

export function mapsUrl(h: WebHeader): string | null {
	if (h.alamat_lat == null || h.alamat_lng == null) return null;
	return `https://www.google.com/maps/search/?api=1&query=${h.alamat_lat},${h.alamat_lng}`;
}
