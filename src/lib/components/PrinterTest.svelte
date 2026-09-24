<script lang="ts">
	// Uji printer lewat RawBT sebelum alur cetak lengkap dibangun.
	import { isAndroid, rawbtUrl, sendToRawBT, type RawBTMethod } from '$lib/print/rawbt';
	import { testKitchenTicket, testLineSpacing, testReceipt, testWidth } from '$lib/print/test-docs';

	const android = isAndroid();
	let method = $state<RawBTMethod>('intent');
	let pending = $state('');
	// Diagnosis: memastikan tombol benar-benar berjalan & apakah RawBT terbuka.
	let status = $state('');
	let statusKind = $state<'info' | 'ok' | 'fail'>('info');

	const directLink = $derived(rawbtUrl(testReceipt(), method));

	async function print(name: string, make: () => Uint8Array) {
		statusKind = 'info';
		status = `Mengirim "${name}" ke RawBT (metode ${method})…`;
		try {
			const bytes = make();
			const opened = await sendToRawBT(bytes, method);
			if (opened) {
				statusKind = 'ok';
				status = `"${name}": RawBT terbuka (${bytes.length} byte dikirim, metode ${method}).`;
			} else {
				statusKind = 'fail';
				status = `"${name}": tidak ada aplikasi yang terbuka dalam 3 detik (metode ${method}). Coba metode lain atau tautan langsung di bawah.`;
			}
		} catch (e) {
			statusKind = 'fail';
			status = `"${name}": gagal sebelum memanggil RawBT — ${(e as Error).message}`;
		}
	}

	// Meniru cetak otomatis setelah menunggu server (mis. setelah Simpan).
	function printDelayed(seconds: number) {
		pending = `Mencetak dalam ${seconds} detik…`;
		setTimeout(() => {
			pending = '';
			print(`Tiket tertunda ${seconds} detik`, testKitchenTicket);
		}, seconds * 1000);
	}
</script>

<h2>Uji printer (RawBT)</h2>
<p class="muted">
	Pastikan aplikasi RawBT sudah terpasang di tablet, dan kedua printer MP58SB sudah dipasangkan
	(pairing) lewat Bluetooth.
</p>

{#if !android}
	<p class="warn">
		Perangkat ini bukan Android. Tombol di bawah hanya berfungsi di tablet Android yang terpasang
		RawBT.
	</p>
{/if}

<div class="method">
	<span>Cara memanggil RawBT:</span>
	<div class="segmented">
		<button class:selected={method === 'intent'} onclick={() => (method = 'intent')}>
			Intent (disarankan)
		</button>
		<button class:selected={method === 'scheme'} onclick={() => (method = 'scheme')}>
			Skema rawbt:
		</button>
	</div>
</div>

{#if status}
	<p class="status {statusKind}" role="status">{status}</p>
{/if}

<div class="buttons">
	<button class="btn-primary" onclick={() => print('Tes tiket dapur', testKitchenTicket)}
		>Tes tiket dapur</button
	>
	<button class="btn-primary" onclick={() => print('Tes struk', testReceipt)}>Tes struk</button>
	<button class="btn-ghost" onclick={() => print('Tes lebar kertas', testWidth)}
		>Tes lebar kertas</button
	>
	<button class="btn-ghost" onclick={() => print('Tes jarak baris', testLineSpacing)}
		>Tes jarak baris</button
	>
</div>

<h3>Tautan langsung</h3>
<p class="muted">
	Kalau tombol di atas tidak membuka RawBT, ketuk tautan ini (tes struk, metode yang dipilih di
	atas).
</p>
<a class="btn-ghost as-link" href={directLink}>Buka RawBT lewat tautan</a>

<h3>Tes cetak otomatis (tertunda)</h3>
<p class="muted">
	Meniru tiket dapur yang tercetak otomatis setelah transaksi disimpan (ada jeda menunggu server).
</p>
<div class="buttons">
	<button class="btn-ghost" onclick={() => printDelayed(2)} disabled={!!pending}
		>Tunda 2 detik</button
	>
	<button class="btn-ghost" onclick={() => printDelayed(6)} disabled={!!pending}
		>Tunda 6 detik</button
	>
	{#if pending}<span class="muted">{pending}</span>{/if}
</div>

<h3>Yang perlu dicek & dilaporkan</h3>
<ol class="checklist">
	<li>
		<strong>Cetak dasar:</strong> apakah "Tes struk" langsung tercetak, atau Chrome/RawBT menampilkan
		pertanyaan dulu? (Kalau ada pertanyaan "Buka dengan RawBT?", pilih "Selalu".)
	</li>
	<li>
		<strong>Lebar kertas:</strong> di "Tes lebar kertas", apakah baris angka 1–32 muat dalam satu baris
		tanpa terpotong? Apakah huruf tebal, tinggi 2x, dan besar 2x tampil berbeda?
	</li>
	<li>
		<strong>Dua printer:</strong> di pengaturan RawBT, apakah bisa menyimpan dua printer dan memilih printer
		per cetakan (mis. muncul pilihan printer setiap mencetak)? Coba cetak "Tes tiket dapur" ke printer
		dapur dan "Tes struk" ke printer kasir.
	</li>
	<li>
		<strong>Cetak tertunda:</strong> apakah "Tunda 2 detik" dan "Tunda 6 detik" masih tercetak, atau salah
		satunya diblokir browser?
	</li>
	<li>
		<strong>Jarak baris:</strong> di "Tes jarak baris", pilih yang paling rapat tapi masih nyaman dibaca
		(A default printer, B 28, C 26, D 24 titik). Blok E memakai huruf kecil untuk pemisah & catatan —
		apakah catatan kecil itu masih terbaca jelas?
	</li>
	<li>
		<strong>Kecepatan:</strong> kira-kira berapa detik dari tombol diketuk sampai kertas keluar?
	</li>
</ol>

<style>
	h2 {
		margin: 0 0 0.25rem;
		font-size: 1.1rem;
	}
	h3 {
		margin: 1.25rem 0 0.25rem;
		font-size: 1rem;
	}
	.muted {
		color: var(--muted);
		margin-top: 0;
	}
	.warn {
		padding: 0.6rem 0.85rem;
		border-radius: var(--radius);
		background: #fff4e0;
		color: #8a5300;
	}
	.buttons {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 0.5rem;
	}
	.method {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 0.75rem;
		margin-bottom: 0.75rem;
	}
	.status {
		padding: 0.6rem 0.85rem;
		border-radius: var(--radius);
		background: var(--bg);
		overflow-wrap: anywhere;
	}
	.status.ok {
		background: #eaf6ee;
		color: #1e6b3a;
	}
	.status.fail {
		background: var(--brand-soft);
		color: var(--danger);
	}
	.as-link {
		display: inline-flex;
		align-items: center;
		text-decoration: none;
	}
	.checklist {
		margin: 0;
		padding-left: 1.25rem;
	}
	.checklist li {
		margin-bottom: 0.5rem;
	}
</style>
