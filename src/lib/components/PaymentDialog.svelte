<script lang="ts">
	import Modal from './Modal.svelte';
	import { friendlyError, rupiah } from '$lib/format';
	import { payTransaction, type PaymentResult } from '$lib/pos/data';
	import type { PaymentMethod, SavedTransaction } from '$lib/pos/types';

	let {
		transaction,
		methods,
		ondone,
		onclose
	}: {
		transaction: SavedTransaction;
		methods: PaymentMethod[];
		ondone: (result: PaymentResult) => void;
		onclose: () => void;
	} = $props();

	const QUICK_CASH = [50000, 100000];

	let methodId = $state(methods.find((m) => m.is_cash)?.id ?? methods[0]?.id ?? '');
	let cashInput = $state('');
	let submitting = $state(false);
	let error = $state('');

	const method = $derived(methods.find((m) => m.id === methodId));
	const cash = $derived(Number(cashInput.replace(/\D/g, '')) || 0);
	const change = $derived(cash - transaction.total);
	const canPay = $derived(!!method && (!method.is_cash || cash >= transaction.total));

	function setCash(value: number) {
		cashInput = String(value);
	}

	async function pay() {
		if (!canPay || !method || submitting) return;
		submitting = true;
		error = '';
		try {
			ondone(await payTransaction(transaction.id, method.id, method.is_cash ? cash : null));
		} catch (e) {
			error = friendlyError(e);
		} finally {
			submitting = false;
		}
	}
</script>

<Modal title="Pembayaran {transaction.transaction_number}" {onclose}>
	<p class="total">
		<span>Total</span>
		<strong>{rupiah(transaction.total)}</strong>
	</p>

	<div class="methods">
		{#each methods as m (m.id)}
			<button class="method" class:selected={m.id === methodId} onclick={() => (methodId = m.id)}>
				{m.name}
			</button>
		{/each}
	</div>

	{#if method?.is_cash}
		<label class="field">
			<span>Uang diterima</span>
			<input
				class="input cash"
				inputmode="numeric"
				placeholder="0"
				value={cash ? cash.toLocaleString('id-ID') : ''}
				oninput={(e) => (cashInput = e.currentTarget.value)}
			/>
		</label>
		<div class="quick">
			<button class="btn-ghost" onclick={() => setCash(transaction.total)}>Uang pas</button>
			{#each QUICK_CASH as amount (amount)}
				<button
					class="btn-ghost"
					onclick={() => setCash(amount)}
					disabled={amount < transaction.total}
				>
					{rupiah(amount)}
				</button>
			{/each}
		</div>
		<p class="change" class:negative={change < 0}>
			<span>{change < 0 ? 'Kurang' : 'Kembalian'}</span>
			<strong>{rupiah(Math.abs(change))}</strong>
		</p>
	{:else if method}
		<p class="hint">
			Pastikan dana {method.name} sebesar {rupiah(transaction.total)} sudah diterima.
		</p>
	{/if}

	<p class="error" role="alert">{error}</p>

	{#snippet footer()}
		<div class="actions">
			<button class="btn-ghost" onclick={onclose} disabled={submitting}>Bayar nanti</button>
			<button class="btn-primary" onclick={pay} disabled={!canPay || submitting}>
				{submitting ? 'Memproses…' : 'Konfirmasi bayar'}
			</button>
		</div>
	{/snippet}
</Modal>

<style>
	.total,
	.change {
		display: flex;
		justify-content: space-between;
		align-items: baseline;
		margin: 0 0 1rem;
		font-size: 1.1rem;
	}
	.total strong {
		font-size: 1.6rem;
	}
	.change {
		margin-top: 1rem;
		padding: 0.75rem 1rem;
		border-radius: var(--radius);
		background: #eaf6ee;
		color: #1e6b3a;
	}
	.change.negative {
		background: var(--brand-soft);
		color: var(--danger);
	}
	.methods {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(110px, 1fr));
		gap: 0.5rem;
		margin-bottom: 1rem;
	}
	.method {
		padding: 0.85rem;
		border: 1px solid var(--border);
		border-radius: var(--radius);
		background: var(--surface);
		font-weight: 600;
	}
	.method.selected {
		border-color: var(--brand);
		background: var(--brand-soft);
		box-shadow: inset 0 0 0 1px var(--brand);
	}
	.field {
		display: flex;
		flex-direction: column;
		gap: 0.35rem;
		color: var(--muted);
		font-size: 0.9rem;
	}
	.cash {
		font-size: 1.4rem;
		font-weight: 600;
		text-align: right;
	}
	.quick {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
		margin-top: 0.75rem;
	}
	.quick button:disabled {
		opacity: 0.4;
	}
	.hint {
		color: var(--muted);
	}
	.error {
		color: var(--danger);
		min-height: 1.2em;
		margin: 0.75rem 0 0;
	}
	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 0.5rem;
	}
</style>
