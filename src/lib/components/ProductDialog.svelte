<script lang="ts">
	import Modal from './Modal.svelte';
	import { rupiah } from '$lib/format';
	import { applyMarkup, lineTotal } from '$lib/pos/pricing';
	import type { CartLine, Menu, Product } from '$lib/pos/types';

	let {
		product,
		menu,
		markupPercent,
		onadd,
		onclose
	}: {
		product: Product;
		menu: Menu;
		markupPercent: number;
		onadd: (line: Omit<CartLine, 'key'>) => void;
		onclose: () => void;
	} = $props();

	let variantId = $state(product.variants[0]?.id ?? null);
	let qty = $state(1);
	let notes = $state('');
	let toppingQty = $state<Record<string, number>>({});

	const variant = $derived(product.variants.find((v) => v.id === variantId) ?? null);
	const allowToppings = $derived(product.kind === 'sized' && menu.toppings.length > 0);
	const toppingPrice = $derived(variant ? (menu.toppingPrices[variant.variant_key] ?? null) : null);
	const basePrice = $derived(variant?.price ?? product.base_price ?? 0);

	const chosenToppings = $derived(
		menu.toppings
			.filter((t) => (toppingQty[t.id] ?? 0) > 0)
			.map((t) => ({ topping: t, qty: toppingQty[t.id] }))
	);

	const total = $derived(
		lineTotal(
			basePrice,
			qty,
			chosenToppings.map((t) => ({ price: toppingPrice ?? 0, qty: t.qty })),
			markupPercent
		)
	);

	function changeTopping(id: string, delta: number) {
		const next = Math.max(0, Math.min(20, (toppingQty[id] ?? 0) + delta));
		toppingQty = { ...toppingQty, [id]: next };
	}

	function add() {
		onadd({
			product,
			variant,
			qty,
			notes: notes.trim(),
			toppings: allowToppings ? chosenToppings : []
		});
	}
</script>

<Modal title={product.name} {onclose}>
	{#if product.variants.length > 0}
		<section>
			<h3>{product.kind === 'sized' ? 'Ukuran' : 'Varian'}</h3>
			<div class="options">
				{#each product.variants as v (v.id)}
					<button
						class="option"
						class:selected={v.id === variantId}
						onclick={() => (variantId = v.id)}
					>
						<span>{v.label}</span>
						<small>{rupiah(applyMarkup(v.price, markupPercent))}</small>
					</button>
				{/each}
			</div>
		</section>
	{/if}

	{#if allowToppings}
		<section>
			<h3>
				Extra topping
				{#if toppingPrice != null}
					<small>· {rupiah(applyMarkup(toppingPrice, markupPercent))} / porsi</small>
				{/if}
			</h3>
			{#if toppingPrice == null}
				<p class="warn">Harga topping untuk ukuran ini belum tersedia.</p>
			{:else}
				<ul class="toppings">
					{#each menu.toppings as t (t.id)}
						<li>
							<span>{t.name}</span>
							<div class="stepper">
								<button onclick={() => changeTopping(t.id, -1)} disabled={!toppingQty[t.id]}
									>−</button
								>
								<span class="count">{toppingQty[t.id] ?? 0}</span>
								<button onclick={() => changeTopping(t.id, 1)}>+</button>
							</div>
						</li>
					{/each}
				</ul>
			{/if}
		</section>
	{/if}

	<section>
		<h3>Jumlah</h3>
		<div class="stepper big">
			<button onclick={() => (qty = Math.max(1, qty - 1))} disabled={qty <= 1}>−</button>
			<span class="count">{qty}</span>
			<button onclick={() => (qty = Math.min(999, qty + 1))}>+</button>
		</div>
	</section>

	<section>
		<h3>Catatan</h3>
		<input
			class="input"
			bind:value={notes}
			placeholder="Mis. tanpa bawang, potong 8"
			maxlength="200"
		/>
	</section>

	{#snippet footer()}
		<button
			class="btn-primary add"
			onclick={add}
			disabled={(product.variants.length > 0 && !variant) ||
				(chosenToppings.length > 0 && toppingPrice == null)}
		>
			Tambah · {rupiah(total)}
		</button>
	{/snippet}
</Modal>

<style>
	section + section {
		margin-top: 1.25rem;
	}
	h3 {
		margin: 0 0 0.5rem;
		font-size: 0.9rem;
		color: var(--muted);
	}
	h3 small {
		font-weight: 400;
	}
	.options {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(120px, 1fr));
		gap: 0.5rem;
	}
	.option {
		display: flex;
		flex-direction: column;
		gap: 0.2rem;
		padding: 0.75rem;
		border: 1px solid var(--border);
		border-radius: var(--radius);
		background: var(--surface);
		text-align: left;
	}
	.option small {
		color: var(--muted);
	}
	.option.selected {
		border-color: var(--brand);
		background: var(--brand-soft);
		box-shadow: inset 0 0 0 1px var(--brand);
	}
	.toppings {
		list-style: none;
		margin: 0;
		padding: 0;
	}
	.toppings li {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 0.4rem 0;
		border-bottom: 1px solid var(--border);
	}
	.stepper {
		display: inline-flex;
		align-items: center;
		gap: 0.5rem;
	}
	.stepper button {
		width: 36px;
		height: 36px;
		border: 1px solid var(--border);
		border-radius: 8px;
		background: var(--surface);
		font-size: 1.1rem;
	}
	.stepper button:disabled {
		opacity: 0.35;
	}
	.stepper.big button {
		width: 48px;
		height: 48px;
	}
	.count {
		min-width: 2ch;
		text-align: center;
		font-weight: 600;
	}
	.warn {
		color: var(--danger);
		font-size: 0.9rem;
	}
	.add {
		width: 100%;
		font-size: 1.05rem;
	}
</style>
