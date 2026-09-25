<script lang="ts">
	// Pilih printer dapur & kasir (Bluetooth yang sudah dipasangkan) dan uji cetak.
	import { onMount } from 'svelte';
	import {
		assignPrinter,
		getPrinterAssignment,
		isNativeApp,
		listPairedPrinters,
		printTo,
		PRINTER_ROLE_LABEL,
		type BluetoothPrinter,
		type PrinterRole
	} from '$lib/print/printer';
	import { testKitchenTicket, testLineSpacing, testReceipt, testWidth } from '$lib/print/test-docs';

	const ROLES: PrinterRole[] = ['kitchen', 'cashier'];

	const native = isNativeApp();
	let paired = $state<BluetoothPrinter[]>([]);
	let assignment = $state(getPrinterAssignment());
	let loading = $state(false);
	let status = $state('');
	let statusKind = $state<'info' | 'ok' | 'fail'>('info');

	onMount(() => {
		if (native) refresh();
	});

	async function refresh() {
		loading = true;
		try {
			paired = await listPairedPrinters();
			if (!paired.length) {
				statusKind = 'info';
				status =
					'Belum ada perangkat Bluetooth yang dipasangkan. Pasangkan printer di Pengaturan Bluetooth Android dulu.';
			}
		} catch (e) {
			statusKind = 'fail';
			status = (e as Error).message;
		} finally {
			loading = false;
		}
	}

	function choose(role: PrinterRole, printer: BluetoothPrinter) {
		assignment = assignPrinter(role, printer);
	}

	async function print(name: string, role: PrinterRole, make: () => Uint8Array) {
		statusKind = 'info';
		status = `Mencetak "${name}" ke ${PRINTER_ROLE_LABEL[role]}…`;
		const started = performance.now();
		try {
			await printTo(role, make());
			const seconds = ((performance.now() - started) / 1000).toFixed(1);
			statusKind = 'ok';
			status = `"${name}" terkirim ke ${PRINTER_ROLE_LABEL[role]} (${seconds} detik).`;
		} catch (e) {
			statusKind = 'fail';
			status = (e as Error).message;
		}
	}
</script>

<h2>Printer</h2>

{#if !native}
	<p class="warn">
		Anda membuka POS lewat browser. Pengaturan & cetak printer hanya tersedia di
		<strong>aplikasi Android Pizza Lezzato POS</strong> di tablet kasir.
	</p>
{:else}
	<p class="muted">
		Pasangkan (pairing) kedua printer lewat Pengaturan Bluetooth Android, lalu pilih mana printer
		dapur dan mana printer kasir. Pilihan ini tersimpan di tablet ini.
	</p>

	<div class="refresh">
		<button class="btn-ghost" onclick={refresh} disabled={loading}>
			{loading ? 'Memuat…' : 'Muat ulang daftar printer'}
		</button>
	</div>

	{#each ROLES as role (role)}
		<section class="role">
			<h3>
				{PRINTER_ROLE_LABEL[role]}:
				<span class:unset={!assignment[role]}>{assignment[role]?.name ?? 'belum dipilih'}</span>
			</h3>
			<div class="options">
				{#each paired as p (p.address)}
					<button
						class="option"
						class:selected={assignment[role]?.address === p.address}
						onclick={() => choose(role, p)}
					>
						<span>{p.name}</span>
						<small>{p.address}</small>
					</button>
				{/each}
			</div>
		</section>
	{/each}

	{#if status}
		<p class="status {statusKind}" role="status">{status}</p>
	{/if}

	<h3>Uji cetak</h3>
	<div class="buttons">
		<button
			class="btn-primary"
			onclick={() => print('Tes tiket dapur', 'kitchen', testKitchenTicket)}
		>
			Tes tiket → dapur
		</button>
		<button class="btn-primary" onclick={() => print('Tes struk', 'cashier', testReceipt)}>
			Tes struk → kasir
		</button>
		<button class="btn-ghost" onclick={() => print('Tes lebar kertas', 'cashier', testWidth)}>
			Tes lebar kertas
		</button>
		<button class="btn-ghost" onclick={() => print('Tes jarak baris', 'cashier', testLineSpacing)}>
			Tes jarak baris
		</button>
	</div>

	<h3>Yang perlu dicek & dilaporkan</h3>
	<ol class="checklist">
		<li>
			<strong>Dua printer:</strong> apakah "Tes tiket → dapur" keluar di printer dapur dan "Tes struk
			→ kasir" keluar di printer kasir?
		</li>
		<li>
			<strong>Lebar kertas:</strong> apakah baris angka 1–32 muat satu baris tanpa terpotong? Apakah huruf
			tebal, tinggi 2x, dan besar 2x tampil berbeda?
		</li>
		<li>
			<strong>Jarak baris:</strong> pilih yang paling rapat tapi masih nyaman dibaca (A default printer,
			B 28, C 26, D 24 titik). Apakah catatan huruf kecil di blok E masih terbaca?
		</li>
		<li>
			<strong>Kecepatan:</strong> berapa detik yang tertulis di status, dan kira-kira berapa detik sampai
			kertas keluar?
		</li>
	</ol>
{/if}

<style>
	h2 {
		margin: 0 0 0.25rem;
		font-size: 1.1rem;
	}
	h3 {
		margin: 1.25rem 0 0.5rem;
		font-size: 1rem;
	}
	h3 .unset {
		color: var(--danger);
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
	.refresh {
		margin-bottom: 0.25rem;
	}
	.options {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
		gap: 0.5rem;
	}
	.option {
		display: flex;
		flex-direction: column;
		justify-content: center;
		gap: 0.15rem;
		min-height: 56px;
		padding: 0.4rem 0.75rem;
		border: 1px solid var(--border);
		border-radius: var(--radius);
		background: var(--surface);
		text-align: left;
		color: var(--text);
	}
	.option small {
		color: var(--muted);
		font-size: 0.75rem;
	}
	.option.selected {
		border-color: var(--brand);
		background: var(--brand-soft);
		box-shadow: inset 0 0 0 1px var(--brand);
	}
	.buttons {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
	}
	.status {
		margin-top: 1rem;
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
	.checklist {
		margin: 0;
		padding-left: 1.25rem;
	}
	.checklist li {
		margin-bottom: 0.5rem;
	}
</style>
