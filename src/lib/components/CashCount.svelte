<script lang="ts">
	import { rupiah } from '$lib/format';

	// Sama dengan daftar pecahan di fungsi database cash_denomination_total.
	const DENOMINATIONS = [100000, 50000, 20000, 10000, 5000, 2000, 1000, 500, 200, 100];

	let { counts = $bindable() }: { counts: Record<string, number> } = $props();

	const total = $derived(DENOMINATIONS.reduce((sum, d) => sum + d * (counts[d] ?? 0), 0));

	function set(denomination: number, value: number) {
		counts = { ...counts, [denomination]: Math.max(0, Math.min(100000, value)) };
	}
</script>

<div class="count">
	{#each DENOMINATIONS as d (d)}
		<div class="row">
			<span class="label">{rupiah(d)}</span>
			<div class="stepper">
				<button
					onclick={() => set(d, (counts[d] ?? 0) - 1)}
					disabled={!counts[d]}
					aria-label="Kurangi">−</button
				>
				<input
					class="input qty"
					inputmode="numeric"
					value={counts[d] ?? 0}
					onfocus={(e) => e.currentTarget.select()}
					oninput={(e) => set(d, Number(e.currentTarget.value.replace(/\D/g, '')) || 0)}
					aria-label="Jumlah lembar {rupiah(d)}"
				/>
				<button onclick={() => set(d, (counts[d] ?? 0) + 1)} aria-label="Tambah">+</button>
			</div>
			<span class="subtotal">{rupiah(d * (counts[d] ?? 0))}</span>
		</div>
	{/each}
	<div class="total">
		<span>Total uang di laci</span>
		<strong>{rupiah(total)}</strong>
	</div>
</div>

<style>
	/* Dua kolom di landscape supaya 10 pecahan muat tanpa banyak menggulir */
	.count {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(360px, 1fr));
		column-gap: 2rem;
	}
	.row {
		display: grid;
		grid-template-columns: 7rem auto 1fr;
		align-items: center;
		gap: 0.75rem;
		padding: 0.35rem 0;
		border-bottom: 1px solid var(--border);
	}
	.label {
		font-weight: 600;
	}
	.qty {
		width: 4.5rem;
		text-align: center;
		padding: 0 0.25rem;
	}
	.subtotal {
		text-align: right;
		color: var(--muted);
	}
	.total {
		grid-column: 1 / -1;
		display: flex;
		justify-content: space-between;
		align-items: baseline;
		margin-top: 0.75rem;
		font-size: 1.15rem;
	}
	.total strong {
		font-size: 1.5rem;
	}
</style>
