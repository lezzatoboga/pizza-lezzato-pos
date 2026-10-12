// Kelola pengguna & hak akses (khusus Owner) — pembungkus RPC admin_*.
// Semua aturan (khusus Owner, Owner terakhir, diri sendiri, nama unik,
// PIN 4–6 digit) dicek di server; tampilan hanya membantu.
import { supabase } from '$lib/supabase/client';

function unwrap<T>(result: { data: T | null; error: { message: string } | null }): T {
	if (result.error) throw new Error(result.error.message);
	return result.data as T;
}

export type RoleCode = 'owner' | 'supervisor' | 'kasir';

export const ROLE_OPTIONS: { code: RoleCode; name: string }[] = [
	{ code: 'owner', name: 'Owner' },
	{ code: 'supervisor', name: 'Supervisor' },
	{ code: 'kasir', name: 'Kasir' }
];

export type AdminUser = {
	id: string;
	name: string;
	role_code: RoleCode;
	role_name: string;
	active: boolean;
	failed_pin_attempts: number;
	// Hanya terisi kalau kunci masih berlaku.
	pin_locked_until: string | null;
	pin_lockout_level: number;
	created_at: string;
	last_sign_in_at: string | null;
	is_me: boolean;
};

export type PermissionMatrix = {
	roles: { code: RoleCode; name: string }[];
	permissions: {
		code: string;
		label: string;
		owner_only: boolean;
		granted: Record<RoleCode, boolean>;
	}[];
};

export type PermissionChange = { role: RoleCode; permission: string; granted: boolean };

export type AuditEntry = {
	id: string;
	created_at: string;
	actor: string | null;
	target: string | null;
	action:
		| 'buat'
		| 'ubah_nama'
		| 'ubah_role'
		| 'nonaktifkan'
		| 'aktifkan'
		| 'reset_pin'
		| 'buka_kunci'
		| 'ubah_izin';
	details: Record<string, string | boolean>;
};

export const PIN_PATTERN = /^[0-9]{4,6}$/;

export async function listUsers(): Promise<AdminUser[]> {
	return unwrap(await supabase.rpc('admin_list_users')) as AdminUser[];
}

export async function createUser(name: string, role: RoleCode, pin: string): Promise<string> {
	return unwrap(
		await supabase.rpc('admin_create_user', { p_name: name, p_role_code: role, p_pin: pin })
	) as string;
}

export async function updateUser(id: string, name: string, role: RoleCode): Promise<void> {
	unwrap(
		await supabase.rpc('admin_update_user', { p_user_id: id, p_name: name, p_role_code: role })
	);
}

export async function setUserActive(id: string, active: boolean): Promise<void> {
	unwrap(await supabase.rpc('admin_set_user_active', { p_user_id: id, p_active: active }));
}

export async function resetPin(id: string, pin: string): Promise<void> {
	unwrap(await supabase.rpc('admin_reset_pin', { p_user_id: id, p_pin: pin }));
}

export async function unlockPin(id: string): Promise<void> {
	unwrap(await supabase.rpc('admin_unlock_pin', { p_user_id: id }));
}

export async function loadPermissionMatrix(): Promise<PermissionMatrix> {
	return unwrap(await supabase.rpc('admin_role_permissions')) as PermissionMatrix;
}

export async function savePermissionChanges(changes: PermissionChange[]): Promise<number> {
	return unwrap(await supabase.rpc('admin_set_role_permissions', { p_changes: changes })) as number;
}

export async function loadAuditLog(limit = 100): Promise<AuditEntry[]> {
	return unwrap(await supabase.rpc('admin_audit_log', { p_limit: limit })) as AuditEntry[];
}

// Pengelompokan & catatan ketergantungan izin untuk tampilan.
export const PERMISSION_GROUPS: { title: string; codes: string[] }[] = [
	{
		title: 'Laporan',
		codes: ['view_sales_report', 'view_transaction_detail', 'export_report', 'view_finance_report']
	},
	{
		title: 'Transaksi & pembatalan',
		codes: ['override_markup', 'void_unlocked_transaction', 'void_transaction']
	},
	{ title: 'Pengaturan & sinkron', codes: ['manage_settings', 'edit_markup', 'sync_menu'] },
	{ title: 'Admin (khusus Owner)', codes: ['manage_users', 'manage_permissions'] }
];

export const PERMISSION_NOTES: Record<string, string> = {
	export_report: 'Ekspor detail transaksi butuh juga "Lihat laporan detail transaksi".',
	edit_markup: 'Butuh juga "Kelola pengaturan POS" untuk membuka menu Pengaturan.',
	void_transaction: 'Mencakup pembatalan kapan pun; pemegangnya juga jadi penyetuju void (PIN).',
	view_finance_report: 'Membuka Riwayat shift beserta selisih kas.',
	sync_menu: 'Tombol Sinkron di bilah atas.'
};
