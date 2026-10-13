<script lang="ts">
	// Edit pesanan website (hanya sebelum Konfirmasi & Proses). Baris website:
	// qty diubah/dihapus dengan harga website tetap. Tambahan kasir: harga
	// normal POS. Ongkir bisa diubah (Delivery). Saat disimpan, penanda
	// diubah_kasir dikirim ke website DULU — ditolak/offline = tidak tersimpan.
	import Modal from './Modal.svelte';
	import PackageDialog from './PackageDialog.svelte';
	import ProductDialog from './ProductDialog.svelte';
	import { friendlyError, rupiah } from '$lib/format';
	import { lineTotal } from '$lib/pos/pricing';
	import type { CartLine, Menu, Product } from '$lib/pos/types';
	import { editWebOrder, type WebEditPayload, type WebOrder } from '$lib/pos/web-orders';

	let {
		order,
		menu,
		onsaved,
		onclose
	}: { order: WebOrder; menu: Menu; onsaved: () => void; onclose: () => void } = $props();

	type Added = {
		key: string;
		label: string;
		detail: string;
		unit: number; // harga per unit termasuk topping (harga POS)
		qty: number;
		item: Omit<WebEditPayload['new_items'][number], 'qty'>;
	};

	const initial = (() => order)();
	const tx = initial.transactions!;
	const websiteLines = tx.transaction_items.filter((i) => i.source_line_ref);

	// Qty per baris website (0 = dihapus).
	let qty = $state<Record<string, number>>(
		Object.fromEntries(websiteLines.map((i) => [i.source_line_ref!, i.qty]))
	);
	// Tambahan kasir yang sudah ada + yang baru.
	let added = $state<Added[]>(
		tx.transaction_items
			.filter((i) => !i.source_line_ref)
			.map((i) => ({
				key: i.id,
				label: i.product_name_snapshot,
				detail: [
					i.variant_name_snapshot,
					...i.transaction_item_addons.map((a) => `+ ${a.addon_name_snapshot}`),
					...(i.package_choices_snapshot ?? []).map((c) => c.value)
				]
					.filter(Boolean)
					.join(' · '),
				unit: i.subtotal_item / i.qty,
				qty: i.qty,
				item: {
					item_type: i.item_type,
					product_id: i.product_id,
					variant_id: i.variant_id,
					notes: i.notes ?? undefined,
					toppings: i.transaction_item_addons.map((a) => ({ id: a.addon_id, qty: a.qty })),
					choices: Object.fromEntries(
						(i.package_choices_snapshot ?? []).map((c) => [c.key, c.value])
					)
				}
			}))
	);
	const isDelivery = tx.sales_type === 'delivery';
	let shippingInput = $state(String(tx.shipping_cost));
	let search = $state('');
	let picking = $state<Product | null>(null);
	let busy = $state(false);
	let error = $state('');

	const shipping = $derived(Number(shippingInput.replace(/\D/g, '')) || 0);
	const websiteSubtotal = $derived(
		websiteLines.reduce((s, i) => s + (i.subtotal_item / i.qty) * (qty[i.source_line_ref!] ?? 0), 0)
	);
	const addedSubtotal = $derived(added.reduce((s, a) => s + a.unit * a.qty, 0));
	const subtotal = $derived(websiteSubtotal + addedSubtotal);
	const discount = $derived(Math.min(tx.discount_amount, subtotal));
	const total = $derived(subtotal - discount + (isDelivery ? shipping : 0));
	const itemCount = $derived(
		Object.values(qty).reduce((s, q) => s + q, 0) + added.reduce((s, a) => s + a.qty, 0)
	);
	const results = $derived(
		search.trim().length < 2
			? []
			: menu.products
					.filter((p) => p.name.toLowerCase().includes(search.trim().toLowerCase()))
					.slice(0, 8)
	);

	function priceOf(p: Product): number {
		if (p.kind === 'package' || p.kind === 'simple') return p.base_price ?? 0;
		return Math.min(...p.variants.map((v) => v.price));
	}

	function tapProduct(p: Product) {
		const needsDialog =
			p.kind === 'package' ? (p.package_choices ?? []).length > 0 : p.kind !== 'simple';
		if (needsDialog) picking = p;
		else addLine({ product: p, variant: null, qty: 1, notes: '', toppings: [], choices: [] });
	}

	function addLine(line: Omit<CartLine, 'key'>) {
		const base = line.variant?.price ?? line.product.base_price ?? 0;
		const toppings = line.toppings.map((t) => ({
			price: line.variant ? (menu.toppingPrices[line.variant.variant_key] ?? 0) : 0,
			qty: t.qty
		}));
		added.push({
			key: crypto.randomUUID(),
			label: line.product.name,
			detail: [
				line.variant?.label,
				...line.toppings.map((t) => `+ ${t.topping.name}`),
				...line.choices.map((c) => c.value)
			]
				.filter(Boolean)
				.join(' · '),
			unit: lineTotal(base, 1, toppings, 0),
			qty: line.qty,
			item: {
				item_type: line.product.kind === 'package' ? 'package' : 'product',
				product_id: line.product.id,
				variant_id: line.variant?.id ?? null,
				notes: line.notes || undefined,
				toppings: line.toppings.map((t) => ({ id: t.topping.id, qty: t.qty })),
				choices: Object.fromEntries(line.choices.map((c) => [c.key, c.value]))
			}
		});
		picking = null;
		search = '';
	}

	async function save() {
		if (busy) return;
		busy = true;
		error = '';
		try {
			await editWebOrder(tx.id, {
				lines: websiteLines.map((i) => ({
					ref: i.source_line_ref!,
					qty: qty[i.source_line_ref!] ?? 0
				})),
				new_items: added.map((a) => ({ ...a.item, qty: a.qty })),
				...(isDelivery ? { shipping_cost: shipping } : {})
			});
			onsaved();
		} catch (e) {
			error = friendlyError(e);
		} finally {
			busy = false;
		}
	}
</script>

<Modal title="Ubah pesanan {order.order_code}" {onclose}>
	<p class="note">
		Perubahan dikirim ke website sebagai <strong>diubah kasir</strong> sebelum disimpan — pelanggan lalu
		membayar di tempat. Setelah Konfirmasi & Proses, pesanan tidak bisa diubah lagi.
	</p>

	<h3>Item dari website <small>(harga website)</small></h3>
	{#each websiteLines as i (i.id)}
		{@const ref = i.source_line_ref!}
		<div class="line" class:removed={!qty[ref]}>
			<div class="what">
				<strong>{i.product_name_snapshot}</strong>
				{#if i.variant_name_snapshot}<span class="muted">({i.variant_name_snapshot})</span>{/if}
				<small>{rupiah(i.subtotal_item / i.qty)} / item</small>
			</div>
			<div class="stepper">
				<button onclick={() => (qty[ref] = Math.max(0, (qty[ref] ?? 0) - 1))} aria-label="Kurangi"
					>−</button
				>
				<span class="count">{qty[ref] ?? 0}</span>
				<button onclick={() => (qty[ref] = Math.min(999, (qty[ref] ?? 0) + 1))} aria-label="Tambah"
					>+</button
				>
			</div>
		</div>
	{/each}

	<h3>Tambahan kasir <small>(harga POS)</small></h3>
	{#each added as a, idx (a.key)}
		<div class="line">
			<div class="what">
				<strong>{a.label}</strong>
				{#if a.detail}<span class="muted">{a.detail}</span>{/if}
				<small>{rupiah(a.unit)} / item</small>
			</div>
			<div class="stepper">
				<button
					onclick={() => (a.qty > 1 ? (a.qty -= 1) : added.splice(idx, 1))}
					aria-label="Kurangi">−</button
				>
				<span class="count">{a.qty}</span>
				<button onclick={() => (a.qty = Math.min(999, a.qty + 1))} aria-label="Tambah">+</button>
			</div>
		</div>
	{:else}
		<p class="muted">Belum ada.</p>
	{/each}
	<input class="input" placeholder="Cari menu untuk ditambahkan…" bind:value={search} />
	{#if results.length}
		<div class="results">
			{#each results as p (p.id)}
				<button class="result" onclick={() => tapProduct(p)}>
					<span>{p.name}</span>
					<small
						>{p.kind === 'sized' || p.kind === 'variant' ? 'mulai ' : ''}{rupiah(priceOf(p))}</small
					>
				</button>
			{/each}
		</div>
	{/if}

	{#if isDelivery}
		<h3>Ongkir</h3>
		<div class="with-unit">
			<span>Rp</span>
			<input
				class="input"
				inputmode="numeric"
				value={shipping.toLocaleString('id-ID')}
				oninput={(e) => (shippingInput = e.currentTarget.value)}
			/>
		</div>
	{/if}

	<dl class="sum">
		<dt>Subtotal</dt>
		<dd>{rupiah(subtotal)}</dd>
		{#if discount}<dt>Diskon voucher</dt>
			<dd>− {rupiah(discount)}</dd>{/if}
		{#if isDelivery}<dt>Ongkir</dt>
			<dd>{rupiah(shipping)}</dd>{/if}
		<dt class="strong">Total baru</dt>
		<dd class="strong">{rupiah(total)}</dd>
	</dl>

	<p class="error" role="alert">{error}</p>

	{#snippet footer()}
		<div class="actions">
			<button class="btn-ghost" onclick={onclose} disabled={busy}>Batal</button>
			<button class="btn-primary" onclick={save} disabled={busy || itemCount === 0}>
				{busy ? 'Mengirim ke website…' : 'Simpan perubahan'}
			</button>
		</div>
	{/snippet}
</Modal>

{#if picking && picking.kind === 'package'}
	<PackageDialog pkg={picking} markupPercent={0} onadd={addLine} onclose={() => (picking = null)} />
{:else if picking}
	<ProductDialog
		product={picking}
		{menu}
		markupPercent={0}
		onadd={addLine}
		onclose={() => (picking = null)}
	/>
{/if}

<style>
	.note {
		margin: 0 0 0.75rem;
		padding: 0.6rem 0.85rem;
		border-radius: var(--radius);
		background: #fff4e0;
		color: #8a5300;
		font-size: 0.9rem;
	}
	h3 {
		margin: 1rem 0 0.4rem;
		font-size: 0.95rem;
	}
	h3 small,
	.muted {
		color: var(--muted);
		font-weight: normal;
	}
	.line {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 0.75rem;
		padding: 0.4rem 0;
		border-bottom: 1px solid var(--border);
	}
	.line.removed .what {
		text-decoration: line-through;
		opacity: 0.55;
	}
	.what {
		display: flex;
		flex-direction: column;
	}
	.what small {
		color: var(--muted);
	}
	.results {
		display: flex;
		flex-direction: column;
		margin-top: 0.4rem;
		border: 1px solid var(--border);
		border-radius: var(--radius);
		overflow: hidden;
	}
	.result {
		display: flex;
		justify-content: space-between;
		min-height: var(--touch);
		padding: 0 0.85rem;
		border: none;
		border-bottom: 1px solid var(--border);
		background: var(--surface);
		color: var(--text);
		text-align: left;
	}
	.result:active {
		background: var(--brand-soft);
	}
	.result small {
		color: var(--muted);
	}
	.input {
		margin-top: 0.5rem;
	}
	.with-unit {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		max-width: 14rem;
	}
	.with-unit .input {
		margin: 0;
	}
	.sum {
		display: grid;
		grid-template-columns: 1fr auto;
		gap: 0.25rem 1rem;
		margin: 1rem 0 0;
	}
	.sum dd {
		margin: 0;
		text-align: right;
	}
	.strong {
		font-weight: 700;
	}
	.error {
		color: var(--danger);
		min-height: 1.2em;
		margin: 0.5rem 0 0;
	}
	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 0.5rem;
	}
</style>
