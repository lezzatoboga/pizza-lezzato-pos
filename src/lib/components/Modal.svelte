<script lang="ts">
	import type { Snippet } from 'svelte';

	let {
		title,
		onclose,
		children,
		footer
	}: {
		title: string;
		onclose: () => void;
		children: Snippet;
		footer?: Snippet;
	} = $props();

	function onKeydown(event: KeyboardEvent) {
		if (event.key === 'Escape') onclose();
	}
</script>

<svelte:window onkeydown={onKeydown} />

<div
	class="backdrop"
	role="presentation"
	onclick={(e) => e.target === e.currentTarget && onclose()}
>
	<div class="modal" role="dialog" aria-modal="true" aria-label={title}>
		<header>
			<h2>{title}</h2>
			<button class="close" onclick={onclose} aria-label="Tutup">✕</button>
		</header>
		<div class="body">
			{@render children()}
		</div>
		{#if footer}
			<footer>{@render footer()}</footer>
		{/if}
	</div>
</div>

<style>
	.backdrop {
		position: fixed;
		inset: 0;
		z-index: 50;
		display: grid;
		place-items: center;
		padding: 1rem;
		background: rgb(0 0 0 / 0.45);
	}
	.modal {
		display: flex;
		flex-direction: column;
		width: 100%;
		max-width: 600px;
		max-height: calc(100dvh - 2rem);
		background: var(--surface);
		border-radius: 16px;
		overflow: hidden;
	}
	header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 1rem;
		padding: 0.5rem 0.5rem 0.5rem 1.25rem;
		border-bottom: 1px solid var(--border);
	}
	h2 {
		margin: 0;
		font-size: 1.15rem;
	}
	.close {
		width: var(--touch-lg);
		height: var(--touch-lg);
		border: none;
		border-radius: 10px;
		background: none;
		font-size: 1.2rem;
		color: var(--muted);
	}
	.close:active {
		background: var(--bg);
	}
	.body {
		padding: 1rem 1.25rem;
		overflow-y: auto;
	}
	footer {
		padding: 1rem 1.25rem;
		border-top: 1px solid var(--border);
	}
</style>
