<script lang="ts">
	import {
		COURIER_TYPE_LABEL,
		type Courier,
		type CourierType,
		type CourierValue,
		type StaffMember
	} from '$lib/pos/types';

	let {
		value = $bindable(),
		couriers,
		staff
	}: {
		value: CourierValue | null;
		couriers: Courier[];
		staff: StaffMember[];
	} = $props();

	const TYPES: CourierType[] = ['karyawan', 'freelance', 'shopee_express', 'maxim'];

	// Jenis yang sedang dibuka (karyawan/freelance butuh pilih nama dulu).
	let openType = $state<CourierType | null>(value?.type ?? null);

	// Keranjang dikosongkan dari luar (value → null): tutup pilihan tetap.
	$effect(() => {
		if (value === null && (openType === 'shopee_express' || openType === 'maxim')) openType = null;
	});

	function chooseType(type: CourierType) {
		openType = type;
		value = type === 'shopee_express' || type === 'maxim' ? { type } : null;
	}

	const people = $derived(
		openType === 'karyawan'
			? staff.map((s) => ({ id: s.id, name: s.name }))
			: openType === 'freelance'
				? couriers.map((c) => ({ id: c.id, name: c.name }))
				: []
	);

	function isSelected(id: string) {
		return openType === 'karyawan' ? value?.user_id === id : value?.courier_id === id;
	}

	function choosePerson(id: string) {
		value =
			openType === 'karyawan'
				? { type: 'karyawan', user_id: id }
				: { type: 'freelance', courier_id: id };
	}
</script>

<div class="picker">
	<div class="segmented">
		{#each TYPES as t (t)}
			<button class:selected={openType === t} onclick={() => chooseType(t)}>
				{COURIER_TYPE_LABEL[t]}
			</button>
		{/each}
	</div>

	{#if openType === 'karyawan' || openType === 'freelance'}
		<div class="people">
			{#each people as p (p.id)}
				<button class="person" class:selected={isSelected(p.id)} onclick={() => choosePerson(p.id)}>
					{p.name}
				</button>
			{:else}
				<p class="hint">
					{openType === 'freelance'
						? 'Belum ada kurir freelance aktif. Tambahkan di Pengaturan.'
						: 'Tidak ada karyawan aktif.'}
				</p>
			{/each}
		</div>
	{/if}
</div>

<style>
	.picker {
		display: flex;
		flex-direction: column;
		gap: 0.5rem;
	}
	.segmented button {
		font-size: 0.85rem;
	}
	.people {
		display: flex;
		flex-wrap: wrap;
		gap: 0.4rem;
	}
	.person {
		min-height: var(--touch);
		padding: 0 0.9rem;
		border: 1px solid var(--border);
		border-radius: 999px;
		background: var(--surface);
		color: var(--text);
	}
	.person.selected {
		border-color: var(--brand);
		background: var(--brand-soft);
		color: var(--brand);
		font-weight: 600;
	}
	.hint {
		margin: 0;
		color: var(--muted);
		font-size: 0.85rem;
	}
</style>
