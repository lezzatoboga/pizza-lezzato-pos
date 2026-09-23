<script lang="ts">
	import { onMount } from 'svelte';
	import Modal from './Modal.svelte';
	import { formatPhone, friendlyError, normalizePhone } from '$lib/format';
	import { searchCustomers } from '$lib/pos/data';
	import type { Customer } from '$lib/pos/types';

	let {
		delivery,
		onselect,
		onclose
	}: {
		delivery: boolean;
		// Pelanggan baru: id null; alamat/patokan dari form (khusus delivery).
		onselect: (customer: Customer) => void;
		onclose: () => void;
	} = $props();

	let query = $state('');
	let results = $state<Customer[]>([]);
	let searching = $state(false);
	let searched = $state(false);
	let error = $state('');
	let searchInput: HTMLInputElement | undefined = $state();

	// Form pelanggan baru
	let creating = $state(false);
	let newName = $state('');
	let newPhone = $state('');
	let newAddress = $state('');
	let newPatokan = $state('');

	let timer: ReturnType<typeof setTimeout> | undefined;
	let requestId = 0;

	const isDigits = $derived(/^[+0-9 ()-]+$/.test(query.trim()));
	const tooShort = $derived(
		isDigits ? query.replace(/\D/g, '').length < 4 : query.trim().length < 3
	);
	const normalizedNewPhone = $derived(normalizePhone(newPhone));

	onMount(() => searchInput?.focus());

	function onQueryInput() {
		clearTimeout(timer);
		error = '';
		if (tooShort) {
			results = [];
			searched = false;
			return;
		}
		timer = setTimeout(runSearch, 250);
	}

	async function runSearch() {
		const id = ++requestId;
		searching = true;
		try {
			const found = await searchCustomers(query);
			if (id !== requestId) return; // hasil ketikan lama
			results = found;
			searched = true;
		} catch (e) {
			if (id === requestId) error = friendlyError(e);
		} finally {
			if (id === requestId) searching = false;
		}
	}

	function startCreate() {
		creating = true;
		newPhone = isDigits ? query.trim() : '';
		newName = isDigits ? '' : query.trim();
	}

	function createNew() {
		if (!normalizedNewPhone || !newName.trim()) return;
		onselect({
			id: null,
			name: newName.trim(),
			phone: normalizedNewPhone,
			default_address: delivery ? newAddress.trim() || null : null,
			default_patokan: delivery ? newPatokan.trim() || null : null,
			phone_verified: false,
			from_website: false
		});
	}
</script>

<Modal title={creating ? 'Pelanggan baru' : 'Pilih pelanggan'} {onclose}>
	{#if !creating}
		<input
			bind:this={searchInput}
			class="input search"
			placeholder="Ketik nomor HP atau nama"
			bind:value={query}
			oninput={onQueryInput}
			autocomplete="off"
		/>
		<p class="hint">
			{#if tooShort}
				Minimal 4 digit nomor HP atau 3 huruf nama.
			{:else if searching}
				Mencari…
			{:else if searched && results.length === 0}
				Tidak ditemukan.
			{:else}
				&nbsp;
			{/if}
		</p>
		<p class="error" role="alert">{error}</p>

		<ul class="results">
			{#each results as c (c.id)}
				<li>
					<button class="result" onclick={() => onselect(c)}>
						<span class="top">
							<strong>{c.name}</strong>
							{#if c.from_website && !c.phone_verified}
								<span class="badge">belum terverifikasi</span>
							{/if}
							{#if !c.from_website}
								<span class="badge local">lokal</span>
							{/if}
						</span>
						<span class="phone">{formatPhone(c.phone)}</span>
						{#if c.default_address}
							<span class="address">{c.default_address}</span>
						{/if}
					</button>
				</li>
			{/each}
		</ul>

		{#if searched && !searching}
			<button class="btn-ghost new" onclick={startCreate}>+ Pelanggan baru</button>
		{/if}
	{:else}
		<div class="form">
			<label>
				<span>Nomor HP</span>
				<input class="input" inputmode="tel" bind:value={newPhone} placeholder="0812…" />
				{#if newPhone && !normalizedNewPhone}
					<small class="error">Nomor HP tidak valid</small>
				{:else if normalizedNewPhone}
					<small>{formatPhone(normalizedNewPhone)}</small>
				{/if}
			</label>
			<label>
				<span>Nama</span>
				<input class="input" bind:value={newName} maxlength="80" />
			</label>
			{#if delivery}
				<label>
					<span>Alamat</span>
					<textarea class="input" rows="2" bind:value={newAddress} maxlength="300"></textarea>
				</label>
				<label>
					<span>Patokan (opsional)</span>
					<input class="input" bind:value={newPatokan} maxlength="150" />
				</label>
			{/if}
		</div>
	{/if}

	{#snippet footer()}
		{#if creating}
			<div class="actions">
				<button class="btn-ghost" onclick={() => (creating = false)}>Kembali cari</button>
				<button
					class="btn-primary"
					onclick={createNew}
					disabled={!normalizedNewPhone || !newName.trim()}
				>
					Pakai pelanggan ini
				</button>
			</div>
		{/if}
	{/snippet}
</Modal>

<style>
	.search {
		font-size: 1.15rem;
		min-height: var(--touch-lg);
	}
	.hint {
		margin: 0.5rem 0 0;
		color: var(--muted);
		font-size: 0.85rem;
	}
	.error {
		color: var(--danger);
		margin: 0;
		min-height: 0;
	}
	.results {
		list-style: none;
		margin: 0.5rem 0 0;
		padding: 0;
	}
	.result {
		display: flex;
		flex-direction: column;
		gap: 0.15rem;
		width: 100%;
		min-height: 56px;
		padding: 0.5rem 0.75rem;
		border: none;
		border-bottom: 1px solid var(--border);
		background: var(--surface);
		text-align: left;
		color: var(--text);
	}
	.result:active {
		background: var(--brand-soft);
	}
	.top {
		display: flex;
		align-items: center;
		gap: 0.5rem;
	}
	.phone,
	.address {
		color: var(--muted);
		font-size: 0.9rem;
	}
	.address {
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.badge {
		font-size: 0.72rem;
		padding: 0.05rem 0.45rem;
		border-radius: 999px;
		background: #fff4e0;
		color: #8a5300;
	}
	.badge.local {
		background: var(--bg);
		color: var(--muted);
	}
	.new {
		width: 100%;
		margin-top: 0.75rem;
		min-height: var(--touch-lg);
		font-weight: 600;
	}
	.form {
		display: flex;
		flex-direction: column;
		gap: 0.85rem;
	}
	.form label {
		display: flex;
		flex-direction: column;
		gap: 0.3rem;
		color: var(--muted);
		font-size: 0.9rem;
	}
	.form small {
		color: var(--muted);
	}
	textarea.input {
		padding: 0.6rem 0.85rem;
		resize: vertical;
	}
	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 0.5rem;
	}
</style>
