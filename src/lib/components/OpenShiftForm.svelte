<script lang="ts">
	import { friendlyError, rupiah } from '$lib/format';
	import { openShift } from '$lib/pos/data';
	import type { Outlet, Shift } from '$lib/pos/types';

	let { outlet, onopened }: { outlet: Outlet; onopened: (shift: Shift) => void } = $props();

	let input = $state('');
	let submitting = $state(false);
	let error = $state('');

	const amount = $derived(Number(input.replace(/\D/g, '')) || 0);

	async function submit(event: SubmitEvent) {
		event.preventDefault();
		if (submitting || input.trim() === '') return;
		submitting = true;
		error = '';
		try {
			onopened(await openShift(outlet.id, amount));
		} catch (e) {
			error = friendlyError(e);
		} finally {
			submitting = false;
		}
	}
</script>

<form class="card" onsubmit={submit}>
	<h1>Buka shift</h1>
	<p class="hint">{outlet.name}</p>

	<label class="field">
		<span>Saldo awal kas di laci</span>
		<input
			class="input amount"
			inputmode="numeric"
			placeholder="0"
			value={input === '' ? '' : amount.toLocaleString('id-ID')}
			oninput={(e) => (input = e.currentTarget.value)}
		/>
	</label>
	{#if input !== ''}
		<p class="preview">{rupiah(amount)}</p>
	{/if}

	<p class="error" role="alert">{error}</p>

	<button class="btn-primary" type="submit" disabled={submitting || input.trim() === ''}>
		{submitting ? 'Membuka…' : 'Buka shift'}
	</button>
</form>

<style>
	.card {
		max-width: 420px;
		margin: 3rem auto;
		padding: 1.75rem 1.5rem;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: 20px;
		display: flex;
		flex-direction: column;
	}
	h1 {
		margin: 0;
		font-size: 1.4rem;
	}
	.hint {
		color: var(--muted);
		margin: 0.25rem 0 1.5rem;
	}
	.field {
		display: flex;
		flex-direction: column;
		gap: 0.4rem;
		color: var(--muted);
		font-size: 0.9rem;
	}
	.amount {
		font-size: 1.5rem;
		font-weight: 600;
		text-align: right;
	}
	.preview {
		text-align: right;
		color: var(--muted);
		margin: 0.35rem 0 0;
	}
	.error {
		color: var(--danger);
		min-height: 1.2em;
	}
</style>
