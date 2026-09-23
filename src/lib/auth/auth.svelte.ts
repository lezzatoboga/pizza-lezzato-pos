import { FunctionsHttpError } from '@supabase/supabase-js';
import { supabase } from '$lib/supabase/client';

export type LoginUser = { id: string; name: string; role: string };

export type PosProfile = {
	id: string;
	name: string;
	role: { code: 'owner' | 'supervisor' | 'kasir'; name: string };
	permissions: string[];
};

export class LoginError extends Error {
	constructor(
		message: string,
		public attemptsLeft: number | null = null,
		public lockedUntil: Date | null = null
	) {
		super(message);
	}
}

class AuthState {
	profile = $state<PosProfile | null>(null);
	ready = $state(false);

	async init() {
		supabase.auth.onAuthStateChange((event) => {
			if (event === 'SIGNED_OUT') this.profile = null;
		});

		const {
			data: { session }
		} = await supabase.auth.getSession();
		if (session) await this.loadProfile();
		this.ready = true;
	}

	// Sesi yang tidak terhubung ke pengguna aktif (mis. dinonaktifkan Owner)
	// langsung dikeluarkan.
	async loadProfile() {
		const { data, error } = await supabase.rpc('get_my_profile');
		if (error || !data) {
			await supabase.auth.signOut();
			this.profile = null;
			return;
		}
		this.profile = data as PosProfile;
	}

	can(permission: string) {
		return this.profile?.permissions.includes(permission) ?? false;
	}

	async listLoginUsers(): Promise<LoginUser[]> {
		const { data, error } = await supabase.functions.invoke<{ users: LoginUser[] }>(
			'pos-login-users',
			{ method: 'GET' }
		);
		if (error || !data) throw new Error('Gagal memuat daftar pengguna. Periksa koneksi internet.');
		return data.users;
	}

	async loginWithPin(userId: string, pin: string) {
		const { data, error } = await supabase.functions.invoke<{
			access_token: string;
			refresh_token: string;
		}>('pos-pin-login', { body: { user_id: userId, pin } });

		if (error) {
			if (error instanceof FunctionsHttpError) {
				const body = await error.context.json().catch(() => ({}));
				throw new LoginError(
					body.error ?? 'Login gagal',
					body.attempts_left ?? null,
					body.locked_until ? new Date(body.locked_until) : null
				);
			}
			throw new LoginError('Tidak bisa terhubung ke server. Periksa koneksi internet.');
		}

		const { error: sessionError } = await supabase.auth.setSession({
			access_token: data!.access_token,
			refresh_token: data!.refresh_token
		});
		if (sessionError) throw new LoginError('Gagal menyimpan sesi login');

		await this.loadProfile();
		if (!this.profile) throw new LoginError('Akun tidak aktif');
	}

	async logout() {
		await supabase.auth.signOut();
		this.profile = null;
	}
}

export const auth = new AuthState();
