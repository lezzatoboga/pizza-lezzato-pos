<script lang="ts">
	// Rincian satu shift di Riwayat shift (view_finance_report).
	import Modal from './Modal.svelte';
	import ShiftResult from './ShiftResult.svelte';
	import { friendlyError, rupiah, timeOf } from '$lib/format';
	import type { ShiftSummary } from '$lib/pos/data';
	import { dateTimeOf, loadShiftDetail } from '$lib/pos/report';

	let { id, onclose }: { id: string; onclose: () => void } = $props();

	let summary = $state<ShiftSummary | null>(null);
	let error = $state('');

	$effect(() => {
		const current = id;
		summary = null;
		error = '';
		loadShiftDetail(current)
			.then((s) => (summary = s))
			.catch((e) => (error = friendlyError(e)));
	});
</script>

<Modal title="Rincian shift" {onclose}>
	{#if error}
		<p class="error" role="alert">{error}</p>
	{:else if !summary}
		<p class="muted">Memuat…</p>
	{:else}
		{@const s = summary.shift}
		<dl class="meta">
			<dt>Dibuka</dt>
			<dd>{dateTimeOf(s.opening_time)} · {s.opened_by ?? '—'}</dd>
			{#if s.closing_time}
				<dt>Ditutup</dt>
				<dd>{dateTimeOf(s.closing_time)} · {s.closed_by ?? '—'}</dd>
			{/if}
			{#if s.counted_by}
				<dt>Dihitung</dt>
				<dd>{s.counted_by}</dd>
			{/if}
			<dt>Transaksi</dt>
			<dd>{summary.transaction_count}</dd>
			{#if s.notes}
				<dt>Catatan</dt>
				<dd>{s.notes}</dd>
			{/if}
		</dl>

		{#if summary.cash}
			<ShiftResult {summary} />
		{:else}
			<p class="muted">Shift masih terbuka — angka kas tampil setelah uang dihitung.</p>
		{/if}

		<h3>Kas masuk / keluar</h3>
		{#each summary.cash_movements as m (m.id)}
			<div class="movement">
				<span>{timeOf(m.created_at)} · {m.description} <small>({m.created_by ?? '—'})</small></span>
				<strong class:out={m.type === 'keluar'}>
					{m.type === 'keluar' ? '−' : '+'}
					{rupiah(m.amount)}
				</strong>
			</div>
		{:else}
			<p class="muted">Tidak ada.</p>
		{/each}

		{#if summary.unpaid.length}
			<h3>Belum lunas saat ditutup</h3>
			{#each summary.unpaid as u (u.id)}
				<div class="movement">
					<span>{u.transaction_number} · {timeOf(u.created_at)}</span>
					<strong>{rupiah(u.total)}</strong>
				</div>
			{/each}
		{/if}
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
	.meta {
		display: grid;
		grid-template-columns: auto 1fr;
		gap: 0.3rem 1rem;
		margin: 0 0 1rem;
	}
	.meta dt {
		color: var(--muted);
	}
	.meta dd {
		margin: 0;
	}
	h3 {
		margin: 1.25rem 0 0.5rem;
		font-size: 0.95rem;
	}
	.movement {
		display: flex;
		justify-content: space-between;
		gap: 1rem;
		padding: 0.4rem 0;
		border-top: 1px solid var(--border);
	}
	.movement small {
		color: var(--muted);
	}
	.out {
		color: var(--danger);
	}
	.actions {
		display: flex;
		justify-content: flex-end;
	}
</style>
