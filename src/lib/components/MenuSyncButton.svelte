<script lang="ts">
	// Tombol "Sinkron": menu lalu pelanggan dari website.
	import { onMount } from 'svelte';
	import { friendlyError, timeOf } from '$lib/format';
	import { lastSyncRuns, syncCustomersNow, syncMenuNow, type MenuSyncRun } from '$lib/pos/data';
	import { menuVersion } from '$lib/pos/menu-version.svelte';

	const KIND_LABEL: Record<string, string> = { menu: 'Menu', customers: 'Pelanggan' };

	let runs = $state<MenuSyncRun[]>([]);
	let syncing = $state(false);
	let message = $state('');
	let failures = $state<string[]>([]);
	// Detail error ditampilkan lewat ketukan (bukan tooltip hover).
	let showDetail = $state(false);

	onMount(refresh);

	async function refresh() {
		try {
			runs = await lastSyncRuns();
		} catch {
			runs = [];
		}
	}

	async function sync() {
		if (syncing) return;
		syncing = true;
		message = '';
		failures = [];
		showDetail = false;
		const parts: string[] = [];

		try {
			const menu = await syncMenuNow();
			parts.push(`${menu.products} produk, ${menu.packages} paket`);
			menuVersion.bump();
		} catch (e) {
			failures.push(`Menu: ${friendlyError(e)}`);
		}
		try {
			const result = await syncCustomersNow();
			parts.push(`${result.customers} pelanggan`);
		} catch (e) {
			failures.push(`Pelanggan: ${friendlyError(e)}`);
		}

		message = parts.join(' · ');
		syncing = false;
		await refresh();
	}

	// Gagal terakhir per jenis (dari log) atau dari sinkron manual barusan.
	const errorDetails = $derived(
		failures.length
			? failures
			: runs
					.filter((r) => r.status === 'failed')
					.map((r) => `${KIND_LABEL[r.kind] ?? r.kind}: ${r.error ?? 'gagal'}`)
	);
	const lastTime = $derived(
		runs.length
			? timeOf(
					runs
						.map((r) => r.created_at)
						.sort()
						.at(-1)!
				)
			: null
	);
</script>

<div class="sync">
	<button class="btn-ghost" onclick={sync} disabled={syncing}>
		{syncing ? 'Menyinkron…' : 'Sinkron'}
	</button>

	{#if errorDetails.length}
		<button class="status failed" onclick={() => (showDetail = !showDetail)}>
			Gagal {lastTime ?? ''} ⓘ
		</button>
	{:else}
		<span class="status">
			{#if message}
				{message}
			{:else if lastTime}
				Terakhir {lastTime}
			{:else}
				Belum pernah
			{/if}
		</span>
	{/if}

	{#if showDetail && errorDetails.length}
		<div class="detail" role="alert">
			{#each errorDetails as detail (detail)}
				<p>{detail}</p>
			{/each}
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
		margin: 0 0 0.5rem;
		color: var(--danger);
		overflow-wrap: anywhere;
	}
	.detail button {
		margin-top: 0.25rem;
	}
</style>
