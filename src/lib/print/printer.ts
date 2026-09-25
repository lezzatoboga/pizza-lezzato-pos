// Kirim byte ESC/POS ke printer Bluetooth lewat plugin native aplikasi Android
// (android/app/src/main/java/com/pizzalezzato/pos/EscPosPrinterPlugin.java).
// Hanya berfungsi di dalam APK Pizza Lezzato POS, bukan di browser biasa.
//
// Tiket dapur & struk diarahkan ke printer berbeda: pilihan printer per peran
// disimpan di perangkat ini (pairing Bluetooth juga berlaku per perangkat).
import { Capacitor, registerPlugin } from '@capacitor/core';
import { toBase64 } from './escpos';

export type BluetoothPrinter = { name: string; address: string };
export type PrinterRole = 'kitchen' | 'cashier';

export const PRINTER_ROLE_LABEL: Record<PrinterRole, string> = {
	kitchen: 'Printer dapur',
	cashier: 'Printer kasir'
};

interface EscPosPrinterPlugin {
	listPairedPrinters(): Promise<{ printers: BluetoothPrinter[] }>;
	print(options: { address: string; data: string }): Promise<void>;
}

const EscPosPrinter = registerPlugin<EscPosPrinterPlugin>('EscPosPrinter');

export function isNativeApp(): boolean {
	return Capacitor.isNativePlatform();
}

export async function listPairedPrinters(): Promise<BluetoothPrinter[]> {
	return (await EscPosPrinter.listPairedPrinters()).printers;
}

// ---------------------------------------------------------------- pilihan printer

const STORAGE_KEY = 'pos.printers';

export type PrinterAssignment = Record<PrinterRole, BluetoothPrinter | null>;

export function getPrinterAssignment(): PrinterAssignment {
	try {
		const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '{}');
		return { kitchen: saved.kitchen ?? null, cashier: saved.cashier ?? null };
	} catch {
		return { kitchen: null, cashier: null };
	}
}

export function assignPrinter(
	role: PrinterRole,
	printer: BluetoothPrinter | null
): PrinterAssignment {
	const next = { ...getPrinterAssignment(), [role]: printer };
	try {
		localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
	} catch {
		// penyimpanan tidak tersedia; pilihan hanya berlaku sampai aplikasi ditutup
	}
	return next;
}

// ---------------------------------------------------------------- cetak

export class PrintError extends Error {}

export async function printTo(role: PrinterRole, bytes: Uint8Array): Promise<void> {
	if (!isNativeApp()) {
		throw new PrintError('Cetak hanya bisa dari aplikasi Android Pizza Lezzato POS.');
	}
	const printer = getPrinterAssignment()[role];
	if (!printer) {
		throw new PrintError(`${PRINTER_ROLE_LABEL[role]} belum dipilih di Pengaturan → Printer.`);
	}
	try {
		await EscPosPrinter.print({ address: printer.address, data: toBase64(bytes) });
	} catch (e) {
		throw new PrintError(`${PRINTER_ROLE_LABEL[role]} (${printer.name}): ${(e as Error).message}`);
	}
}
