<script lang="ts">
	import { onMount } from 'svelte';
	import { friendlyError, timeOf } from '$lib/format';
	import { lastMenuSync, syncMenuNow, type MenuSyncRun } from '$lib/pos/data';
	import { menuVersion } from '$lib/pos/menu-version.svelte';

	let last = $state<MenuSyncRun | null>(null);
	let syncing = $state(false);
	let message = $state('');

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
		try {
			const result = await syncMenuNow();
			message = `${result.products} produk, ${result.toppings} topping`;
			menuVersion.bump();
		} catch (e) {
			message = friendlyError(e);
		} finally {
			syncing = false;
			await refresh();
		}
	}
</script>

<div class="sync">
	<button class="btn-ghost" onclick={sync} disabled={syncing}>
		{syncing ? 'Menyinkron…' : 'Sinkron menu'}
	</button>
	<small title={last?.error ?? ''} class:failed={last?.status === 'failed'}>
		{#if message}
			{message}
		{:else if last}
			{last.status === 'failed' ? 'Gagal' : 'Terakhir'} {timeOf(last.created_at)}
		{:else}
			Belum pernah
		{/if}
	</small>
</div>

<style>
	.sync {
		display: flex;
		align-items: center;
		gap: 0.5rem;
	}
	small {
		color: var(--muted);
		max-width: 16rem;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	small.failed {
		color: var(--danger);
	}
	@media (max-width: 900px) {
		small {
			display: none;
		}
	}
</style>
