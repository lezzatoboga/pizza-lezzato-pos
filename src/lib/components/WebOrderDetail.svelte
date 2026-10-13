<script lang="ts">
	// Detail satu pesanan website: data penerima, penanda, perbandingan
	// Asli (website) vs Sekarang (POS), dan tombol aksi sesuai status.
	import CourierDialog from './CourierDialog.svelte';
	import PaymentDialog from './PaymentDialog.svelte';
	import VoidDialog from './VoidDialog.svelte';
	import WebOrderEditor from './WebOrderEditor.svelte';
	import { formatPhone, friendlyError, rupiah, timeOf } from '$lib/format';
	import type { PosContext } from '$lib/pos/data';
	import { COURIER_TYPE_LABEL, type CourierValue, type Menu } from '$lib/pos/types';
	import { printKitchenTicket, printReceipt } from '$lib/print/jobs';
	import { isReceiptReprint } from '$lib/print/reprint';
	import {
		confirmWebOrder,
		finishWebOrder,
		mapsUrl,
		ORDER_TYPE_LABEL,
		OUTBOX_ERROR_TEXT,
		outboxState,
		READY_LABEL,
		readyWebOrder,
		statusText,
		type WebOrder
	} from '$lib/pos/web-orders';

	let {
		order,
		ctx,
		menu,
		onchanged
	}: { order: WebOrder; ctx: PosContext; menu: Menu | null; onchanged: () => void } = $props();

	const tx = $derived(order.transactions);
	const active = $derived(tx?.status === 'active');
	const h = $derived(order.header);
	const snap = $derived(
		tx?.original_order_snapshot ?? { header: order.header, items: order.items }
	);

	let busy = $state(false);
	let message = $state<{ text: string; failed: boolean } | null>(null);
	let editing = $state(false);
	let paying = $state(false);
	let courierOpen = $state(false);
	let voiding = $state(false);

	// ---------------- perbandingan ----------------
	type Row = {
		key: string;
		asli: string | null;
		asliQty: number | null;
		asliTotal: number | null;
		kini: string | null;
		kiniDetail: string;
		kiniQty: number | null;
		kiniTotal: number | null;
		change: 'sama' | 'qty' | 'hapus' | 'tambah';
		warning: string | null;
	};

	const rows = $derived.by((): Row[] => {
		if (!tx) return [];
		const out: Row[] = [];
		for (const w of snap.items) {
			const cur = tx.transaction_items.find((i) => i.source_line_ref === w.id);
			out.push({
				key: w.id,
				asli: w.name,
				asliQty: w.qty,
				asliTotal: w.unit_price * w.qty,
				kini: cur ? cur.product_name_snapshot : null,
				kiniDetail: cur ? itemDetail(cur) : '',
				kiniQty: cur?.qty ?? null,
				kiniTotal: cur?.subtotal_item ?? null,
				change: !cur ? 'hapus' : cur.qty !== w.qty ? 'qty' : 'sama',
				warning: cur?.mapping_warning ?? null
			});
		}
		for (const cur of tx.transaction_items.filter((i) => !i.source_line_ref)) {
			out.push({
				key: cur.id,
				asli: null,
				asliQty: null,
				asliTotal: null,
				kini: cur.product_name_snapshot,
				kiniDetail: itemDetail(cur),
				kiniQty: cur.qty,
				kiniTotal: cur.subtotal_item,
				change: 'tambah',
				warning: null
			});
		}
		return out;
	});

	function itemDetail(i: NonNullable<typeof tx>['transaction_items'][number]): string {
		return [
			i.variant_name_snapshot,
			...i.transaction_item_addons.map((a) => `+ ${a.addon_name_snapshot}`),
			...(i.package_choices_snapshot ?? []).map((c) => `${c.label}: ${c.value}`)
		]
			.filter(Boolean)
			.join(' · ');
	}

	const asliDiscount = $derived((snap.header.discount ?? 0) + (snap.header.diskon_ongkir ?? 0));
	const asliShipping = $derived(
		snap.header.order_type === 'delivery' ? (snap.header.ongkir_rupiah ?? 0) : 0
	);
	const changed = $derived(
		!!tx && (rows.some((r) => r.change !== 'sama') || tx.total !== snap.header.total)
	);
	const warnings = $derived(rows.filter((r) => r.warning).length);

	// ---------------- aksi ----------------
	const canEdit = $derived(
		!!tx &&
			active &&
			['baru', 'diterima'].includes(tx.order_status) &&
			!tx.is_locked &&
			!order.terkunci_edit
	);
	const confirmBlock = $derived(
		!tx || !active || !['baru', 'diterima'].includes(tx.order_status)
			? null
			: !ctx.shift || ctx.shift.status !== 'open'
				? 'Buka shift dulu'
				: order.menunggu_admin
					? 'Menunggu verifikasi admin website'
					: order.metode_bayar === 'online' && order.status_bayar !== 'lunas'
						? 'Pembayaran online belum lunas'
						: ''
	);
	// Lunas online tapi belum tercatat di POS: Bayar & Struk Belum Lunas disembunyikan
	// (pencatatan otomatis = backlog Proyek B, docs/JEMBATAN-PESANAN.md).
	const paidOnline = $derived(order.status_bayar === 'lunas' && tx?.payment_status !== 'paid');
	const needsCourier = $derived(tx?.sales_type === 'delivery');
	const courierMissing = $derived(needsCourier && !tx?.courier_type);

	async function run(action: () => Promise<string>) {
		if (busy) return;
		busy = true;
		message = null;
		try {
			message = { text: await action(), failed: false };
		} catch (e) {
			message = { text: friendlyError(e), failed: true };
		} finally {
			busy = false;
			onchanged();
		}
	}

	const confirm = () =>
		run(async () => {
			await confirmWebOrder(tx!.id);
			try {
				const { reprint } = await printKitchenTicket(tx!.id);
				return `Dikonfirmasi · tiket dapur tercetak${reprint ? ' (cetak ulang)' : ''}`;
			} catch (e) {
				return `Dikonfirmasi · tiket dapur belum tercetak: ${friendlyError(e)}`;
			}
		});
	const ready = () =>
		run(async () => {
			await readyWebOrder(tx!.id);
			return `Status: ${READY_LABEL[order.order_type]}`;
		});
	const finish = () =>
		run(async () => {
			await finishWebOrder(tx!.id);
			return 'Pesanan selesai';
		});
	const ticket = () =>
		run(async () => {
			const { reprint } = await printKitchenTicket(tx!.id);
			return `Tiket dapur tercetak${reprint ? ' (cetak ulang)' : ''}`;
		});
	const struk = () =>
		run(async () => {
			const { reprint, paid } = await printReceipt(tx!.id);
			return `Struk ${paid ? 'Lunas' : 'Belum Lunas'} tercetak${reprint ? ' (cetak ulang)' : ''}`;
		});

	function courierName(): string | null {
		if (!tx?.courier_type) return null;
		if (tx.courier_type === 'karyawan')
			return ctx.staff.find((p) => p.id === tx.courier_user_id)?.name ?? 'Karyawan';
		if (tx.courier_type === 'freelance')
			return ctx.couriers.find((c) => c.id === tx.courier_id)?.name ?? 'Freelance';
		return COURIER_TYPE_LABEL[tx.courier_type];
	}

	function courierValue(): CourierValue | null {
		if (!tx?.courier_type) return null;
		return {
			type: tx.courier_type,
			user_id: tx.courier_user_id ?? undefined,
			courier_id: tx.courier_id ?? undefined
		};
	}

	const outbox = $derived(outboxState(order));
	const lastFail = $derived(
		[...order.web_status_outbox]
			.reverse()
			.find((r) => r.failed_at && r.last_error !== 'dibatalkan di website')
	);
</script>

<article class="detail">
	<header>
		<div class="title">
			<span class="type {order.order_type}">{ORDER_TYPE_LABEL[order.order_type].toUpperCase()}</span
			>
			<h2>{order.order_code}</h2>
			<span class="status">{statusText(order)}</span>
		</div>
		<small class="muted">
			Masuk {timeOf(order.first_seen_at)}{tx ? ` · ${tx.transaction_number}` : ''}
		</small>
	</header>

	<!-- Penanda -->
	<div class="flags">
		{#if order.menunggu_admin}<p class="flag warn">
				⏳ Menunggu verifikasi admin website — Konfirmasi & Proses ditahan.
			</p>{/if}
		{#if order.terkunci_edit}<p class="flag info">
				🔒 Lunas online — pesanan tidak bisa diubah.
			</p>{/if}
		{#if order.diubah_di_pos}<p class="flag info">
				✎ Diubah kasir — pelanggan membayar di tempat.
			</p>{/if}
		{#if order.metode_bayar === 'online' && order.status_bayar !== 'lunas'}
			<p class="flag warn">Pembayaran online: {order.status_bayar ?? '—'}</p>
		{/if}
		{#if warnings}<p class="flag danger">
				⚠ {warnings} item tidak terpetakan ke menu POS — periksa (tiket dapur ditandai PERIKSA).
			</p>{/if}
		{#if order.header_notice}<p class="flag warn">{order.header_notice}</p>{/if}
		{#if order.cancel_notice}<p class="flag danger">{order.cancel_notice}</p>{/if}
		{#if outbox === 'gagal' && lastFail}
			<p class="flag danger">
				Status "{lastFail.status}" ditolak website: {OUTBOX_ERROR_TEXT[lastFail.last_error ?? ''] ??
					lastFail.last_error}
			</p>
		{:else if outbox === 'menunggu'}
			<p class="flag muted-flag">Status menunggu terkirim ke website…</p>
		{/if}
		{#if tx?.status === 'voided'}
			<p class="flag danger">
				{tx.void_source === 'website' ? 'Dibatalkan di website' : 'Dibatalkan'} · {tx.void_reason}
				{tx.voided_at ? `· ${timeOf(tx.voided_at)}` : ''}
			</p>
		{/if}
	</div>

	<!-- Penerima -->
	<dl class="who">
		<dt>Penerima</dt>
		<dd>
			<strong>{h.recipient_name}</strong> ·
			<a href="tel:{h.recipient_phone}">{formatPhone(h.recipient_phone)}</a>
		</dd>
		{#if order.order_type === 'delivery'}
			<dt>Alamat</dt>
			<dd>
				{h.address ?? '—'}{h.patokan ? ` (${h.patokan})` : ''}
				{#if mapsUrl(h)}<a href={mapsUrl(h)} target="_blank" rel="noopener">Peta ↗</a>{/if}
				{#if h.jarak_tagih_km}<small class="muted"> · {h.jarak_tagih_km} km</small>{/if}
			</dd>
		{/if}
		{#if h.note}
			<dt>Catatan</dt>
			<dd class="note">“{h.note}”</dd>
		{/if}
		{#if tx?.sales_type === 'delivery'}
			<dt>Kurir</dt>
			<dd class:missing={!tx.courier_type}>{courierName() ?? 'Belum dipilih'}</dd>
		{/if}
	</dl>

	<!-- Perbandingan -->
	<h3>
		Asli (website) vs Sekarang (POS) {#if !changed}<small class="muted">— tidak ada perubahan</small
			>{/if}
	</h3>
	<table class="compare">
		<thead>
			<tr
				><th>Asli (website)</th><th class="num">Rp</th><th>Sekarang (POS)</th><th class="num">Rp</th
				></tr
			>
		</thead>
		<tbody>
			{#each rows as r (r.key)}
				<tr class={r.change}>
					<td
						>{#if r.asli}{r.asliQty}× {r.asli}{:else}<span class="muted">—</span>{/if}</td
					>
					<td class="num">{r.asliTotal != null ? rupiah(r.asliTotal) : ''}</td>
					<td>
						{#if r.kini}
							{r.kiniQty}× {r.kini}
							{#if r.kiniDetail}<small>{r.kiniDetail}</small>{/if}
							{#if r.warning}<small class="warn-text">⚠ PERIKSA: {r.warning}</small>{/if}
							{#if r.change === 'tambah'}<span class="tag">ditambah kasir</span>{/if}
							{#if r.change === 'qty'}<span class="tag">qty diubah</span>{/if}
						{:else}
							<span class="tag">dihapus</span>
						{/if}
					</td>
					<td class="num">{r.kiniTotal != null ? rupiah(r.kiniTotal) : ''}</td>
				</tr>
			{/each}
		</tbody>
		<tfoot>
			<tr
				><td>Subtotal</td><td class="num">{rupiah(snap.header.subtotal)}</td><td></td><td
					class="num">{rupiah(tx?.subtotal ?? 0)}</td
				></tr
			>
			{#if asliDiscount || tx?.discount_amount}
				<tr>
					<td>Diskon {snap.header.voucher_code ?? ''}</td><td class="num"
						>− {rupiah(asliDiscount)}</td
					>
					<td>{tx?.discount_code ?? ''}</td><td class="num">− {rupiah(tx?.discount_amount ?? 0)}</td
					>
				</tr>
			{/if}
			{#if order.order_type === 'delivery'}
				<tr
					><td>Ongkir</td><td class="num">{rupiah(asliShipping)}</td><td></td><td class="num"
						>{rupiah(tx?.shipping_cost ?? 0)}</td
					></tr
				>
			{/if}
			<tr class="grand"
				><td>Total</td><td class="num">{rupiah(snap.header.total)}</td><td></td><td class="num"
					>{rupiah(tx?.total ?? 0)}</td
				></tr
			>
		</tfoot>
	</table>

	{#if message}
		<p class="msg" class:failed={message.failed} role="status">{message.text}</p>
	{/if}

	<!-- Aksi -->
	{#if tx && active}
		<div class="actions">
			{#if confirmBlock !== null}
				<button class="btn-primary big" disabled={busy || confirmBlock !== ''} onclick={confirm}>
					Konfirmasi & Proses
				</button>
				{#if confirmBlock}<span class="why">{confirmBlock}</span>{/if}
			{:else if tx.order_status === 'diproses'}
				<button class="btn-primary big" disabled={busy} onclick={ready}
					>{READY_LABEL[order.order_type]}</button
				>
			{/if}
			{#if tx.order_status !== 'selesai' && tx.order_status !== 'baru' && tx.order_status !== 'diterima'}
				<button
					class="btn-primary"
					disabled={busy || tx.payment_status !== 'paid'}
					title={tx.payment_status !== 'paid' && !paidOnline ? 'Lunasi dulu' : undefined}
					onclick={finish}
				>
					Selesai{paidOnline
						? ' (bayar online belum tercatat di POS)'
						: tx.payment_status !== 'paid'
							? ' (lunasi dulu)'
							: ''}
				</button>
			{/if}
		</div>
		<div class="actions secondary">
			{#if canEdit && menu}<button
					class="btn-ghost"
					disabled={busy}
					onclick={() => (editing = true)}>Ubah pesanan</button
				>{/if}
			{#if needsCourier && tx.payment_status !== 'paid'}
				<button class="btn-ghost" disabled={busy} onclick={() => (courierOpen = true)}>
					{courierMissing ? 'Pilih kurir' : 'Ganti kurir'}
				</button>
			{/if}
			{#if tx.payment_status !== 'paid' && !paidOnline}
				<button class="btn-ghost" disabled={busy || courierMissing} onclick={() => (paying = true)}
					>Bayar</button
				>
			{/if}
			{#if tx.kitchen_ticket_print_count > 0}
				<button class="btn-ghost" disabled={busy} onclick={ticket}>Tiket ulang</button>
			{/if}
			{#if !paidOnline}
				<button class="btn-ghost" disabled={busy || courierMissing} onclick={struk}>
					Struk {tx.payment_status === 'paid' ? 'Lunas' : 'Belum Lunas'}{isReceiptReprint(tx)
						? ' (ulang)'
						: ''}
				</button>
			{/if}
			<button class="btn-ghost danger" disabled={busy} onclick={() => (voiding = true)}
				>Batalkan</button
			>
		</div>
	{/if}
</article>

{#if editing && menu}
	<WebOrderEditor
		{order}
		{menu}
		onsaved={() => {
			editing = false;
			message = { text: 'Perubahan tersimpan & penanda terkirim ke website', failed: false };
			onchanged();
		}}
		onclose={() => (editing = false)}
	/>
{/if}
{#if paying && tx}
	<PaymentDialog
		transaction={{ id: tx.id, transaction_number: tx.transaction_number, total: tx.total }}
		methods={ctx.paymentMethods}
		bankAccounts={ctx.bankAccounts}
		ondone={() => {
			paying = false;
			onchanged();
		}}
		onclose={() => {
			paying = false;
			onchanged();
		}}
	/>
{/if}
{#if courierOpen && tx}
	<CourierDialog
		transactionId={tx.id}
		transactionNumber={tx.transaction_number}
		current={courierValue()}
		couriers={ctx.couriers}
		staff={ctx.staff}
		ondone={() => {
			courierOpen = false;
			onchanged();
		}}
		onclose={() => (courierOpen = false)}
	/>
{/if}
{#if voiding && tx}
	<VoidDialog
		transaction={{ id: tx.id, transaction_number: tx.transaction_number, total: tx.total }}
		ondone={() => {
			voiding = false;
			onchanged();
		}}
		onclose={() => (voiding = false)}
	/>
{/if}

<style>
	.detail {
		display: flex;
		flex-direction: column;
		gap: 0.75rem;
	}
	header .title {
		display: flex;
		align-items: center;
		gap: 0.6rem;
		flex-wrap: wrap;
	}
	h2 {
		margin: 0;
		font-size: 1.3rem;
	}
	h3 {
		margin: 0.5rem 0 0;
		font-size: 0.95rem;
	}
	.muted {
		color: var(--muted);
	}
	.type {
		padding: 0.25rem 0.7rem;
		border-radius: 8px;
		font-weight: 800;
		letter-spacing: 0.04em;
		color: #fff;
	}
	.type.delivery {
		background: #2a4f9a;
	}
	.type.takeaway {
		background: #1e6b3a;
	}
	.type.dinein {
		background: #8a3fb0;
	}
	.status {
		padding: 0.2rem 0.6rem;
		border-radius: 999px;
		background: var(--bg);
		font-weight: 600;
		font-size: 0.9rem;
	}
	.flags {
		display: flex;
		flex-direction: column;
		gap: 0.35rem;
	}
	.flags:empty {
		display: none;
	}
	.flag {
		margin: 0;
		padding: 0.5rem 0.8rem;
		border-radius: var(--radius);
		font-size: 0.92rem;
	}
	.flag.warn {
		background: #fff4e0;
		color: #8a5300;
	}
	.flag.info {
		background: #e8eefb;
		color: #2a4f9a;
	}
	.flag.danger {
		background: var(--brand-soft);
		color: var(--danger);
		font-weight: 600;
	}
	.flag.muted-flag {
		background: var(--bg);
		color: var(--muted);
	}
	.who {
		display: grid;
		grid-template-columns: auto 1fr;
		gap: 0.3rem 1rem;
		margin: 0;
	}
	.who dt {
		color: var(--muted);
	}
	.who dd {
		margin: 0;
	}
	.who a {
		color: var(--brand);
		font-weight: 600;
	}
	.note {
		font-style: italic;
	}
	.missing {
		color: var(--danger);
		font-weight: 600;
	}
	.compare {
		width: 100%;
		border-collapse: collapse;
		font-size: 0.92rem;
	}
	.compare th {
		text-align: left;
		color: var(--muted);
		font-size: 0.8rem;
		padding: 0.35rem 0.4rem;
		border-bottom: 2px solid var(--border);
	}
	.compare td {
		padding: 0.4rem;
		border-bottom: 1px solid var(--border);
		vertical-align: top;
	}
	.compare td small {
		display: block;
		color: var(--muted);
	}
	.compare .warn-text {
		color: var(--danger);
		font-weight: 600;
	}
	.compare tr.qty td:nth-child(3),
	.compare tr.tambah td:nth-child(3) {
		background: #fff8e8;
	}
	.compare tr.hapus td:nth-child(1) {
		text-decoration: line-through;
		color: var(--muted);
	}
	.compare tfoot td {
		border-bottom: none;
		padding-top: 0.3rem;
	}
	.compare tr.grand td {
		font-weight: 700;
		border-top: 2px solid var(--text);
	}
	.tag {
		display: inline-block;
		margin-left: 0.3rem;
		padding: 0 0.4rem;
		border-radius: 6px;
		background: #fff4e0;
		color: #8a5300;
		font-size: 0.78rem;
		font-weight: 600;
	}
	.num {
		text-align: right;
		white-space: nowrap;
	}
	.msg {
		margin: 0;
		padding: 0.55rem 0.8rem;
		border-radius: var(--radius);
		background: #e8f4ec;
		color: #1e6b3a;
	}
	.msg.failed {
		background: var(--brand-soft);
		color: var(--danger);
	}
	.actions {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 0.5rem;
	}
	.big {
		min-height: 56px;
		padding: 0 1.6rem;
		font-size: 1.05rem;
	}
	.why {
		color: #8a5300;
		font-weight: 600;
	}
	.danger:not(:disabled) {
		color: var(--danger);
	}
</style>
