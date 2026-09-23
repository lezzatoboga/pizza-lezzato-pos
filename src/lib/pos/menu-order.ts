// Urutan tampilan menu, sama dengan /menu di website:
//   kategori (menu_categories.sort_order)
//   → section (menu_sections.sort_order)
//   → produk (menu_items.sort_order, dimulai ulang per section)
import type { Menu, Product } from './types';

export type MenuSectionGroup = {
	key: string | null;
	// null kalau kategori hanya punya satu section (tidak perlu subjudul).
	label: string | null;
	products: Product[];
};

export type MenuCategoryGroup = {
	slug: string;
	label: string;
	sections: MenuSectionGroup[];
};

const UNKNOWN = Number.MAX_SAFE_INTEGER;

// Cadangan kalau kategori/section belum ada di cache (mis. baru ditambah
// di website sebelum sinkron berikutnya).
const prettify = (slug: string) =>
	slug.replace(/[-_]/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());

const bySortThenName =
	<T>(sort: (x: T) => number, name: (x: T) => string) =>
	(a: T, b: T) =>
		sort(a) - sort(b) || name(a).localeCompare(name(b));

export function groupMenu(menu: Menu): MenuCategoryGroup[] {
	const categories = new Map(menu.categories.map((c) => [c.slug, c]));
	const sections = new Map(menu.sections.map((s) => [s.key, s]));

	const productsByCategory = new Map<string, Product[]>();
	for (const p of menu.products) {
		const list = productsByCategory.get(p.category) ?? [];
		list.push(p);
		productsByCategory.set(p.category, list);
	}

	const groups: MenuCategoryGroup[] = [...productsByCategory].map(([slug, products]) => {
		const bySection = new Map<string | null, Product[]>();
		for (const p of products) {
			const list = bySection.get(p.section_key) ?? [];
			list.push(p);
			bySection.set(p.section_key, list);
		}

		const sectionGroups = [...bySection]
			.sort(
				bySortThenName(
					([key]) => (key != null ? (sections.get(key)?.sort_order ?? UNKNOWN) : UNKNOWN),
					([key]) => key ?? ''
				)
			)
			.map(([key, list]) => ({
				key,
				label: key != null ? (sections.get(key)?.label ?? prettify(key)) : null,
				products: list.sort(
					bySortThenName(
						(p) => p.sort_order,
						(p) => p.name
					)
				)
			}));

		if (sectionGroups.length === 1) sectionGroups[0].label = null;

		return {
			slug,
			label: categories.get(slug)?.label ?? prettify(slug),
			sections: sectionGroups
		};
	});

	return groups.sort(
		bySortThenName(
			(g) => categories.get(g.slug)?.sort_order ?? UNKNOWN,
			(g) => g.slug
		)
	);
}
