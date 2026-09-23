<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { auth, LoginError, type LoginUser } from '$lib/auth/auth.svelte';

	const PIN_MIN = 4;
	const PIN_MAX = 6;

	let users = $state<LoginUser[]>([]);
	let loadingUsers = $state(true);
	let loadError = $state('');

	let selected = $state<LoginUser | null>(null);
	let pin = $state('');
	let submitting = $state(false);
	let error = $state('');

	onMount(loadUsers);

	async function loadUsers() {
		loadingUsers = true;
		loadError = '';
		try {
			users = await auth.listLoginUsers();
		} catch (e) {
			loadError = (e as Error).message;
		} finally {
			loadingUsers = false;
		}
	}

	function choose(user: LoginUser) {
		selected = user;
		pin = '';
		error = '';
	}

	function back() {
		selected = null;
		pin = '';
		error = '';
	}

	function press(digit: string) {
		if (submitting || pin.length >= PIN_MAX) return;
		error = '';
		pin += digit;
	}

	function backspace() {
		if (submitting) return;
		pin = pin.slice(0, -1);
	}

	async function submit() {
		if (!selected || pin.length < PIN_MIN || submitting) return;
		submitting = true;
		error = '';
		try {
			await auth.loginWithPin(selected.id, pin);
			goto('/', { replaceState: true });
		} catch (e) {
			pin = '';
			if (e instanceof LoginError) {
				if (e.lockedUntil) {
					const time = e.lockedUntil.toLocaleTimeString('id-ID', {
						hour: '2-digit',
						minute: '2-digit'
					});
					error = `Terlalu banyak PIN salah. Coba lagi setelah pukul ${time}.`;
				} else if (e.attemptsLeft != null) {
					error = `PIN salah. Sisa ${e.attemptsLeft} percobaan sebelum dikunci sementara.`;
				} else {
					error = e.message;
				}
			} else {
				error = 'Login gagal. Coba lagi.';
			}
		} finally {
			submitting = false;
		}
	}

	function onKeydown(event: KeyboardEvent) {
		if (!selected) return;
		if (/^[0-9]$/.test(event.key)) press(event.key);
		else if (event.key === 'Backspace') backspace();
		else if (event.key === 'Enter') submit();
		else if (event.key === 'Escape') back();
	}
</script>

<svelte:window onkeydown={onKeydown} />

<div class="login">
	<div class="card">
		<h1>Pizza Lezzato <span>POS</span></h1>

		{#if !selected}
			<p class="hint">Pilih nama Anda</p>

			{#if loadingUsers}
				<p class="status">Memuat daftar pengguna…</p>
			{:else if loadError}
				<p class="status error">{loadError}</p>
				<button class="btn-ghost" onclick={loadUsers}>Coba lagi</button>
			{:else if users.length === 0}
				<p class="status">Belum ada pengguna aktif. Hubungi Owner.</p>
			{:else}
				<div class="users">
					{#each users as user (user.id)}
						<button class="user" onclick={() => choose(user)}>
							<span class="avatar">{user.name.charAt(0).toUpperCase()}</span>
							<span class="name">{user.name}</span>
							<span class="role">{user.role}</span>
						</button>
					{/each}
				</div>
			{/if}
		{:else}
			<button class="btn-ghost back" onclick={back} disabled={submitting}>← Ganti nama</button>
			<p class="hint">
				Masukkan PIN untuk <strong>{selected.name}</strong>
			</p>

			<div class="dots" aria-label="PIN, {pin.length} digit dimasukkan">
				{#each { length: PIN_MAX }, i (i)}
					<span class="dot" class:filled={i < pin.length} class:optional={i >= PIN_MIN}></span>
				{/each}
			</div>

			<p class="error" role="alert">{error}</p>

			<div class="pad">
				{#each ['1', '2', '3', '4', '5', '6', '7', '8', '9'] as digit (digit)}
					<button class="key" onclick={() => press(digit)} disabled={submitting}>{digit}</button>
				{/each}
				<button class="key muted" onclick={backspace} disabled={submitting} aria-label="Hapus"
					>⌫</button
				>
				<button class="key" onclick={() => press('0')} disabled={submitting}>0</button>
				<button
					class="key enter"
					onclick={submit}
					disabled={submitting || pin.length < PIN_MIN}
					aria-label="Masuk">{submitting ? '…' : '→'}</button
				>
			</div>
		{/if}
	</div>
</div>

<style>
	.login {
		display: grid;
		place-items: center;
		min-height: 100dvh;
		padding: 1rem;
	}
	.card {
		width: 100%;
		max-width: 440px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: 20px;
		padding: 1.75rem 1.5rem;
		text-align: center;
	}
	h1 {
		margin: 0 0 0.25rem;
		color: var(--brand);
		font-size: 1.5rem;
	}
	h1 span {
		color: var(--muted);
		font-weight: 500;
	}
	.hint {
		color: var(--muted);
		margin: 0.5rem 0 1.25rem;
	}
	.status {
		color: var(--muted);
	}
	.error {
		color: var(--danger);
		min-height: 1.5em;
		margin: 0.5rem 0;
		font-size: 0.9rem;
	}
	.users {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(120px, 1fr));
		gap: 0.75rem;
	}
	.user {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 0.35rem;
		padding: 1rem 0.5rem;
		border: 1px solid var(--border);
		border-radius: var(--radius);
		background: var(--surface);
	}
	.user:hover {
		border-color: var(--brand);
		background: var(--brand-soft);
	}
	.avatar {
		display: grid;
		place-items: center;
		width: 48px;
		height: 48px;
		border-radius: 50%;
		background: var(--brand);
		color: #fff;
		font-weight: 700;
		font-size: 1.25rem;
	}
	.name {
		font-weight: 600;
	}
	.role {
		font-size: 0.8rem;
		color: var(--muted);
	}
	.back {
		float: left;
		padding: 0.35rem 0.7rem;
		font-size: 0.85rem;
	}
	.dots {
		clear: both;
		display: flex;
		justify-content: center;
		gap: 0.75rem;
		margin-top: 0.5rem;
	}
	.dot {
		width: 16px;
		height: 16px;
		border-radius: 50%;
		border: 2px solid var(--brand);
	}
	.dot.optional {
		border-style: dashed;
		opacity: 0.5;
	}
	.dot.filled {
		background: var(--brand);
		opacity: 1;
	}
	.pad {
		display: grid;
		grid-template-columns: repeat(3, 1fr);
		gap: 0.75rem;
		max-width: 300px;
		margin: 0.5rem auto 0;
	}
	.key {
		height: 64px;
		border: 1px solid var(--border);
		border-radius: var(--radius);
		background: var(--surface);
		font-size: 1.5rem;
		font-weight: 600;
		color: var(--text);
	}
	.key:active:not(:disabled) {
		background: var(--brand-soft);
	}
	.key.muted {
		color: var(--muted);
	}
	.key.enter {
		background: var(--brand);
		border-color: var(--brand);
		color: #fff;
	}
	.key:disabled {
		opacity: 0.4;
		cursor: default;
	}
</style>
