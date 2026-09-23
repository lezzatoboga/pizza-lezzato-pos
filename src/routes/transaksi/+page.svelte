<script lang="ts">
	import { onMount } from 'svelte';
	import CourierDialog from '$lib/components/CourierDialog.svelte';
	import PaymentDialog from '$lib/components/PaymentDialog.svelte';
	import { friendlyError, jakartaToday, rupiah, timeOf } from '$lib/format';
	import { loadContext, loadTransactions, type TransactionRow } from '$lib/pos/data';
	import {
		CHANNEL_LABEL,
		COURIER_TYPE_LABEL,
		SALES_TYPE_LABEL,
		type BankAccount,
		type Courier,
		type CourierValue,
		type StaffMember,
		type PaymentMethod,
		type SavedTransaction
	} from '$lib/pos/types';

	let rows = $state<TransactionRow[] | null>(null);
	let methods = $state<PaymentMethod[]>([]);
	let bankAccounts = $state<BankAccount[]>([]);
	let couriers = $state<Courier[]>([]);
	let staff = $state<StaffMember[]>([]);
	let editingCourier = $state<TransactionRow | null>(null);
	let error = $state('');
	let filter = $state<'all' | 'unpaid'>('all');
	let paying = $state<SavedTransaction | null>(null);

	const visible = $derived(
		(rows ?? []).filter(
			(r) => filter === 'all' || (r.payment_status === 'unpaid' && r.status === 'active')
		)
	);
	const activeRows = $derived((rows ?? []).filter((r) => r.status === 'active'));
	const paidTotal = $derived(
		activeRows.filter((r) => r.payment_status === 'paid').reduce((s, r) => s + r.total, 0)
	);
	const unpaidCount = $derived(activeRows.filter((r) => r.payment_status === 'unpaid').length);

	onMount(async () => {
		try {
			const ctx = await loadContext();
			methods = ctx.paymentMethods;
			bankAccounts = ctx.bankAccounts;
			couriers = ctx.couriers;
			staff = ctx.staff;
		} catch (e) {
			error = friendlyError(e);
		}
		await refresh();
	});

	async function refresh() {
		try {
			rows = await loadTransactions(jakartaToday());
		} catch (e) {
			error = friendlyError(e);
		}
	}

	const needsCourier = (r: TransactionRow) =>
		r.sales_type === 'delivery' && (r.channel === 'admin_toko' || r.channel === 'website');

	function courierText(r: TransactionRow) {
		if (!r.courier_type) return null;
		if (r.courier_type === 'karyawan')
			return staff.find((s) => s.id === r.courier_user_id)?.name ?? 'Karyawan';
		if (r.courier_type === 'freelance') return r.couriers?.name ?? 'Freelance';
		return COURIER_TYPE_LABEL[r.courier_type];
	}

	function courierValue(r: TransactionRow): CourierValue | null {
		if (!r.courier_type) return null;
		return {
			type: r.courier_type,
			user_id: r.courier_user_id ?? undefined,
			courier_id: r.courier_id ?? undefined
		};
	}

	function channelText(r: TransactionRow) {
		return r.marketplace_platforms?.name ?? CHANNEL_LABEL[r.channel] ?? r.channel;
	}
</script>

<section class="page">
	<header>
		<h1>Transaksi hari ini</h1>
		<div class="segmented filter">
			<button class:selected={filter === 'all'} onclick={() => (filter = 'all')}>Semua</button>
			<button class:selected={filter === 'unpaid'} onclick={() => (filter = 'unpaid')}>
				Belum bayar{unpaidCount ? ` (${unpaidCount})` : ''}
			</button>
		</div>
	</header>

	<p class="summary">
		{activeRows.length} transaksi · lunas {rupiah(paidTotal)}
	</p>

	{#if error}
		<p class="error">{error}</p>
	{:else if !rows}
		<p class="muted">Memuat…</p>
	{:else}
		<ul class="list">
			{#each visible as r (r.id)}
				<li class:voided={r.status === 'voided'}>
					<div class="main">
						<div class="title">
							<strong>{r.transaction_number}</strong>
							<span class="muted">{timeOf(r.created_at)}</span>
							<span class="chip">{channelText(r)}</span>
							<span class="chip">{SALES_TYPE_LABEL[r.sales_type]}</span>
							{#if r.customer_name}<span class="muted">· {r.customer_name}</span>{/if}
						</div>
						<div class="items">
							{#each r.transaction_items as item, i (i)}
								<span>
									{item.qty}× {item.product_name_snapshot}{item.variant_name_snapshot
										? ` (${item.variant_name_snapshot})`
										: ''}{#if item.package_choices_snapshot?.length}
										— {item.package_choices_snapshot
											.map((c) => c.value)
											.join(', ')}{/if}{#each item.transaction_item_addons as a, j (j)}
										+ {a.addon_name_snapshot}{a.qty > 1 ? ` ×${a.qty}` : ''}{/each}
								</span>
							{/each}
						</div>
						{#if needsCourier(r)}
							<div class="courier" class:missing={!r.courier_type}>
								Kurir: {courierText(r) ?? 'belum diatur'}
								{#if r.status === 'active' && r.payment_status === 'unpaid'}
									<button class="link" onclick={() => (editingCourier = r)}>
										{r.courier_type ? 'Ganti' : 'Atur kurir'}
									</button>
								{/if}
							</div>
						{/if}
					</div>
					<div class="side">
						<strong>{rupiah(r.total)}</strong>
						{#if r.status === 'voided'}
							<span class="badge void">Dibatalkan</span>
						{:else if r.payment_status === 'paid'}
							<span class="badge paid"
								>Lunas · {r.payment_methods?.name}{r.bank_accounts
									? ` ${r.bank_accounts.bank_name}`
									: ''}</span
							>
						{:else}
							<button
								class="btn-primary pay"
								onclick={() =>
									needsCourier(r) && !r.courier_type
										? (editingCourier = r)
										: (paying = {
												id: r.id,
												transaction_number: r.transaction_number,
												total: r.total
											})}
							>
								Bayar
							</button>
						{/if}
					</div>
				</li>
			{:else}
				<li class="empty">Belum ada transaksi.</li>
			{/each}
		</ul>
	{/if}
</section>

{#if editingCourier}
	<CourierDialog
		transactionId={editingCourier.id}
		transactionNumber={editingCourier.transaction_number}
		current={courierValue(editingCourier)}
		{couriers}
		{staff}
		ondone={() => {
			editingCourier = null;
			refresh();
		}}
		onclose={() => (editingCourier = null)}
	/>
{/if}

{#if paying}
	<PaymentDialog
		transaction={paying}
		{methods}
		{bankAccounts}
		ondone={() => {
			paying = null;
			refresh();
		}}
		onclose={() => (paying = null)}
	/>
{/if}

<style>
	.page {
		max-width: 960px;
		margin: 0 auto;
		padding: 1rem;
	}
	header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 1rem;
		flex-wrap: wrap;
	}
	h1 {
		margin: 0;
		font-size: 1.3rem;
	}
	.filter {
		min-width: 260px;
	}
	.summary,
	.muted {
		color: var(--muted);
	}
	.error {
		color: var(--danger);
	}
	.list {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 0.5rem;
	}
	.list li {
		display: flex;
		justify-content: space-between;
		gap: 1rem;
		padding: 0.85rem 1rem;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--radius);
	}
	.list li.voided {
		opacity: 0.55;
	}
	.list li.empty {
		justify-content: center;
		color: var(--muted);
	}
	.title {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 0.5rem;
	}
	.chip {
		font-size: 0.78rem;
		padding: 0.1rem 0.5rem;
		border-radius: 999px;
		background: var(--bg);
		color: var(--muted);
	}
	.items {
		display: flex;
		flex-direction: column;
		margin-top: 0.35rem;
		font-size: 0.9rem;
	}
	.side {
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: 0.4rem;
		white-space: nowrap;
	}
	.badge {
		font-size: 0.8rem;
		padding: 0.15rem 0.55rem;
		border-radius: 999px;
	}
	.badge.paid {
		background: #eaf6ee;
		color: #1e6b3a;
	}
	.badge.void {
		background: var(--bg);
		color: var(--muted);
	}
	.courier {
		display: flex;
		align-items: center;
		gap: 0.25rem;
		margin-top: 0.25rem;
		font-size: 0.9rem;
		color: var(--muted);
	}
	.courier.missing {
		color: var(--danger);
		font-weight: 600;
	}
	.pay {
		padding: 0 1.25rem;
	}
</style>
