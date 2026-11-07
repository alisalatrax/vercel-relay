# Republik Netizenia v2 — Tes Tahap 6 (optimasi HP dan pemeriksaan akhir)

Tahap ini hanya mengubah `v2/index.html`. Tidak ada perubahan SQL.

## Yang baru

- **Jalan-jalan dengan tokohmu** (tombol orang berjalan di kanan). HP: joystick kiri bawah. Laptop: W/A/S/D atau panah, Q/E memutar kamera, Escape keluar. Geser layar untuk memutar kamera. Tokoh memakai warna profesi dan warna topi pilihanmu, tidak bisa menembus bangunan (taman, lapangan, alun-alun, pasar, PKL, dan sawah bisa dilewati), dan tombol "Lihat …" muncul saat dekat bangunan.
- **Mode hemat otomatis:** bila HP di bawah ±26 fps dalam beberapa detik pertama, bayangan dimatikan, resolusi diturunkan, dan pejalan kaki dikurangi. Pilihan ini diingat di perangkat. Bisa diubah manual di menu Kota → Grafik.
- **Cache warga** 10 menit di perangkat: kunjungan berikutnya tidak memuat ulang 1.205 nama warga.

## Ukuran (terkompresi gzip)

| Bagian | Ukuran |
|---|---|
| `v2/index.html` | 61 KB |
| three.js r128 (cdnjs, cache browser) | 149 KB |
| supabase-js 2.117.3 (jsdelivr, cache browser) | 55 KB |
| Data kota pertama (snapshot + bangunan pusat + warga) | ±23 KB |

## Tes

| # | Langkah | Hasil yang benar |
|---|---|---|
| 1 | Masuk sebagai warga → tombol orang berjalan | Tokohmu muncul di depan rumahmu (atau pusat kota bila belum punya rumah), menu bawah tersembunyi. |
| 2 | HP: geser joystick. Laptop: tahan W | Tokoh berjalan, kamera mengikuti. |
| 3 | Jalan menabrak rumah | Tokoh berhenti, tidak menembus. Taman dan pasar bisa dilewati. |
| 4 | Dekati bangunan → "Lihat …" | Panel info bangunan terbuka. |
| 5 | "Selesai jalan-jalan" (atau Escape) | Kembali ke peta biasa. |
| 6 | Tamu menekan tombol jalan-jalan | Diminta masuk dulu. |
| 7 | Menu Kota → Grafik → Pakai mode hemat | Halaman dimuat ulang tanpa bayangan. "Pakai grafik penuh" mengembalikan. |
| 8 | HP lama | Bila tersendat, muncul pemberitahuan mode hemat otomatis dan kota jadi lebih lancar. |

## Yang sudah saya uji sendiri

- **Semua alur sebelumnya** (Tahap 3–5, perbaikan tes ulang) dijalankan ulang di Chromium tanpa galat.
- **Jalan-jalan:** W/A/D di laptop menggerakkan tokoh tanpa menembus bangunan, tombol "Lihat Rumah Pak Mulyo" membuka panel, Escape keluar. Joystick di HP menggerakkan tokoh.
- **Cache warga:** kunjungan kedua tidak memanggil `get_npcs`.
- **Tangkapan layar akhir 390px dan 1280px:** tamu, bangun, kerja, voting, chat, jalan-jalan, panel presiden, kota.

Yang belum bisa saya uji dari sini: kelancaran di HP fisik (Chromium di sini memakai grafik perangkat lunak).
