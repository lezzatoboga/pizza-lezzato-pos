<script lang="ts">
	import { auth } from '$lib/auth/auth.svelte';
</script>

<section class="home">
	<h1>Halo, {auth.profile?.name}</h1>
	<p>Login berhasil. Layar transaksi akan dibangun di tahap berikutnya.</p>

	<h2>Hak akses Anda</h2>
	<ul>
		{#each auth.profile?.permissions ?? [] as code (code)}
			<li><code>{code}</code></li>
		{:else}
			<li>Tidak ada hak akses tambahan.</li>
		{/each}
	</ul>
</section>

<style>
	.home {
		max-width: 720px;
		margin: 2rem auto;
		padding: 0 1rem;
	}
	h2 {
		font-size: 1rem;
		margin-top: 2rem;
		color: var(--muted);
	}
</style>
