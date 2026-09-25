<script lang="ts">
	// Laporan penjualan (SPEC §5): Ringkasan & Detail dengan filter yang sama,
	// ekspor CSV/Excel, dan Riwayat shift. Semua angka dihitung di server.
	import { auth } from '$lib/auth/auth.svelte';
	import ReportTxDialog from '$lib/components/ReportTxDialog.svelte';
	import SalesChart from '$lib/components/SalesChart.svelte';
	import ShiftDetailDialog from '$lib/components/ShiftDetailDialog.svelte';
	import { friendlyError, jakartaToday, rupiah } from '$lib/format';
	import { CHANNEL_LABEL, SALES_TYPE_LABEL } from '$lib/pos/types';
	import {
		DATE_PRESETS,
		GROUP_LABEL,
		ITEM_GROUPS,
		dateTimeOf,
		exportDateTime,
		formatDay,
		groupLabel,
		loadFilterOptions,
		loadReportExport,
		loadReportTransactions,
		loadShiftHistory,
		loadSummary,
		presetRange,
		type DatePreset,
		type FilterOptions,
		type GroupBy,
		type ReportFilters,
		type ReportSummary,
		type ReportTxRow,
		type ReportView,
		type ShiftHistoryRow,
		type SummaryRow,
		type TxMetrics
	} from '$lib/pos/report';
	import { downloadCsv, downloadXlsx, type Cell, type Table } from '$lib/report/export';
	import { isNativeApp } from '$lib/print/printer';

	type Tab = 'summary' | 'detail' | 'shifts';

	const canSummary = $derived(auth.can('view_sales_report'));
	const canDetail = $derived(auth.can('view_transaction_detail'));
	const canExport = $derived(auth.can('export_report'));
	const canShifts = $derived(auth.can('view_finance_report'));

	const tabs = $derived(
		[
			canSummary && { code: 'summary' as Tab, label: 'Ringkasan' },
			canDetail && { code: 'detail' as Tab, label: 'Detail' },
			canShifts && { code: 'shifts' as Tab, label: 'Riwayat shift' }
		].filter((t): t is { code: Tab; label: string } => !!t)
	);

	let tab = $state<Tab | null>(null);
	$effect(() => {
		if (!tab || !tabs.some((t) => t.code === tab)) tab = tabs[0]?.code ?? null;
	});

	// ---------------- Filter ----------------
	const today = jakartaToday();
	const EMPTY: Omit<ReportFilters, 'date_from' | 'date_to'> = {
		include_unpaid: false,
		channel: '',
		platform_id: '',
		sales_type: '',
		payment_method_id: '',
		bank_account_id: '',
		cashier_id: '',
		courier: '',
		product_id: '',
		category: ''
	};

	let preset = $state<DatePreset>('today');
	let filters = $state<ReportFilters>({ date_from: today, date_to: today, ...EMPTY });
	let options = $state<FilterOptions | null>(null);
	let showFilters = $state(false);

	const dateError = $derived(
		!filters.date_from || !filters.date_to
			? 'Pilih tanggal awal dan akhir.'
			: filters.date_to < filters.date_from
				? 'Tanggal akhir sebelum tanggal awal.'
				: ''
	);

	$effect(() => {
		loadFilterOptions()
			.then((o) => (options = o))
			.catch(() => (options = null));
	});

	function setPreset(p: DatePreset) {
		preset = p;
		if (p === 'custom') return;
		const r = presetRange(p, today);
		filters.date_from = r.from;
		filters.date_to = r.to;
	}

	function resetFilters() {
		Object.assign(filters, EMPTY);
	}

	const nameOf = (list: { id: string; name: string }[] | undefined, id: string) =>
		list?.find((x) => x.id === id)?.name ?? '…';

	function courierName(key: string) {
		if (key === 'shopee_express') return 'Shopee Express';
		if (key === 'maxim') return 'Maxim';
		const [type, id] = key.split(':');
		return type === 'karyawan' ? nameOf(options?.users, id) : nameOf(options?.couriers, id);
	}

	// Filter aktif (selain tanggal) — untuk chip & lembar Info ekspor.
	const activeFilters = $derived(
		[
			filters.channel && {
				key: 'channel',
				label: 'Channel',
				value: CHANNEL_LABEL[filters.channel] ?? filters.channel
			},
			filters.platform_id && {
				key: 'platform_id',
				label: 'Platform',
				value: nameOf(options?.platforms, filters.platform_id)
			},
			filters.sales_type && {
				key: 'sales_type',
				label: 'Tipe',
				value: SALES_TYPE_LABEL[filters.sales_type] ?? filters.sales_type
			},
			filters.payment_method_id && {
				key: 'payment_method_id',
				label: 'Metode',
				value: nameOf(options?.payment_methods, filters.payment_method_id)
			},
			filters.bank_account_id && {
				key: 'bank_account_id',
				label: 'Rekening',
				value: nameOf(options?.bank_accounts, filters.bank_account_id)
			},
			filters.cashier_id && {
				key: 'cashier_id',
				label: 'Kasir',
				value: nameOf(options?.users, filters.cashier_id)
			},
			filters.courier && { key: 'courier', label: 'Kurir', value: courierName(filters.courier) },
			filters.category && {
				key: 'category',
				label: 'Kategori',
				value:
					options?.categories.find((c) => c.slug === filters.category)?.name ?? filters.category
			},
			filters.product_id && {
				key: 'product_id',
				label: 'Produk',
				value: nameOf(options?.products, filters.product_id)
			}
		].filter((f): f is { key: keyof ReportFilters; label: string; value: string } => !!f)
	);

	function clearFilter(key: keyof ReportFilters) {
		(filters as Record<string, unknown>)[key] = '';
	}

	const periodLabel = $derived(
		filters.date_from === filters.date_to
			? formatDay(filters.date_from)
			: `${formatDay(filters.date_from)} – ${formatDay(filters.date_to)}`
	);

	// ---------------- Ringkasan ----------------
	let group1 = $state<GroupBy | ''>('date');
	let group2 = $state<GroupBy | ''>('');
	let summary = $state<ReportSummary | null>(null);
	let summaryError = $state('');
	let summaryLoading = $state(false);
	let summaryReq = 0;

	const groups = $derived(
		[group1, group2].filter((g, i, a): g is GroupBy => !!g && a.indexOf(g) === i)
	);
	const GROUP_OPTIONS = Object.keys(GROUP_LABEL) as GroupBy[];

	$effect(() => {
		if (tab !== 'summary' || dateError) return;
		const f = $state.snapshot(filters);
		const g = [...groups];
		const req = ++summaryReq;
		summaryLoading = true;
		summaryError = '';
		loadSummary(f, g)
			.then((s) => req === summaryReq && (summary = s))
			.catch((e) => req === summaryReq && (summaryError = friendlyError(e)))
			.finally(() => req === summaryReq && (summaryLoading = false));
	});

	const isTxRow = (r: SummaryRow): r is SummaryRow & TxMetrics => 'net_sales' in r;
	const avg = (m: { net_sales: number; tx_count: number }) =>
		m.tx_count ? Math.round(m.net_sales / m.tx_count) : 0;
	const discount = (m: TxMetrics) => m.voucher_discount + m.manual_discount;

	// Kolom pertama hanya ditulis saat nilainya berganti (tampilan bertingkat).
	const showFirstKey = (rows: SummaryRow[], i: number) =>
		i === 0 || rows[i - 1].keys[0].k !== rows[i].keys[0].k;

	const itemTotals = $derived(
		summary?.level === 'item'
			? summary.rows.reduce(
					(t, r) => ('qty' in r ? { qty: t.qty + r.qty, value: t.value + r.value } : t),
					{ qty: 0, value: 0 }
				)
			: null
	);

	// ---------------- Detail ----------------
	let view = $state<ReportView>('included');
	let detailRows = $state<ReportTxRow[]>([]);
	let detailCount = $state(0);
	let detailError = $state('');
	let detailLoading = $state(false);
	let detailReq = 0;
	let openTx = $state<string | null>(null);

	async function loadDetail(reset: boolean) {
		const req = ++detailReq;
		detailLoading = true;
		detailError = '';
		try {
			const res = await loadReportTransactions(
				$state.snapshot(filters),
				view,
				reset ? 0 : detailRows.length
			);
			if (req !== detailReq) return;
			detailRows = reset ? res.rows : [...detailRows, ...res.rows];
			detailCount = res.total_count;
		} catch (e) {
			if (req === detailReq) detailError = friendlyError(e);
		} finally {
			if (req === detailReq) detailLoading = false;
		}
	}

	$effect(() => {
		if (tab !== 'detail' || dateError) return;
		JSON.stringify(filters);
		void view;
		detailRows = [];
		loadDetail(true);
	});

	function showVoided() {
		view = 'voided';
		tab = 'detail';
	}

	// ---------------- Riwayat shift ----------------
	let shifts = $state<ShiftHistoryRow[]>([]);
	let shiftError = $state('');
	let shiftLoading = $state(false);
	let openShift = $state<string | null>(null);
	let shiftReq = 0;

	$effect(() => {
		if (tab !== 'shifts' || dateError) return;
		const from = filters.date_from;
		const to = filters.date_to;
		const req = ++shiftReq;
		shiftLoading = true;
		shiftError = '';
		loadShiftHistory(from, to)
			.then((r) => req === shiftReq && (shifts = r))
			.catch((e) => req === shiftReq && (shiftError = friendlyError(e)))
			.finally(() => req === shiftReq && (shiftLoading = false));
	});

	// ---------------- Ekspor ----------------
	let exportBusy = $state(false);
	let exportMessage = $state('');
	let exportFailed = $state(false);

	function exportInfo(title: string): [string, string][] {
		return [
			['Laporan', title],
			['Periode', periodLabel],
			[
				'Transaksi',
				filters.include_unpaid
					? 'Lunas + belum lunas (transaksi batal tidak dihitung)'
					: 'Hanya lunas (transaksi batal tidak dihitung)'
			],
			[
				'Filter',
				activeFilters.length ? activeFilters.map((f) => `${f.label}: ${f.value}`).join('; ') : '—'
			],
			['Penjualan', 'Subtotal − diskon voucher − diskon manual (ongkir terpisah)'],
			['Diekspor', `${dateTimeOf(new Date().toISOString())} oleh ${auth.profile?.name ?? ''}`]
		];
	}

	const fileBase = (kind: string) => `laporan-${kind}_${filters.date_from}_${filters.date_to}`;

	function summaryTable(s: ReportSummary): Table {
		const dims = s.group_by;
		const dimCols = dims.map((d) => ({ label: GROUP_LABEL[d], width: d === 'date' ? 14 : 26 }));
		const keyCells = (r: SummaryRow): Cell[] =>
			r.keys.map((k, i) => (dims[i] === 'date' ? k.k : k.l));
		if (s.level === 'item') {
			return {
				name: 'Ringkasan',
				columns: [
					...dimCols,
					{ label: 'Qty' },
					{ label: 'Nilai kotor', money: true, width: 16 },
					{ label: 'Transaksi' }
				],
				rows: s.rows.map((r) =>
					'qty' in r ? [...keyCells(r), r.qty, r.value, r.tx_count] : keyCells(r)
				),
				footer: itemTotals
					? ['TOTAL', ...dims.slice(1).map(() => ''), itemTotals.qty, itemTotals.value, '']
					: undefined
			};
		}
		const metrics = (m: TxMetrics): Cell[] => [
			m.tx_count,
			m.net_sales,
			avg(m),
			m.voucher_discount,
			m.manual_discount,
			m.markup,
			m.shipping,
			m.total,
			m.items_qty
		];
		return {
			name: 'Ringkasan',
			columns: [
				...dimCols,
				{ label: 'Transaksi' },
				{ label: 'Penjualan', money: true, width: 16 },
				{ label: 'Rata-rata', money: true },
				{ label: 'Diskon voucher', money: true },
				{ label: 'Diskon manual', money: true },
				{ label: 'Markup marketplace', money: true, width: 18 },
				{ label: 'Ongkir', money: true },
				{ label: 'Total diterima', money: true, width: 16 },
				{ label: 'Item terjual' }
			],
			rows: dims.length ? s.rows.filter(isTxRow).map((r) => [...keyCells(r), ...metrics(r)]) : [],
			footer: [
				...(dims.length ? ['TOTAL', ...dims.slice(1).map(() => '')] : []),
				...metrics(s.totals)
			]
		};
	}

	function dailyTable(s: ReportSummary): Table {
		return {
			name: 'Harian',
			columns: [
				{ label: 'Tanggal' },
				{ label: 'Transaksi' },
				{ label: 'Penjualan', money: true, width: 16 }
			],
			rows: s.daily.map((d) => [d.date, d.tx_count, d.net_sales])
		};
	}

	function txTable(rows: ReportTxRow[]): Table {
		return {
			name: view === 'voided' ? 'Transaksi batal' : 'Transaksi',
			columns: [
				{ label: 'No. transaksi', width: 17 },
				{ label: 'Tanggal' },
				{ label: 'Waktu dibuat', width: 20 },
				{ label: 'Channel' },
				{ label: 'Platform' },
				{ label: 'Tipe' },
				{ label: 'Pelanggan / kode pesanan', width: 24 },
				{ label: 'Kasir' },
				{ label: 'Status bayar' },
				{ label: 'Metode bayar' },
				{ label: 'Rekening' },
				{ label: 'Waktu bayar', width: 20 },
				{ label: 'Kurir', width: 20 },
				{ label: 'Jarak (km)' },
				{ label: 'Subtotal', money: true },
				{ label: 'Markup', money: true },
				{ label: 'Kode voucher' },
				{ label: 'Diskon voucher', money: true },
				{ label: 'Diskon manual', money: true },
				{ label: 'Alasan diskon', width: 20 },
				{ label: 'Penjualan', money: true },
				{ label: 'Ongkir', money: true },
				{ label: 'Total diterima', money: true, width: 16 },
				{ label: 'Item' },
				{ label: 'Status' },
				{ label: 'Alasan batal', width: 24 },
				{ label: 'Dibatalkan oleh' },
				{ label: 'Catatan', width: 24 }
			],
			rows: rows.map((r) => [
				r.transaction_number,
				r.transaction_date,
				exportDateTime(r.created_at),
				CHANNEL_LABEL[r.channel] ?? r.channel,
				r.platform,
				SALES_TYPE_LABEL[r.sales_type] ?? r.sales_type,
				r.customer_name,
				r.cashier,
				r.payment_status === 'paid' ? 'Lunas' : 'Belum lunas',
				r.payment_method,
				r.bank,
				exportDateTime(r.paid_at),
				r.courier_type ? r.courier : '',
				r.distance_km,
				r.subtotal,
				r.markup,
				r.discount_code,
				r.voucher_discount,
				r.manual_discount,
				r.manual_discount_reason,
				r.net_sales,
				r.shipping,
				r.total,
				r.items_qty,
				r.status === 'voided' ? 'Batal' : 'Aktif',
				r.void_reason,
				r.voided_by,
				r.notes
			])
		};
	}

	async function runExport(
		kind: 'summary-xlsx' | 'summary-csv' | 'detail-xlsx' | 'tx-csv' | 'item-csv'
	) {
		exportMessage = '';
		exportFailed = false;
		if (isNativeApp()) {
			exportFailed = true;
			exportMessage =
				'Ekspor file tidak tersedia di aplikasi tablet. Buka pizza-lezzato-pos.pages.dev di browser laptop/HP, login, lalu ekspor dari menu Laporan.';
			return;
		}
		if (exportBusy) return;
		exportBusy = true;
		try {
			if (kind === 'summary-xlsx' || kind === 'summary-csv') {
				if (!summary) return;
				const table = summaryTable(summary);
				if (kind === 'summary-csv') downloadCsv(table, `${fileBase('ringkasan')}.csv`);
				else
					await downloadXlsx(
						[table, dailyTable(summary)],
						`${fileBase('ringkasan')}.xlsx`,
						exportInfo('Ringkasan penjualan')
					);
			} else {
				exportMessage = 'Menyiapkan data…';
				const data = await loadReportExport($state.snapshot(filters), view);
				const items: Table = {
					name: 'Item',
					columns: [
						{ label: 'No. transaksi', width: 17 },
						{ label: 'Tanggal' },
						{ label: 'Channel' },
						{ label: 'Platform' },
						{ label: 'Jenis' },
						{ label: 'Kategori', width: 18 },
						{ label: 'Produk', width: 26 },
						{ label: 'Ukuran/varian' },
						{ label: 'Qty' },
						{ label: 'Harga website', money: true },
						{ label: 'Harga jual', money: true },
						{ label: 'Nilai item', money: true },
						{ label: 'Nilai topping', money: true },
						{ label: 'Subtotal item', money: true },
						{ label: 'Extra topping', width: 28 },
						{ label: 'Pilihan paket', width: 28 },
						{ label: 'Catatan', width: 20 }
					],
					rows: data.items.map((i) => [
						i.transaction_number,
						i.transaction_date,
						CHANNEL_LABEL[i.channel] ?? i.channel,
						i.platform,
						i.item_type === 'package' ? 'Paket' : 'Produk',
						i.category,
						i.product_name,
						i.variant_name,
						i.qty,
						i.price_snapshot,
						i.unit_price,
						i.item_value,
						i.topping_value,
						i.subtotal_item,
						i.toppings,
						i.package_choices,
						i.notes
					])
				};
				const tx = txTable(data.transactions);
				const base = fileBase(view === 'voided' ? 'batal' : 'detail');
				if (kind === 'tx-csv') downloadCsv(tx, `${base}-transaksi.csv`);
				else if (kind === 'item-csv') downloadCsv(items, `${base}-item.csv`);
				else
					await downloadXlsx(
						[tx, items],
						`${base}.xlsx`,
						exportInfo(view === 'voided' ? 'Detail transaksi batal' : 'Detail transaksi')
					);
				exportMessage = `${data.transactions.length} transaksi diekspor.`;
			}
		} catch (e) {
			exportFailed = true;
			exportMessage = `Ekspor gagal: ${friendlyError(e)}`;
		} finally {
			exportBusy = false;
		}
	}

	// Pesan ekspor dihapus saat pindah tab
	$effect(() => {
		void tab;
		exportMessage = '';
	});
</script>

{#snippet exportButtons(kinds: { kind: Parameters<typeof runExport>[0]; label: string }[])}
	{#if canExport}
		<div class="export">
			{#each kinds as k (k.kind)}
				<button class="btn-ghost" onclick={() => runExport(k.kind)} disabled={exportBusy}>
					{k.label}
				</button>
			{/each}
		</div>
	{/if}
{/snippet}

<div class="page">
	{#if !tabs.length}
		<p class="empty">Anda tidak punya akses ke laporan. Hubungi Owner untuk mengatur hak akses.</p>
	{:else}
		<div class="head">
			<div class="segmented tabs">
				{#each tabs as t (t.code)}
					<button class:selected={tab === t.code} onclick={() => (tab = t.code)}>{t.label}</button>
				{/each}
			</div>
		</div>

		<!-- ---------------- Filter ---------------- -->
		<section class="card filters">
			<div class="presets">
				{#each DATE_PRESETS as p (p.code)}
					<button class="chip" class:selected={preset === p.code} onclick={() => setPreset(p.code)}>
						{p.label}
					</button>
				{/each}
			</div>
			<div class="range">
				<label>
					<span>Dari</span>
					<input
						class="input"
						type="date"
						bind:value={filters.date_from}
						max={today}
						oninput={() => (preset = 'custom')}
					/>
				</label>
				<label>
					<span>Sampai</span>
					<input
						class="input"
						type="date"
						bind:value={filters.date_to}
						max={today}
						oninput={() => (preset = 'custom')}
					/>
				</label>
				{#if tab !== 'shifts'}
					<button class="btn-ghost" onclick={() => (showFilters = !showFilters)}>
						{showFilters ? 'Tutup filter' : 'Filter lainnya'}
						{activeFilters.length ? `(${activeFilters.length})` : ''}
					</button>
					<label class="check">
						<input type="checkbox" bind:checked={filters.include_unpaid} />
						<span>Termasuk belum lunas</span>
					</label>
				{/if}
			</div>
			{#if dateError}<p class="error">{dateError}</p>{/if}

			{#if tab !== 'shifts'}
				{#if showFilters}
					<div class="filter-grid">
						<label>
							<span>Channel</span>
							<select class="input" bind:value={filters.channel}>
								<option value="">Semua</option>
								{#each Object.entries(CHANNEL_LABEL) as [code, label] (code)}
									<option value={code}>{label}</option>
								{/each}
							</select>
						</label>
						<label>
							<span>Platform marketplace</span>
							<select class="input" bind:value={filters.platform_id}>
								<option value="">Semua</option>
								{#each options?.platforms ?? [] as p (p.id)}
									<option value={p.id}>{p.name}</option>
								{/each}
							</select>
						</label>
						<label>
							<span>Tipe penjualan</span>
							<select class="input" bind:value={filters.sales_type}>
								<option value="">Semua</option>
								{#each Object.entries(SALES_TYPE_LABEL) as [code, label] (code)}
									<option value={code}>{label}</option>
								{/each}
							</select>
						</label>
						<label>
							<span>Metode bayar</span>
							<select class="input" bind:value={filters.payment_method_id}>
								<option value="">Semua</option>
								{#each options?.payment_methods ?? [] as m (m.id)}
									<option value={m.id}>{m.name}</option>
								{/each}
							</select>
						</label>
						<label>
							<span>Rekening</span>
							<select class="input" bind:value={filters.bank_account_id}>
								<option value="">Semua</option>
								{#each options?.bank_accounts ?? [] as b (b.id)}
									<option value={b.id}>{b.name}</option>
								{/each}
							</select>
						</label>
						<label>
							<span>Kasir</span>
							<select class="input" bind:value={filters.cashier_id}>
								<option value="">Semua</option>
								{#each options?.users ?? [] as u (u.id)}
									<option value={u.id}>{u.name}</option>
								{/each}
							</select>
						</label>
						<label>
							<span>Kurir</span>
							<select class="input" bind:value={filters.courier}>
								<option value="">Semua</option>
								<option value="shopee_express">Shopee Express</option>
								<option value="maxim">Maxim</option>
								{#if options?.users.length}
									<optgroup label="Karyawan">
										{#each options.users as u (u.id)}
											<option value="karyawan:{u.id}">{u.name}</option>
										{/each}
									</optgroup>
								{/if}
								{#if options?.couriers.length}
									<optgroup label="Freelance">
										{#each options.couriers as c (c.id)}
											<option value="freelance:{c.id}">{c.name}</option>
										{/each}
									</optgroup>
								{/if}
							</select>
						</label>
						<label>
							<span>Kategori</span>
							<select class="input" bind:value={filters.category}>
								<option value="">Semua</option>
								{#each options?.categories ?? [] as c (c.slug)}
									<option value={c.slug}>{c.name}</option>
								{/each}
							</select>
						</label>
						<label>
							<span>Produk</span>
							<select class="input" bind:value={filters.product_id}>
								<option value="">Semua</option>
								{#each options?.products ?? [] as p (p.id)}
									<option value={p.id}>{p.name}</option>
								{/each}
							</select>
						</label>
					</div>
				{/if}
				{#if activeFilters.length}
					<div class="active-filters">
						{#each activeFilters as f (f.key)}
							<button class="chip selected" onclick={() => clearFilter(f.key)}>
								{f.label}: {f.value} ✕
							</button>
						{/each}
						<button class="link" onclick={resetFilters}>Hapus semua filter</button>
					</div>
				{/if}
			{/if}
		</section>

		{#if exportMessage}
			<p class="export-message" class:failed={exportFailed} role="status">{exportMessage}</p>
		{/if}

		<!-- ---------------- Ringkasan ---------------- -->
		{#if tab === 'summary'}
			{#if summaryError}
				<p class="error" role="alert">{summaryError}</p>
			{:else if summary}
				{@const t = summary.totals}
				<div class="cards" class:loading={summaryLoading}>
					<div class="metric main">
						<span>Penjualan</span>
						<strong>{rupiah(t.net_sales)}</strong>
					</div>
					<div class="metric">
						<span>Transaksi</span>
						<strong>{t.tx_count}</strong>
					</div>
					<div class="metric">
						<span>Rata-rata / transaksi</span>
						<strong>{rupiah(avg(t))}</strong>
					</div>
					<div class="metric">
						<span>Item terjual</span>
						<strong>{t.items_qty}</strong>
						{#if t.topping_qty}<small>+ {t.topping_qty} porsi extra topping</small>{/if}
					</div>
					<div class="metric">
						<span>Diskon</span>
						<strong>{rupiah(discount(t))}</strong>
						<small>voucher {rupiah(t.voucher_discount)} · manual {rupiah(t.manual_discount)}</small>
					</div>
					<div class="metric">
						<span>Markup marketplace</span>
						<strong>{rupiah(t.markup)}</strong>
					</div>
					<div class="metric">
						<span>Ongkir</span>
						<strong>{rupiah(t.shipping)}</strong>
					</div>
					<div class="metric">
						<span>Total diterima</span>
						<strong>{rupiah(t.total)}</strong>
						<small>penjualan + ongkir</small>
					</div>
				</div>

				<div class="notes">
					{#if !filters.include_unpaid && summary.unpaid.tx_count}
						<span>
							Belum lunas (tidak dihitung): {summary.unpaid.tx_count} transaksi · {rupiah(
								summary.unpaid.total
							)}
						</span>
					{/if}
					{#if summary.voided.tx_count}
						{#if canDetail}
							<button class="link" onclick={showVoided}>
								Dibatalkan (tidak dihitung): {summary.voided.tx_count} transaksi · {rupiah(
									summary.voided.total
								)} ›
							</button>
						{:else}
							<span>
								Dibatalkan (tidak dihitung): {summary.voided.tx_count} transaksi · {rupiah(
									summary.voided.total
								)}
							</span>
						{/if}
					{/if}
					{#if filters.product_id || filters.category}
						<span>
							Angka di atas = transaksi yang berisi {filters.product_id ? 'produk' : 'kategori'} ini (nilai
							penuh transaksi).
						</span>
					{/if}
				</div>

				{#if summary.daily.length > 1}
					<section class="card">
						<h3>Penjualan per hari</h3>
						<SalesChart daily={summary.daily} />
					</section>
				{/if}

				<section class="card">
					<div class="table-head">
						<div class="grouping">
							<label>
								<span>Kelompokkan per</span>
								<select
									class="input"
									bind:value={group1}
									onchange={() => group1 === group2 && (group2 = '')}
								>
									<option value="">Tanpa pengelompokan</option>
									{#each GROUP_OPTIONS as g (g)}
										<option value={g}>{GROUP_LABEL[g]}</option>
									{/each}
								</select>
							</label>
							<label>
								<span>lalu per</span>
								<select class="input" bind:value={group2} disabled={!group1}>
									<option value="">—</option>
									{#each GROUP_OPTIONS.filter((g) => g !== group1) as g (g)}
										<option value={g}>{GROUP_LABEL[g]}</option>
									{/each}
								</select>
							</label>
						</div>
						{@render exportButtons([
							{ kind: 'summary-xlsx', label: 'Excel' },
							{ kind: 'summary-csv', label: 'CSV' }
						])}
					</div>

					{#if summary.level === 'item'}
						<p class="hint">
							Nilai kotor = qty × harga jual, sebelum diskon transaksi. Extra topping dihitung
							terpisah.
						</p>
					{/if}

					{#if summary.group_by.length}
						<div class="scroll">
							<table class="report" class:loading={summaryLoading}>
								<thead>
									<tr>
										{#each summary.group_by as g (g)}<th>{GROUP_LABEL[g]}</th>{/each}
										{#if summary.level === 'item'}
											<th class="num">Qty</th>
											<th class="num">Nilai kotor</th>
											<th class="num">Transaksi</th>
										{:else}
											<th class="num">Trx</th>
											<th class="num">Penjualan</th>
											<th class="num">Rata-rata</th>
											<th class="num">Diskon</th>
											<th class="num">Markup</th>
											<th class="num">Ongkir</th>
											<th class="num">Total diterima</th>
											<th class="num">Item</th>
										{/if}
									</tr>
								</thead>
								<tbody>
									{#each summary.rows as r, i (r.keys.map((k) => k.k).join('|'))}
										<tr
											class:group-start={summary.group_by.length > 1 &&
												showFirstKey(summary.rows, i)}
										>
											{#each r.keys as k, j (j)}
												<td class:topping={k.k === '__topping'}>
													{#if j > 0 || showFirstKey(summary.rows, i)}
														{groupLabel(summary.group_by[j], k)}
													{/if}
												</td>
											{/each}
											{#if 'qty' in r}
												<td class="num">{r.qty}</td>
												<td class="num">{rupiah(r.value)}</td>
												<td class="num">{r.tx_count}</td>
											{:else if isTxRow(r)}
												<td class="num">{r.tx_count}</td>
												<td class="num strong">{rupiah(r.net_sales)}</td>
												<td class="num">{rupiah(avg(r))}</td>
												<td class="num">{rupiah(discount(r))}</td>
												<td class="num">{rupiah(r.markup)}</td>
												<td class="num">{rupiah(r.shipping)}</td>
												<td class="num">{rupiah(r.total)}</td>
												<td class="num">{r.items_qty}</td>
											{/if}
										</tr>
									{:else}
										<tr>
											<td colspan="12" class="empty-row"
												>Tidak ada transaksi pada periode & filter ini.</td
											>
										</tr>
									{/each}
								</tbody>
								{#if summary.rows.length}
									<tfoot>
										<tr>
											<td colspan={summary.group_by.length}>Total</td>
											{#if summary.level === 'item' && itemTotals}
												<td class="num">{itemTotals.qty}</td>
												<td class="num">{rupiah(itemTotals.value)}</td>
												<td class="num"></td>
											{:else}
												<td class="num">{t.tx_count}</td>
												<td class="num">{rupiah(t.net_sales)}</td>
												<td class="num">{rupiah(avg(t))}</td>
												<td class="num">{rupiah(discount(t))}</td>
												<td class="num">{rupiah(t.markup)}</td>
												<td class="num">{rupiah(t.shipping)}</td>
												<td class="num">{rupiah(t.total)}</td>
												<td class="num">{t.items_qty}</td>
											{/if}
										</tr>
									</tfoot>
								{/if}
							</table>
						</div>
					{:else}
						<p class="hint">
							Pilih pengelompokan untuk melihat rincian per tanggal, channel, produk, dll.
						</p>
					{/if}
				</section>
			{:else}
				<p class="muted">Memuat…</p>
			{/if}
		{/if}

		<!-- ---------------- Detail ---------------- -->
		{#if tab === 'detail'}
			<section class="card">
				<div class="table-head">
					<div class="segmented view">
						<button class:selected={view === 'included'} onclick={() => (view = 'included')}>
							{filters.include_unpaid ? 'Lunas & belum lunas' : 'Lunas'}
						</button>
						<button class:selected={view === 'voided'} onclick={() => (view = 'voided')}>
							Dibatalkan
						</button>
					</div>
					<span class="muted">{detailCount} transaksi</span>
					{@render exportButtons([
						{ kind: 'detail-xlsx', label: 'Excel' },
						{ kind: 'tx-csv', label: 'CSV transaksi' },
						{ kind: 'item-csv', label: 'CSV item' }
					])}
				</div>

				{#if detailError}
					<p class="error" role="alert">{detailError}</p>
				{/if}

				<div class="scroll">
					<table class="report detail">
						<thead>
							<tr>
								<th>No. transaksi</th>
								<th>Waktu</th>
								<th>Channel</th>
								<th>Pelanggan / kode</th>
								<th>Kasir</th>
								<th>{view === 'voided' ? 'Alasan batal' : 'Pembayaran'}</th>
								<th class="num">Penjualan</th>
								<th class="num">Total</th>
							</tr>
						</thead>
						<tbody>
							{#each detailRows as r (r.id)}
								<tr class="clickable" onclick={() => (openTx = r.id)}>
									<td><strong>{r.transaction_number}</strong></td>
									<td>{dateTimeOf(r.created_at)}</td>
									<td>
										{r.platform ?? CHANNEL_LABEL[r.channel]}
										<small>{SALES_TYPE_LABEL[r.sales_type]}</small>
									</td>
									<td>{r.customer_name ?? '—'}</td>
									<td>{r.cashier ?? '—'}</td>
									<td>
										{#if view === 'voided'}
											{r.void_reason}
										{:else if r.payment_status === 'paid'}
											{r.payment_method}{r.bank ? ` · ${r.bank}` : ''}
										{:else}
											<span class="unpaid">Belum lunas</span>
										{/if}
									</td>
									<td class="num">{rupiah(r.net_sales)}</td>
									<td class="num strong">{rupiah(r.total)}</td>
								</tr>
							{:else}
								<tr>
									<td colspan="8" class="empty-row">
										{detailLoading ? 'Memuat…' : 'Tidak ada transaksi pada periode & filter ini.'}
									</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
				{#if detailRows.length < detailCount}
					<div class="more">
						<button class="btn-ghost" onclick={() => loadDetail(false)} disabled={detailLoading}>
							{detailLoading ? 'Memuat…' : `Muat lagi (${detailCount - detailRows.length} tersisa)`}
						</button>
					</div>
				{/if}
			</section>
		{/if}

		<!-- ---------------- Riwayat shift ---------------- -->
		{#if tab === 'shifts'}
			<section class="card">
				{#if shiftError}
					<p class="error" role="alert">{shiftError}</p>
				{/if}
				<div class="scroll">
					<table class="report" class:loading={shiftLoading}>
						<thead>
							<tr>
								<th>Dibuka</th>
								<th>Ditutup</th>
								<th>Kasir</th>
								<th class="num">Trx</th>
								<th class="num">Penjualan lunas</th>
								<th class="num">Kas seharusnya</th>
								<th class="num">Hitungan</th>
								<th class="num">Selisih</th>
								<th>Catatan</th>
							</tr>
						</thead>
						<tbody>
							{#each shifts as s (s.id)}
								<tr class="clickable" onclick={() => (openShift = s.id)}>
									<td>{dateTimeOf(s.opening_time)}</td>
									<td>
										{#if s.closing_time}
											{dateTimeOf(s.closing_time)}
										{:else}
											<span class="status"
												>{s.status === 'open' ? 'Masih buka' : 'Sedang dihitung'}</span
											>
										{/if}
									</td>
									<td>
										{s.opened_by ?? '—'}
										{#if s.closed_by && s.closed_by !== s.opened_by}<small
												>tutup: {s.closed_by}</small
											>{/if}
									</td>
									<td class="num">
										{s.tx_count}{#if s.voided_count}<small> ({s.voided_count} batal)</small>{/if}
									</td>
									<td class="num">{s.sales_total != null ? rupiah(s.sales_total) : '—'}</td>
									<td class="num">{s.expected != null ? rupiah(s.expected) : '—'}</td>
									<td class="num">{s.counted != null ? rupiah(s.counted) : '—'}</td>
									<td
										class="num strong"
										class:short={(s.difference ?? 0) < 0}
										class:over={(s.difference ?? 0) > 0}
									>
										{#if s.difference == null}
											—
										{:else if s.difference === 0}
											Sesuai
										{:else}
											{s.difference > 0 ? '+' : '−'}{rupiah(Math.abs(s.difference))}
										{/if}
									</td>
									<td class="note">{s.notes ?? ''}</td>
								</tr>
							{:else}
								<tr>
									<td colspan="9" class="empty-row">
										{shiftLoading ? 'Memuat…' : 'Tidak ada shift pada periode ini.'}
									</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			</section>
		{/if}
	{/if}
</div>

{#if openTx}
	<ReportTxDialog id={openTx} onclose={() => (openTx = null)} />
{/if}
{#if openShift}
	<ShiftDetailDialog id={openShift} onclose={() => (openShift = null)} />
{/if}

<style>
	.page {
		display: flex;
		flex-direction: column;
		gap: 0.85rem;
		max-width: 1280px;
		margin: 0 auto;
		padding: 1rem;
	}
	.empty,
	.muted {
		color: var(--muted);
	}
	.error {
		color: var(--danger);
		margin: 0.5rem 0 0;
	}
	.tabs {
		max-width: 520px;
	}
	.card {
		padding: 1rem;
		border: 1px solid var(--border);
		border-radius: var(--radius);
		background: var(--surface);
	}
	.card h3 {
		margin: 0 0 0.5rem;
		font-size: 0.95rem;
		color: var(--muted);
	}
	.presets,
	.active-filters {
		display: flex;
		flex-wrap: wrap;
		gap: 0.4rem;
	}
	.active-filters {
		margin-top: 0.75rem;
		align-items: center;
	}
	.chip {
		min-height: var(--touch);
		padding: 0 0.9rem;
		border: 1px solid var(--border);
		border-radius: 999px;
		background: var(--surface);
		color: var(--text);
		font-weight: 600;
	}
	.chip.selected {
		border-color: var(--brand);
		background: var(--brand-soft);
		color: var(--brand);
	}
	.chip:active {
		background: var(--brand-soft);
	}
	.range {
		display: flex;
		flex-wrap: wrap;
		align-items: flex-end;
		gap: 0.6rem;
		margin-top: 0.75rem;
	}
	.range label,
	.filter-grid label,
	.grouping label {
		display: flex;
		flex-direction: column;
		gap: 0.25rem;
		font-size: 0.85rem;
		color: var(--muted);
	}
	.range .input {
		width: 11.5rem;
	}
	.check {
		flex-direction: row !important;
		align-items: center;
		gap: 0.5rem !important;
		min-height: var(--touch);
		font-size: 1rem !important;
		color: var(--text) !important;
	}
	.check input {
		width: 22px;
		height: 22px;
		accent-color: var(--brand);
	}
	.filter-grid {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
		gap: 0.6rem;
		margin-top: 0.85rem;
	}
	.export-message {
		margin: 0;
		padding: 0.6rem 0.85rem;
		border-radius: var(--radius);
		background: #e8f4ec;
		color: #1e6b3a;
	}
	.export-message.failed {
		background: #fff4e0;
		color: #8a5300;
	}
	.cards {
		display: grid;
		grid-template-columns: repeat(4, minmax(0, 1fr));
		gap: 0.6rem;
	}
	.metric {
		display: flex;
		flex-direction: column;
		gap: 0.2rem;
		padding: 0.85rem 1rem;
		border: 1px solid var(--border);
		border-radius: var(--radius);
		background: var(--surface);
	}
	.metric span {
		font-size: 0.85rem;
		color: var(--muted);
	}
	.metric strong {
		font-size: 1.25rem;
	}
	.metric small {
		font-size: 0.78rem;
		color: var(--muted);
	}
	.metric.main {
		border-color: var(--brand);
		background: var(--brand-soft);
	}
	.metric.main strong {
		color: var(--brand);
		font-size: 1.45rem;
	}
	.loading {
		opacity: 0.55;
	}
	.notes {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 0.25rem 1.25rem;
		font-size: 0.9rem;
		color: var(--muted);
	}
	.notes:empty {
		display: none;
	}
	.notes .link {
		padding: 0;
	}
	.table-head {
		display: flex;
		flex-wrap: wrap;
		align-items: flex-end;
		justify-content: space-between;
		gap: 0.75rem;
		margin-bottom: 0.75rem;
	}
	.grouping {
		display: flex;
		flex-wrap: wrap;
		gap: 0.6rem;
	}
	.grouping .input {
		width: 13rem;
	}
	.export {
		display: flex;
		flex-wrap: wrap;
		gap: 0.4rem;
	}
	.view {
		min-width: 280px;
	}
	.hint {
		margin: 0 0 0.75rem;
		font-size: 0.85rem;
		color: var(--muted);
	}
	.scroll {
		overflow-x: auto;
	}
	.report {
		width: 100%;
		border-collapse: collapse;
		font-size: 0.92rem;
	}
	.report th {
		padding: 0.5rem 0.6rem;
		border-bottom: 2px solid var(--border);
		color: var(--muted);
		font-size: 0.8rem;
		text-align: left;
		white-space: nowrap;
	}
	.report td {
		padding: 0.55rem 0.6rem;
		border-bottom: 1px solid var(--border);
		vertical-align: top;
	}
	.report tr.group-start td {
		border-top: 2px solid var(--border);
	}
	.report td small {
		display: block;
		color: var(--muted);
		font-size: 0.78rem;
	}
	.report tfoot td {
		border-top: 2px solid var(--text);
		border-bottom: none;
		font-weight: 700;
	}
	.num {
		text-align: right !important;
		white-space: nowrap;
	}
	.strong {
		font-weight: 700;
	}
	.topping {
		font-style: italic;
	}
	.empty-row {
		padding: 1.5rem !important;
		text-align: center;
		color: var(--muted);
	}
	.clickable {
		cursor: pointer;
	}
	.clickable:active td {
		background: var(--brand-soft);
	}
	.detail td {
		height: var(--touch-lg);
		white-space: nowrap;
	}
	.unpaid,
	.status {
		color: #8a5300;
		font-weight: 600;
	}
	.short {
		color: var(--danger);
	}
	.over {
		color: #8a5300;
	}
	.note {
		max-width: 16rem;
		color: var(--muted);
	}
	.more {
		display: flex;
		justify-content: center;
		margin-top: 0.75rem;
	}
	@media (max-width: 640px) {
		.page {
			padding: 0.75rem;
		}
		.range .input,
		.grouping .input {
			width: 100%;
		}
		.range label,
		.grouping label {
			flex: 1 1 140px;
		}
		.cards {
			grid-template-columns: repeat(2, minmax(0, 1fr));
		}
	}
</style>
