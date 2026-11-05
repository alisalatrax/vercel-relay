# Republik Netizenia v2 — Tes Tahap 5 (donatur, chat, klaim, panel presiden, mode foto)

## 0. Perbarui database dulu

Tahap 5 menambah tabel donatur, kolom tautan Saweria, dan tiga RPC presiden (`pres_add_donation`, `pres_set_saweria`, `admin_delete_donation`). Jalankan ulang SQL dengan kode pemuat yang diberikan di chat. Kode itu terkunci ke commit Tahap 5. Data lama tidak hilang karena file aman diulang.

Cek sesudahnya:

```sql
select (select count(*) from nz.buildings) as bangunan,
       (select count(*) from nz.npcs) as warga,
       to_regclass('nz.donations') is not null as tabel_donasi;
```

## Tes

| # | Langkah | Hasil yang benar |
|---|---|---|
| 1 | Presiden: Profil → Panel presiden → Catat donasi (nama, nominal, pesan) | Muncul bar "Donatur terbaru" di atas, berita terima kasih, dan awan emas bernama donatur di atas kota (1 jam per Rp1.000, maksimal 6 awan). |
| 2 | Presiden: isi tautan Saweria → Simpan | Papan donatur menampilkan tombol "Dukung lewat Saweria". Tautan selain `https://saweria.co/...` ditolak. |
| 3 | Presiden: isi target donasi | Papan donatur dan menu Kota menampilkan bar progres. |
| 4 | Cek koin presiden setelah mencatat donasi | Tidak berubah. Donasi tidak menghasilkan koin. |
| 5 | Tamu: ketuk bar donatur | Papan donatur tampil tanpa login. |
| 6 | Warga A dan B login, buka Chat, kirim pesan | Pesan muncul di perangkat lain dalam ±2 detik (realtime). Nama otomatis dari tokoh. |
| 7 | Kirim dua pesan dalam 5 detik | Pesan kedua ditolak "Tunggu 5 detik…". |
| 8 | Tamu buka Chat | Bisa membaca 30 pesan terbaru, tombol "Masuk untuk ikut ngobrol". |
| 9 | Warga: Kerja → Daftar warga → cari nama warga komen → ketuk nama → "Ini aku: klaim tokoh ini" | Klaim terkirim. Tombol berubah "Klaimmu sedang menunggu persetujuan". |
| 10 | Presiden: Panel presiden → Antrean klaim → Setujui | Tokoh tertaut ke akun pengklaim. Nama tampil pengklaim berganti ke nama tokoh, rumahnya ikut jadi milik pengklaim. |
| 11 | Warga: kartu warga komen → "Minta hapus nama ini" → Presiden setujui | Nama hilang dari kota (pejalan kaki dan daftar warga). |
| 12 | Presiden: hapus satu pesan chat | Pesan hilang untuk semua. |
| 13 | Presiden: ubah pajak, siarkan pengumuman | Ticker atas menampilkan pengumuman. |
| 14 | Presiden: "Hitung sekarang" | Voting yang sudah lewat 24 jam langsung diputuskan. |
| 15 | Tombol kamera (kanan) → geser jam → Simpan foto | Semua tombol tersembunyi, kota berganti siang/malam sesuai jam, file PNG bertanda "Republik Netizenia" terunduh. Selesai mengembalikan jam WIB nyata. |

## Yang sudah saya uji sendiri

- **Postgres lokal (proyek kosong):** SQL berjalan sebagai satu transaksi dan aman diulang. Donasi hanya oleh presiden, validasi nama/nominal/tautan, tidak ada transaksi koin dari donasi, tamu bisa membaca papan donatur. Semua tes Tahap 2–4 tetap lulus.
- **Chromium 390px dengan server tiruan:** bar dan papan donatur, chat tamu dan warga, kartu warga komen, formulir klaim, panel presiden (catat donasi, setujui klaim), mode foto malam + unduhan PNG, awan emas donatur.
- **Kecocokan nama:** 39 RPC yang dipanggil halaman cocok dengan fungsi dan parameter di SQL.

Belum bisa saya uji dari sini: realtime chat sungguhan antar dua perangkat.
