<script lang="ts">
	import { onMount } from 'svelte';
	import MonoPreview from './MonoPreview.svelte';
	import { friendlyError } from '$lib/format';
	import {
		loadReceiptSettings,
		saveReceiptLogo,
		saveReceiptText,
		type ReceiptSettings
	} from '$lib/pos/data';
	import { EscPos, fromBase64, toBase64 } from '$lib/print/escpos';
	import {
		convertLogo,
		DEFAULT_LOGO_OPTIONS,
		packBits,
		toGray,
		unpackBits,
		type Gray,
		type LogoOptions
	} from '$lib/print/logo';
	import { sendToRawBT } from '$lib/print/rawbt';
	import { writeReceiptFooter, writeReceiptHeader } from '$lib/print/receipt-template';

	let { outletId }: { outletId: string } = $props();

	const WIDTH_CHOICES = [192, 256, 320, 384];
	// Gambar sangat besar diperkecil dulu sebelum diolah, supaya tablet tetap cepat.
	const MAX_SOURCE_SIDE = 1600;

	let settings = $state<ReceiptSettings | null>(null);
	let loadError = $state('');
	let busy = $state(false);
	let error = $state('');
	let saved = $state('');

	// Teks
	let storeName = $state('');
	let address = $state('');
	let whatsapp = $state('');
	let website = $state('');
	let footer = $state('');

	// Logo baru yang sedang disiapkan
	let source = $state<Gray | null>(null);
	let options = $state<LogoOptions>({ ...DEFAULT_LOGO_OPTIONS });
	let fileInput: HTMLInputElement | undefined = $state();

	const draft = $derived(source ? convertLogo(source, options) : null);
	const currentLogo = $derived(
		settings?.logo_data && settings.logo_width && settings.logo_height
			? unpackBits(settings.logo_width, settings.logo_height, fromBase64(settings.logo_data))
			: null
	);
	const textChanged = $derived(
		!!settings &&
			(storeName !== settings.store_name ||
				address !== settings.address ||
				whatsapp !== settings.whatsapp ||
				website !== settings.website ||
				footer !== settings.footer)
	);

	onMount(reload);

	async function reload() {
		try {
			settings = await loadReceiptSettings(outletId);
			storeName = settings?.store_name ?? '';
			address = settings?.address ?? '';
			whatsapp = settings?.whatsapp ?? '';
			website = settings?.website ?? '';
			footer = settings?.footer ?? '';
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

	function saveText() {
		run(
			() =>
				saveReceiptText(outletId, {
					store_name: storeName,
					address,
					whatsapp,
					website,
					footer
				}),
			'Teks struk disimpan'
		);
	}

	async function onFile(event: Event) {
		const file = (event.currentTarget as HTMLInputElement).files?.[0];
		if (!file) return;
		error = '';
		saved = '';
		try {
			const bitmap = await createImageBitmap(file);
			const scale = Math.min(1, MAX_SOURCE_SIDE / Math.max(bitmap.width, bitmap.height));
			const w = Math.round(bitmap.width * scale);
			const h = Math.round(bitmap.height * scale);
			const canvas = document.createElement('canvas');
			canvas.width = w;
			canvas.height = h;
			const ctx = canvas.getContext('2d')!;
			ctx.imageSmoothingQuality = 'high';
			ctx.drawImage(bitmap, 0, 0, w, h);
			source = toGray(ctx.getImageData(0, 0, w, h).data, w, h);
			options = { ...DEFAULT_LOGO_OPTIONS };
		} catch {
			error = 'File tidak bisa dibaca sebagai gambar. Gunakan PNG atau JPG.';
		} finally {
			if (fileInput) fileInput.value = '';
		}
	}

	function saveLogo() {
		if (!draft) return;
		const logo = { width: draft.width, height: draft.height, data: toBase64(packBits(draft)) };
		run(async () => {
			await saveReceiptLogo(outletId, logo);
			source = null;
		}, 'Logo disimpan');
	}

	function removeLogo() {
		run(() => saveReceiptLogo(outletId, null), 'Logo dihapus');
	}

	// Contoh kop & penutup struk sesuai pengaturan yang tersimpan.
	function printSample() {
		if (!settings) return;
		const doc = new EscPos();
		writeReceiptHeader(doc, settings);
		doc.rule('=').align('center').line('(contoh isi struk)').align('left').rule();
		writeReceiptFooter(doc, settings);
		sendToRawBT(doc.cut().toBytes());
	}
</script>

{#if loadError}
	<p class="error">{loadError}</p>
{:else if !settings && !loadError}
	<p class="muted">Memuat…</p>
{:else}
	<h2>Template struk</h2>
	<p class="muted">
		Kop dan penutup yang dicetak di setiap struk. Kalau logo sudah diupload, nama toko tidak dicetak
		(logo sudah memuatnya).
	</p>

	<div class="form">
		<label
			><span>Nama toko</span><input class="input" bind:value={storeName} maxlength="40" /></label
		>
		<label
			><span>Alamat outlet</span><input class="input" bind:value={address} maxlength="120" /></label
		>
		<label
			><span>Nomor WA untuk pelanggan</span><input
				class="input"
				inputmode="tel"
				bind:value={whatsapp}
				maxlength="20"
			/></label
		>
		<label><span>Website</span><input class="input" bind:value={website} maxlength="60" /></label>
		<label
			><span>Ucapan penutup</span><input class="input" bind:value={footer} maxlength="120" /></label
		>
	</div>
	<div class="actions">
		<button
			class="btn-primary"
			onclick={saveText}
			disabled={busy || !textChanged || !storeName.trim()}
		>
			Simpan teks
		</button>
	</div>

	<h3>Logo</h3>
	{#if !source}
		{#if currentLogo}
			<div class="logo-box">
				<MonoPreview image={currentLogo} />
				<small class="muted">{currentLogo.width}×{currentLogo.height} titik</small>
			</div>
		{:else}
			<p class="muted">Belum ada logo. Struk tetap dicetak tanpa logo.</p>
		{/if}
		<div class="actions left">
			<button class="btn-ghost" onclick={() => fileInput?.click()} disabled={busy}>
				{currentLogo ? 'Ganti logo' : 'Upload logo'}
			</button>
			{#if currentLogo}
				<button class="btn-ghost" onclick={removeLogo} disabled={busy}>Hapus logo</button>
			{/if}
		</div>
	{:else if draft}
		<p class="muted">
			Area kosong di sekeliling logo dipotong otomatis. Atur sampai pratinjau terlihat jelas —
			beginilah logo akan tercetak.
		</p>
		<div class="logo-box">
			<MonoPreview image={draft} />
			<small class="muted">{draft.width}×{draft.height} titik</small>
		</div>

		<div class="controls">
			<div>
				<span class="label">Mode</span>
				<div class="segmented">
					<button
						class:selected={options.mode === 'threshold'}
						onclick={() => (options = { ...options, mode: 'threshold', threshold: 160 })}
						>Ambang batas</button
					>
					<button
						class:selected={options.mode === 'dither'}
						onclick={() => (options = { ...options, mode: 'dither', threshold: 128 })}
						>Dithering (foto)</button
					>
				</div>
			</div>
			<div>
				<span class="label">Lebar maksimal</span>
				<div class="segmented">
					{#each WIDTH_CHOICES as w (w)}
						<button
							class:selected={options.maxWidth === w}
							onclick={() => (options = { ...options, maxWidth: w })}>{w}</button
						>
					{/each}
				</div>
			</div>
			<label class="slider">
				<span class="label">Kegelapan: {options.threshold}</span>
				<input
					type="range"
					min="40"
					max="230"
					step="5"
					value={options.threshold}
					oninput={(e) => (options = { ...options, threshold: Number(e.currentTarget.value) })}
				/>
			</label>
		</div>

		<div class="actions">
			<button class="btn-ghost" onclick={() => (source = null)} disabled={busy}>Batal</button>
			<button class="btn-primary" onclick={saveLogo} disabled={busy}>Simpan logo</button>
		</div>
	{/if}
	<input
		bind:this={fileInput}
		type="file"
		accept="image/png,image/jpeg,image/webp"
		hidden
		onchange={onFile}
	/>

	<h3>Contoh cetak</h3>
	<p class="muted">Mencetak kop & penutup yang sudah tersimpan lewat RawBT (tablet Android).</p>
	<button class="btn-ghost" onclick={printSample} disabled={busy}>Cetak contoh struk</button>

	<p class="error" role="alert">{error}</p>
	{#if saved}<p class="saved" role="status">{saved}</p>{/if}
{/if}

<style>
	h2 {
		margin: 0 0 0.25rem;
		font-size: 1.1rem;
	}
	h3 {
		margin: 1.5rem 0 0.5rem;
		font-size: 1rem;
	}
	.muted {
		color: var(--muted);
		margin-top: 0;
	}
	.form {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
		gap: 0.75rem 1rem;
	}
	.form label {
		display: flex;
		flex-direction: column;
		gap: 0.3rem;
		color: var(--muted);
		font-size: 0.9rem;
	}
	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 0.5rem;
		margin-top: 0.75rem;
	}
	.actions.left {
		justify-content: flex-start;
	}
	.logo-box {
		display: inline-flex;
		flex-direction: column;
		gap: 0.35rem;
		padding: 0.75rem;
		border: 1px dashed var(--border);
		border-radius: var(--radius);
		background: #fff;
	}
	.controls {
		display: flex;
		flex-wrap: wrap;
		gap: 1rem 1.5rem;
		margin-top: 0.75rem;
	}
	.label {
		display: block;
		margin-bottom: 0.3rem;
		color: var(--muted);
		font-size: 0.9rem;
	}
	.slider {
		min-width: 260px;
	}
	.slider input {
		width: 100%;
		height: var(--touch);
		accent-color: var(--brand);
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
