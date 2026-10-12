<script lang="ts">
	// Tombol "Sinkron": menu lalu pelanggan dari website. Selama sinkron
	// pelanggan dijeda (Pengaturan → Sinkron), hanya menu yang disinkron dan
	// indikator hanya menampilkan status menu.
	import { onMount } from 'svelte';
	import { friendlyError, timeOf } from '$lib/format';
	import { getSyncStatus, syncCustomersNow, syncMenuNow, type SyncStatus } from '$lib/pos/data';
	import { menuVersion } from '$lib/pos/menu-version.svelte';
	import { dateTimeOf } from '$lib/pos/report';

	const KIND_LABEL: Record<string, string> = { menu: 'Menu', customers: 'Pelanggan' };

	let status = $state<SyncStatus | null>(null);
	let syncing = $state(false);
	let message = $state('');
	let failures = $state<string[]>([]);
	// Detail ditampilkan lewat ketukan (bukan tooltip hover).
	let showDetail = $state(false);

	onMount(refresh);

	async function refresh() {
		try {
			status = await getSyncStatus();
		} catch {
			status = null;
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
		if (!paused) {
			try {
				const result = await syncCustomersNow();
				if (!result.paused) parts.push(`${result.customers} pelanggan`);
			} catch (e) {
				failures.push(`Pelanggan: ${friendlyError(e)}`);
			}
		}

		message = parts.join(' · ');
		syncing = false;
		await refresh();
	}

	const paused = $derived(status?.customers_paused ?? false);
	const runs = $derived((status?.last_runs ?? []).filter((r) => !paused || r.kind === 'menu'));

	// Gagal terakhir (dari log, atau dari sinkron manual barusan). Selama
	// pelanggan dijeda, hanya kegagalan menu yang dihitung.
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
	const pauseInfo = $derived(
		paused && status
			? [
					`Sinkron pelanggan dijeda${status.customers_paused_at ? ` sejak ${dateTimeOf(status.customers_paused_at)}` : ''}.`,
					`Data pelanggan terakhir: ${status.last_success.customers ? dateTimeOf(status.last_success.customers) : 'belum pernah'}.`,
					'Pelanggan baru tetap bisa diinput manual di kasir.'
				]
			: []
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
	{:else if paused}
		<button class="status" onclick={() => (showDetail = !showDetail)}>
			Menu {lastTime ?? '–'} · Pelanggan dijeda
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

	{#if showDetail && (errorDetails.length || pauseInfo.length)}
		<div class="detail" role="alert">
			{#each errorDetails as detail (detail)}
				<p>{detail}</p>
			{/each}
			{#each pauseInfo as info (info)}
				<p class="info">{info}</p>
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
	.detail p.info {
		color: var(--text);
	}
	.detail button {
		margin-top: 0.25rem;
	}
</style>
