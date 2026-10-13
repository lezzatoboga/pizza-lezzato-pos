<script lang="ts">
	// Pesanan Web: daftar pesanan website (kiri) + detail terpilih (kanan).
	// Data diperbarui tiap 15 detik; penarikan dari website oleh Edge Function
	// web-orders-sync (cron 30 detik) atau tombol "Cek pesanan".
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import WebOrderDetail from '$lib/components/WebOrderDetail.svelte';
	import { friendlyError, rupiah, timeOf } from '$lib/format';
	import { loadContext, loadMenu, type PosContext } from '$lib/pos/data';
	import type { Menu } from '$lib/pos/types';
	import { webAlerts } from '$lib/pos/web-alerts.svelte';
	import {
		loadBridgeState,
		loadWebOrders,
		openWebOrder,
		ORDER_TYPE_LABEL,
		isTestWebOrder,
		outboxState,
		statusText,
		syncWebOrders,
		type BridgeState,
		type WebOrder
	} from '$lib/pos/web-orders';

	let orders = $state<WebOrder[] | null>(null);
	let ctx = $state<PosContext | null>(null);
	let menu = $state<Menu | null>(null);
	let bridge = $state<BridgeState | null>(null);
	let error = $state('');
	let tab = $state<'aktif' | 'selesai'>('aktif');
	let syncing = $state(false);
	let syncMessage = $state('');

	const selectedId = $derived(page.url.searchParams.get('id'));
	const selected = $derived(orders?.find((o) => o.id === selectedId) ?? null);

	const isActive = (o: WebOrder) =>
		!!o.transactions &&
		o.transactions.status === 'active' &&
		o.transactions.order_status !== 'selesai';
	const visible = $derived(
		(orders ?? []).filter((o) => (tab === 'aktif' ? isActive(o) : !isActive(o)))
	);
	const activeCount = $derived((orders ?? []).filter(isActive).length);

	async function refresh() {
		try {
			const [o, b] = await Promise.all([loadWebOrders(), loadBridgeState()]);
			orders = o;
			bridge = b;
			error = '';
		} catch (e) {
			error = friendlyError(e);
		}
		webAlerts.refresh();
	}

	onMount(() => {
		Promise.all([loadContext(), loadMenu()])
			.then(([c, m]) => {
				ctx = c;
				menu = m;
			})
			.catch((e) => (error = friendlyError(e)));
		refresh();
		const t = setInterval(refresh, 15_000);
		return () => clearInterval(t);
	});

	// Membuka pesanan menghentikan bunyi notifikasi.
	$effect(() => {
		const o = selected;
		if (o && !o.opened_at) openWebOrder(o.id).then(refresh);
	});

	function select(o: WebOrder) {
		goto(`?id=${o.id}`, { replaceState: true, noScroll: true, keepFocus: true });
	}

	async function checkNow() {
		if (syncing) return;
		syncing = true;
		syncMessage = '';
		try {
			const r = await syncWebOrders();
			syncMessage = r.busy
				? 'Sedang dicek otomatis — tunggu sebentar.'
				: r.ok
					? `Selesai dicek · ${r.created ?? 0} pesanan baru`
					: String(r.error ?? 'Gagal dicek');
		} catch (e) {
			syncMessage = friendlyError(e);
		} finally {
			syncing = false;
			refresh();
		}
	}

	// Setelah aksi kasir: muat ulang & kirim status secepatnya (tanpa menunggu cron).
	function changed() {
		refresh();
		syncWebOrders()
			.then(refresh)
			.catch(() => {});
	}

	const bridgeText = $derived(
		!bridge
			? ''
			: bridge.inactive_reason === 'sebelum_go_live'
				? 'Jembatan dimatikan dari website — kelola pesanan aktif di panel admin website.'
				: bridge.last_error
					? `Gagal cek terakhir: ${bridge.last_error}`
					: bridge.view_empty && !orders?.length
						? 'Jembatan website belum aktif (go-live belum diisi di website).'
						: bridge.last_ok_at
							? `Dicek ${timeOf(bridge.last_ok_at)}`
							: 'Belum pernah dicek'
	);
</script>

<section class="page">
	<aside class="list">
		<header>
			<h1>Pesanan Web</h1>
			<button class="btn-ghost" onclick={checkNow} disabled={syncing}>
				{syncing ? 'Mengecek…' : 'Cek pesanan'}
			</button>
		</header>
		<p class="bridge" class:bad={!!bridge?.last_error || bridge?.inactive_reason}>
			{syncMessage || bridgeText}
		</p>
		<div class="segmented">
			<button class:selected={tab === 'aktif'} onclick={() => (tab = 'aktif')}>
				Aktif{activeCount ? ` (${activeCount})` : ''}
			</button>
			<button class:selected={tab === 'selesai'} onclick={() => (tab = 'selesai')}>
				Selesai & batal
			</button>
		</div>

		{#if error}
			<p class="error">{error}</p>
		{:else if !orders}
			<p class="muted">Memuat…</p>
		{:else}
			<ul>
				{#each visible as o (o.id)}
					{@const tx = o.transactions}
					<li>
						<button
							class="row"
							class:selected={o.id === selectedId}
							class:unopened={!o.opened_at}
							onclick={() => select(o)}
						>
							<span class="top">
								<span class="type {o.order_type}"
									>{ORDER_TYPE_LABEL[o.order_type].toUpperCase()}</span
								>
								<strong>{o.order_code}</strong>
								<span class="time">{timeOf(o.first_seen_at)}</span>
							</span>
							<span class="mid">
								<span>{o.header.recipient_name}</span>
								<strong>{rupiah(tx?.total ?? o.header.total)}</strong>
							</span>
							<span class="tags">
								{#if isTestWebOrder(o.header)}<span class="tag test">UJI</span>{/if}
								{#if !o.opened_at}<span class="tag new">BARU</span>{/if}
								<span class="tag">{statusText(o)}</span>
								{#if tx?.payment_status === 'paid'}<span class="tag ok">Lunas</span>{/if}
								{#if o.menunggu_admin}<span class="tag warn">Menunggu admin</span>{/if}
								{#if tx?.transaction_items.some((i) => i.mapping_warning)}<span class="tag bad"
										>Periksa item</span
									>{/if}
								{#if o.diubah_di_pos}<span class="tag">Diubah kasir</span>{/if}
								{#if o.terkunci_edit}<span class="tag">Lunas online</span>{/if}
								{#if outboxState(o) === 'gagal'}<span class="tag bad">Status ditolak</span>{/if}
								{#if o.cancel_notice}<span class="tag bad">Batal setelah bayar</span>{/if}
							</span>
						</button>
					</li>
				{:else}
					<li class="muted empty">
						{tab === 'aktif'
							? 'Tidak ada pesanan website aktif.'
							: 'Belum ada pesanan selesai/batal (3 hari terakhir).'}
					</li>
				{/each}
			</ul>
		{/if}
	</aside>

	<main class="pane">
		{#if selected && ctx}
			{#key selected.id}
				<WebOrderDetail order={selected} {ctx} {menu} onchanged={changed} />
			{/key}
		{:else}
			<p class="muted placeholder">Pilih pesanan di kiri.</p>
		{/if}
	</main>
</section>

<style>
	.page {
		display: grid;
		grid-template-columns: minmax(300px, 380px) 1fr;
		gap: 1rem;
		padding: 1rem;
		max-width: 1400px;
		margin: 0 auto;
	}
	.list {
		display: flex;
		flex-direction: column;
		gap: 0.6rem;
	}
	.list header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 0.5rem;
	}
	h1 {
		margin: 0;
		font-size: 1.3rem;
	}
	.bridge {
		margin: 0;
		font-size: 0.85rem;
		color: var(--muted);
	}
	.bridge.bad {
		color: var(--danger);
		font-weight: 600;
	}
	ul {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 0.45rem;
	}
	.row {
		display: flex;
		flex-direction: column;
		gap: 0.3rem;
		width: 100%;
		padding: 0.7rem 0.85rem;
		border: 1px solid var(--border);
		border-radius: var(--radius);
		background: var(--surface);
		color: var(--text);
		text-align: left;
	}
	.row.selected {
		border-color: var(--brand);
		box-shadow: inset 0 0 0 1px var(--brand);
	}
	.row.unopened {
		background: #fff8f6;
		border-left: 5px solid var(--brand);
	}
	.row:active {
		background: var(--brand-soft);
	}
	.top,
	.mid {
		display: flex;
		align-items: center;
		gap: 0.5rem;
	}
	.mid {
		justify-content: space-between;
	}
	.time {
		margin-left: auto;
		color: var(--muted);
		font-size: 0.85rem;
	}
	.type {
		padding: 0.1rem 0.45rem;
		border-radius: 6px;
		font-size: 0.75rem;
		font-weight: 800;
		color: #fff;
	}
	.type.delivery {
		background: #2a4f9a;
	}
	.type.takeaway {
		background: #1e6b3a;
	}
	.type.dinein {
		background: #8a3fb0;
	}
	.tags {
		display: flex;
		flex-wrap: wrap;
		gap: 0.3rem;
	}
	.tag {
		padding: 0.05rem 0.45rem;
		border-radius: 999px;
		background: var(--bg);
		font-size: 0.75rem;
		font-weight: 600;
		color: var(--muted);
	}
	.tag.new {
		background: var(--brand);
		color: #fff;
	}
	.tag.test {
		background: #1d4ed8;
		color: #fff;
	}
	.tag.ok {
		background: #e8f4ec;
		color: #1e6b3a;
	}
	.tag.warn {
		background: #fff4e0;
		color: #8a5300;
	}
	.tag.bad {
		background: var(--brand-soft);
		color: var(--danger);
	}
	.pane {
		min-width: 0;
		padding: 1rem 1.2rem;
		border: 1px solid var(--border);
		border-radius: var(--radius);
		background: var(--surface);
		align-self: start;
	}
	.placeholder,
	.empty {
		padding: 2rem 0;
		text-align: center;
	}
	.muted {
		color: var(--muted);
	}
	.error {
		color: var(--danger);
	}
	@media (max-width: 900px) {
		.page {
			grid-template-columns: 1fr;
		}
	}
</style>
