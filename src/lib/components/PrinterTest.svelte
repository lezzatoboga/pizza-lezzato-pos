<script lang="ts">
	// Uji printer lewat RawBT sebelum alur cetak lengkap dibangun.
	import { isAndroid, sendToRawBT } from '$lib/print/rawbt';
	import { testKitchenTicket, testReceipt, testWidth } from '$lib/print/test-docs';

	const android = isAndroid();
	let pending = $state('');

	function print(bytes: Uint8Array) {
		sendToRawBT(bytes);
	}

	// Meniru cetak otomatis setelah menunggu server (mis. setelah Simpan).
	function printDelayed(seconds: number) {
		pending = `Mencetak dalam ${seconds} detik…`;
		setTimeout(() => {
			pending = '';
			sendToRawBT(testKitchenTicket());
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

<div class="buttons">
	<button class="btn-primary" onclick={() => print(testKitchenTicket())}>Tes tiket dapur</button>
	<button class="btn-primary" onclick={() => print(testReceipt())}>Tes struk</button>
	<button class="btn-ghost" onclick={() => print(testWidth())}>Tes lebar kertas</button>
</div>

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
	.checklist {
		margin: 0;
		padding-left: 1.25rem;
	}
	.checklist li {
		margin-bottom: 0.5rem;
	}
</style>
