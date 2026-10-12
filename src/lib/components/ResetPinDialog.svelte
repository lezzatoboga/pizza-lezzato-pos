<script lang="ts">
	// Reset PIN pengguna (sekaligus membuka kunci PIN).
	import Modal from './Modal.svelte';
	import { friendlyError } from '$lib/format';
	import { PIN_PATTERN, resetPin, type AdminUser } from '$lib/pos/users';

	let {
		user,
		onsaved,
		onclose
	}: { user: AdminUser; onsaved: (message: string) => void; onclose: () => void } = $props();

	let pin = $state('');
	let pinConfirm = $state('');
	let busy = $state(false);
	let error = $state('');

	const pinError = $derived(
		pin && !PIN_PATTERN.test(pin)
			? 'PIN harus 4–6 digit angka.'
			: pinConfirm && pin !== pinConfirm
				? 'Konfirmasi PIN tidak sama.'
				: ''
	);
	const valid = $derived(PIN_PATTERN.test(pin) && pin === pinConfirm);

	async function save() {
		if (busy || !valid) return;
		busy = true;
		error = '';
		try {
			await resetPin(user.id, pin);
			onsaved(`PIN ${user.name} sudah diganti`);
		} catch (e) {
			error = friendlyError(e);
		} finally {
			busy = false;
		}
	}
</script>

<Modal title="Reset PIN {user.name}" {onclose}>
	<p class="muted">
		PIN lama langsung tidak berlaku. Kunci PIN (kalau ada) ikut dibuka. Berlaku juga untuk PIN
		persetujuan pembatalan.
	</p>
	<div class="pins">
		<label class="field">
			<span>PIN baru (4–6 digit)</span>
			<input
				class="input pin"
				type="password"
				inputmode="numeric"
				autocomplete="new-password"
				maxlength="6"
				bind:value={pin}
			/>
		</label>
		<label class="field">
			<span>Ulangi PIN baru</span>
			<input
				class="input pin"
				type="password"
				inputmode="numeric"
				autocomplete="new-password"
				maxlength="6"
				bind:value={pinConfirm}
				onkeydown={(e) => e.key === 'Enter' && save()}
			/>
		</label>
	</div>

	<p class="error" role="alert">{pinError || error}</p>

	{#snippet footer()}
		<div class="actions">
			<button class="btn-ghost" onclick={onclose} disabled={busy}>Batal</button>
			<button class="btn-primary" onclick={save} disabled={busy || !valid}>
				{busy ? 'Menyimpan…' : 'Simpan PIN baru'}
			</button>
		</div>
	{/snippet}
</Modal>

<style>
	.muted {
		margin: 0 0 1rem;
		color: var(--muted);
	}
	.pins {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 0.75rem;
	}
	.field {
		display: flex;
		flex-direction: column;
		gap: 0.35rem;
		color: var(--muted);
		font-size: 0.9rem;
	}
	.pin {
		font-size: 1.3rem;
		letter-spacing: 0.3em;
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
