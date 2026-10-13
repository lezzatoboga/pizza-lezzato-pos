<script lang="ts">
	import { onMount } from 'svelte';
	import { page } from '$app/state';
	import { auth } from '$lib/auth/auth.svelte';
	import ReceiptTemplate from '$lib/components/ReceiptTemplate.svelte';
	import PrinterTest from '$lib/components/PrinterTest.svelte';
	import NamedListEditor from '$lib/components/NamedListEditor.svelte';
	import { friendlyError, rupiah } from '$lib/format';
	import {
		getSyncStatus,
		loadSettings,
		saveBankAccount,
		saveCourier,
		setCustomerSyncPaused,
		setDeliveryRate,
		setPaymentMethodActive,
		updatePlatformMarkup,
		type SettingsData,
		type SyncStatus
	} from '$lib/pos/data';
	import { dateTimeOf } from '$lib/pos/report';
	import {
		checkWebConnection,
		loadResendIssues,
		OUTBOX_ERROR_TEXT,
		resolveResendIssue,
		statusLabelOf,
		type ConnectionCheck,
		type ResendIssue
	} from '$lib/pos/web-orders';
	import { webAlerts } from '$lib/pos/web-alerts.svelte';
	import { shippingFromDistance } from '$lib/pos/pricing';

	type Tab =
		'markup' | 'ongkir' | 'kurir' | 'rekening' | 'metode' | 'struk' | 'printer' | 'sinkron';

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
				['printer', 'Printer'],
				['sinkron', 'Sinkron']
			] as [Tab, string][]
		).filter(([t]) => t !== 'markup' || canMarkup)
	);

	let tab = $state<Tab | null>((page.url.searchParams.get('tab') as Tab | null) ?? null);
	let data = $state<SettingsData | null>(null);
	let loadError = $state('');
	let busy = $state(false);
	let error = $state('');
	let saved = $state('');

	// Draft input
	let markupDrafts = $state<Record<string, string>>({});
	let rateInput = $state('');
	let sync = $state<SyncStatus | null>(null);
	let pauseNote = $state('');
	// Jembatan pesanan website — khusus Owner.
	const isOwner = $derived(auth.profile?.role.code === 'owner');
	let checks = $state<ConnectionCheck[] | null>(null);
	let checking = $state(false);
	let issues = $state<ResendIssue[]>([]);

	const activeTab = $derived(tab ?? tabs[0]?.[0] ?? 'ongkir');
	const rate = $derived(Number(rateInput.replace(/\D/g, '')) || 0);

	onMount(reload);

	async function reload() {
		try {
			[data, sync] = await Promise.all([loadSettings(), getSyncStatus()]);
			issues = isOwner ? await loadResendIssues() : [];
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

	async function runChecks() {
		checking = true;
		checks = null;
		error = '';
		try {
			checks = (await checkWebConnection()).checks;
		} catch (e) {
			error = friendlyError(e);
		} finally {
			checking = false;
		}
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
					<ReceiptTemplate outletId={data.outlet.id} />
				{:else if activeTab === 'sinkron' && sync}
					{@const menuRun = sync.last_runs.find((r) => r.kind === 'menu')}
					<h2>Sinkron dari website</h2>
					<p class="muted">
						Menu disinkron otomatis tiap 15 menit; pelanggan juga, kecuali sedang dijeda.
					</p>

					<dl class="sync-info">
						<dt>Menu</dt>
						<dd>
							{#if menuRun}
								{menuRun.status === 'success' ? 'Berhasil' : 'Gagal'} · {dateTimeOf(
									menuRun.created_at
								)}
								{#if menuRun.status !== 'success' && menuRun.error}
									<span class="sync-error">{menuRun.error}</span>
								{/if}
							{:else}
								Belum pernah
							{/if}
						</dd>
						<dt>Pelanggan</dt>
						<dd>
							<strong class:paused={sync.customers_paused}>
								{sync.customers_paused ? 'Dijeda' : 'Aktif'}
							</strong>
							{#if sync.customers_paused && sync.customers_paused_at}
								sejak {dateTimeOf(sync.customers_paused_at)}{sync.customers_paused_by
									? ` oleh ${sync.customers_paused_by}`
									: ''}
							{/if}
						</dd>
						{#if sync.customers_paused && sync.customers_pause_note}
							<dt>Alasan</dt>
							<dd>{sync.customers_pause_note}</dd>
						{/if}
						<dt>Data pelanggan terakhir</dt>
						<dd>
							{sync.last_success.customers
								? dateTimeOf(sync.last_success.customers)
								: 'Belum pernah'}
						</dd>
					</dl>

					{#if sync.customers_paused}
						<p class="muted">
							Selama dijeda, pencarian pelanggan di kasir memakai data terakhir di atas; pelanggan
							baru tetap bisa diinput manual. Aktifkan kembali hanya setelah akses baca pelanggan
							website dibuka lagi — kalau belum, sinkron akan gagal terus.
						</p>
						<button
							class="btn-primary"
							disabled={busy}
							onclick={() =>
								run(async () => {
									await setCustomerSyncPaused(false, '');
								}, 'Sinkron pelanggan diaktifkan kembali')}
						>
							Aktifkan kembali sinkron pelanggan
						</button>
					{:else}
						<label class="pause-note">
							<span>Alasan jeda (opsional)</span>
							<input class="input" bind:value={pauseNote} maxlength="200" />
						</label>
						<button
							class="btn-primary"
							disabled={busy}
							onclick={() =>
								run(async () => {
									await setCustomerSyncPaused(true, pauseNote);
									pauseNote = '';
								}, 'Sinkron pelanggan dijeda')}
						>
							Jeda sinkron pelanggan
						</button>
					{/if}

					{#if isOwner}
						<h2 class="section">Jembatan pesanan website</h2>
						<p class="muted">
							Cek koneksi ke database website (uji X1–X2): hanya membaca dan memanggil fungsi status
							dengan data yang pasti ditolak — tidak mengubah data apa pun.
						</p>
						<button class="btn-primary" disabled={checking} onclick={runChecks}>
							{checking ? 'Mengecek…' : 'Cek koneksi website'}
						</button>
						{#if checks}
							<p class="check-summary" class:bad={!checks.every((c) => c.lolos)}>
								{checks.filter((c) => c.lolos).length} dari {checks.length} lolos
							</p>
							<table class="checks">
								<thead>
									<tr><th>Uji</th><th>Harapan</th><th>Hasil</th><th></th></tr>
								</thead>
								<tbody>
									{#each checks as c, i (i)}
										<tr class:bad={!c.lolos}>
											<td>{c.kode} · {c.uji}</td>
											<td>{c.harapan}</td>
											<td class="result">{c.hasil}</td>
											<td>{c.lolos ? 'LOLOS' : 'GAGAL'}</td>
										</tr>
									{/each}
								</tbody>
							</table>
						{/if}

						<h3>Perlu diselesaikan manual</h3>
						{#if issues.length === 0}
							<p class="muted">
								Tidak ada. Status yang ditolak website setelah saklar go-live menyala lagi muncul di
								sini.
							</p>
						{:else}
							<p class="muted">
								Setelah saklar go-live menyala lagi, status terakhir POS untuk pesanan ini ditolak
								website (dikirim ulang sekali, tidak dicoba lagi) atau tidak bisa dikirim karena
								status akhirnya berbeda. Samakan di panel admin website atau di POS, lalu tandai
								selesai. Lihat docs/SOP-SAKLAR-GO-LIVE.md.
							</p>
							<ul class="rows">
								{#each issues as it (it.id)}
									<li class="issue">
										<span class="label">
											<strong>{it.web_orders.order_code}</strong>
											{it.web_orders.transactions?.transaction_number ?? ''} · POS:
											{statusLabelOf(it.status)} · website: {statusLabelOf(
												it.web_orders.web_status
											)}
											<span class="sync-error"
												>{OUTBOX_ERROR_TEXT[it.last_error ?? ''] ?? it.last_error}</span
											>
										</span>
										<button
											class="btn-ghost"
											disabled={busy}
											onclick={() =>
												run(async () => {
													await resolveResendIssue(it.id);
													await webAlerts.refresh();
												}, `${it.web_orders.order_code} ditandai selesai`)}
										>
											Tandai selesai
										</button>
									</li>
								{/each}
							</ul>
						{/if}
					{/if}
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
	h2.section {
		margin-top: 1.5rem;
	}
	h3 {
		margin: 1.25rem 0 0.25rem;
		font-size: 1rem;
	}
	.check-summary {
		font-weight: 700;
		color: #166534;
	}
	.check-summary.bad,
	tr.bad td {
		color: #b42318;
	}
	.checks {
		width: 100%;
		border-collapse: collapse;
		font-size: 0.9rem;
	}
	.checks th,
	.checks td {
		text-align: left;
		padding: 0.35rem 0.5rem;
		border-bottom: 1px solid var(--border, #ddd);
		vertical-align: top;
	}
	.checks .result {
		word-break: break-word;
	}
	.issue .label {
		flex: 1;
	}
	.sync-info {
		display: grid;
		grid-template-columns: auto 1fr;
		gap: 0.4rem 1.25rem;
		margin: 1rem 0;
	}
	.sync-info dt {
		color: var(--muted);
	}
	.sync-info dd {
		margin: 0;
	}
	.sync-error {
		display: block;
		color: var(--danger);
		font-size: 0.9rem;
	}
	.paused {
		color: #8a5300;
	}
	.pause-note {
		display: flex;
		flex-direction: column;
		gap: 0.3rem;
		max-width: 28rem;
		margin-bottom: 0.75rem;
		color: var(--muted);
		font-size: 0.9rem;
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
