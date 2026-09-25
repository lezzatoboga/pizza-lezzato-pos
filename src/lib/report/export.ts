// Ekspor laporan ke CSV / Excel (.xlsx), dibuat di browser dari data yang sudah
// difilter server. Di aplikasi Android (APK) unduhan file tidak didukung —
// halaman laporan menampilkan pesan agar ekspor dari browser laptop/HP.

export type Cell = string | number | null | undefined;

export type Table = {
	name: string; // nama sheet Excel (maks 31 karakter)
	columns: { label: string; width?: number; money?: boolean }[];
	rows: Cell[][];
	// Baris total di bawah (ditebalkan di Excel)
	footer?: Cell[];
};

function csvCell(value: Cell): string {
	if (value === null || value === undefined) return '';
	const s = String(value);
	return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

export function tableToCsv(table: Table): string {
	const lines = [table.columns.map((c) => c.label), ...table.rows];
	if (table.footer) lines.push(table.footer);
	// BOM supaya Excel membaca UTF-8 dengan benar
	return '﻿' + lines.map((row) => row.map(csvCell).join(',')).join('\r\n') + '\r\n';
}

function saveBlob(blob: Blob, fileName: string) {
	const url = URL.createObjectURL(blob);
	const a = document.createElement('a');
	a.href = url;
	a.download = fileName;
	document.body.appendChild(a);
	a.click();
	a.remove();
	setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

export function downloadCsv(table: Table, fileName: string) {
	saveBlob(new Blob([tableToCsv(table)], { type: 'text/csv;charset=utf-8' }), fileName);
}

const MONEY_FORMAT = '#,##0';

export async function downloadXlsx(
	tables: Table[],
	fileName: string,
	info: [string, string][] = []
) {
	// Dimuat hanya saat ekspor supaya tidak membebani halaman kasir.
	const { default: writeXlsxFile } = await import('write-excel-file/browser');

	const header = (label: string) => ({
		value: label,
		fontWeight: 'bold' as const,
		backgroundColor: '#F3E5E3'
	});

	const sheets = tables.map((t) => {
		const cell = (value: Cell, i: number, bold = false) => {
			if (value === null || value === undefined || value === '') return null;
			const base = bold ? { fontWeight: 'bold' as const } : {};
			if (typeof value === 'number') {
				return {
					...base,
					value,
					type: Number,
					...(t.columns[i]?.money ? { format: MONEY_FORMAT } : {})
				};
			}
			return { ...base, value: String(value), type: String };
		};
		return {
			sheet: t.name.slice(0, 31),
			stickyRowsCount: 1,
			columns: t.columns.map((c) => ({ width: c.width ?? 14 })),
			data: [
				t.columns.map((c) => header(c.label)),
				...t.rows.map((r) => r.map((v, i) => cell(v, i))),
				...(t.footer ? [t.footer.map((v, i) => cell(v, i, true))] : [])
			]
		};
	});

	if (info.length) {
		sheets.push({
			sheet: 'Info',
			stickyRowsCount: 0,
			columns: [{ width: 22 }, { width: 60 }],
			data: info.map(([k, v]) => [
				{ value: k, fontWeight: 'bold' as const, type: String },
				{ value: v, type: String }
			]) as never
		});
	}

	const blob = await writeXlsxFile(sheets as Parameters<typeof writeXlsxFile>[0]).toBlob();
	saveBlob(blob, fileName);
}
