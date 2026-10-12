<script lang="ts">
	// Tambah pengguna (nama, role, PIN) atau ubah nama/role pengguna.
	import Modal from './Modal.svelte';
	import { friendlyError } from '$lib/format';
	import {
		createUser,
		PIN_PATTERN,
		ROLE_OPTIONS,
		updateUser,
		type AdminUser,
		type RoleCode
	} from '$lib/pos/users';

	let {
		user = null,
		onsaved,
		onclose
	}: {
		// null = tambah pengguna baru
		user?: AdminUser | null;
		onsaved: (message: string) => void;
		onclose: () => void;
	} = $props();

	const editing = $derived(!!user);
	// Nilai awal dari pengguna yang diubah (dialog dibuat ulang per pengguna).
	const initial = (() => user)();
	let name = $state(initial?.name ?? '');
	let role = $state<RoleCode>(initial?.role_code ?? 'kasir');
	let pin = $state('');
	let pinConfirm = $state('');
	let busy = $state(false);
	let error = $state('');

	const roleLocked = $derived(!!user?.is_me);
	const pinError = $derived(
		editing
			? ''
			: pin && !PIN_PATTERN.test(pin)
				? 'PIN harus 4–6 digit angka.'
				: pinConfirm && pin !== pinConfirm
					? 'Konfirmasi PIN tidak sama.'
					: ''
	);
	const valid = $derived(
		name.trim().length > 0 &&
			(editing || (PIN_PATTERN.test(pin) && pin === pinConfirm)) &&
			!(editing && user && name.trim() === user.name && role === user.role_code)
	);

	async function save() {
		if (busy || !valid) return;
		busy = true;
		error = '';
		try {
			if (user) {
				await updateUser(user.id, name.trim(), role);
				onsaved(`${name.trim()} disimpan`);
			} else {
				await createUser(name.trim(), role, pin);
				onsaved(
					`${name.trim()} ditambahkan sebagai ${ROLE_OPTIONS.find((r) => r.code === role)?.name}`
				);
			}
		} catch (e) {
			error = friendlyError(e);
		} finally {
			busy = false;
		}
	}
</script>

<Modal title={editing ? `Ubah ${user?.name}` : 'Tambah pengguna'} {onclose}>
	<label class="field">
		<span>Nama (tampil di layar login)</span>
		<input class="input" bind:value={name} maxlength="40" autocomplete="off" />
	</label>

	<div class="field">
		<span>Role</span>
		<div class="segmented">
			{#each ROLE_OPTIONS as r (r.code)}
				<button
					class:selected={role === r.code}
					disabled={roleLocked}
					onclick={() => (role = r.code)}
				>
					{r.name}
				</button>
			{/each}
		</div>
		{#if roleLocked}
			<small>Role akun Anda sendiri tidak bisa diubah.</small>
		{:else if role === 'owner'}
			<small>Owner punya semua izin, termasuk kelola pengguna & hak akses.</small>
		{/if}
	</div>

	{#if !editing}
		<div class="pins">
			<label class="field">
				<span>PIN (4–6 digit)</span>
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
				<span>Ulangi PIN</span>
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
		<small class="hint"
			>PIN tidak bisa dilihat lagi setelah disimpan; bisa direset kapan saja.</small
		>
	{/if}

	<p class="error" role="alert">{pinError || error}</p>

	{#snippet footer()}
		<div class="actions">
			<button class="btn-ghost" onclick={onclose} disabled={busy}>Batal</button>
			<button class="btn-primary" onclick={save} disabled={busy || !valid}>
				{busy ? 'Menyimpan…' : editing ? 'Simpan' : 'Tambah pengguna'}
			</button>
		</div>
	{/snippet}
</Modal>

<style>
	.field {
		display: flex;
		flex-direction: column;
		gap: 0.35rem;
		margin-bottom: 1rem;
		color: var(--muted);
		font-size: 0.9rem;
	}
	.field small,
	.hint {
		color: var(--muted);
		font-size: 0.85rem;
	}
	.pins {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 0.75rem;
	}
	.pin {
		font-size: 1.3rem;
		letter-spacing: 0.3em;
	}
	.segmented button:disabled {
		opacity: 0.6;
		cursor: default;
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
