// Cermin perhitungan harga di fungsi create_transaction (database).
// Hanya untuk tampilan — angka final selalu dari server.

// Markup tanpa pembulatan kelipatan; dibulatkan ke rupiah terdekat.
export function applyMarkup(base: number, markupPercent: number): number {
	const basisPoints = Math.round(markupPercent * 100);
	return Math.round((base * (10000 + basisPoints)) / 10000);
}

export type PricedTopping = { price: number; qty: number };

// qty × (harga item + Σ harga topping × qty topping)
export function lineTotal(
	basePrice: number,
	qty: number,
	toppings: PricedTopping[],
	markupPercent: number
): number {
	const unit = applyMarkup(basePrice, markupPercent);
	const toppingSum = toppings.reduce(
		(sum, t) => sum + applyMarkup(t.price, markupPercent) * t.qty,
		0
	);
	return qty * (unit + toppingSum);
}

// Cermin create_transaction: ongkir dari jarak dibulatkan ke atas per Rp1.000.
// Jarak disimpan 2 desimal (numeric(6,2)); dihitung dalam satuan 0,01 km
// supaya tidak ada galat float (mis. 0,3 × 10000 = 3000,0000000000005).
export function shippingFromDistance(km: number, ratePerKm: number): number {
	const hundredths = Math.round(km * 100);
	return Math.ceil((hundredths * ratePerKm) / 100000) * 1000;
}

// Diskon manual: persen dari subtotal item (dibulatkan ke rupiah) atau rupiah langsung.
export function manualDiscountAmount(
	type: 'percent' | 'amount',
	value: number,
	subtotal: number
): number {
	return type === 'percent' ? Math.round((subtotal * value) / 100) : Math.round(value);
}
