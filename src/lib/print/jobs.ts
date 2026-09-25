// Cetak tiket dapur & struk untuk satu transaksi, lalu catat di database.
// Urutan: ambil data → susun dokumen → kirim ke printer → catat. Pencatatan
// dilakukan SETELAH terkirim, jadi penanda "CETAK ULANG" hanya muncul kalau
// cetakan sebelumnya benar-benar sampai ke printer.
import { supabase } from '$lib/supabase/client';
import { loadReceiptSettings } from '$lib/pos/data';
import { kitchenTicket, receipt, type PrintData } from './documents';
import { PrintError, printTo } from './printer';

async function loadPrintData(transactionId: string): Promise<PrintData> {
	const { data, error } = await supabase.rpc('get_transaction_print_data', {
		p_transaction_id: transactionId
	});
	if (error) throw new PrintError(error.message.replace(/^[A-Z_]+:\s*/, ''));
	return data as PrintData;
}

async function mark(fn: 'mark_kitchen_ticket_printed' | 'mark_receipt_printed', id: string) {
	const { error } = await supabase.rpc(fn, { p_transaction_id: id });
	if (error) {
		throw new PrintError(
			`Sudah tercetak, tapi gagal dicatat: ${error.message.replace(/^[A-Z_]+:\s*/, '')}`
		);
	}
}

export async function printKitchenTicket(transactionId: string): Promise<{ reprint: boolean }> {
	const data = await loadPrintData(transactionId);
	if (data.status !== 'active') throw new PrintError('Transaksi sudah dibatalkan.');
	await printTo('kitchen', kitchenTicket(data));
	await mark('mark_kitchen_ticket_printed', transactionId);
	return { reprint: data.kitchen_ticket_print_count > 0 };
}

export function needsCourier(data: Pick<PrintData, 'sales_type' | 'channel'>) {
	return (
		data.sales_type === 'delivery' && (data.channel === 'admin_toko' || data.channel === 'website')
	);
}

export async function printReceipt(
	transactionId: string
): Promise<{ reprint: boolean; paid: boolean }> {
	const data = await loadPrintData(transactionId);
	if (data.status !== 'active') throw new PrintError('Transaksi sudah dibatalkan.');
	// Aturan yang sama dicek ulang di server saat pencatatan.
	if (needsCourier(data) && !data.courier_type) {
		throw new PrintError('Tentukan kurir pengantar sebelum mencetak struk.');
	}
	const settings = await loadReceiptSettings(data.outlet_id).catch(() => null);
	await printTo('cashier', receipt(data, settings));
	await mark('mark_receipt_printed', transactionId);
	return { reprint: data.receipt_print_count > 0, paid: data.payment_status === 'paid' };
}
