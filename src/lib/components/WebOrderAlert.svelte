<script lang="ts">
	// Notifikasi pesanan website di SEMUA halaman (keputusan Owner 13 Okt):
	//   - bunyi berulang ±10 detik + banner sampai pesanan dibuka kasir;
	//   - slip BATAL otomatis dicetak di tablet untuk pesanan yang dibatalkan
	//     dari website (tiket dapur sudah tercetak).
	// Browser/WebView butuh satu ketukan sebelum suara boleh berbunyi.
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { auth } from '$lib/auth/auth.svelte';
	import { friendlyError } from '$lib/format';
	import { webAlerts } from '$lib/pos/web-alerts.svelte';
	import { voidSlipDone } from '$lib/pos/web-orders';
	import { printVoidSlip } from '$lib/print/jobs';
	import { isNativeApp } from '$lib/print/printer';

	const POLL_MS = 15_000;
	const BEEP_MS = 10_000;

	let audio: AudioContext | null = null;
	let soundBlocked = $state(false);
	let slipError = $state('');
	const slipTried = new Map<string, number>();

	function unlockAudio() {
		try {
			audio ??= new AudioContext();
			if (audio.state === 'suspended') audio.resume();
			soundBlocked = false;
		} catch {
			// tanpa Web Audio: banner saja
		}
	}

	// Dua nada tinggi ×2 — jelas terdengar di dapur/kasir yang ramai.
	function beep() {
		if (!audio || audio.state !== 'running') {
			soundBlocked = true;
			return;
		}
		const t0 = audio.currentTime;
		[880, 1320, 880, 1320].forEach((freq, i) => {
			const osc = audio!.createOscillator();
			const gain = audio!.createGain();
			const t = t0 + i * 0.22;
			osc.type = 'square';
			osc.frequency.value = freq;
			gain.gain.setValueAtTime(0.0001, t);
			gain.gain.exponentialRampToValueAtTime(0.35, t + 0.02);
			gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.18);
			osc.connect(gain).connect(audio!.destination);
			osc.start(t);
			osc.stop(t + 0.2);
		});
	}

	async function printPendingSlips() {
		if (!isNativeApp()) return;
		for (const s of webAlerts.voidSlips) {
			const last = slipTried.get(s.id) ?? 0;
			if (!s.transaction_id || Date.now() - last < 60_000) continue;
			slipTried.set(s.id, Date.now());
			try {
				await printVoidSlip(s.transaction_id, 'Dibatalkan di website');
				await voidSlipDone(s.id);
				slipError = '';
			} catch (e) {
				slipError = `Slip BATAL ${s.order_code} belum tercetak: ${friendlyError(e)}`;
			}
		}
		await webAlerts.refresh();
	}

	onMount(() => {
		window.addEventListener('pointerdown', unlockAudio, { capture: true });
		unlockAudio();
		webAlerts.refresh().then(printPendingSlips);
		const poll = setInterval(() => webAlerts.refresh().then(printPendingSlips), POLL_MS);
		const ring = setInterval(() => {
			if (webAlerts.unopened.length > 0) beep();
		}, BEEP_MS);
		return () => {
			clearInterval(poll);
			clearInterval(ring);
			window.removeEventListener('pointerdown', unlockAudio, { capture: true });
			webAlerts.clear();
		};
	});

	// Bunyi langsung begitu ada pesanan baru (tak menunggu 10 detik).
	let lastCount = 0;
	$effect(() => {
		const n = webAlerts.unopened.length;
		if (n > lastCount) beep();
		lastCount = n;
	});

	const first = $derived(webAlerts.unopened[0]);
	const onOrdersPage = $derived(page.url.pathname === '/pesanan-web');
	const isOwner = $derived(auth.profile?.role.code === 'owner');
</script>

{#if webAlerts.bridgeOff}
	<div class="banner off" role="alert">
		<strong>Jembatan website DIMATIKAN.</strong>
		Pesanan web baru tidak masuk ke POS; status untuk pelanggan diurus admin di panel website. Bayar &
		masak pesanan yang sudah ada tetap di POS.
	</div>
{/if}
{#if webAlerts.manual > 0 && isOwner && page.url.pathname !== '/pengaturan'}
	<div class="banner notice" role="status">
		{webAlerts.manual} status pesanan web ditolak website setelah saklar go-live menyala lagi — selesaikan
		manual.
		<a class="link" href="/pengaturan?tab=sinkron">Pengaturan → Sinkron</a>
	</div>
{/if}

{#if webAlerts.unopened.length > 0}
	<div class="banner new" role="alert">
		<span class="bell" aria-hidden="true">🔔</span>
		<span class="text">
			<strong>{webAlerts.unopened.length} pesanan website baru</strong>
			<span class="codes">{webAlerts.unopened.map((o) => o.order_code).join(' · ')}</span>
		</span>
		{#if soundBlocked}<span class="hint">Ketuk layar sekali untuk mengaktifkan bunyi</span>{/if}
		<button
			class="open"
			onclick={() => goto(`/pesanan-web?id=${first.id}`, { replaceState: onOrdersPage })}
		>
			Buka pesanan
		</button>
	</div>
{/if}
{#if webAlerts.voidSlips.length > 0 && !isNativeApp()}
	<div class="banner slip" role="status">
		Slip BATAL perlu dicetak dari tablet kasir: {webAlerts.voidSlips
			.map((s) => s.order_code)
			.join(', ')}
	</div>
{/if}
{#if slipError}
	<div class="banner slip" role="alert">{slipError}</div>
{/if}
{#if webAlerts.notices > 0 && !onOrdersPage}
	<div class="banner notice" role="status">
		{webAlerts.notices} pesanan website dibatalkan setelah dibayar — buka Pesanan Web.
	</div>
{/if}

<style>
	.banner {
		display: flex;
		align-items: center;
		gap: 0.75rem;
		padding: 0.5rem 1rem;
		font-size: 0.95rem;
	}
	.banner.new {
		background: var(--brand);
		color: #fff;
		animation: pulse 1.6s ease-in-out infinite;
	}
	@keyframes pulse {
		50% {
			background: var(--brand-strong);
		}
	}
	.bell {
		font-size: 1.4rem;
	}
	.text {
		display: flex;
		flex-direction: column;
		flex: 1;
		min-width: 0;
	}
	.codes {
		font-size: 0.85rem;
		opacity: 0.9;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.hint {
		font-size: 0.85rem;
		font-weight: 600;
		background: rgb(255 255 255 / 0.2);
		padding: 0.2rem 0.6rem;
		border-radius: 999px;
	}
	.open {
		min-height: var(--touch-lg);
		padding: 0 1.2rem;
		border: none;
		border-radius: var(--radius);
		background: #fff;
		color: var(--brand);
		font-weight: 700;
	}
	.banner.off {
		display: block;
		background: #b42318;
		color: #fff;
	}
	.link {
		color: inherit;
		font-weight: 700;
		text-decoration: underline;
		white-space: nowrap;
	}
	.banner.slip,
	.banner.notice {
		background: #fff4e0;
		color: #8a5300;
		font-weight: 600;
	}
	@media (prefers-reduced-motion: reduce) {
		.banner.new {
			animation: none;
		}
	}
</style>
