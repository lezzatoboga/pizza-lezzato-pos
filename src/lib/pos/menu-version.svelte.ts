// Penanda sederhana: naik setiap kali sinkron menu manual selesai,
// supaya layar kasir memuat ulang menu.
class MenuVersion {
	value = $state(0);
	bump() {
		this.value += 1;
	}
}

export const menuVersion = new MenuVersion();
