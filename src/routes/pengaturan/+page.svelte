<script lang="ts">
	import { onMount } from 'svelte';
	import { auth } from '$lib/auth/auth.svelte';
	import PrinterTest from '$lib/components/PrinterTest.svelte';
	import NamedListEditor from '$lib/components/NamedListEditor.svelte';
	import { friendlyError, rupiah } from '$lib/format';
	import {
		loadSettings,
		saveBankAccount,
		saveCourier,
		setDeliveryRate,
		setPaymentMethodActive,
		updatePlatformMarkup,
		type SettingsData
	} from '$lib/pos/data';
	import { shippingFromDistance } from '$lib/pos/pricing';

	type Tab = 'markup' | 'ongkir' | 'kurir' | 'rekening' | 'metode' | 'struk' | 'printer';

	const canMarkup = $derived(auth.can('edit_markup'));
	const tabs = $derived(
		(
			[
				['markup', 'Markup marketplace'],
				['ongkir', 'Tarif ongkir'],
				['kurir', 'Kurir freelance'],
				['rekening', 'Rekening bank'],
				['metode', 'Metode bayar'],
				['struk', 'Template struk'],
				['printer', 'Printer']
			] as [Tab, string][]
		).filter(([t]) => t !== 'markup' || canMarkup)
	);

	let tab = $state<Tab | null>(null);
	let data = $state<SettingsData | null>(null);
	let loadError = $state('');
	let busy = $state(false);
	let error = $state('');
	let saved = $state('');

	// Draft input
	let markupDrafts = $state<Record<string, string>>({});
	let rateInput = $state('');

	const activeTab = $derived(tab ?? tabs[0]?.[0] ?? 'ongkir');
	const rate = $derived(Number(rateInput.replace(/\D/g, '')) || 0);

	onMount(reload);

	async function reload() {
		try {
			data = await loadSettings();
			rateInput = String(data.outlet.delivery_rate_per_km);
			markupDrafts = {};
		} catch (e) {
			loadError = friendlyError(e);
		}
	}

	async function run(action: () => Promise<void>, message: string) {
		if (busy) return;
		busy = true;
		error = '';
		saved = '';
		try {
			await action();
			await reload();
			saved = message;
		} catch (e) {
			error = friendlyError(e);
		} finally {
			busy = false;
		}
	}

	function selectTab(t: Tab) {
		tab = t;
		error = '';
		saved = '';
	}
</script>

{#if !auth.can('manage_settings')}
	<p class="denied">Anda tidak punya izin membuka Pengaturan.</p>
{:else}
	<section class="page">
		<h1>Pengaturan</h1>

		<div class="tabs">
			{#each tabs as [t, label] (t)}
				<button class:selected={activeTab === t} onclick={() => selectTab(t)}>{label}</button>
			{/each}
		</div>

		{#if loadError}
			<p class="error">{loadError}</p>
		{:else if !data}
			<p class="muted">Memuat…</p>
		{:else}
			<div class="card">
				{#if activeTab === 'markup'}
					<h2>Markup marketplace</h2>
					<p class="muted">
						Harga setiap item dinaikkan sebesar persentase ini untuk platform terkait.
					</p>
					<ul class="rows">
						{#each data.platforms as p (p.id)}
							{@const draft = markupDrafts[p.id] ?? String(p.markup_percent)}
							<li>
								<span class="label">{p.name}</span>
								<div class="with-unit">
									<input
										class="input num"
										inputmode="decimal"
										value={draft}
										oninput={(e) =>
											(markupDrafts = { ...markupDrafts, [p.id]: e.currentTarget.value })}
									/>
									<span>%</span>
								</div>
								<button
									class="btn-primary"
									disabled={busy || Number(draft.replace(',', '.')) === p.markup_percent}
									onclick={() =>
										run(
											() => updatePlatformMarkup(p.id, Number(draft.replace(',', '.'))),
											`Markup ${p.name} disimpan`
										)}>Simpan</button
								>
							</li>
						{/each}
					</ul>
				{:else if activeTab === 'ongkir'}
					<h2>Tarif ongkir per km</h2>
					<p class="muted">
						Dipakai mode "Hitung jarak" di layar kasir. Hasil dibulatkan ke atas per Rp1.000.
					</p>
					<div class="rate">
						<div class="with-unit">
							<span>Rp</span>
							<input
								class="input num wide"
								inputmode="numeric"
								value={rate ? rate.toLocaleString('id-ID') : rateInput === '' ? '' : '0'}
								oninput={(e) => (rateInput = e.currentTarget.value)}
							/>
							<span>/ km</span>
						</div>
						<button
							class="btn-primary"
							disabled={busy || rate === data.outlet.delivery_rate_per_km}
							onclick={() =>
								run(() => setDeliveryRate(data!.outlet.id, rate), 'Tarif ongkir disimpan')}
							>Simpan</button
						>
					</div>
					{#if rate > 0}
						<p class="muted">
							Contoh: 3,7 km → {rupiah(shippingFromDistance(3.7, rate))}
						</p>
					{/if}
				{:else if activeTab === 'kurir'}
					<h2>Kurir freelance</h2>
					<p class="muted">
						Kurir nonaktif tidak muncul di pilihan kasir, tapi tetap tercatat di transaksi lama.
					</p>
					<NamedListEditor
						items={data.couriers}
						addPlaceholder="Nama kurir baru"
						onsave={async (id, name, active) => {
							await saveCourier(id, name, active);
							await reload();
						}}
					/>
				{:else if activeTab === 'rekening'}
					<h2>Rekening bank tujuan transfer</h2>
					<p class="muted">Pilihan rekening saat kasir menerima pembayaran Transfer Bank.</p>
					<NamedListEditor
						items={data.banks.map((b) => ({ id: b.id, name: b.bank_name, active: b.active }))}
						addPlaceholder="Nama bank, mis. BCA"
						onsave={async (id, name, active) => {
							await saveBankAccount(id, name, active);
							await reload();
						}}
					/>
				{:else if activeTab === 'metode'}
					<h2>Metode pembayaran</h2>
					<p class="muted">Tunai selalu aktif karena dipakai rekonsiliasi kas tutup shift.</p>
					<ul class="rows">
						{#each data.methods as m (m.id)}
							<li>
								<span class="label">{m.name}</span>
								<span class="state">{m.active ? 'Aktif' : 'Nonaktif'}</span>
								<button
									class="btn-ghost"
									disabled={busy || m.is_cash}
									onclick={() =>
										run(
											() => setPaymentMethodActive(m.id, !m.active),
											`${m.name} ${m.active ? 'dinonaktifkan' : 'diaktifkan'}`
										)}
								>
									{m.active ? 'Nonaktifkan' : 'Aktifkan'}
								</button>
							</li>
						{/each}
					</ul>
				{:else if activeTab === 'printer'}
					<PrinterTest />
				{:else if activeTab === 'struk'}
					<h2>Template struk</h2>
					<p class="muted">Diatur di tahap cetak (tiket dapur & struk lewat RawBT).</p>
				{/if}

				<p class="error" role="alert">{error}</p>
				{#if saved}<p class="saved" role="status">{saved}</p>{/if}
			</div>
		{/if}
	</section>
{/if}

<style>
	.page {
		max-width: 900px;
		margin: 0 auto;
		padding: 1rem;
	}
	h1 {
		margin: 0 0 1rem;
		font-size: 1.3rem;
	}
	h2 {
		margin: 0 0 0.25rem;
		font-size: 1.1rem;
	}
	.denied {
		text-align: center;
		margin-top: 3rem;
		color: var(--muted);
	}
	.muted {
		color: var(--muted);
		margin-top: 0;
	}
	.tabs {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
		margin-bottom: 1rem;
	}
	.tabs button {
		min-height: var(--touch-lg);
		padding: 0 1.1rem;
		border: 1px solid var(--border);
		border-radius: 999px;
		background: var(--surface);
		color: var(--muted);
		font-weight: 600;
	}
	.tabs button.selected {
		border-color: var(--brand);
		background: var(--brand);
		color: #fff;
	}
	.card {
		padding: 1.25rem;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: 16px;
	}
	.rows {
		list-style: none;
		margin: 0;
		padding: 0;
	}
	.rows li {
		display: grid;
		grid-template-columns: 1fr auto auto;
		align-items: center;
		gap: 0.75rem;
		padding: 0.5rem 0;
		border-bottom: 1px solid var(--border);
	}
	.label {
		font-weight: 600;
	}
	.state {
		color: var(--muted);
		font-size: 0.9rem;
	}
	.with-unit {
		display: flex;
		align-items: center;
		gap: 0.4rem;
	}
	.num {
		width: 6rem;
		text-align: right;
	}
	.num.wide {
		width: 9rem;
	}
	.rate {
		display: flex;
		align-items: center;
		gap: 0.75rem;
		margin: 0.5rem 0;
	}
	.error {
		color: var(--danger);
		min-height: 1.2em;
		margin: 0.75rem 0 0;
	}
	.saved {
		color: #1e6b3a;
		margin: 0.25rem 0 0;
	}
</style>
