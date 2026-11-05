# Republik Netizenia v2 — Tes Tahap 3 (halaman v2 + login, profil, bangun, voting)

## 0. Proyek Supabase

Halaman v2 memakai proyek baru `bwubqnfvdxwhwwiibdzv` (dibuat 5 November). Proyek lama `siyknwzzjtyykwhiqmeu` tidak dipakai v2. Index.html lama tidak diubah dan masih menunjuk ke proyek lama.

Dicek dari luar setelah SQL dijalankan:

- 67 bangunan, 1.205 warga NPC, kas 9.000, dua usulan lama (Istana, Stadion) sedang divoting.
- Tamu yang memanggil `vote_proposal` ditolak (permission denied), dan schema `nz` tidak terbuka lewat REST.
- **Confirm email masih ON.** Daftar dengan username baru bisa langsung masuk setelah ini dimatikan (langkah 1 di bawah).

## 1. Langkah dashboard (sekali saja)

1. **Authentication → Sign In / Providers → Email:** aktif, **Confirm email: OFF**, minimum password 8.
2. **Authentication → Sign In / Providers → Google:** sudah aktif (dipakai presiden). Warga memakai provider yang sama.
3. **Authentication → URL Configuration → Redirect URLs**, tambahkan:
   - `https://<proyek-anda>.pages.dev/v2/**`
   - domain kustom Anda + `/v2/**` (bila ada)
4. **Cloudflare Pages:** tanpa build command, output directory = root repo. Halaman ada di `/v2/`.

## 2. Tes di HP dan laptop

| # | Langkah | Hasil yang benar |
|---|---|---|
| 1 | Buka `/v2/` tanpa login | Kota 3D tampil, angka penduduk/kas/kepuasan terisi, ada spanduk "Kamu sedang melihat kota". |
| 2 | Ketuk pejalan kaki | Muncul nama warga dari komen, profesi, dan rumahnya. |
| 3 | Ketuk bangunan | Panel info. Usulan menampilkan bar suara dan sisa waktu. |
| 4 | Tamu menekan Setuju / Bangun | Diarahkan ke layar Masuk. |
| 5 | Masuk → Daftar baru → username + kata sandi | Langsung masuk, muncul "Buat tokohmu". |
| 6 | Isi nama, pilih profesi dan warna | Sambutan dengan 3 langkah dan koin 400 NC. |
| 7 | Mulai: ambil rumah gratis → Rumah Kecil → ketuk kavling hijau → Bangun | Rumah muncul dengan crane, label progres, harga 0. |
| 8 | Bangun rumah kedua | Harga 170 NC, koin berkurang dengan angka melayang. |
| 9 | Ketuk kavling yang sudah terisi saat mode bangun | Teks merah "Kavling sudah terisi.", tombol Bangun mati. |
| 10 | Voting → Setuju, lalu Tolak | Angka pindah, tombol pilihanmu bertanda. Suara tidak dobel. |
| 11 | Bangun → Usulan umum → Taman → Ajukan | Kotak biru transparan + label suara. Usulan ke-3 ditolak "Maksimal 2 usulan aktif." |
| 12 | Ketuk hutan di luar pusat | Panel distrik tertutup + tombol Usulkan. |
| 13 | Profil → ganti profesi (ketuk 2x) | Koin -100, profesi berganti. |
| 14 | Keluar lalu masuk lagi dengan username sama | Tokoh dan bangunan tetap ada. |
| 15 | Masuk dengan Google (akun presiden) | Tokoh "Pak Mulyo" sebagai Presiden. Ada tombol Setujui/Veto di usulan dan "Buka sekarang" di distrik. |
| 16 | **Realtime:** dua perangkat login, satu membangun | Perangkat lain melihat bangunan baru dalam ±2 detik. |
| 17 | **Tamu tanpa realtime:** buka DevTools → Network → WS sebagai tamu | Tidak ada koneksi websocket realtime. |
| 18 | Tambahkan `?jam=20` di URL | Kota malam: jendela menyala, lampu jalan berpendar, bintang. Tanpa parameter, jam mengikuti WIB nyata. |
| 19 | Tambahkan `?hemat=1` | Mode hemat: tanpa bayangan, pejalan lebih sedikit, 30 fps. |

## 3. Yang memang belum ada di Tahap 3

- **Kerja, aksi profesi, lapor, tangkap, misi:** Tahap 4. Panel Kerja menampilkan "Segera hadir".
- **Kirim chat, papan donatur, klaim tokoh, panel admin, mode foto:** Tahap 5. Chat tamu sudah bisa dibaca.
- **Mode jalan-jalan dari prototipe:** belum dipasang. Akan saya pasang di Tahap 6 bersama optimasi HP.

## 4. Yang sudah saya uji sendiri

Saya menguji di Chromium (Playwright) pada 390px dan 1280px. Server Supabase diganti server tiruan, jadi tidak ada data asli yang tersentuh. Yang diuji:

- **Tamu siang dan malam:** tanpa galat JavaScript.
- **Alur pemain:** buat tokoh, sambutan, panel bangun, penempatan rumah gratis, info bangunan, voting, profil, dan layar masuk. RPC yang terpanggil: `register_profile`, `build_private`, `vote_proposal`.
- **Mode pratinjau** saat server belum siap.
- **SQL** dijalankan ulang di Postgres lokal setelah tambahan `owner_color`. Pemeriksaan keamanan akhir tetap kosong.

Yang belum bisa saya uji: login Google/username sungguhan, realtime sungguhan, dan tampilan di HP fisik.
