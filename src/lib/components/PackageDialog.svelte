<script lang="ts">
	import Modal from './Modal.svelte';
	import { rupiah } from '$lib/format';
	import { applyMarkup } from '$lib/pos/pricing';
	import type { CartLine, Product } from '$lib/pos/types';

	let {
		pkg,
		markupPercent,
		onadd,
		onclose
	}: {
		pkg: Product;
		markupPercent: number;
		onadd: (line: Omit<CartLine, 'key'>) => void;
		onclose: () => void;
	} = $props();

	let selected = $state<Record<string, string>>({});
	let qty = $state(1);
	let notes = $state('');

	const groups = $derived(pkg.package_choices ?? []);
	const complete = $derived(groups.every((g) => selected[g.key]));
	const unitPrice = $derived(applyMarkup(pkg.base_price ?? 0, markupPercent));

	function add() {
		if (!complete) return;
		onadd({
			product: pkg,
			variant: null,
			qty,
			notes: notes.trim(),
			toppings: [],
			choices: groups.map((g) => ({ key: g.key, label: g.label, value: selected[g.key] }))
		});
	}
</script>

<Modal title={pkg.name} {onclose}>
	<section>
		<h3>Isi paket</h3>
		<ul class="contents">
			{#each pkg.package_items ?? [] as item, i (i)}
				<li>{item}</li>
			{/each}
		</ul>
		{#if pkg.package_note}
			<p class="note">{pkg.package_note}</p>
		{/if}
	</section>

	{#each groups as group (group.key)}
		<section>
			<h3>
				{group.label}
				<span class="required" class:done={!!selected[group.key]}>
					{selected[group.key] ? '✓' : 'wajib pilih'}
				</span>
			</h3>
			<div class="options">
				{#each group.options as option (option)}
					<button
						class="option"
						class:selected={selected[group.key] === option}
						onclick={() => (selected = { ...selected, [group.key]: option })}
					>
						{option}
					</button>
				{/each}
			</div>
		</section>
	{/each}

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
		<input class="input" bind:value={notes} placeholder="Mis. pizza potong 8" maxlength="200" />
	</section>

	{#snippet footer()}
		<button class="btn-primary add" onclick={add} disabled={!complete}>
			{complete ? `Tambah · ${rupiah(unitPrice * qty)}` : 'Lengkapi pilihan paket'}
		</button>
	{/snippet}
</Modal>

<style>
	section + section {
		margin-top: 1.25rem;
	}
	h3 {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		margin: 0 0 0.5rem;
		font-size: 0.9rem;
		color: var(--muted);
	}
	.required {
		font-size: 0.75rem;
		font-weight: 600;
		padding: 0.1rem 0.5rem;
		border-radius: 999px;
		background: var(--brand-soft);
		color: var(--danger);
	}
	.required.done {
		background: #eaf6ee;
		color: #1e6b3a;
	}
	.contents {
		margin: 0;
		padding-left: 1.2rem;
	}
	.contents li {
		padding: 0.15rem 0;
	}
	.note {
		margin: 0.5rem 0 0;
		font-style: italic;
		color: var(--muted);
	}
	.options {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
		gap: 0.5rem;
	}
	.option {
		min-height: var(--touch-lg);
		padding: 0 0.75rem;
		border: 1px solid var(--border);
		border-radius: var(--radius);
		background: var(--surface);
		font-weight: 600;
		text-align: left;
	}
	.option.selected {
		border-color: var(--brand);
		background: var(--brand-soft);
		box-shadow: inset 0 0 0 1px var(--brand);
		color: var(--brand);
	}
	.stepper.big button {
		width: var(--touch-lg);
		height: var(--touch-lg);
	}
	.add {
		width: 100%;
		min-height: 56px;
		font-size: 1.05rem;
	}
</style>
