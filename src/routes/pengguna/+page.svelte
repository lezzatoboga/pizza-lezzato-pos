<script lang="ts">
	// Kelola pengguna & hak akses — khusus Owner (manage_users /
	// manage_permissions, dicek juga di server).
	import { auth } from '$lib/auth/auth.svelte';
	import Modal from '$lib/components/Modal.svelte';
	import ResetPinDialog from '$lib/components/ResetPinDialog.svelte';
	import UserFormDialog from '$lib/components/UserFormDialog.svelte';
	import { friendlyError, timeOf } from '$lib/format';
	import { dateTimeOf } from '$lib/pos/report';
	import {
		listUsers,
		loadAuditLog,
		loadPermissionMatrix,
		PERMISSION_GROUPS,
		PERMISSION_NOTES,
		savePermissionChanges,
		setUserActive,
		unlockPin,
		type AdminUser,
		type AuditEntry,
		type PermissionChange,
		type PermissionMatrix,
		type RoleCode
	} from '$lib/pos/users';

	type Tab = 'users' | 'permissions' | 'log';

	const canUsers = $derived(auth.can('manage_users'));
	const canPermissions = $derived(auth.can('manage_permissions'));
	const tabs = $derived(
		[
			canUsers && { code: 'users' as Tab, label: 'Pengguna' },
			canPermissions && { code: 'permissions' as Tab, label: 'Hak akses' },
			canUsers && { code: 'log' as Tab, label: 'Riwayat' }
		].filter((t): t is { code: Tab; label: string } => !!t)
	);
	let tab = $state<Tab | null>(null);
	const activeTab = $derived(tab && tabs.some((t) => t.code === tab) ? tab : tabs[0]?.code);

	let notice = $state<{ text: string; failed: boolean } | null>(null);

	// ---------------- Pengguna ----------------
	let users = $state<AdminUser[] | null>(null);
	let usersError = $state('');
	let editing = $state<AdminUser | null>(null);
	let adding = $state(false);
	let pinFor = $state<AdminUser | null>(null);
	let confirming = $state<{ user: AdminUser; action: 'deactivate' | 'activate' | 'unlock' } | null>(
		null
	);
	let busy = $state(false);

	const activeOwners = $derived(
		(users ?? []).filter((u) => u.active && u.role_code === 'owner').length
	);
	const activeUsers = $derived((users ?? []).filter((u) => u.active));
	const inactiveUsers = $derived((users ?? []).filter((u) => !u.active));

	async function reloadUsers() {
		try {
			users = await listUsers();
			usersError = '';
		} catch (e) {
			usersError = friendlyError(e);
		}
	}

	$effect(() => {
		if (activeTab === 'users') reloadUsers();
	});

	function done(message: string) {
		adding = false;
		editing = null;
		pinFor = null;
		notice = { text: message, failed: false };
		reloadUsers();
		auth.refresh();
	}

	// Alasan tombol Nonaktifkan dimatikan (null = boleh).
	function deactivateBlocked(u: AdminUser): string | null {
		if (u.is_me) return 'Akun Anda sendiri';
		if (u.role_code === 'owner' && activeOwners <= 1) return 'Owner terakhir';
		return null;
	}

	async function runConfirmed() {
		if (!confirming || busy) return;
		const { user, action } = confirming;
		busy = true;
		try {
			if (action === 'unlock') {
				await unlockPin(user.id);
				done(`Kunci PIN ${user.name} dibuka`);
			} else {
				await setUserActive(user.id, action === 'activate');
				done(`${user.name} ${action === 'activate' ? 'diaktifkan' : 'dinonaktifkan'}`);
			}
		} catch (e) {
			notice = { text: friendlyError(e), failed: true };
		} finally {
			busy = false;
			confirming = null;
		}
	}

	const signInText = (u: AdminUser) =>
		u.last_sign_in_at ? `Terakhir masuk ${dateTimeOf(u.last_sign_in_at)}` : 'Belum pernah masuk';

	// ---------------- Hak akses ----------------
	let matrix = $state<PermissionMatrix | null>(null);
	let matrixError = $state('');
	// Draft perubahan: "role|izin" → nilai baru
	let draft = $state<Record<string, boolean>>({});
	let reviewing = $state(false);

	async function reloadMatrix() {
		try {
			matrix = await loadPermissionMatrix();
			draft = {};
			matrixError = '';
		} catch (e) {
			matrixError = friendlyError(e);
		}
	}

	$effect(() => {
		if (activeTab === 'permissions') reloadMatrix();
	});

	type Perm = PermissionMatrix['permissions'][number];
	const permByCode = $derived(new Map((matrix?.permissions ?? []).map((p) => [p.code, p])));
	const groups = $derived.by(() => {
		const known = new Set(PERMISSION_GROUPS.flatMap((g) => g.codes));
		const list = PERMISSION_GROUPS.map((g) => ({
			title: g.title,
			perms: g.codes.map((c) => permByCode.get(c)).filter((p): p is Perm => !!p)
		}));
		const others = (matrix?.permissions ?? []).filter((p) => !known.has(p.code));
		if (others.length) list.push({ title: 'Lainnya', perms: others });
		return list.filter((g) => g.perms.length);
	});

	const locked = (p: Perm, role: RoleCode) => role === 'owner' || p.owner_only;
	const value = (p: Perm, role: RoleCode) => draft[`${role}|${p.code}`] ?? p.granted[role];

	function toggle(p: Perm, role: RoleCode) {
		if (locked(p, role)) return;
		const key = `${role}|${p.code}`;
		const next = !value(p, role);
		const copy = { ...draft };
		if (next === p.granted[role]) delete copy[key];
		else copy[key] = next;
		draft = copy;
	}

	const changes = $derived(
		Object.entries(draft).map(([key, granted]) => {
			const [role, permission] = key.split('|');
			return { role: role as RoleCode, permission, granted } satisfies PermissionChange;
		})
	);

	async function saveMatrix() {
		if (busy || !changes.length) return;
		busy = true;
		try {
			const n = await savePermissionChanges(changes);
			reviewing = false;
			notice = { text: `${n} perubahan izin disimpan`, failed: false };
			await reloadMatrix();
			auth.refresh();
		} catch (e) {
			notice = { text: friendlyError(e), failed: true };
		} finally {
			busy = false;
		}
	}

	const roleName = (code: string) => matrix?.roles.find((r) => r.code === code)?.name ?? code;

	// ---------------- Riwayat ----------------
	let log = $state<AuditEntry[] | null>(null);
	let logError = $state('');

	$effect(() => {
		if (activeTab !== 'log') return;
		loadAuditLog(100)
			.then((l) => {
				log = l;
				logError = '';
			})
			.catch((e) => (logError = friendlyError(e)));
	});

	function describe(e: AuditEntry): string {
		const d = e.details;
		switch (e.action) {
			case 'buat':
				return `menambahkan ${e.target ?? d.name} sebagai ${d.role}`;
			case 'ubah_nama':
				return `mengubah nama "${d.from}" → "${d.to}"`;
			case 'ubah_role':
				return `mengubah role ${e.target}: ${d.from} → ${d.to}`;
			case 'nonaktifkan':
				return `menonaktifkan ${e.target}`;
			case 'aktifkan':
				return `mengaktifkan ${e.target}`;
			case 'reset_pin':
				return `mereset PIN ${e.target}`;
			case 'buka_kunci':
				return `membuka kunci PIN ${e.target}`;
			case 'ubah_izin':
				return `${d.to ? 'memberi' : 'mencabut'} izin "${d.label}" untuk ${d.role}`;
		}
	}
</script>

{#snippet userRow(u: AdminUser)}
	{@const blocked = deactivateBlocked(u)}
	<li class:inactive={!u.active}>
		<div class="who">
			<strong>{u.name}{u.is_me ? ' (Anda)' : ''}</strong>
			<div class="chips">
				<span class="chip role {u.role_code}">{u.role_name}</span>
				{#if !u.active}
					<span class="chip off">Nonaktif</span>
				{:else if u.pin_locked_until}
					<span class="chip locked">PIN terkunci sampai {timeOf(u.pin_locked_until)}</span>
				{:else if u.failed_pin_attempts > 0}
					<span class="chip warn">{u.failed_pin_attempts}× PIN salah</span>
				{/if}
			</div>
			<small>{signInText(u)}</small>
		</div>
		<div class="row-actions">
			<button class="btn-ghost" onclick={() => (editing = u)}>Ubah</button>
			<button class="btn-ghost" onclick={() => (pinFor = u)}>Reset PIN</button>
			{#if u.active && (u.pin_locked_until || u.pin_lockout_level > 0 || u.failed_pin_attempts > 0)}
				<button class="btn-ghost" onclick={() => (confirming = { user: u, action: 'unlock' })}>
					Buka kunci
				</button>
			{/if}
			{#if u.active}
				<button
					class="btn-ghost danger"
					disabled={!!blocked}
					title={blocked ?? undefined}
					onclick={() => (confirming = { user: u, action: 'deactivate' })}
				>
					{blocked ? `Nonaktifkan · ${blocked}` : 'Nonaktifkan'}
				</button>
			{:else}
				<button class="btn-ghost" onclick={() => (confirming = { user: u, action: 'activate' })}>
					Aktifkan
				</button>
			{/if}
		</div>
	</li>
{/snippet}

{#if !canUsers && !canPermissions}
	<p class="denied">Menu ini khusus Owner.</p>
{:else}
	<section class="page">
		<header>
			<h1>Pengguna & hak akses</h1>
			<div class="segmented tabs">
				{#each tabs as t (t.code)}
					<button
						class:selected={activeTab === t.code}
						onclick={() => {
							tab = t.code;
							notice = null;
						}}>{t.label}</button
					>
				{/each}
			</div>
		</header>

		{#if notice}
			<p class="notice" class:failed={notice.failed} role="status">{notice.text}</p>
		{/if}

		{#if activeTab === 'users'}
			<div class="toolbar">
				<p class="muted">
					Pengguna tidak pernah dihapus — nonaktifkan saja; riwayat transaksi, shift, dan pembatalan
					tetap mencatat namanya.
				</p>
				<button class="btn-primary" onclick={() => (adding = true)}>+ Tambah pengguna</button>
			</div>
			{#if usersError}
				<p class="error">{usersError}</p>
			{:else if !users}
				<p class="muted">Memuat…</p>
			{:else}
				<ul class="users">
					{#each activeUsers as u (u.id)}
						{@render userRow(u)}
					{/each}
				</ul>
				{#if inactiveUsers.length}
					<h2>Nonaktif</h2>
					<ul class="users">
						{#each inactiveUsers as u (u.id)}
							{@render userRow(u)}
						{/each}
					</ul>
				{/if}
			{/if}
		{:else if activeTab === 'permissions'}
			{#if matrixError}
				<p class="error">{matrixError}</p>
			{:else if !matrix}
				<p class="muted">Memuat…</p>
			{:else}
				<p class="muted">
					Kolom Owner selalu aktif dan terkunci. Izin admin hanya untuk Owner. Perubahan langsung
					berlaku di server; menu di tablet lain menyesuaikan saat pindah halaman.
				</p>
				<div class="scroll">
					<table class="matrix">
						<thead>
							<tr>
								<th>Izin</th>
								{#each matrix.roles as r (r.code)}<th class="role-col">{r.name}</th>{/each}
							</tr>
						</thead>
						{#each groups as g (g.title)}
							<tbody>
								<tr class="group"><td colspan={1 + matrix.roles.length}>{g.title}</td></tr>
								{#each g.perms as p (p.code)}
									<tr>
										<td>
											{p.label}
											{#if PERMISSION_NOTES[p.code]}<small>{PERMISSION_NOTES[p.code]}</small>{/if}
										</td>
										{#each matrix.roles as r (r.code)}
											{@const on = value(p, r.code)}
											{@const changed = `${r.code}|${p.code}` in draft}
											<td class="role-col">
												<button
													class="check"
													class:on
													class:changed
													disabled={locked(p, r.code)}
													aria-pressed={on}
													aria-label="{p.label} untuk {r.name}"
													onclick={() => toggle(p, r.code)}
												>
													{on ? '✓' : ''}
												</button>
											</td>
										{/each}
									</tr>
								{/each}
							</tbody>
						{/each}
					</table>
				</div>
				{#if changes.length}
					<div class="save-bar">
						<span>{changes.length} perubahan belum disimpan</span>
						<button class="btn-ghost" onclick={() => (draft = {})} disabled={busy}>Batal</button>
						<button class="btn-primary" onclick={() => (reviewing = true)} disabled={busy}>
							Simpan perubahan
						</button>
					</div>
				{/if}
			{/if}
		{:else if activeTab === 'log'}
			{#if logError}
				<p class="error">{logError}</p>
			{:else if !log}
				<p class="muted">Memuat…</p>
			{:else}
				<ul class="log">
					{#each log as e (e.id)}
						<li>
							<span class="when">{dateTimeOf(e.created_at)}</span>
							<span><strong>{e.actor ?? '—'}</strong> {describe(e)}</span>
						</li>
					{:else}
						<li class="muted">Belum ada perubahan tercatat.</li>
					{/each}
				</ul>
				<p class="muted small">Menampilkan 100 perubahan terakhir. PIN tidak pernah dicatat.</p>
			{/if}
		{/if}
	</section>
{/if}

{#if adding}
	<UserFormDialog onsaved={done} onclose={() => (adding = false)} />
{/if}
{#if editing}
	<UserFormDialog user={editing} onsaved={done} onclose={() => (editing = null)} />
{/if}
{#if pinFor}
	<ResetPinDialog user={pinFor} onsaved={done} onclose={() => (pinFor = null)} />
{/if}

{#if confirming}
	{@const c = confirming}
	<Modal
		title={c.action === 'deactivate'
			? `Nonaktifkan ${c.user.name}?`
			: c.action === 'activate'
				? `Aktifkan ${c.user.name}?`
				: `Buka kunci PIN ${c.user.name}?`}
		onclose={() => (confirming = null)}
	>
		<p>
			{#if c.action === 'deactivate'}
				{c.user.name} tidak bisa login lagi dan sesi yang sedang terbuka langsung berhenti. Namanya hilang
				dari pilihan kurir dan penyetuju, tapi tetap tercatat di riwayat.
			{:else if c.action === 'activate'}
				{c.user.name} bisa login lagi dengan PIN terakhirnya.
			{:else}
				Hitungan PIN salah dan kunci sementara direset; PIN tidak berubah.
			{/if}
		</p>
		{#snippet footer()}
			<div class="actions">
				<button class="btn-ghost" onclick={() => (confirming = null)} disabled={busy}>Batal</button>
				<button class="btn-primary" onclick={runConfirmed} disabled={busy}>
					{busy
						? 'Memproses…'
						: c.action === 'deactivate'
							? 'Nonaktifkan'
							: c.action === 'activate'
								? 'Aktifkan'
								: 'Buka kunci'}
				</button>
			</div>
		{/snippet}
	</Modal>
{/if}

{#if reviewing && matrix}
	<Modal title="Simpan perubahan izin?" onclose={() => (reviewing = false)}>
		<ul class="review">
			{#each changes as c (c.role + c.permission)}
				<li>
					<strong>{roleName(c.role)}</strong> · {permByCode.get(c.permission)?.label}:
					<span class:grant={c.granted} class:revoke={!c.granted}>
						{c.granted ? 'diberi' : 'dicabut'}
					</span>
				</li>
			{/each}
		</ul>
		{#snippet footer()}
			<div class="actions">
				<button class="btn-ghost" onclick={() => (reviewing = false)} disabled={busy}
					>Kembali</button
				>
				<button class="btn-primary" onclick={saveMatrix} disabled={busy}>
					{busy ? 'Menyimpan…' : 'Simpan'}
				</button>
			</div>
		{/snippet}
	</Modal>
{/if}

<style>
	.page {
		max-width: 1000px;
		margin: 0 auto;
		padding: 1rem;
	}
	header {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		justify-content: space-between;
		gap: 0.75rem;
		margin-bottom: 1rem;
	}
	h1 {
		margin: 0;
		font-size: 1.3rem;
	}
	h2 {
		margin: 1.5rem 0 0.5rem;
		font-size: 1rem;
		color: var(--muted);
	}
	.tabs {
		min-width: 360px;
	}
	.denied {
		text-align: center;
		margin-top: 3rem;
		color: var(--muted);
	}
	.muted {
		color: var(--muted);
	}
	.small {
		font-size: 0.85rem;
	}
	.error {
		color: var(--danger);
	}
	.notice {
		margin: 0 0 1rem;
		padding: 0.6rem 0.85rem;
		border-radius: var(--radius);
		background: #e8f4ec;
		color: #1e6b3a;
	}
	.notice.failed {
		background: #fff4e0;
		color: #8a5300;
	}
	.toolbar {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		justify-content: space-between;
		gap: 0.75rem;
		margin-bottom: 0.75rem;
	}
	.toolbar p {
		margin: 0;
		max-width: 36rem;
	}
	.users {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 0.5rem;
	}
	.users li {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		justify-content: space-between;
		gap: 0.75rem;
		padding: 0.85rem 1rem;
		border: 1px solid var(--border);
		border-radius: var(--radius);
		background: var(--surface);
	}
	.users li.inactive {
		opacity: 0.65;
	}
	.who {
		display: flex;
		flex-direction: column;
		gap: 0.3rem;
	}
	.who small {
		color: var(--muted);
	}
	.chips {
		display: flex;
		flex-wrap: wrap;
		gap: 0.35rem;
	}
	.chip {
		padding: 0.15rem 0.6rem;
		border-radius: 999px;
		font-size: 0.8rem;
		font-weight: 600;
		background: var(--bg);
		color: var(--muted);
	}
	.chip.owner {
		background: var(--brand-soft);
		color: var(--brand);
	}
	.chip.supervisor {
		background: #e8eefb;
		color: #2a4f9a;
	}
	.chip.off {
		background: #eee;
		color: #555;
	}
	.chip.locked,
	.chip.warn {
		background: #fff4e0;
		color: #8a5300;
	}
	.row-actions {
		display: flex;
		flex-wrap: wrap;
		gap: 0.4rem;
	}
	.danger:not(:disabled) {
		color: var(--danger);
	}
	.scroll {
		overflow-x: auto;
	}
	.matrix {
		width: 100%;
		border-collapse: collapse;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--radius);
	}
	.matrix th,
	.matrix td {
		padding: 0.45rem 0.75rem;
		border-bottom: 1px solid var(--border);
		text-align: left;
	}
	.matrix th {
		color: var(--muted);
		font-size: 0.85rem;
	}
	.matrix td small {
		display: block;
		color: var(--muted);
		font-size: 0.8rem;
	}
	.matrix .group td {
		background: var(--bg);
		font-weight: 700;
		font-size: 0.85rem;
		color: var(--muted);
	}
	.role-col {
		width: 7.5rem;
		text-align: center !important;
	}
	.check {
		width: var(--touch);
		height: var(--touch);
		border: 2px solid var(--border);
		border-radius: 10px;
		background: var(--surface);
		font-size: 1.3rem;
		font-weight: 700;
		color: #fff;
	}
	.check.on {
		border-color: var(--brand);
		background: var(--brand);
	}
	.check.changed {
		outline: 3px solid #f0b44c;
		outline-offset: 2px;
	}
	.check:disabled {
		opacity: 0.45;
		cursor: default;
	}
	.save-bar {
		position: sticky;
		bottom: 0;
		display: flex;
		align-items: center;
		justify-content: flex-end;
		gap: 0.5rem;
		margin-top: 0.75rem;
		padding: 0.75rem 1rem;
		border: 1px solid var(--border);
		border-radius: var(--radius);
		background: var(--surface);
		box-shadow: 0 -4px 16px rgb(0 0 0 / 0.08);
	}
	.save-bar span {
		margin-right: auto;
		font-weight: 600;
	}
	.log {
		list-style: none;
		margin: 0;
		padding: 0;
	}
	.log li {
		display: flex;
		gap: 1rem;
		padding: 0.6rem 0;
		border-bottom: 1px solid var(--border);
	}
	.when {
		flex: none;
		width: 11rem;
		color: var(--muted);
		font-size: 0.9rem;
	}
	.review {
		margin: 0;
		padding-left: 1.2rem;
	}
	.review li {
		margin-bottom: 0.35rem;
	}
	.grant {
		color: #1e6b3a;
		font-weight: 700;
	}
	.revoke {
		color: var(--danger);
		font-weight: 700;
	}
	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 0.5rem;
	}
	@media (max-width: 640px) {
		.tabs {
			min-width: 0;
			width: 100%;
		}
		.when {
			width: 7rem;
		}
	}
</style>
