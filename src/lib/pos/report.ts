// Laporan penjualan & riwayat shift — pembungkus RPC report_* (hak akses dicek di server).
import { supabase } from '$lib/supabase/client';
import type { ShiftSummary } from './data';

function unwrap<T>(result: { data: T | null; error: { message: string } | null }): T {
	if (result.error) throw new Error(result.error.message);
	return result.data as T;
}

export type ReportFilters = {
	date_from: string;
	date_to: string;
	include_unpaid: boolean;
	channel: string;
	platform_id: string;
	sales_type: string;
	payment_method_id: string;
	bank_account_id: string;
	cashier_id: string;
	courier: string;
	product_id: string;
	category: string;
};

export type GroupBy =
	| 'date'
	| 'channel'
	| 'platform'
	| 'sales_type'
	| 'payment_method'
	| 'bank'
	| 'cashier'
	| 'courier'
	| 'category'
	| 'product'
	| 'variant';

export const GROUP_LABEL: Record<GroupBy, string> = {
	date: 'Tanggal',
	channel: 'Channel',
	platform: 'Platform',
	sales_type: 'Tipe penjualan',
	payment_method: 'Metode bayar',
	bank: 'Rekening',
	cashier: 'Kasir',
	courier: 'Kurir',
	category: 'Kategori',
	product: 'Produk',
	variant: 'Produk + ukuran'
};

export const ITEM_GROUPS: GroupBy[] = ['category', 'product', 'variant'];

export type TxMetrics = {
	tx_count: number;
	subtotal: number;
	voucher_discount: number;
	manual_discount: number;
	markup: number;
	shipping: number;
	net_sales: number;
	total: number;
	items_qty: number;
};

export type GroupKey = { k: string; l: string };

export type SummaryRow =
	| ({ keys: GroupKey[] } & TxMetrics)
	| { keys: GroupKey[]; qty: number; value: number; tx_count: number };

export type ReportSummary = {
	level: 'transaction' | 'item' | null;
	group_by: GroupBy[];
	totals: TxMetrics & { topping_qty: number };
	rows: SummaryRow[];
	daily: { date: string; net_sales: number; tx_count: number }[];
	voided: { tx_count: number; total: number };
	unpaid: { tx_count: number; total: number };
};

export type ReportView = 'included' | 'voided';

export type ReportTxRow = {
	id: string;
	transaction_number: string;
	transaction_date: string;
	created_at: string;
	paid_at: string | null;
	channel: string;
	platform: string | null;
	sales_type: string;
	customer_name: string | null;
	customer_phone: string | null;
	cashier: string | null;
	payment_status: 'paid' | 'unpaid';
	payment_method: string | null;
	bank: string | null;
	courier: string;
	courier_type: string | null;
	distance_km: number | null;
	subtotal: number;
	discount_code: string | null;
	voucher_discount: number;
	manual_discount: number;
	manual_discount_reason: string | null;
	markup_percent: number | null;
	markup: number;
	shipping: number;
	net_sales: number;
	total: number;
	items_qty: number;
	status: 'active' | 'voided';
	voided_at: string | null;
	void_reason: string | null;
	voided_by: string | null;
	void_requested_by: string | null;
	notes: string | null;
};

export type ReportTxDetail = ReportTxRow & {
	delivery_address: string | null;
	delivery_patokan: string | null;
	amount_paid: number | null;
	change_amount: number | null;
	items: {
		item_type: 'product' | 'package';
		qty: number;
		product_name: string;
		variant_name: string | null;
		unit_price: number;
		subtotal_item: number;
		notes: string | null;
		package_choices: { key: string; label: string; value: string }[] | null;
		addons: { name: string; qty: number; unit_price: number }[];
	}[];
};

export type ReportExportItem = {
	transaction_number: string;
	transaction_date: string;
	channel: string;
	platform: string | null;
	item_type: 'product' | 'package';
	product_id: string;
	product_name: string;
	variant_name: string | null;
	category: string;
	qty: number;
	price_snapshot: number;
	unit_price: number;
	item_value: number;
	topping_value: number;
	subtotal_item: number;
	toppings: string | null;
	package_choices: string | null;
	notes: string | null;
};

export type FilterOptions = {
	platforms: { id: string; name: string }[];
	payment_methods: { id: string; name: string }[];
	bank_accounts: { id: string; name: string }[];
	users: { id: string; name: string }[];
	couriers: { id: string; name: string }[];
	categories: { slug: string; name: string }[];
	products: { id: string; name: string }[];
};

export type ShiftHistoryRow = {
	id: string;
	status: 'open' | 'counting' | 'closed';
	opening_time: string;
	closing_time: string | null;
	opened_by: string | null;
	counted_by: string | null;
	closed_by: string | null;
	opening_balance: number;
	notes: string | null;
	tx_count: number;
	voided_count: number;
	// Tidak ada selama shift masih terbuka (hitung buta).
	cash_sales?: number;
	cash_in?: number;
	cash_out?: number;
	expected?: number;
	counted?: number;
	difference?: number;
	sales_total?: number;
};

// Filter kosong ('') tidak dikirim ke server.
function payload(filters: ReportFilters) {
	return Object.fromEntries(Object.entries(filters).filter(([, v]) => v !== '')) as Record<
		string,
		string | boolean
	>;
}

export async function loadFilterOptions(): Promise<FilterOptions> {
	return unwrap(await supabase.rpc('report_filter_options')) as FilterOptions;
}

export async function loadSummary(
	filters: ReportFilters,
	groupBy: GroupBy[]
): Promise<ReportSummary> {
	return unwrap(
		await supabase.rpc('report_summary', { p_filters: payload(filters), p_group_by: groupBy })
	) as ReportSummary;
}

export async function loadReportTransactions(
	filters: ReportFilters,
	view: ReportView,
	offset: number,
	limit = 50
): Promise<{ total_count: number; rows: ReportTxRow[] }> {
	return unwrap(
		await supabase.rpc('report_transactions', {
			p_filters: payload(filters),
			p_view: view,
			p_limit: limit,
			p_offset: offset
		})
	) as { total_count: number; rows: ReportTxRow[] };
}

export async function loadReportTransaction(id: string): Promise<ReportTxDetail> {
	return unwrap(
		await supabase.rpc('report_transaction', { p_transaction_id: id })
	) as ReportTxDetail;
}

export async function loadReportExport(
	filters: ReportFilters,
	view: ReportView
): Promise<{ transactions: ReportTxRow[]; items: ReportExportItem[] }> {
	return unwrap(
		await supabase.rpc('report_export', { p_filters: payload(filters), p_view: view })
	) as { transactions: ReportTxRow[]; items: ReportExportItem[] };
}

export async function loadShiftHistory(from: string, to: string): Promise<ShiftHistoryRow[]> {
	return unwrap(
		await supabase.rpc('report_shifts', { p_date_from: from, p_date_to: to })
	) as ShiftHistoryRow[];
}

export async function loadShiftDetail(id: string): Promise<ShiftSummary> {
	return unwrap(await supabase.rpc('get_shift_summary', { p_shift_id: id })) as ShiftSummary;
}

// ---------------------------------------------------------------------
// Rentang tanggal (zona Asia/Jakarta)
// ---------------------------------------------------------------------
export type DatePreset = 'today' | 'yesterday' | 'last7' | 'this_month' | 'last_month' | 'custom';

export const DATE_PRESETS: { code: DatePreset; label: string }[] = [
	{ code: 'today', label: 'Hari ini' },
	{ code: 'yesterday', label: 'Kemarin' },
	{ code: 'last7', label: '7 hari' },
	{ code: 'this_month', label: 'Bulan ini' },
	{ code: 'last_month', label: 'Bulan lalu' },
	{ code: 'custom', label: 'Pilih tanggal' }
];

// Aritmetika tanggal kalender pada string YYYY-MM-DD (UTC, bebas zona waktu perangkat).
const iso = (d: Date) => d.toISOString().slice(0, 10);
const parse = (s: string) => new Date(`${s}T00:00:00Z`);

export function addDays(date: string, days: number): string {
	const d = parse(date);
	d.setUTCDate(d.getUTCDate() + days);
	return iso(d);
}

export function presetRange(preset: DatePreset, today: string): { from: string; to: string } {
	const t = parse(today);
	switch (preset) {
		case 'yesterday': {
			const y = addDays(today, -1);
			return { from: y, to: y };
		}
		case 'last7':
			return { from: addDays(today, -6), to: today };
		case 'this_month':
			return { from: iso(new Date(Date.UTC(t.getUTCFullYear(), t.getUTCMonth(), 1))), to: today };
		case 'last_month':
			return {
				from: iso(new Date(Date.UTC(t.getUTCFullYear(), t.getUTCMonth() - 1, 1))),
				to: iso(new Date(Date.UTC(t.getUTCFullYear(), t.getUTCMonth(), 0)))
			};
		default:
			return { from: today, to: today };
	}
}

const dayFormat = new Intl.DateTimeFormat('id-ID', {
	weekday: 'short',
	day: 'numeric',
	month: 'short',
	year: 'numeric',
	timeZone: 'UTC'
});
const shortDayFormat = new Intl.DateTimeFormat('id-ID', {
	day: 'numeric',
	month: 'short',
	timeZone: 'UTC'
});

// "Sab, 26 Sep 2026"
export const formatDay = (date: string) => dayFormat.format(parse(date));
// "26 Sep"
export const formatShortDay = (date: string) => shortDayFormat.format(parse(date));

export const dateTimeOf = (value: string) =>
	new Date(value).toLocaleString('id-ID', {
		day: 'numeric',
		month: 'short',
		year: 'numeric',
		hour: '2-digit',
		minute: '2-digit',
		timeZone: 'Asia/Jakarta'
	});

// Untuk file ekspor: "2026-09-17 01:03" (WIB) — bisa diurutkan di Excel.
const exportFormat = new Intl.DateTimeFormat('sv-SE', {
	year: 'numeric',
	month: '2-digit',
	day: '2-digit',
	hour: '2-digit',
	minute: '2-digit',
	timeZone: 'Asia/Jakarta'
});
export const exportDateTime = (value: string | null) =>
	value ? exportFormat.format(new Date(value)) : '';

// Label kunci pengelompokan untuk tampilan (tanggal diformat).
export const groupLabel = (dim: GroupBy, key: GroupKey) =>
	dim === 'date' ? formatDay(key.k) : key.l;
