# Catatan: jembatan pesanan website ↔ POS

Status: **DITUNDA** sampai fitur ongkir otomatis di website selesai (supaya skema pesanan
website tidak disesuaikan dua kali). Pekerjaan di sisi website dikerjakan di project website,
bukan dari repo POS; kebutuhan dari website ditulis sebagai permintaan untuk Owner.

## Yang ditunggu sebelum dilanjutkan

- Jawaban Owner untuk pertanyaan desain B1–B7 (akan dikirim lengkap saat dilanjutkan; jawabannya
  berbeda dari usulan awal, jadi jangan dianggap disetujui).
- Skema pesanan website yang baru setelah ongkir otomatis (termasuk kolom ongkir dan pembayaran).
- Satu sumber tarif ongkir per km (saat ini ada di Pengaturan POS dan di pengaturan website).
- Akses baca data website untuk POS: role `pos_reader` sengaja dinonaktifkan di sisi website;
  pengaktifannya dibahas bersama kontrak data jembatan ini (sinkron pelanggan POS dijeda selama
  itu — Pengaturan → Sinkron).

## Hal yang perlu ditinjau ulang saat jembatan/pembayaran online dikerjakan

### Tanda CETAK ULANG pada struk

Aturan sekarang (keputusan Owner 2026-10-12): struk diberi tanda **CETAK ULANG** hanya kalau
struk dengan **status yang sama** sudah pernah dicetak (Belum Lunas → Belum Lunas, Lunas →
Lunas). Struk Lunas setelah struk Belum Lunas **tidak** bertanda. Tiket dapur memakai hitungan
cetaknya sendiri.

Implementasinya membandingkan status struk terakhir yang dicetak (`receipt_printed_status`)
dengan status bayar saat ini (`src/lib/print/reprint.ts`, migrasi `20261012000006`). Ini benar
karena status bayar di POS tidak bisa kembali dari Lunas ke Belum Lunas.

**Kalau pembayaran online (mis. Midtrans) atau jembatan pesanan memperkenalkan pembatalan
pembayaran atau refund** (Lunas → Belum Lunas), aturan ini harus ditinjau ulang dan kemungkinan
beralih ke penghitung cetak per status (`receipt_unpaid_print_count` / `receipt_paid_print_count`
di `transactions`, diisi oleh `mark_receipt_printed`).
