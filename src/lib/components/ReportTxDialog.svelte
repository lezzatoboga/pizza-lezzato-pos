<script lang="ts">
	// Drill-down satu transaksi di laporan detail (audit & rekonsiliasi).
	import Modal from './Modal.svelte';
	import { friendlyError, rupiah } from '$lib/format';
	import { dateTimeOf, loadReportTransaction, type ReportTxDetail } from '$lib/pos/report';
	import { CHANNEL_LABEL, SALES_TYPE_LABEL } from '$lib/pos/types';

	let { id, onclose }: { id: string; onclose: () => void } = $props();

	let tx = $state<ReportTxDetail | null>(null);
	let error = $state('');

	$effect(() => {
		const current = id;
		tx = null;
		error = '';
		loadReportTransaction(current)
			.then((d) => (tx = d))
			.catch((e) => (error = friendlyError(e)));
	});
</script>

<Modal title={tx ? tx.transaction_number : 'Rincian transaksi'} {onclose}>
	{#if error}
		<p class="error" role="alert">{error}</p>
	{:else if !tx}
		<p class="muted">Memuat…</p>
	{:else}
		{#if tx.status === 'voided'}
			<p class="voided">
				<strong>DIBATALKAN</strong>
				{tx.voided_at ? dateTimeOf(tx.voided_at) : ''} · {tx.void_reason}
				{#if tx.voided_by}· disetujui {tx.voided_by}{/if}
				{#if tx.void_requested_by && tx.void_requested_by !== tx.voided_by}
					· diajukan {tx.void_requested_by}
				{/if}
			</p>
		{/if}

		<dl class="meta">
			<dt>Waktu</dt>
			<dd>{dateTimeOf(tx.created_at)}</dd>
			<dt>Channel</dt>
			<dd>
				{tx.platform ?? CHANNEL_LABEL[tx.channel] ?? tx.channel} · {SALES_TYPE_LABEL[
					tx.sales_type
				] ?? tx.sales_type}
			</dd>
			{#if tx.customer_name}
				<dt>{tx.channel === 'marketplace' ? 'Kode pesanan' : 'Pelanggan'}</dt>
				<dd>{tx.customer_name}{tx.customer_phone ? ` · ${tx.customer_phone}` : ''}</dd>
			{/if}
			{#if tx.delivery_address}
				<dt>Alamat</dt>
				<dd>
					{tx.delivery_address}{tx.delivery_patokan ? ` (${tx.delivery_patokan})` : ''}
				</dd>
			{/if}
			{#if tx.sales_type === 'delivery'}
				<dt>Kurir</dt>
				<dd>{tx.courier}{tx.distance_km != null ? ` · ${tx.distance_km} km` : ''}</dd>
			{/if}
			<dt>Kasir</dt>
			<dd>{tx.cashier ?? '—'}</dd>
			<dt>Pembayaran</dt>
			<dd>
				{#if tx.payment_status === 'paid'}
					{tx.payment_method}{tx.bank ? ` · ${tx.bank}` : ''}
					{tx.paid_at ? `· ${dateTimeOf(tx.paid_at)}` : ''}
				{:else}
					Belum lunas
				{/if}
			</dd>
			{#if tx.notes}
				<dt>Catatan</dt>
				<dd>{tx.notes}</dd>
			{/if}
		</dl>

		<table class="items">
			<tbody>
				{#each tx.items as item, i (i)}
					<tr>
						<td class="qty">{item.qty}×</td>
						<td>
							<strong>{item.product_name}</strong>
							{#if item.variant_name}<span class="muted">({item.variant_name})</span>{/if}
							<span class="muted">@ {rupiah(item.unit_price)}</span>
							{#each item.package_choices ?? [] as c (c.key)}
								<div class="sub">{c.label}: {c.value}</div>
							{/each}
							{#each item.addons as a (a.name)}
								<div class="sub">
									+ {a.name}{a.qty > 1 ? ` ×${a.qty}` : ''} @ {rupiah(a.unit_price)}
								</div>
							{/each}
							{#if item.notes}<div class="sub note">“{item.notes}”</div>{/if}
						</td>
						<td class="num">{rupiah(item.subtotal_item)}</td>
					</tr>
				{/each}
			</tbody>
		</table>

		<dl class="money">
			<dt>Subtotal</dt>
			<dd>{rupiah(tx.subtotal)}</dd>
			{#if tx.markup > 0}
				<dt class="muted">termasuk markup {tx.markup_percent}%</dt>
				<dd class="muted">{rupiah(tx.markup)}</dd>
			{/if}
			{#if tx.voucher_discount > 0}
				<dt>Diskon voucher {tx.discount_code ?? ''}</dt>
				<dd>− {rupiah(tx.voucher_discount)}</dd>
			{/if}
			{#if tx.manual_discount > 0}
				<dt>Diskon manual {tx.manual_discount_reason ? `(${tx.manual_discount_reason})` : ''}</dt>
				<dd>− {rupiah(tx.manual_discount)}</dd>
			{/if}
			<dt class="strong">Penjualan</dt>
			<dd class="strong">{rupiah(tx.net_sales)}</dd>
			{#if tx.shipping > 0}
				<dt>Ongkir</dt>
				<dd>{rupiah(tx.shipping)}</dd>
			{/if}
			<dt class="strong">Total diterima</dt>
			<dd class="strong">{rupiah(tx.total)}</dd>
		</dl>
	{/if}

	{#snippet footer()}
		<div class="actions">
			<button class="btn-primary" onclick={onclose}>Tutup</button>
		</div>
	{/snippet}
</Modal>

<style>
	.muted {
		color: var(--muted);
	}
	.error {
		color: var(--danger);
	}
	.voided {
		margin: 0 0 0.75rem;
		padding: 0.6rem 0.85rem;
		border-radius: var(--radius);
		background: var(--brand-soft);
		color: var(--danger);
	}
	dl {
		display: grid;
		grid-template-columns: auto 1fr;
		gap: 0.3rem 1rem;
		margin: 0;
	}
	dt {
		color: var(--muted);
	}
	dd {
		margin: 0;
	}
	.items {
		width: 100%;
		margin: 1rem 0;
		border-collapse: collapse;
	}
	.items td {
		padding: 0.5rem 0.25rem;
		border-top: 1px solid var(--border);
		vertical-align: top;
	}
	.qty {
		width: 3ch;
		font-weight: 600;
	}
	.sub {
		font-size: 0.9rem;
		color: var(--muted);
	}
	.note {
		font-style: italic;
	}
	.num {
		text-align: right;
		white-space: nowrap;
	}
	.money dt {
		color: var(--text);
	}
	.money dd {
		text-align: right;
	}
	.money .muted {
		color: var(--muted);
		font-size: 0.9rem;
	}
	.strong {
		font-weight: 700;
	}
	.actions {
		display: flex;
		justify-content: flex-end;
	}
</style>
