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

## Perbaikan setelah laporan tes 6 November

| Temuan | Penyebab | Perbaikan |
|---|---|---|
| Draf chat hilang | Kolom dikosongkan setelah jawaban server datang, sehingga pesan kedua yang diketik selama menunggu ikut terhapus. | Kolom hanya dikosongkan bila isinya masih pesan yang baru terkirim. |
| Slider pajak kembali ke nilai lama, klik di tengah jadi 7% | Nilai slider sengaja tidak disimpan saat panel diperbarui, dan slider dibangun ulang saat diklik. | Slider diganti angka + tombol −1/+1. Semua kolom yang sedang diubah bertahan saat panel diperbarui. |
| "Tunggu 5 detik" tidak terlihat | Pesan hanya muncul sebagai toast sesaat. | Halaman menahan kirim ulang dalam 5 detik dan menulis peringatan tetap di bawah kolom chat, draf tetap tersimpan. |
| Pengumuman tes tidak bisa dihapus | Belum ada caranya. | RPC baru `admin_delete_announcement` + tombol Hapus di Panel presiden (pengumuman dan kabar ticker-nya ikut terhapus). |
| Bilah target tidak terlihat di menu Kota | Bilah ada tapi terisi 1% dengan warna terlalu pucat. | Bilah lebih tebal dan kontras, selalu tampil minimal. |

Perbaikan pengumuman butuh SQL dijalankan ulang (kode pemuat baru di chat).

## Tes ulang

1. **Chat:** kirim satu pesan, langsung ketik pesan kedua sebelum yang pertama muncul. Pesan kedua tetap di kolom. Tekan Enter sebelum 5 detik: muncul tulisan merah "Tunggu … detik" di bawah kolom, draf tetap ada. Setelah 5 detik pesan terkirim.
2. **Pajak:** Panel presiden → −1/+1 beberapa kali, tunggu 1–2 menit (panel diperbarui otomatis), angka tetap. Simpan, angka di menu Kota berubah.
3. **Pengumuman:** Panel presiden → Pajak & pengumuman → Hapus pada pengumuman tes (ketuk 2x). Ticker dan menu Kota tidak lagi menampilkannya.
4. **Langkah 9, 11, 14** dari tabel di atas, memakai akun tes baru (lihat di bawah).

## Akun tes

Akun username tidak punya email sungguhan, jadi kata sandinya **tidak bisa direset**. Kalau login akun tes gagal:

- Buat akun baru lewat **Masuk → Daftar baru** di pratinjau, misalnya `tesa6` dan `tesb6`. Kata sandi diketik langsung, minimal 8 karakter. Tidak perlu email.
- Akun tes lama bisa dihapus di Supabase: Authentication → Users → pilih → Delete user. Tokoh, bangunan, dan suaranya ikut terhapus.
