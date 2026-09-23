<script lang="ts">
	import { rupiah } from '$lib/format';
	import type { ShiftSummary } from '$lib/pos/data';
	import { CHANNEL_LABEL } from '$lib/pos/types';

	let { summary }: { summary: ShiftSummary } = $props();

	const cash = $derived(summary.cash);
</script>

{#if cash}
	<div class="difference" class:ok={cash.difference === 0} class:short={cash.difference < 0}>
		<span>
			{cash.difference === 0 ? 'Kas sesuai' : cash.difference < 0 ? 'Kas kurang' : 'Kas lebih'}
		</span>
		<strong>{cash.difference === 0 ? rupiah(0) : rupiah(Math.abs(cash.difference))}</strong>
	</div>

	<div class="columns">
		<section>
			<h3>Rekonsiliasi kas</h3>
			<dl>
				<dt>Saldo awal</dt>
				<dd>{rupiah(cash.opening_balance)}</dd>
				<dt>Penjualan tunai</dt>
				<dd>+ {rupiah(cash.cash_sales)}</dd>
				<dt>Kas masuk</dt>
				<dd>+ {rupiah(cash.cash_in)}</dd>
				<dt>Kas keluar</dt>
				<dd>− {rupiah(cash.cash_out)}</dd>
				<dt class="strong">Seharusnya di laci</dt>
				<dd class="strong">{rupiah(cash.expected)}</dd>
				<dt class="strong">Hasil hitung</dt>
				<dd class="strong">{rupiah(cash.counted)}</dd>
			</dl>
		</section>

		<section>
			<h3>Penjualan shift · {rupiah(summary.sales_total ?? 0)}</h3>
			<dl>
				{#each summary.by_payment ?? [] as p (p.method + (p.bank ?? ''))}
					<dt>{p.method}{p.bank ? ` · ${p.bank}` : ''} <small>({p.count})</small></dt>
					<dd>{rupiah(p.total)}</dd>
				{:else}
					<dt>Belum ada penjualan lunas</dt>
					<dd></dd>
				{/each}
			</dl>
			<h3 class="sub">Per channel</h3>
			<dl>
				{#each summary.by_channel ?? [] as c (c.channel + (c.platform ?? ''))}
					<dt>
						{c.platform ?? CHANNEL_LABEL[c.channel] ?? c.channel} <small>({c.count})</small>
					</dt>
					<dd>{rupiah(c.total)}</dd>
				{/each}
			</dl>
		</section>
	</div>
{/if}

<style>
	.difference {
		display: flex;
		justify-content: space-between;
		align-items: baseline;
		padding: 1rem 1.25rem;
		border-radius: var(--radius);
		background: #fff4e0;
		color: #8a5300;
		font-size: 1.1rem;
	}
	.difference strong {
		font-size: 1.6rem;
	}
	.difference.ok {
		background: #eaf6ee;
		color: #1e6b3a;
	}
	.difference.short {
		background: var(--brand-soft);
		color: var(--danger);
	}
	.columns {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
		gap: 1.5rem;
		margin-top: 1rem;
	}
	h3 {
		margin: 0 0 0.5rem;
		font-size: 0.95rem;
		color: var(--muted);
	}
	h3.sub {
		margin-top: 1rem;
	}
	dl {
		display: grid;
		grid-template-columns: 1fr auto;
		gap: 0.4rem 1rem;
		margin: 0;
	}
	dd {
		margin: 0;
		text-align: right;
	}
	small {
		color: var(--muted);
	}
	.strong {
		font-weight: 700;
	}
</style>
