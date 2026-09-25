<script lang="ts">
	// Pembatalan transaksi: alasan → (persetujuan PIN Supervisor/Owner bila perlu)
	// → ringkasan pengembalian uang & slip BATAL ke dapur.
	import Modal from './Modal.svelte';
	import { friendlyError, rupiah, timeOf } from '$lib/format';
	import {
		listVoidApprovers,
		voidTransaction,
		VOID_REASONS,
		type VoidReasonCode,
		type VoidResult
	} from '$lib/pos/data';
	import type { StaffMember } from '$lib/pos/types';
	import { printVoidSlip } from '$lib/print/jobs';

	let {
		transaction,
		ondone,
		onclose
	}: {
		transaction: { id: string; transaction_number: string; total: number };
		ondone: () => void;
		onclose: () => void;
	} = $props();

	type Voided = Extract<VoidResult, { status: 'voided' }>;

	let step = $state<'reason' | 'approval' | 'done'>('reason');
	let reasonCode = $state<VoidReasonCode | null>(null);
	let reasonDetail = $state('');
	let busy = $state(false);
	let error = $state('');

	// Persetujuan
	let approvalMessage = $state('');
	let approvers = $state<StaffMember[]>([]);
	let approverId = $state<string | null>(null);
	let pin = $state('');

	// Hasil
	let result = $state<Voided | null>(null);
	let slipStatus = $state('');
	let slipFailed = $state(false);

	const reasonLabel = $derived(
		reasonCode
			? `${VOID_REASONS.find((r) => r.code === reasonCode)?.label}${reasonDetail.trim() ? `: ${reasonDetail.trim()}` : ''}`
			: ''
	);
	const reasonValid = $derived(!!reasonCode && (reasonCode !== 'lainnya' || !!reasonDetail.trim()));

	async function submit(withApproval: boolean) {
		if (busy || !reasonCode) return;
		busy = true;
		error = '';
		try {
			const res = await voidTransaction(
				transaction.id,
				reasonCode,
				reasonDetail.trim(),
				withApproval && approverId ? { approverId, pin } : undefined
			);
			if (res.status === 'approval_required') {
				approvalMessage = res.reason;
				approvers = await listVoidApprovers();
				approverId = approvers.length === 1 ? approvers[0].id : null;
				step = 'approval';
			} else if (res.status === 'pin_invalid') {
				pin = '';
				error =
					res.attempts_left != null
						? `PIN salah. Sisa ${res.attempts_left} percobaan sebelum dikunci sementara.`
						: 'PIN salah.';
			} else if (res.status === 'pin_locked') {
				pin = '';
				error = `Terlalu banyak PIN salah. Penyetuju terkunci sampai pukul ${timeOf(res.locked_until)}.`;
			} else {
				result = res;
				step = 'done';
				if (res.kitchen_ticket_printed) printSlip();
			}
		} catch (e) {
			error = friendlyError(e);
		} finally {
			busy = false;
		}
	}

	async function printSlip() {
		slipFailed = false;
		slipStatus = 'Mengirim slip BATAL ke dapur…';
		try {
			await printVoidSlip(transaction.id, reasonLabel);
			slipStatus = 'Slip BATAL tercetak di printer dapur.';
		} catch (e) {
			slipFailed = true;
			slipStatus = `Slip BATAL belum tercetak: ${friendlyError(e)}`;
		}
	}
</script>

<Modal
	title="Batalkan {transaction.transaction_number}"
	onclose={() => (step === 'done' ? ondone() : onclose())}
>
	{#if step === 'reason'}
		<p class="muted">
			Total {rupiah(transaction.total)}. Transaksi yang dibatalkan tetap tercatat, tidak dihapus.
		</p>
		<h3>Alasan</h3>
		<div class="reasons">
			{#each VOID_REASONS as r (r.code)}
				<button
					class="option"
					class:selected={reasonCode === r.code}
					onclick={() => (reasonCode = r.code)}
				>
					{r.label}
				</button>
			{/each}
		</div>
		<input
			class="input detail"
			placeholder={reasonCode === 'lainnya' ? 'Keterangan (wajib)' : 'Keterangan (opsional)'}
			bind:value={reasonDetail}
			maxlength="150"
		/>
	{:else if step === 'approval'}
		<p class="approval-note">{approvalMessage}</p>
		<h3>Penyetuju</h3>
		<div class="reasons">
			{#each approvers as a (a.id)}
				<button
					class="option"
					class:selected={approverId === a.id}
					onclick={() => (approverId = a.id)}
				>
					{a.name}
				</button>
			{:else}
				<p class="muted">Tidak ada pengguna yang berizin menyetujui pembatalan.</p>
			{/each}
		</div>
		<label class="pin">
			<span>PIN penyetuju</span>
			<input
				class="input"
				type="password"
				inputmode="numeric"
				autocomplete="off"
				maxlength="6"
				bind:value={pin}
				onkeydown={(e) => e.key === 'Enter' && submit(true)}
			/>
		</label>
	{:else if result}
		<div class="voided">
			<strong>DIBATALKAN</strong>
			<span>{result.transaction_number} · {reasonLabel}</span>
		</div>
		{#if result.refund_cash > 0}
			<p class="money">
				Kembalikan uang tunai <strong>{rupiah(result.refund_cash)}</strong> ke pelanggan.
				{#if result.refund_recorded_as_cash_out}
					Sudah tercatat sebagai kas keluar di shift ini.
				{/if}
			</p>
		{:else if result.paid}
			<p class="money">
				Pembayaran {result.payment_method_name ?? 'non-tunai'} dikembalikan di luar POS (mis. transfer
				balik ke pelanggan).
			</p>
		{/if}
		{#if slipStatus}
			<p class="slip" class:failed={slipFailed} role="status">{slipStatus}</p>
			{#if slipFailed}
				<button class="btn-ghost" onclick={printSlip}>Cetak slip BATAL lagi</button>
			{/if}
		{/if}
	{/if}

	<p class="error" role="alert">{error}</p>

	{#snippet footer()}
		<div class="actions">
			{#if step === 'reason'}
				<button class="btn-ghost" onclick={onclose} disabled={busy}>Kembali</button>
				<button class="btn-primary" onclick={() => submit(false)} disabled={busy || !reasonValid}>
					{busy ? 'Memproses…' : 'Batalkan transaksi'}
				</button>
			{:else if step === 'approval'}
				<button class="btn-ghost" onclick={onclose} disabled={busy}>Kembali</button>
				<button
					class="btn-primary"
					onclick={() => submit(true)}
					disabled={busy || !approverId || pin.length < 4}
				>
					{busy ? 'Memeriksa…' : 'Setujui pembatalan'}
				</button>
			{:else}
				<button class="btn-primary" onclick={ondone}>Selesai</button>
			{/if}
		</div>
	{/snippet}
</Modal>

<style>
	h3 {
		margin: 1rem 0 0.5rem;
		font-size: 0.9rem;
		color: var(--muted);
	}
	.muted {
		color: var(--muted);
		margin: 0;
	}
	.reasons {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
		gap: 0.5rem;
	}
	.option {
		min-height: var(--touch-lg);
		padding: 0 0.75rem;
		border: 1px solid var(--border);
		border-radius: var(--radius);
		background: var(--surface);
		font-weight: 600;
		color: var(--text);
	}
	.option.selected {
		border-color: var(--brand);
		background: var(--brand-soft);
		box-shadow: inset 0 0 0 1px var(--brand);
		color: var(--brand);
	}
	.detail {
		margin-top: 0.75rem;
	}
	.approval-note {
		margin: 0;
		padding: 0.6rem 0.85rem;
		border-radius: var(--radius);
		background: #fff4e0;
		color: #8a5300;
	}
	.pin {
		display: flex;
		flex-direction: column;
		gap: 0.35rem;
		margin-top: 1rem;
		color: var(--muted);
		font-size: 0.9rem;
	}
	.pin input {
		font-size: 1.4rem;
		letter-spacing: 0.3em;
		max-width: 12rem;
	}
	.voided {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 0.25rem;
		padding: 1rem;
		border-radius: var(--radius);
		background: var(--brand-soft);
		color: var(--danger);
		text-align: center;
	}
	.voided strong {
		font-size: 1.5rem;
		letter-spacing: 0.1em;
	}
	.money {
		margin: 1rem 0 0;
		font-size: 1.05rem;
	}
	.slip {
		margin: 1rem 0 0.5rem;
		color: #1e6b3a;
	}
	.slip.failed {
		color: var(--danger);
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
