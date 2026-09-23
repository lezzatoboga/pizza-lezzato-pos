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
