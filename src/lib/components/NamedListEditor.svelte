<script lang="ts">
	// Daftar nama yang bisa ditambah, diubah, dan dinonaktifkan (tanpa hapus
	// permanen, supaya riwayat transaksi tetap utuh). Dipakai untuk kurir
	// freelance & rekening bank.
	import { friendlyError } from '$lib/format';

	type Item = { id: string; name: string; active: boolean };

	let {
		items,
		addPlaceholder,
		onsave
	}: {
		items: Item[];
		addPlaceholder: string;
		// id null = tambah baru
		onsave: (id: string | null, name: string, active: boolean) => Promise<void>;
	} = $props();

	let newName = $state('');
	let drafts = $state<Record<string, string>>({});
	let busy = $state(false);
	let error = $state('');

	async function run(action: () => Promise<void>) {
		if (busy) return;
		busy = true;
		error = '';
		try {
			await action();
		} catch (e) {
			error = friendlyError(e);
		} finally {
			busy = false;
		}
	}

	function add(event: SubmitEvent) {
		event.preventDefault();
		const name = newName.trim();
		if (!name) return;
		run(async () => {
			await onsave(null, name, true);
			newName = '';
		});
	}

	function rename(item: Item) {
		const name = (drafts[item.id] ?? item.name).trim();
		if (!name || name === item.name) return;
		run(async () => {
			await onsave(item.id, name, item.active);
			delete drafts[item.id];
		});
	}

	function toggle(item: Item) {
		run(() => onsave(item.id, drafts[item.id]?.trim() || item.name, !item.active));
	}
</script>

<form class="add" onsubmit={add}>
	<input class="input" placeholder={addPlaceholder} bind:value={newName} maxlength="80" />
	<button class="btn-primary" type="submit" disabled={busy || !newName.trim()}>Tambah</button>
</form>
<p class="error" role="alert">{error}</p>

<ul class="list">
	{#each items as item (item.id)}
		{@const draft = drafts[item.id] ?? item.name}
		<li class:inactive={!item.active}>
			<input
				class="input"
				value={draft}
				oninput={(e) => (drafts = { ...drafts, [item.id]: e.currentTarget.value })}
				maxlength="80"
			/>
			<button
				class="btn-ghost"
				onclick={() => rename(item)}
				disabled={busy || !draft.trim() || draft.trim() === item.name}>Simpan</button
			>
			<button class="btn-ghost" onclick={() => toggle(item)} disabled={busy}>
				{item.active ? 'Nonaktifkan' : 'Aktifkan'}
			</button>
			<span class="state">{item.active ? 'Aktif' : 'Nonaktif'}</span>
		</li>
	{:else}
		<li class="empty">Belum ada data.</li>
	{/each}
</ul>

<style>
	.add {
		display: grid;
		grid-template-columns: 1fr auto;
		gap: 0.5rem;
	}
	.error {
		color: var(--danger);
		min-height: 1.2em;
		margin: 0.4rem 0;
	}
	.list {
		list-style: none;
		margin: 0;
		padding: 0;
	}
	.list li {
		display: grid;
		grid-template-columns: 1fr auto auto 5.5rem;
		align-items: center;
		gap: 0.5rem;
		padding: 0.4rem 0;
		border-bottom: 1px solid var(--border);
	}
	.list li.inactive .input {
		color: var(--muted);
		text-decoration: line-through;
	}
	.list li.empty {
		display: block;
		color: var(--muted);
		border: none;
	}
	.state {
		font-size: 0.85rem;
		color: var(--muted);
		text-align: center;
	}
</style>
