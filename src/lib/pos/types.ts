export type ProductKind = 'sized' | 'simple' | 'variant';

export type Variant = {
	id: string;
	product_id: string;
	variant_key: string;
	label: string;
	price: number;
	sort_order: number;
};

export type Product = {
	id: string;
	name: string;
	category: string;
	kind: ProductKind;
	base_price: number | null;
	sort_order: number;
	variants: Variant[];
};

export type Topping = { id: string; name: string; sort_order: number };

export type Menu = {
	products: Product[];
	toppings: Topping[];
	toppingPrices: Record<string, number>;
};

export type Outlet = { id: string; code: string; name: string };

export type Shift = {
	id: string;
	outlet_id: string;
	cashier_id: string;
	opening_balance: number;
	opening_time: string;
	status: 'open' | 'closed';
};

export type PaymentMethod = { id: string; code: string; name: string; is_cash: boolean };

export type Platform = { id: string; code: string; name: string; markup_percent: number };

export type Channel = 'admin_toko' | 'marketplace';
export type SalesType = 'dine_in' | 'take_away' | 'delivery';

export const SALES_TYPE_LABEL: Record<string, string> = {
	dine_in: 'Dine-in',
	take_away: 'Take away',
	delivery: 'Delivery'
};

export const CHANNEL_LABEL: Record<string, string> = {
	admin_toko: 'Admin toko',
	website: 'Website',
	marketplace: 'Marketplace'
};

export type CartLine = {
	key: string;
	product: Product;
	variant: Variant | null;
	qty: number;
	notes: string;
	toppings: { topping: Topping; qty: number }[];
};

// Ringkasan transaksi yang dikembalikan RPC create_transaction.
export type SavedTransaction = { id: string; transaction_number: string; total: number };
