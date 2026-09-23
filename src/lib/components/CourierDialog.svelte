<script lang="ts">
	import CourierPicker from './CourierPicker.svelte';
	import Modal from './Modal.svelte';
	import { friendlyError } from '$lib/format';
	import { setTransactionCourier } from '$lib/pos/data';
	import type { Courier, CourierValue, StaffMember } from '$lib/pos/types';

	let {
		transactionId,
		transactionNumber,
		current,
		couriers,
		staff,
		ondone,
		onclose
	}: {
		transactionId: string;
		transactionNumber: string;
		current: CourierValue | null;
		couriers: Courier[];
		staff: StaffMember[];
		ondone: () => void;
		onclose: () => void;
	} = $props();

	let value = $state<CourierValue | null>(current ? { ...current } : null);
	let saving = $state(false);
	let error = $state('');

	async function save() {
		if (!value || saving) return;
		saving = true;
		error = '';
		try {
			await setTransactionCourier(transactionId, value);
			ondone();
		} catch (e) {
			error = friendlyError(e);
		} finally {
			saving = false;
		}
	}
</script>

<Modal title="Kurir {transactionNumber}" {onclose}>
	<CourierPicker bind:value {couriers} {staff} />
	<p class="error" role="alert">{error}</p>

	{#snippet footer()}
		<div class="actions">
			<button class="btn-ghost" onclick={onclose} disabled={saving}>Batal</button>
			<button class="btn-primary" onclick={save} disabled={!value || saving}>
				{saving ? 'Menyimpan…' : 'Simpan kurir'}
			</button>
		</div>
	{/snippet}
</Modal>

<style>
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
