# Republik Netizenia v2 — Tes Tahap 4 (kerja, profesi, laporan, penangkapan, misi)

Semua aturan dijalankan server (RPC dari Tahap 2). Tahap ini hanya mengubah `v2/index.html`.

## Yang baru

- **Menu Kerja:** status (profesi, energi, kesehatan, koin dari aksi hari ini / 300), pekerjaanmu (Masuk kerja tiap 4 jam, Berhenti), kerja serabutan (12 NC tiap 2 jam), aksi profesi sesuai profesi, bantu bangun untuk Tukang/Mandor, berobat, misi harian, usaha milikmu (atur gaji, buka/tutup lowongan), dan daftar lowongan.
- **Daftar Warga:** cari, filter Semua / Sedang sakit / Dilaporkan. Tombol sesuai profesi: Obati (Dokter), Ajar (Guru), Tangkap (Polisi). Semua pemain bisa Lapor (ketuk 2x). Presiden bisa Angkat/Copot Menteri dan Bebaskan tahanan.
- **Info bangunan:** Lamar kerja, Masuk kerja, atau Kelola lowongan bila milikmu. Rumah Sakit punya tombol Berobat.
- **Langkah berikutnya:** "Shift siap di …", "Misi hari ini 1/3", atau "Ditahan sampai …".
- **Angka Penduduk** di atas sekarang jumlah orang (warga dari komen + pemain). Daya tampung rumah pindah ke menu Kota.

## Tes (butuh minimal 3 akun username; pakai HP + laptop atau jendela penyamaran)

| # | Langkah | Hasil yang benar |
|---|---|---|
| 1 | Akun A (Warga): Kerja → Kerja serabutan | +12 NC, tombol berubah "lagi 2 jam", misi "Masuk kerja" selesai (+40 NC). |
| 2 | Akun A: Kerja → Lamar di Pasar/Ruko | Diterima, muncul di "Pekerjaanmu". |
| 3 | Akun A: Masuk kerja | Shift dimulai, tombol "lagi 4 jam". Gaji negara masuk bertahap tiap jam (cron). |
| 4 | Akun A: lamar Rumah Sakit | Tombol mati "Khusus Dokter". |
| 5 | Akun A: Kerja bakti | +8 NC, jeda 1 jam. |
| 6 | Akun B ganti profesi ke Dokter (Profil, 100 NC), lalu Kerja → Obati pasien | Daftar warga sakit. Obati → +30 NC dari kas. RS sudah berdiri sejak awal. |
| 7 | Akun B dan C masing-masing **Lapor** akun A | Akun A punya "2 laporan". Akun A melihat "Dilaporkan 2 akun" di menu Kerja. |
| 8 | Akun C ganti profesi ke Polisi → Kerja → Tangkap tersangka → Tangkap akun A | Gagal bila kantor polisi/penjara belum jadi (60%/50% saat dipasang, selesai sendiri dalam beberapa jam). Setelah jadi: gagal karena laporan C sendiri tidak dihitung (hanya 1 pelapor lain). Butuh 2 pelapor **selain** polisi. |
| 9 | Setelah akun A ditahan | Spanduk "Kamu sedang ditahan", semua tombol aksi mati. Presiden bisa Bebaskan di daftar Warga. |
| 10 | Presiden: Warga → Angkat Menteri pada satu akun | Profesi akun itu jadi Menteri, aksi "Rapat negara". |
| 11 | Coba 6 laporan dalam sehari | Laporan ke-6 ditolak "Maksimal 5 laporan per hari." |

## Yang sudah saya uji sendiri

- **Alur Tahap 4 dengan server tiruan** di Chromium 390px dan 1280px, tanpa galat: kerja serabutan, lamar, shift + jeda, daftar warga sakit, obati NPC, lapor (ketuk 2x).
- **Kecocokan nama:** 26 RPC yang dipanggil halaman beserta nama parameternya cocok dengan fungsi di `supabase_v2.sql`.
- **Aturan server** (jeda, energi, batas harian, tangkap butuh 2 pelapor lain, ditahan) sudah diuji di Postgres lokal sejak Tahap 2.
