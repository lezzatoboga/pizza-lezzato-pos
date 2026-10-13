// Status notifikasi pesanan website, dipakai bersama banner (semua halaman),
// lencana menu, dan halaman Pesanan Web.
import { loadWebAlerts, type WebAlerts } from './web-orders';

class WebAlertState {
	unopened = $state<WebAlerts['unopened']>([]);
	voidSlips = $state<WebAlerts['voidSlips']>([]);
	notices = $state(0);

	async refresh() {
		try {
			const a = await loadWebAlerts();
			this.unopened = a.unopened;
			this.voidSlips = a.voidSlips;
			this.notices = a.notices;
		} catch {
			// Gangguan jaringan: pertahankan keadaan terakhir.
		}
	}

	clear() {
		this.unopened = [];
		this.voidSlips = [];
		this.notices = 0;
	}
}

export const webAlerts = new WebAlertState();
