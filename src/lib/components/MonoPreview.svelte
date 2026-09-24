<script lang="ts">
	// Menampilkan gambar hitam-putih persis titik per titik seperti hasil cetak.
	import type { MonoImage } from '$lib/print/logo';

	let { image, scale = 2 }: { image: MonoImage; scale?: number } = $props();

	let canvas: HTMLCanvasElement | undefined = $state();

	$effect(() => {
		if (!canvas) return;
		canvas.width = image.width;
		canvas.height = image.height;
		const ctx = canvas.getContext('2d')!;
		const pixels = ctx.createImageData(image.width, image.height);
		for (let i = 0; i < image.bits.length; i++) {
			const v = image.bits[i] ? 0 : 255;
			pixels.data[i * 4] = v;
			pixels.data[i * 4 + 1] = v;
			pixels.data[i * 4 + 2] = v;
			pixels.data[i * 4 + 3] = 255;
		}
		ctx.putImageData(pixels, 0, 0);
	});
</script>

<canvas
	bind:this={canvas}
	style:width="{image.width * scale}px"
	aria-label="Pratinjau logo {image.width}×{image.height} titik"
></canvas>

<style>
	canvas {
		image-rendering: pixelated;
		max-width: 100%;
		height: auto;
		background: #fff;
	}
</style>
