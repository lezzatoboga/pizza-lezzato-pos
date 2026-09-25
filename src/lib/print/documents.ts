// Tiket dapur & struk dari data transaksi (RPC get_transaction_print_data).
// Kertas 58mm = 32 karakter per baris; huruf ukuran normal, jarak baris rapat
// (COMPACT_LINE_SPACING di escpos.ts).
import type { ReceiptSettings } from '$lib/pos/data';
import { EscPos } from './escpos';
import { writeReceiptFooter, writeReceiptHeader } from './receipt-template';

export type PrintItem = {
	item_type: 'product' | 'package';
	qty: number;
	product_name: string;
	variant_name: string | null;
	unit_price: number;
	subtotal_item: number;
	notes: string | null;
	package_items: string[] | null;
	package_choices: { key: string; label: string; value: string }[] | null;
	package_note: string | null;
	addons: { name: string; qty: number; unit_price: number }[];
};

export type PrintData = {
	id: string;
	outlet_id: string;
	transaction_number: string;
	created_at: string;
	channel: 'admin_toko' | 'website' | 'marketplace';
	sales_type: 'dine_in' | 'take_away' | 'delivery';
	status: 'active' | 'voided';
	platform_name: string | null;
	customer_name: string | null;
	delivery_address: string | null;
	delivery_patokan: string | null;
	notes: string | null;
	cashier_name: string | null;
	courier_type: string | null;
	courier_name: string | null;
	subtotal: number;
	discount_code: string | null;
	discount_amount: number;
	manual_discount_type: 'percent' | 'amount' | null;
	manual_discount_value: number | null;
	manual_discount_amount: number | null;
	shipping_cost: number;
	total: number;
	payment_status: 'unpaid' | 'paid';
	payment_method_name: string | null;
	payment_is_cash: boolean | null;
	bank_name: string | null;
	amount_paid: number | null;
	change_amount: number | null;
	kitchen_ticket_print_count: number;
	receipt_print_count: number;
	items: PrintItem[];
};

const SALES_TYPE_TEXT: Record<PrintData['sales_type'], string> = {
	dine_in: 'DINE-IN',
	take_away: 'TAKE AWAY',
	delivery: 'DELIVERY'
};

// Angka rupiah ringkas untuk kertas sempit: 206000 → "Rp206.000".
const rp = (value: number) => 'Rp' + Math.round(value).toLocaleString('id-ID');

const dateTime = (iso: string) => {
	const d = new Date(iso);
	const date = d.toLocaleDateString('id-ID', {
		day: '2-digit',
		month: '2-digit',
		year: '2-digit',
		timeZone: 'Asia/Jakarta'
	});
	const time = d.toLocaleTimeString('id-ID', {
		hour: '2-digit',
		minute: '2-digit',
		timeZone: 'Asia/Jakarta'
	});
	return { date, time: time.replace('.', ':') };
};

function reprintBanner(doc: EscPos) {
	doc.align('center').bold(true).line('*** CETAK ULANG ***').bold(false).align('left');
}

// Isi item bersama (tanpa harga) — dipakai tiket dapur & struk.
function writeItemDetails(doc: EscPos, item: PrintItem, kitchen: boolean) {
	for (const a of item.addons) doc.wrap(`+ ${a.name}${a.qty > 1 ? ` x${a.qty}` : ''}`, 3);
	if (item.item_type === 'package') {
		if (kitchen) for (const p of item.package_items ?? []) doc.wrap(`- ${p}`, 3);
		for (const c of item.package_choices ?? []) {
			const text = `${c.label}: ${kitchen ? c.value.toUpperCase() : c.value}`;
			if (kitchen) doc.bold(true).wrap(text, 3).bold(false);
			else doc.wrap(text, 3);
		}
		if (item.package_note) doc.wrap(item.package_note, 3);
	}
	if (item.notes) doc.wrap(`"${item.notes}"`, 3);
}

// ------------------------------------------------------------------ tiket dapur

export function kitchenTicket(data: PrintData): Uint8Array {
	const doc = new EscPos();
	if (data.kitchen_ticket_print_count > 0) reprintBanner(doc);

	const { time } = dateTime(data.created_at);
	doc.rule('=');
	doc.pair(data.transaction_number, time);
	doc.align('center').size(2).bold(true).line(SALES_TYPE_TEXT[data.sales_type]).size(1).bold(false);

	if (data.channel === 'marketplace') {
		// Nama platform + kode pesanan huruf besar.
		doc.line((data.platform_name ?? 'Marketplace').toUpperCase());
		if (data.customer_name)
			doc.size(2).bold(true).wrap(data.customer_name.toUpperCase(), 0, 16).size(1).bold(false);
	} else {
		doc.line(data.channel === 'website' ? 'Website' : 'Admin toko');
		if (data.customer_name) doc.bold(true).wrap(data.customer_name).bold(false);
	}
	doc.align('left').rule();

	for (const item of data.items) {
		doc.size(1, 2).bold(true).wrap(`${item.qty}x ${item.product_name}`).size(1).bold(false);
		if (item.variant_name) doc.line(`   ${item.variant_name.toUpperCase()}`);
		writeItemDetails(doc, item, true);
	}

	if (data.notes) {
		doc.rule();
		doc.wrap(`Catatan: ${data.notes}`);
	}
	doc.rule('=');
	return doc.cut().toBytes();
}

// ------------------------------------------------------------------ struk

export function receipt(data: PrintData, settings: ReceiptSettings | null): Uint8Array {
	const doc = new EscPos();
	if (settings) writeReceiptHeader(doc, settings);
	if (data.receipt_print_count > 0) reprintBanner(doc);

	const { date, time } = dateTime(data.created_at);
	doc.rule('=');
	doc.line(data.transaction_number);
	doc.pair(`${date} ${time}`, data.cashier_name ? `Kasir: ${data.cashier_name}` : '');

	const channel =
		data.channel === 'marketplace'
			? (data.platform_name ?? 'Marketplace')
			: data.channel === 'website'
				? 'Website'
				: 'Admin toko';
	const salesType =
		data.sales_type === 'dine_in'
			? 'Dine-in'
			: data.sales_type === 'take_away'
				? 'Take away'
				: 'Delivery';
	doc.line(`${channel} - ${salesType}`);
	// Nomor HP pelanggan sengaja tidak dicetak.
	if (data.customer_name) doc.wrap(data.customer_name);
	if (data.sales_type === 'delivery' && data.delivery_address) {
		doc.wrap(data.delivery_address + (data.delivery_patokan ? ` (${data.delivery_patokan})` : ''));
	}
	if (data.courier_name) doc.line(`Kurir: ${data.courier_name}`);
	doc.rule();

	for (const item of data.items) {
		const name = `${item.qty}x ${item.product_name}${item.variant_name ? ` (${item.variant_name})` : ''}`;
		const hasDetails =
			item.addons.length > 0 ||
			(item.package_choices?.length ?? 0) > 0 ||
			!!item.package_note ||
			!!item.notes;
		if (hasDetails) {
			doc.wrap(name);
			writeItemDetails(doc, item, false);
			doc.pair('', rp(item.subtotal_item));
		} else {
			doc.pair(name, rp(item.subtotal_item));
		}
	}
	doc.rule();

	doc.pair('Subtotal', rp(data.subtotal));
	if (data.discount_amount > 0) {
		doc.pair(
			data.discount_code ? `Voucher ${data.discount_code}` : 'Voucher',
			'-' + rp(data.discount_amount)
		);
	}
	if (data.manual_discount_amount) {
		const label =
			data.manual_discount_type === 'percent'
				? `Diskon ${Number(data.manual_discount_value)}%`
				: 'Diskon';
		doc.pair(label, '-' + rp(data.manual_discount_amount));
	}
	if (data.sales_type === 'delivery' && data.channel !== 'marketplace')
		doc.pair('Ongkir', rp(data.shipping_cost));
	doc.bold(true).pair('TOTAL', rp(data.total)).bold(false);
	doc.rule();

	if (data.payment_status === 'paid') {
		const method = `${data.payment_method_name ?? 'Bayar'}${data.bank_name ? ` ${data.bank_name}` : ''}`;
		if (data.payment_is_cash) {
			doc.pair(method, rp(data.amount_paid ?? data.total));
			doc.pair('Kembali', rp(data.change_amount ?? 0));
		} else {
			doc.pair(method, rp(data.total));
		}
		doc.align('center').size(2).bold(true).line('LUNAS').size(1).bold(false).align('left');
	} else {
		doc.align('center').size(2).bold(true).line('BELUM LUNAS').size(1).bold(false).align('left');
	}

	if (settings) writeReceiptFooter(doc, settings);
	return doc.cut().toBytes();
}
