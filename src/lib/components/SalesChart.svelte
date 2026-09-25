<script lang="ts">
	// Grafik batang penjualan per hari. Tanpa hover: ketuk batang untuk
	// melihat angkanya (default: hari terakhir yang ada penjualan).
	import { rupiah } from '$lib/format';
	import { formatDay, formatShortDay } from '$lib/pos/report';

	let { daily }: { daily: { date: string; net_sales: number; tx_count: number }[] } = $props();

	const W = 1000;
	const H = 180;
	const TOP = 8;

	let selected = $state<string | null>(null);

	const max = $derived(Math.max(1, ...daily.map((d) => d.net_sales)));
	const slot = $derived(W / Math.max(daily.length, 1));
	const barW = $derived(Math.max(1, slot * 0.7));
	// Label sumbu: kira-kira 8 label saja supaya tidak bertumpuk
	const labelEvery = $derived(Math.max(1, Math.ceil(daily.length / 8)));
	const active = $derived(
		daily.find((d) => d.date === selected) ??
			[...daily].reverse().find((d) => d.net_sales > 0) ??
			daily[daily.length - 1]
	);

	function barHeight(v: number) {
		return v <= 0 ? 0 : Math.max(2, ((H - TOP) * v) / max);
	}
</script>

<div class="chart">
	{#if active}
		<p class="readout">
			<span>{formatDay(active.date)}</span>
			<strong>{rupiah(active.net_sales)}</strong>
			<span class="muted">{active.tx_count} transaksi</span>
		</p>
	{/if}
	<svg viewBox="0 0 {W} {H}" preserveAspectRatio="none" role="img" aria-label="Penjualan per hari">
		<line x1="0" x2={W} y1={H} y2={H} class="axis" />
		{#each daily as d, i (d.date)}
			<!-- Area ketuk selebar slot penuh, batangnya sendiri bisa tipis -->
			<rect
				x={i * slot}
				y="0"
				width={slot}
				height={H}
				class="hit"
				role="button"
				tabindex="-1"
				aria-label="{formatDay(d.date)}: {rupiah(d.net_sales)}"
				onclick={() => (selected = d.date)}
				onkeydown={(e) => e.key === 'Enter' && (selected = d.date)}
			/>
			<rect
				x={i * slot + (slot - barW) / 2}
				y={H - barHeight(d.net_sales)}
				width={barW}
				height={barHeight(d.net_sales)}
				class="bar"
				class:on={active?.date === d.date}
				rx={Math.min(4, barW / 3)}
			/>
		{/each}
	</svg>
	<div class="labels">
		{#each daily as d, i (d.date)}
			{#if i % labelEvery === 0}
				<span style="left: {((i + 0.5) * 100) / Math.max(daily.length, 1)}%">
					{formatShortDay(d.date)}
				</span>
			{/if}
		{/each}
	</div>
</div>

<style>
	.chart {
		position: relative;
	}
	.readout {
		display: flex;
		align-items: baseline;
		gap: 0.75rem;
		margin: 0 0 0.5rem;
		flex-wrap: wrap;
	}
	.readout strong {
		font-size: 1.15rem;
	}
	.muted {
		color: var(--muted);
		font-size: 0.9rem;
	}
	svg {
		display: block;
		width: 100%;
		height: 150px;
	}
	.axis {
		stroke: var(--border);
		stroke-width: 2;
	}
	.hit {
		fill: transparent;
		cursor: pointer;
		outline: none;
	}
	.bar {
		fill: #e3a59e;
		pointer-events: none;
	}
	.bar.on {
		fill: var(--brand);
	}
	.labels {
		position: relative;
		height: 1.2rem;
		margin-top: 0.25rem;
		font-size: 0.75rem;
		color: var(--muted);
	}
	.labels span {
		position: absolute;
		transform: translateX(-50%);
		white-space: nowrap;
	}
</style>
