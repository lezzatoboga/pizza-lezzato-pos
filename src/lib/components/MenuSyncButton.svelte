<script lang="ts">
	import { onMount } from 'svelte';
	import { friendlyError, timeOf } from '$lib/format';
	import { lastMenuSync, syncMenuNow, type MenuSyncRun } from '$lib/pos/data';
	import { menuVersion } from '$lib/pos/menu-version.svelte';

	let last = $state<MenuSyncRun | null>(null);
	let syncing = $state(false);
	let message = $state('');
	let failedMessage = $state('');
	// Detail error ditampilkan lewat ketukan (bukan tooltip hover).
	let showDetail = $state(false);

	onMount(refresh);

	async function refresh() {
		try {
			last = await lastMenuSync();
		} catch {
			last = null;
		}
	}

	async function sync() {
		if (syncing) return;
		syncing = true;
		message = '';
		failedMessage = '';
		showDetail = false;
		try {
			const result = await syncMenuNow();
			message = `${result.products} produk, ${result.toppings} topping`;
			menuVersion.bump();
		} catch (e) {
			failedMessage = friendlyError(e);
		} finally {
			syncing = false;
			await refresh();
		}
	}

	const errorDetail = $derived(
		failedMessage || (last?.status === 'failed' ? (last.error ?? '') : '')
	);
</script>

<div class="sync">
	<button class="btn-ghost" onclick={sync} disabled={syncing}>
		{syncing ? 'Menyinkron…' : 'Sinkron menu'}
	</button>

	{#if errorDetail}
		<button class="status failed" onclick={() => (showDetail = !showDetail)}>
			Gagal {last ? timeOf(last.created_at) : ''} ⓘ
		</button>
	{:else}
		<span class="status">
			{#if message}
				{message}
			{:else if last}
				Terakhir {timeOf(last.created_at)}
			{:else}
				Belum pernah
			{/if}
		</span>
	{/if}

	{#if showDetail && errorDetail}
		<div class="detail" role="alert">
			<p>{errorDetail}</p>
			<button class="btn-ghost" onclick={() => (showDetail = false)}>Tutup</button>
		</div>
	{/if}
</div>

<style>
	.sync {
		position: relative;
		display: flex;
		align-items: center;
		gap: 0.5rem;
	}
	.status {
		color: var(--muted);
		font-size: 0.85rem;
		white-space: nowrap;
	}
	button.status {
		min-height: var(--touch);
		border: none;
		background: none;
		padding: 0 0.5rem;
		font: inherit;
		font-size: 0.85rem;
	}
	.status.failed {
		color: var(--danger);
		font-weight: 600;
	}
	.detail {
		position: absolute;
		top: calc(100% + 0.5rem);
		right: 0;
		z-index: 40;
		width: min(420px, 90vw);
		padding: 0.75rem 1rem;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--radius);
		box-shadow: 0 8px 24px rgb(0 0 0 / 0.15);
	}
	.detail p {
		margin: 0 0 0.75rem;
		color: var(--danger);
		overflow-wrap: anywhere;
	}
</style>
