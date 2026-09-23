<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import CashCount from '$lib/components/CashCount.svelte';
	import Modal from '$lib/components/Modal.svelte';
	import ShiftResult from '$lib/components/ShiftResult.svelte';
	import { friendlyError, rupiah, timeOf } from '$lib/format';
	import {
		addCashMovement,
		closeShift,
		getShiftSummary,
		loadContext,
		submitCashCount,
		type PosContext,
		type ShiftSummary
	} from '$lib/pos/data';

	// overview → (unpaid) → count → result → done
	type Step = 'overview' | 'unpaid' | 'count' | 'result' | 'done';

	let ctx = $state<PosContext | null>(null);
	let summary = $state<ShiftSummary | null>(null);
	let step = $state<Step>('overview');
	let error = $state('');
	let busy = $state(false);

	// Kas masuk/keluar
	let moveType = $state<'masuk' | 'keluar'>('keluar');
	let moveAmountInput = $state('');
	let moveDescription = $state('');
	let moveError = $state('');
	const moveAmount = $derived(Number(moveAmountInput.replace(/\D/g, '')) || 0);

	// Hitung & tutup
	let counts = $state<Record<string, number>>({});
	let confirmCount = $state(false);
	let notes = $state('');

	onMount(load);

	async function load() {
		error = '';
		try {
			ctx = await loadContext();
			if (ctx.shift) {
				summary = await getShiftSummary(ctx.shift.id);
				if (summary.shift.status === 'counting') step = 'result';
			}
		} catch (e) {
			error = friendlyError(e);
		}
	}

	async function refreshSummary() {
		if (ctx?.shift) summary = await getShiftSummary(ctx.shift.id);
	}

	async function saveMovement(event: SubmitEvent) {
		event.preventDefault();
		if (!ctx || busy) return;
		busy = true;
		moveError = '';
		try {
			await addCashMovement(ctx.outlet.id, moveType, moveAmount, moveDescription);
			moveAmountInput = '';
			moveDescription = '';
			await refreshSummary();
		} catch (e) {
			moveError = friendlyError(e);
		} finally {
			busy = false;
		}
	}

	function startClose() {
		error = '';
		step = summary && summary.unpaid.length > 0 ? 'unpaid' : 'count';
	}

	async function saveCount() {
		if (!ctx?.shift || busy) return;
		busy = true;
		error = '';
		try {
			summary = await submitCashCount(ctx.shift.id, counts);
			confirmCount = false;
			step = 'result';
		} catch (e) {
			error = friendlyError(e);
			confirmCount = false;
		} finally {
			busy = false;
		}
	}

	async function finish() {
		if (!ctx?.shift || busy) return;
		busy = true;
		error = '';
		try {
			summary = await closeShift(ctx.shift.id, notes);
			step = 'done';
		} catch (e) {
			error = friendlyError(e);
		} finally {
			busy = false;
		}
	}

	const countedTotal = $derived(
		Object.entries(counts).reduce((sum, [d, n]) => sum + Number(d) * n, 0)
	);
	const needsNotes = $derived((summary?.cash?.difference ?? 0) !== 0);
</script>

<section class="page">
	{#if error && !summary}
		<p class="error">{error}</p>
	{:else if !ctx}
		<p class="muted">Memuat…</p>
	{:else if !ctx.shift || !summary}
		<div class="card center">
			<p>Tidak ada shift yang terbuka.</p>
			<a class="btn-primary as-link" href="/">Ke layar kasir untuk buka shift</a>
		</div>
	{:else if step === 'overview'}
		<header>
			<div>
				<h1>Shift berjalan</h1>
				<p class="muted">
					Dibuka {summary.shift.opened_by} · {timeOf(summary.shift.opening_time)} · saldo awal
					{rupiah(summary.shift.opening_balance)} · {summary.transaction_count} transaksi
				</p>
			</div>
			<button class="btn-primary" onclick={startClose}>Tutup shift</button>
		</header>

		<div class="card">
			<h2>Kas masuk / keluar</h2>
			<form class="move-form" onsubmit={saveMovement}>
				<div class="segmented">
					<button
						type="button"
						class:selected={moveType === 'keluar'}
						onclick={() => (moveType = 'keluar')}>Kas keluar</button
					>
					<button
						type="button"
						class:selected={moveType === 'masuk'}
						onclick={() => (moveType = 'masuk')}>Kas masuk</button
					>
				</div>
				<input
					class="input amount"
					inputmode="numeric"
					placeholder="Jumlah"
					value={moveAmount ? moveAmount.toLocaleString('id-ID') : ''}
					oninput={(e) => (moveAmountInput = e.currentTarget.value)}
				/>
				<input
					class="input"
					placeholder={moveType === 'keluar'
						? 'Keterangan, mis. beli gas'
						: 'Keterangan, mis. tambah uang kecil'}
					bind:value={moveDescription}
					maxlength="150"
				/>
				<button
					class="btn-primary"
					type="submit"
					disabled={busy || moveAmount <= 0 || !moveDescription.trim()}>Simpan</button
				>
			</form>
			<p class="error" role="alert">{moveError}</p>

			<ul class="moves">
				{#each summary.cash_movements as m (m.id)}
					<li>
						<span class="time">{timeOf(m.created_at)}</span>
						<span class="desc">{m.description} <small>· {m.created_by}</small></span>
						<strong class:out={m.type === 'keluar'}>
							{m.type === 'keluar' ? '−' : '+'}
							{rupiah(m.amount)}
						</strong>
					</li>
				{:else}
					<li class="empty">Belum ada kas masuk/keluar di shift ini.</li>
				{/each}
			</ul>
		</div>
	{:else if step === 'unpaid'}
		<div class="card">
			<h1>Masih ada transaksi belum dibayar</h1>
			<p class="muted">
				Shift tetap bisa ditutup. Kalau dibayar belakangan, uangnya masuk ke shift yang sedang
				berjalan saat pembayaran diterima.
			</p>
			<ul class="moves">
				{#each summary.unpaid as u (u.id)}
					<li>
						<span class="time">{timeOf(u.created_at)}</span>
						<span class="desc">{u.transaction_number}</span>
						<strong>{rupiah(u.total)}</strong>
					</li>
				{/each}
			</ul>
			<div class="actions">
				<a class="btn-ghost as-link" href="/transaksi">Lihat &amp; bayar dulu</a>
				<button class="btn-primary" onclick={() => (step = 'count')}>Lanjut tutup shift</button>
			</div>
		</div>
	{:else if step === 'count'}
		<div class="card">
			<h1>Hitung uang di laci</h1>
			<p class="muted">
				Hitung semua uang fisik per pecahan. Setelah disimpan, hitungan tidak bisa diubah, lalu
				sistem menampilkan selisihnya.
			</p>
			<CashCount bind:counts />
			<p class="error" role="alert">{error}</p>
			<div class="actions">
				<button class="btn-ghost" onclick={() => (step = 'overview')} disabled={busy}>Batal</button>
				<button class="btn-primary" onclick={() => (confirmCount = true)} disabled={busy}>
					Simpan hitungan
				</button>
			</div>
		</div>
	{:else if step === 'result'}
		<div class="card">
			<h1>Hasil hitung kas</h1>
			<ShiftResult {summary} />

			<label class="notes">
				<span>Catatan {needsNotes ? '(wajib — jelaskan selisih)' : '(opsional)'}</span>
				<textarea class="input" rows="3" bind:value={notes} maxlength="500"></textarea>
			</label>

			<p class="error" role="alert">{error}</p>
			<div class="actions">
				<button
					class="btn-primary"
					onclick={finish}
					disabled={busy || (needsNotes && !notes.trim())}
				>
					{busy ? 'Menutup…' : 'Tutup shift'}
				</button>
			</div>
		</div>
	{:else if step === 'done'}
		<div class="card">
			<h1>Shift ditutup</h1>
			<p class="muted">
				Ditutup {summary.shift.closed_by} · {summary.shift.closing_time
					? timeOf(summary.shift.closing_time)
					: ''}
			</p>
			<ShiftResult {summary} />
			{#if summary.shift.notes}
				<p class="closing-notes">Catatan: {summary.shift.notes}</p>
			{/if}
			<div class="actions">
				<button class="btn-primary" onclick={() => goto('/', { replaceState: true })}>
					Buka shift baru
				</button>
			</div>
		</div>
	{/if}
</section>

{#if confirmCount}
	<Modal title="Simpan hitungan?" onclose={() => (confirmCount = false)}>
		<p>
			Total uang di laci <strong>{rupiah(countedTotal)}</strong>. Hitungan tidak bisa diubah setelah
			disimpan, dan transaksi baru tidak bisa dibuat sampai shift ditutup.
		</p>
		{#snippet footer()}
			<div class="actions">
				<button class="btn-ghost" onclick={() => (confirmCount = false)} disabled={busy}>
					Hitung ulang
				</button>
				<button class="btn-primary" onclick={saveCount} disabled={busy}>
					{busy ? 'Menyimpan…' : 'Ya, simpan'}
				</button>
			</div>
		{/snippet}
	</Modal>
{/if}

<style>
	.page {
		max-width: 1100px;
		margin: 0 auto;
		padding: 1rem;
	}
	header {
		display: flex;
		align-items: flex-start;
		justify-content: space-between;
		gap: 1rem;
		margin-bottom: 1rem;
	}
	h1 {
		margin: 0 0 0.25rem;
		font-size: 1.3rem;
	}
	h2 {
		margin: 0 0 0.75rem;
		font-size: 1.05rem;
	}
	.muted {
		color: var(--muted);
		margin-top: 0;
	}
	.error {
		color: var(--danger);
		min-height: 1.2em;
	}
	.card {
		padding: 1.25rem;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: 16px;
	}
	.card.center {
		text-align: center;
	}
	.as-link {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		text-decoration: none;
	}
	.move-form {
		display: grid;
		grid-template-columns: 260px 160px 1fr auto;
		gap: 0.5rem;
		align-items: center;
	}
	.amount {
		text-align: right;
	}
	.moves {
		list-style: none;
		margin: 0.5rem 0 0;
		padding: 0;
	}
	.moves li {
		display: grid;
		grid-template-columns: 4rem 1fr auto;
		align-items: center;
		gap: 0.75rem;
		min-height: var(--touch);
		border-bottom: 1px solid var(--border);
	}
	.moves li.empty {
		display: block;
		padding: 1rem 0;
		color: var(--muted);
		border: none;
	}
	.time,
	small {
		color: var(--muted);
	}
	.out {
		color: var(--danger);
	}
	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 0.5rem;
		margin-top: 1rem;
	}
	.notes {
		display: flex;
		flex-direction: column;
		gap: 0.4rem;
		margin-top: 1.25rem;
		color: var(--muted);
		font-size: 0.9rem;
	}
	.notes textarea {
		padding: 0.6rem 0.85rem;
		resize: vertical;
	}
	.closing-notes {
		margin-top: 1rem;
		font-style: italic;
	}
	@media (max-width: 900px) {
		.move-form {
			grid-template-columns: 1fr;
		}
	}
</style>
