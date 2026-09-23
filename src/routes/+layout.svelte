<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import favicon from '$lib/assets/favicon.svg';
	import { auth } from '$lib/auth/auth.svelte';
	import './app.css';

	let { children } = $props();

	const isLoginPage = $derived(page.url.pathname === '/login');

	onMount(() => {
		auth.init();
	});

	$effect(() => {
		if (!auth.ready) return;
		if (!auth.profile && !isLoginPage) goto('/login', { replaceState: true });
		if (auth.profile && isLoginPage) goto('/', { replaceState: true });
	});

	async function logout() {
		await auth.logout();
		goto('/login', { replaceState: true });
	}
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
	<title>POS Pizza Lezzato</title>
</svelte:head>

{#if !auth.ready || (!auth.profile && !isLoginPage) || (auth.profile && isLoginPage)}
	<div class="splash">Memuat…</div>
{:else}
	{#if auth.profile}
		<header class="topbar">
			<strong class="brand">Pizza Lezzato POS</strong>
			<div class="who">
				<span>{auth.profile.name}</span>
				<span class="role">{auth.profile.role.name}</span>
				<button class="btn-ghost" onclick={logout}>Keluar</button>
			</div>
		</header>
	{/if}
	<main>
		{@render children()}
	</main>
{/if}

<style>
	.splash {
		display: grid;
		place-items: center;
		min-height: 100dvh;
		color: var(--muted);
	}
	.topbar {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 1rem;
		padding: 0.75rem 1rem;
		background: var(--surface);
		border-bottom: 1px solid var(--border);
	}
	.brand {
		color: var(--brand);
	}
	.who {
		display: flex;
		align-items: center;
		gap: 0.75rem;
	}
	.role {
		font-size: 0.8rem;
		padding: 0.15rem 0.5rem;
		border-radius: 999px;
		background: var(--brand-soft);
		color: var(--brand);
	}
</style>
