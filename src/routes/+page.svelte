<script lang="ts">
	import { onMount } from 'svelte';
	import { auth } from '$lib/auth/auth.svelte';
	import CustomerDialog from '$lib/components/CustomerDialog.svelte';
	import OpenShiftForm from '$lib/components/OpenShiftForm.svelte';
	import PackageDialog from '$lib/components/PackageDialog.svelte';
	import PaymentDialog from '$lib/components/PaymentDialog.svelte';
	import ProductDialog from '$lib/components/ProductDialog.svelte';
	import { formatPhone, friendlyError, rupiah, timeOf } from '$lib/format';
	import {
		createTransaction,
		loadContext,
		loadMenu,
		type PaymentResult,
		type PosContext,
		type TransactionPayload
	} from '$lib/pos/data';
	import { menuVersion } from '$lib/pos/menu-version.svelte';
	import { groupMenu, type MenuSectionGroup } from '$lib/pos/menu-order';
	import { applyMarkup, lineTotal } from '$lib/pos/pricing';
	import type {
		CartLine,
		Customer,
		Channel,
		Menu,
		Product,
		SalesType,
		SavedTransaction
	} from '$lib/pos/types';

	let ctx = $state<PosContext | null>(null);
	let menu = $state<Menu | null>(null);
	let loadError = $state('');

	// Menu
	let category = $state('');
	let search = $state('');
	let picking = $state<Product | null>(null);

	// Keranjang & detail pesanan
	let lines = $state<CartLine[]>([]);
	let channel = $state<Channel>('admin_toko');
	let salesType = $state<SalesType>('dine_in');
	let platformId = $state('');
	let markupOverride = $state<string | null>(null);
	let shippingInput = $state('');
	// Pelanggan (admin toko) — nama/alamat bisa diubah khusus pesanan ini
	let customer = $state<Customer | null>(null);
	let pickingCustomer = $state(false);
	let orderName = $state('');
	let deliveryAddress = $state('');
	let deliveryPatokan = $state('');
	// Marketplace: kode pesanan dari platform
	let marketplaceRef = $state('');
	let orderNotes = $state('');

	let saving = $state(false);
	let saveError = $state('');
	let paying = $state<SavedTransaction | null>(null);
	let toast = $state('');
	let toastTimer: ReturnType<typeof setTimeout> | undefined;

	onMount(async () => {
		try {
			ctx = await loadContext();
			platformId = ctx.platforms[0]?.id ?? '';
		} catch (e) {
			loadError = friendlyError(e);
		}
	});

	// Muat (ulang) menu saat pertama kali dan setiap selesai sinkron manual.
	$effect(() => {
		void menuVersion.value;
		loadMenu()
			.then((m) => {
				menu = m;
				if (!groups.some((g) => g.slug === category)) category = groups[0]?.slug ?? '';
			})
			.catch((e) => (loadError = friendlyError(e)));
	});

	// Urutan sama dengan /menu website: kategori → section → produk.
	const groups = $derived(menu ? groupMenu(menu) : []);

	const visibleSections = $derived.by((): MenuSectionGroup[] => {
		const q = search.trim().toLowerCase();
		if (q) {
			const products = groups
				.flatMap((g) => g.sections.flatMap((s) => s.products))
				.filter((p) => p.name.toLowerCase().includes(q));
			return [{ key: null, label: null, products }];
		}
		return groups.find((g) => g.slug === category)?.sections ?? [];
	});

	const platform = $derived(ctx?.platforms.find((p) => p.id === platformId) ?? null);
	const markupPercent = $derived(
		channel === 'marketplace'
			? markupOverride !== null && markupOverride.trim() !== ''
				? Number(markupOverride)
				: (platform?.markup_percent ?? 0)
			: 0
	);
	const markupValid = $derived(
		Number.isFinite(markupPercent) && markupPercent >= 0 && markupPercent <= 999
	);

	const shippingAllowed = $derived(channel === 'admin_toko' && salesType === 'delivery');
	const shipping = $derived(shippingAllowed ? Number(shippingInput.replace(/\D/g, '')) || 0 : 0);

	function basePrice(line: CartLine) {
		return line.variant?.price ?? line.product.base_price ?? 0;
	}

	function toppingUnitBase(line: CartLine) {
		return line.variant ? (menu?.toppingPrices[line.variant.variant_key] ?? 0) : 0;
	}

	function priceOf(line: CartLine) {
		const toppingBase = toppingUnitBase(line);
		return lineTotal(
			basePrice(line),
			line.qty,
			line.toppings.map((t) => ({ price: toppingBase, qty: t.qty })),
			markupPercent
		);
	}

	// Admin toko delivery: pelanggan & alamat wajib; dine-in/take away opsional.
	const isDelivery = $derived(channel === 'admin_toko' && salesType === 'delivery');
	const customerMissing = $derived(isDelivery && (!customer || !deliveryAddress.trim()));

	function selectCustomer(c: Customer) {
		customer = c;
		orderName = c.name;
		deliveryAddress = c.default_address ?? '';
		deliveryPatokan = c.default_patokan ?? '';
		pickingCustomer = false;
	}

	const subtotal = $derived(lines.reduce((sum, l) => sum + priceOf(l), 0));
	const total = $derived(subtotal + shipping);

	function productFromPrice(p: Product) {
		const prices = p.variants.length ? p.variants.map((v) => v.price) : [p.base_price ?? 0];
		return applyMarkup(Math.min(...prices), markupPercent);
	}

	function lineSignature(line: Omit<CartLine, 'key'>) {
		return JSON.stringify([
			line.product.id,
			line.variant?.id ?? null,
			line.notes,
			line.toppings.map((t) => [t.topping.id, t.qty]).sort(),
			line.choices.map((c) => [c.key, c.value])
		]);
	}

	function addLine(line: Omit<CartLine, 'key'>) {
		const signature = lineSignature(line);
		const existing = lines.find((l) => lineSignature(l) === signature);
		if (existing) existing.qty = Math.min(999, existing.qty + line.qty);
		else lines.push({ ...line, key: crypto.randomUUID() });
		picking = null;
	}

	// Produk simple & paket tanpa pilihan: langsung masuk keranjang sekali ketuk.
	function tapProduct(p: Product) {
		const needsDialog =
			p.kind === 'package' ? (p.package_choices ?? []).length > 0 : p.kind !== 'simple';
		if (needsDialog) {
			picking = p;
		} else {
			addLine({ product: p, variant: null, qty: 1, notes: '', toppings: [], choices: [] });
		}
	}

	function changeQty(line: CartLine, delta: number) {
		line.qty = Math.max(0, Math.min(999, line.qty + delta));
		if (line.qty === 0) lines = lines.filter((l) => l !== line);
	}

	function selectChannel(next: Channel) {
		channel = next;
		markupOverride = null;
		if (next === 'marketplace') salesType = 'delivery';
	}

	function resetOrder() {
		lines = [];
		shippingInput = '';
		customer = null;
		orderName = '';
		deliveryAddress = '';
		deliveryPatokan = '';
		marketplaceRef = '';
		orderNotes = '';
		markupOverride = null;
		saveError = '';
	}

	function showToast(message: string) {
		toast = message;
		clearTimeout(toastTimer);
		toastTimer = setTimeout(() => (toast = ''), 5000);
	}

	async function save(payNow: boolean) {
		if (!ctx || saving || lines.length === 0) return;
		saving = true;
		saveError = '';

		const payload: TransactionPayload = {
			outlet_id: ctx.outlet.id,
			channel,
			sales_type: channel === 'marketplace' ? 'delivery' : salesType,
			shipping_cost: shipping,
			notes: orderNotes,
			items: lines.map((l) => ({
				item_type: l.product.kind === 'package' ? ('package' as const) : ('product' as const),
				product_id: l.product.id,
				variant_id: l.variant?.id ?? null,
				qty: l.qty,
				notes: l.notes,
				toppings: l.toppings.map((t) => ({ id: t.topping.id, qty: t.qty })),
				choices: Object.fromEntries(l.choices.map((c) => [c.key, c.value]))
			}))
		};
		if (channel === 'admin_toko' && customer) {
			payload.customer = customer.id
				? { id: customer.id }
				: { name: customer.name, phone: customer.phone };
			payload.customer_name = orderName.trim() || customer.name;
		}
		if (isDelivery) {
			payload.delivery_address = deliveryAddress;
			payload.delivery_patokan = deliveryPatokan;
		}
		if (channel === 'marketplace') {
			payload.customer_name = marketplaceRef;
			payload.marketplace_platform_id = platformId;
			payload.markup_percent = markupPercent;
		}

		try {
			const saved = await createTransaction(payload);
			resetOrder();
			if (payNow) paying = saved;
			else
				showToast(`${saved.transaction_number} tersimpan · belum dibayar · ${rupiah(saved.total)}`);
		} catch (e) {
			saveError = friendlyError(e);
		} finally {
			saving = false;
		}
	}

	function onPaid(result: PaymentResult) {
		paying = null;
		showToast(
			result.change_amount > 0
				? `${result.transaction_number} lunas · kembalian ${rupiah(result.change_amount)}`
				: `${result.transaction_number} lunas`
		);
	}

	function onPaymentClosed() {
		if (paying) showToast(`${paying.transaction_number} tersimpan · belum dibayar`);
		paying = null;
	}
</script>

{#if loadError}
	<p class="page-error">{loadError}</p>
{:else if !ctx}
	<p class="page-status">Memuat…</p>
{:else if ctx.shift?.status === 'counting'}
	<div class="counting">
		<p>Shift sedang ditutup — hitungan kas sudah disimpan.</p>
		<a class="btn-primary as-link" href="/shift">Lanjutkan tutup shift</a>
	</div>
{:else if !ctx.shift}
	<OpenShiftForm outlet={ctx.outlet} onopened={(shift) => ctx && (ctx.shift = shift)} />
{:else}
	<div class="pos">
		<!-- Menu -->
		<section class="menu">
			<div class="menu-top">
				<input class="input search" placeholder="Cari menu…" bind:value={search} />
				<span class="shift-info">Shift dibuka {timeOf(ctx.shift.opening_time)}</span>
			</div>

			{#if !menu}
				<p class="page-status">Memuat menu…</p>
			{:else if menu.products.length === 0}
				<div class="empty">
					<p>Menu belum tersedia.</p>
					<p class="muted">
						{auth.can('sync_menu')
							? 'Tekan "Sinkron menu" di atas untuk mengambil menu dari website.'
							: 'Minta Owner menekan "Sinkron menu".'}
					</p>
				</div>
			{:else}
				{#if !search.trim()}
					<div class="tabs">
						{#each groups as g (g.slug)}
							<button class:selected={g.slug === category} onclick={() => (category = g.slug)}>
								{g.label}
							</button>
						{/each}
					</div>
				{/if}

				<div class="products">
					{#each visibleSections as s (s.key)}
						{#if s.label}<h3 class="section-title">{s.label}</h3>{/if}
						<div class="grid">
							{#each s.products as p (p.id)}
								<button class="product" onclick={() => tapProduct(p)}>
									<span class="name">{p.name}</span>
									{#if p.kind === 'package'}
										<span class="contents">{(p.package_items ?? []).join(' · ')}</span>
									{/if}
									<span class="price">
										{p.variants.length > 1 ? 'mulai ' : ''}{rupiah(productFromPrice(p))}
									</span>
								</button>
							{:else}
								<p class="muted">Tidak ada menu yang cocok.</p>
							{/each}
						</div>
					{/each}
				</div>
			{/if}
		</section>

		<!-- Keranjang -->
		<aside class="cart">
			<div class="segmented">
				<button
					class:selected={channel === 'admin_toko'}
					onclick={() => selectChannel('admin_toko')}
				>
					Admin toko
				</button>
				<button
					class:selected={channel === 'marketplace'}
					onclick={() => selectChannel('marketplace')}
				>
					Marketplace
				</button>
			</div>

			{#if channel === 'admin_toko'}
				<div class="segmented">
					<button class:selected={salesType === 'dine_in'} onclick={() => (salesType = 'dine_in')}
						>Dine-in</button
					>
					<button
						class:selected={salesType === 'take_away'}
						onclick={() => (salesType = 'take_away')}>Take away</button
					>
					<button class:selected={salesType === 'delivery'} onclick={() => (salesType = 'delivery')}
						>Delivery</button
					>
				</div>
			{:else}
				<div class="segmented">
					{#each ctx.platforms as p (p.id)}
						<button
							class:selected={p.id === platformId}
							onclick={() => {
								platformId = p.id;
								markupOverride = null;
							}}>{p.name}</button
						>
					{/each}
				</div>
				<div class="markup">
					{#if markupOverride === null}
						<span>Markup {platform?.markup_percent ?? 0}% · Delivery</span>
						{#if auth.can('override_markup')}
							<button
								class="link"
								onclick={() => (markupOverride = String(platform?.markup_percent ?? 0))}
							>
								Ubah
							</button>
						{/if}
					{:else}
						<label>
							Markup khusus transaksi ini (%)
							<input class="input small" inputmode="decimal" bind:value={markupOverride} />
						</label>
						<button class="link" onclick={() => (markupOverride = null)}>Batal</button>
					{/if}
				</div>
			{/if}

			{#if channel === 'marketplace'}
				<input
					class="input"
					placeholder="Kode pesanan / nama (opsional)"
					bind:value={marketplaceRef}
					maxlength="80"
				/>
			{:else if !customer}
				<button
					class="pick-customer"
					class:required={isDelivery}
					onclick={() => (pickingCustomer = true)}
				>
					+ Pilih pelanggan
					<small>{isDelivery ? '(wajib untuk delivery)' : '(opsional)'}</small>
				</button>
			{:else}
				<div class="customer-card">
					<div class="customer-head">
						<input
							class="input name"
							bind:value={orderName}
							maxlength="80"
							aria-label="Nama untuk pesanan ini"
						/>
						<button class="link" onclick={() => (pickingCustomer = true)}>Ganti</button>
						<button class="link" onclick={() => (customer = null)} aria-label="Hapus pelanggan"
							>✕</button
						>
					</div>
					<span class="customer-phone">
						{formatPhone(customer.phone)}{customer.id ? '' : ' · pelanggan baru'}
					</span>
					{#if isDelivery}
						<textarea
							class="input address"
							rows="2"
							placeholder="Alamat pengiriman (wajib)"
							bind:value={deliveryAddress}
							maxlength="300"></textarea>
						<input
							class="input"
							placeholder="Patokan (opsional)"
							bind:value={deliveryPatokan}
							maxlength="150"
						/>
					{/if}
				</div>
			{/if}

			<ul class="lines">
				{#each lines as line (line.key)}
					<li>
						<div class="line-info">
							<strong>{line.product.name}</strong>
							{#if line.variant}<span class="muted"> · {line.variant.label}</span>{/if}
							{#each line.toppings as t (t.topping.id)}
								<div class="sub">+ {t.topping.name}{t.qty > 1 ? ` ×${t.qty}` : ''}</div>
							{/each}
							{#each line.choices as c (c.key)}
								<div class="sub">{c.label}: <strong>{c.value}</strong></div>
							{/each}
							{#if line.product.package_note}
								<div class="sub">{line.product.package_note}</div>
							{/if}
							{#if line.notes}<div class="sub note">“{line.notes}”</div>{/if}
						</div>
						<div class="line-side">
							<span class="line-price">{rupiah(priceOf(line))}</span>
							<div class="stepper">
								<button onclick={() => changeQty(line, -1)} aria-label="Kurangi">−</button>
								<span class="count">{line.qty}</span>
								<button onclick={() => changeQty(line, 1)} aria-label="Tambah">+</button>
							</div>
						</div>
					</li>
				{:else}
					<li class="empty-cart">Belum ada item. Pilih menu di sebelah kiri.</li>
				{/each}
			</ul>

			<input
				class="input"
				placeholder="Catatan pesanan (opsional)"
				bind:value={orderNotes}
				maxlength="200"
			/>

			<dl class="totals">
				<dt>Subtotal</dt>
				<dd>{rupiah(subtotal)}</dd>
				{#if shippingAllowed}
					<dt>Ongkir</dt>
					<dd>
						<input
							class="input small"
							inputmode="numeric"
							placeholder="0"
							value={shipping ? shipping.toLocaleString('id-ID') : ''}
							oninput={(e) => (shippingInput = e.currentTarget.value)}
						/>
					</dd>
				{/if}
				<dt class="grand">Total</dt>
				<dd class="grand">{rupiah(total)}</dd>
			</dl>

			<p class="error" role="alert">
				{saveError ||
					(!markupValid
						? 'Markup tidak valid'
						: customerMissing && lines.length > 0
							? 'Delivery: pilih pelanggan dan isi alamat'
							: '')}
			</p>

			<div class="actions">
				<button
					class="btn-ghost"
					onclick={() => save(false)}
					disabled={saving || lines.length === 0 || !markupValid || customerMissing}
				>
					Simpan
				</button>
				<button
					class="btn-primary"
					onclick={() => save(true)}
					disabled={saving || lines.length === 0 || !markupValid || customerMissing}
				>
					{saving ? 'Menyimpan…' : `Bayar ${rupiah(total)}`}
				</button>
			</div>
		</aside>
	</div>
{/if}

{#if picking && picking.kind === 'package'}
	<PackageDialog pkg={picking} {markupPercent} onadd={addLine} onclose={() => (picking = null)} />
{:else if picking && menu}
	<ProductDialog
		product={picking}
		{menu}
		{markupPercent}
		onadd={addLine}
		onclose={() => (picking = null)}
	/>
{/if}

{#if pickingCustomer}
	<CustomerDialog
		delivery={isDelivery}
		onselect={selectCustomer}
		onclose={() => (pickingCustomer = false)}
	/>
{/if}

{#if paying && ctx}
	<PaymentDialog
		transaction={paying}
		methods={ctx.paymentMethods}
		bankAccounts={ctx.bankAccounts}
		ondone={onPaid}
		onclose={onPaymentClosed}
	/>
{/if}

{#if toast}
	<div class="toast" role="status">{toast}</div>
{/if}

<style>
	.page-status,
	.page-error {
		text-align: center;
		margin-top: 3rem;
		color: var(--muted);
	}
	.page-error {
		color: var(--danger);
	}
	.counting {
		max-width: 420px;
		margin: 3rem auto;
		text-align: center;
	}
	.as-link {
		display: inline-flex;
		align-items: center;
		text-decoration: none;
	}
	.muted {
		color: var(--muted);
	}
	/* Landscape tablet: menu kiri, keranjang kanan, masing-masing bergulir sendiri */
	.pos {
		display: grid;
		grid-template-columns: 1fr minmax(340px, 34%);
		height: calc(100dvh - var(--topbar-h));
	}
	.menu {
		display: flex;
		flex-direction: column;
		gap: 0.75rem;
		padding: 1rem;
		overflow: hidden;
	}
	.menu-top {
		display: flex;
		align-items: center;
		gap: 1rem;
	}
	.search {
		max-width: 320px;
	}
	.shift-info {
		margin-left: auto;
		font-size: 0.85rem;
		color: var(--muted);
		white-space: nowrap;
	}
	/* Semua kategori terlihat sekaligus (terbungkus ke baris berikutnya), tanpa geser */
	.tabs {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
	}
	.tabs button {
		flex: none;
		min-height: var(--touch-lg);
		border: 1px solid var(--border);
		border-radius: 999px;
		background: var(--surface);
		padding: 0 1.1rem;
		font-weight: 600;
		color: var(--muted);
	}
	.tabs button.selected {
		border-color: var(--brand);
		background: var(--brand);
		color: #fff;
	}
	.products {
		flex: 1;
		min-height: 0;
		overflow-y: auto;
		padding-bottom: 1rem;
	}
	.section-title {
		margin: 0.75rem 0 0.5rem;
		font-size: 0.95rem;
		color: var(--muted);
	}
	.section-title:first-child {
		margin-top: 0;
	}
	.grid {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
		gap: 0.75rem;
		align-content: start;
	}
	.product {
		display: flex;
		flex-direction: column;
		justify-content: space-between;
		gap: 0.5rem;
		min-height: 96px;
		padding: 0.85rem;
		border: 1px solid var(--border);
		border-radius: var(--radius);
		background: var(--surface);
		text-align: left;
	}
	.product:active {
		background: var(--brand-soft);
	}
	.product .name {
		font-weight: 600;
	}
	.product .contents {
		font-size: 0.8rem;
		color: var(--muted);
		line-height: 1.3;
	}
	.product .price {
		color: var(--brand);
		font-size: 0.9rem;
	}
	.empty {
		margin: 3rem auto;
		text-align: center;
	}
	.cart {
		display: flex;
		flex-direction: column;
		gap: 0.6rem;
		padding: 1rem;
		background: var(--surface);
		border-left: 1px solid var(--border);
		overflow-y: auto;
	}
	.markup {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 0.5rem;
		font-size: 0.9rem;
		color: var(--muted);
	}
	.markup label {
		display: flex;
		align-items: center;
		gap: 0.5rem;
	}
	.pick-customer {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		min-height: var(--touch-lg);
		padding: 0 1rem;
		border: 1px dashed var(--border);
		border-radius: var(--radius);
		background: var(--surface);
		color: var(--brand);
		font-weight: 600;
	}
	.pick-customer small {
		color: var(--muted);
		font-weight: 400;
	}
	.pick-customer.required {
		border-color: var(--brand);
		background: var(--brand-soft);
	}
	.pick-customer:active {
		background: var(--brand-soft);
	}
	.customer-card {
		display: flex;
		flex-direction: column;
		gap: 0.4rem;
		padding: 0.6rem;
		border: 1px solid var(--border);
		border-radius: var(--radius);
	}
	.customer-head {
		display: flex;
		align-items: center;
		gap: 0.25rem;
	}
	.customer-head .name {
		flex: 1;
		font-weight: 600;
	}
	.customer-phone {
		padding-left: 0.25rem;
		color: var(--muted);
		font-size: 0.9rem;
	}
	textarea.address {
		padding: 0.6rem 0.85rem;
		resize: vertical;
	}
	.input.small {
		width: 7.5rem;
		text-align: right;
	}
	.lines {
		list-style: none;
		margin: 0;
		padding: 0;
		flex: 1;
		min-height: 120px;
	}
	.lines li {
		display: flex;
		justify-content: space-between;
		gap: 0.75rem;
		padding: 0.6rem 0;
		border-bottom: 1px solid var(--border);
	}
	.lines .empty-cart {
		justify-content: center;
		color: var(--muted);
		border: none;
		padding: 2rem 0;
		text-align: center;
	}
	.sub {
		font-size: 0.85rem;
		color: var(--muted);
	}
	.note {
		font-style: italic;
	}
	.line-side {
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: 0.35rem;
	}
	.line-price {
		font-weight: 600;
		white-space: nowrap;
	}
	.totals {
		display: grid;
		grid-template-columns: 1fr auto;
		align-items: center;
		gap: 0.35rem 1rem;
		margin: 0.25rem 0 0;
	}
	.totals dt {
		color: var(--muted);
	}
	.totals dd {
		margin: 0;
		text-align: right;
	}
	.totals .grand {
		font-size: 1.25rem;
		font-weight: 700;
		color: var(--text);
	}
	.error {
		color: var(--danger);
		min-height: 1.2em;
		margin: 0;
		font-size: 0.9rem;
	}
	/* Simpan & Bayar sama besar: delivery COD sering Simpan dulu, Bayar belakangan */
	.actions {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 0.5rem;
	}
	.actions button {
		min-height: 56px;
		font-size: 1.05rem;
		font-weight: 600;
	}
	.actions .btn-ghost {
		border: 2px solid var(--brand);
		color: var(--brand);
	}
	.toast {
		position: fixed;
		left: 50%;
		bottom: 1.5rem;
		transform: translateX(-50%);
		z-index: 60;
		max-width: calc(100vw - 2rem);
		padding: 0.8rem 1.2rem;
		border-radius: var(--radius);
		background: var(--text);
		color: #fff;
		box-shadow: 0 6px 20px rgb(0 0 0 / 0.2);
	}
	@media (max-width: 900px) {
		.pos {
			grid-template-columns: 1fr;
			height: auto;
		}
		.menu {
			overflow: visible;
		}
		.products {
			overflow: visible;
		}
		.cart {
			border-left: none;
			border-top: 1px solid var(--border);
		}
	}
</style>
