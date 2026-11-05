# Republik Netizenia v2 — Rencana Tahap 1

Status: Tahap 1–2 disetujui. Tahap 3 (halaman v2: login, profil, bangun, voting, grafik baru) selesai, menunggu tes dan persetujuan.

## Keputusan yang sudah diambil

- Voting lolos bila setuju > tolak **dan minimal 5 setuju**.
- Batas harian koin dari aksi: **300 NC per hari WIB**.
- **Tanpa Turnstile.**
- Waktu bangun mengikuti tabel 2d.
- Suara akun baru tetap dihitung. Bila nanti ada banjir akun palsu, presiden bisa mengubah `nz.settings.vote_min_account_age_hours` lewat SQL Editor.

## Perubahan setelah membaca index.html lama

- Nama tabel lama (`settings`, `proposals`, `proposal_votes`, `buildings`, `residents`) bertabrakan dengan rencana. Karena itu semua tabel game v2 ditaruh di **schema privat `nz`**. Schema ini tidak dibuka lewat Data API, jadi browser sama sekali tidak bisa menyentuh tabelnya selain lewat RPC.
- Warga NPC disalin dari `public.residents` dan dari rekap komentar (`CONFIG.seed`) ke `nz.npcs`.
- 22 fasilitas lama (`CONFIG.fas`) dipetakan ke grid baru sebagai bangunan negara yang dilindungi.
- Antrean klaim memakai `public.claim_requests` yang sudah ada, ditambah kolom `user_id` dan `npc_id`.
- Donatur tetap dibaca dari `public.donations`, dan `admin_add_donation` lama tetap dipakai.

## 0. Temuan penting sebelum mulai

- Repo yang tersambung ke sesi ini (`alisalatrax/vercel-relay`) **tidak berisi index.html lama**. Isinya hanya relay Vercel (`api/relay.js`).
- Saya juga mencari di GitHub (kode `netizenia`, `claim_resident`, `opt_out_resident`) dan tidak menemukannya.
- Yang saya baca lengkap: prototipe `netizenia-3d.html` (1049 baris, three r128, semua aturan game di localStorage).
- Akibatnya, rencana di bawah memakai **asumsi** soal skema lama. Asumsi ditandai **[ASUMSI]**.
- Untuk Tahap 2 saya butuh dua hal dari Anda (lihat bagian 7):
  1. File `index.html` lama (upload ke chat atau commit ke repo). Di sana ada URL Supabase, publishable key, nama tabel, dan pemanggilan RPC lama.
  2. Hasil kueri baca-saja `v2/cek_skema_lama.sql` (jalankan sendiri di SQL Editor, tempel hasilnya). Kueri ini tidak mengubah apa pun.

## 1. Prinsip arsitektur

- **Server adalah wasit.** Browser hanya menampilkan dan memanggil RPC. Semua angka (koin, energi, cooldown, progres) dihitung di Postgres.
- **RLS aktif di semua tabel.** `anon` dan `authenticated` tidak punya INSERT/UPDATE/DELETE ke tabel game. Semua aksi lewat fungsi `SECURITY DEFINER` dengan `SET search_path = public, pg_temp`.
- **Satu pintu untuk koin.** Semua perpindahan koin lewat fungsi internal `_tx()` yang mengunci baris, memotong pajak, dan menulis ke `transactions`. Saldo tidak pernah diubah di luar fungsi itu.
- **Waktu = jam nyata WIB.** Hari game = `(now() at time zone 'Asia/Jakarta')::date`. Voting 24 jam nyata.
- **Progres dihitung, bukan disimpan per detik.** `progress = least(1, (now() - started_at) / build_hours + boost)`.
- **Energi dan status ditahan dihitung malas (lazy).** Energi = `least(100, energy + 12 × jam sejak energy_at)`. Ditahan = `jail_until > now()`. Tidak perlu cron tiap menit.
- **File statis tanpa build** untuk Cloudflare Pages. Library dikunci: three `r128` dari cdnjs, supabase-js versi pasti dari jsdelivr (versi dipilih dan diverifikasi di Tahap 3).

## 2. Rencana skema

Semua tabel di schema `public`. Kolom inti saja; indeks dan constraint lengkap ditulis di Tahap 2.

### 2a. Tabel lama yang dipertahankan [ASUMSI nama]

| Tabel lama | Perlakuan di v2 |
|---|---|
| `admins` | Tetap. Fungsi `is_admin()` membaca tabel ini. Presiden = admin. |
| `residents` (warga dari komen IG) | Tetap sebagai NPC. Ditambah kolom `profession`, `color`, `home_building_id`, `claimed_by uuid`. |
| antrean klaim (`claims` / `claim_requests`) | Tetap. Ditambah `user_id uuid` supaya klaim tertaut ke akun. |
| chat (`chat_messages`) | Tetap. Ditambah `user_id`. Nama diambil dari profil, bukan input. |
| donatur Saweria (`donors` / `donations`) | Tetap. Hanya admin yang menulis lewat RPC. Tidak menghasilkan koin. |
| tabel vote per `device_id` | Dibekukan (REVOKE). Diganti `proposal_votes` per akun. |

### 2b. Tabel baru

| Tabel | Isi utama |
|---|---|
| `settings` (1 baris) | `kas`, `tax_pct` (0–30), `vote_hours`=24, `min_yes`=5, `daily_cap`, `donation_goal`, `morale`, `morale_until` |
| `districts` | `key` (pusat/utara/selatan/barat/timur), `name`, `cost`, `is_open` |
| `profiles` | `id` = `auth.users.id`, `username` unik, `display_name`, `profession`, `color`, `coins`≥0, `energy`, `energy_at`, `health`, `xp`, `jail_until`, `home_building_id`, `resident_id` (hasil klaim), `free_house_used`, `promo_until`, `last_chat_at`, `created_at` |
| `buildings` | `id`, `type`, `i`, `j`, `w`, `h`, `district`, `owner_id` (null = negara), `npc_owner_id`, `stage` (sketsa/disetujui/bangun/jadi), `started_at`, `build_hours`, `boost`, `wage`, `job_open`, `npc_staff`, `wall`, `protected` (bangunan lama), `seed_key` unik |
| `building_tiles` | `(i, j)` PRIMARY KEY → `building_id`. Mencegah kavling dobel secara atomik, aman saat dua orang membangun bersamaan. |
| `jobs` | `building_id`, `user_id` UNIQUE (1 pekerjaan per akun), `last_shift_at` |
| `proposals` | `id`, `building_id`, `proposer_id`, `cost`, `discount`, `created_at`, `ends_at`, `status` (voting/lolos/menunggu_kas/ditolak/veto) |
| `proposal_votes` | PRIMARY KEY `(proposal_id, user_id)`, `vote` ∈ {-1, 1} |
| `district_proposals` + `district_votes` | Sama seperti di atas, untuk membuka distrik |
| `reports` | `reporter_id`, `target_id`, `created_at`, `resolved_at`. UNIQUE `(reporter_id, target_id)` selama belum selesai |
| `transactions` | Buku besar: `from_kind`/`from_id`, `to_kind`/`to_id` (user/negara/npc/sistem), `amount`, `tax`, `reason`, `ref`, `at` |
| `cooldowns` | `(user_id, action)` → `ready_at` |
| `daily_earnings` | `(user_id, day)` → `earned`. Dipakai untuk batas harian koin. |
| `missions` | `(user_id, day, key)` → `done_at`. Tiga misi per hari dipilih deterministik dari tanggal WIB. |
| `announcements` | Pengumuman presiden |
| `news` | Ticker kota, ditulis oleh RPC (dibersihkan setelah 14 hari) |
| `optout_requests` | Pengganti `opt_out_resident` publik: `resident_id`, `user_id`, `reason`, `status` |
| `city_snapshot` (1 baris jsonb) | Penduduk, kepuasan, cakupan layanan, kas, pajak. Diperbarui cron tiap jam. Dibaca tamu. |

### 2c. Aturan dari prototipe yang dipertahankan

- **Peta:** grid 41×41, blok 5, distrik pusat terbuka. Utara/Selatan 2.500 NC, Barat/Timur 2.000 NC dari kas lewat voting.
- **Harga:** semua harga di `CAT` prototipe, ditambah tanah 20 NC per kavling untuk bangunan pribadi. Rumah Kecil pertama gratis, sekali seumur akun (`free_house_used`, supaya tidak bisa bongkar-bangun ulang). 10% harga masuk kas.
- **Ukuran kavling:** sama dengan prototipe, boleh diputar. Harus muat satu blok, tidak di jalan, distrik harus terbuka.
- **Batas:** maksimal 6 bangunan pribadi. Maksimal 2 usulan aktif per warga (bangunan + distrik), presiden dikecualikan. Kantor khusus Pengusaha.
- **Voting:** 1 akun 1 suara, boleh ganti pilihan selama masih dibuka. Lolos bila setuju > tolak **dan setuju ≥ 5** (sama dengan prototipe; mohon konfirmasi, lihat bagian 7). Lolos tapi kas kurang → `menunggu_kas`.
- **Presiden:** setujui langsung, veto, buka distrik, atur pajak, pengumuman, angkat/turunkan Menteri. Presiden tidak bekerja dan tidak membangun pribadi.
- **Polisi:** hanya bisa menangkap warga dengan laporan dari **2+ akun berbeda** yang belum selesai. Butuh kantor polisi dan penjara yang sudah jadi. Ditahan 3 jam nyata. Laporan NPC tidak dihitung.
- **Cooldown (jam nyata):** shift 4 jam (energi 20), serabutan 2 jam (energi 15), aksi profesi 1 jam (energi 10), bantu bangun 1 jam (energi 15). Energi pulih 12 per jam.
- **Batas harian koin dari aksi:** usulan default **300 NC/hari WIB** per akun. Dihitung untuk serabutan, aksi profesi, upah bantu bangun, gaji negara, dan hadiah misi. Pendapatan usaha dan gaji dari pemilik usaha tidak dihitung karena berupa transfer, bukan koin baru.
- **NPC:** tidak voting, tidak melamar kerja, tidak punya akun. Tetap tampil sebagai penghuni rumah (maks 4 per rumah) dan pejalan kaki. `npc_staff` hanya angka tampilan.

### 2d. Waktu bangun (jam nyata, usulan)

Di prototipe 1 jam game = 1 menit nyata, jadi angkanya harus diterjemahkan ulang. Usulan saya:

| Tipe | Jam | Tipe | Jam |
|---|---|---|---|
| Rumah Kecil, Sawah | 2 | Taman | 6 |
| Warung | 3 | Gardu PLN, Tugu | 12 |
| Rumah Tingkat, Kafe | 4 | Tempat Ibadah | 18 |
| Kos, Toko, Bengkel | 6 | Sekolah, Polisi, Penjara, Pasar | 24 |
| Kantor | 12 | Rumah Sakit | 36 |
| | | Stadion 48 · Istana 72 | |

Bantu bangun mengurangi sisa waktu: Tukang 16%, Mandor 11%, lainnya 5% dari total.

## 3. Daftar RPC

Semua `SECURITY DEFINER`, memeriksa `auth.uid()`, profil ada, dan `jail_until` untuk aksi. Fungsi berawalan `_` adalah internal: `REVOKE EXECUTE` dari `public`, `anon`, `authenticated`.

### 3a. Perbaikan celah lama (paling atas di supabase_v2.sql)

| Langkah | Cara |
|---|---|
| Tutup `claim_resident` | Loop `pg_proc` untuk semua overload, `REVOKE EXECUTE ... FROM public, anon, authenticated`. Aman walau tanda tangannya tidak diketahui. |
| `opt_out_resident` tidak publik | REVOKE seperti di atas. Diganti `request_opt_out(resident_id, reason)` (login wajib) + `admin_review_optout(id, approve)`. |
| Vote per `device_id` | REVOKE fungsi vote lama dan cabut akses tulis tabelnya. Diganti `vote_proposal` per akun. |
| `send_chat_message` | Overload lama di-DROP. Versi baru `send_chat_message(p_text)`: nama dari profil, maks 200 karakter, 1 pesan per 5 detik per akun (dicek dengan `last_chat_at` dan baris terkunci). |

### 3b. Untuk tamu (anon, baca saja, tanpa realtime)

- `get_city_snapshot()` → kas, pajak, statistik, distrik, 10 berita, donatur teratas, ringkasan voting, 30 chat terakhir.
- `get_buildings(p_districts text[])` → bangunan per distrik yang terlihat, termasuk progres dan jumlah suara.
- `get_residents(p_district text)` → NPC per distrik (nama, profesi, warna, rumah) untuk label dan pejalan kaki.
- `username_available(p_username)` → untuk form daftar.

### 3c. Akun dan profil (Tahap 3)

- `register_profile(p_name, p_profession, p_color)` → membuat profil sekali, modal awal 400 NC dicatat di buku besar.
- `get_my_state()` → profil, energi terkini, cooldown, misi hari ini, pekerjaan, sisa batas harian.
- `change_profession(p_prof)` → 100 NC ke kas. Presiden/Menteri tidak bisa dipilih sendiri.
- `set_color(p_color)` → hanya dari daftar warna.

### 3d. Bangun dan voting (Tahap 3)

- `build_private(p_type, p_i, p_j, p_rotated)`
- `propose_public(p_type, p_i, p_j, p_rotated)` → otomatis 1 suara setuju dari pengusul.
- `vote_proposal(p_id, p_vote)`, `propose_district(p_key)`, `vote_district(p_id, p_vote)`
- `help_build(p_building_id)`, `demolish_building(p_id)` (bangunan lama `protected` tidak bisa dibongkar)
- `set_wage(p_building_id, p_wage)` 10–80, `set_job_open(p_building_id, p_open)`

### 3e. Kerja, profesi, laporan, misi (Tahap 4)

- `apply_job(p_building_id)`, `quit_job()`, `do_shift()`, `odd_job()`
- `prof_action(p_kind, p_target_user, p_target_resident)` untuk: bakti, rancang, ajar, belajar, obati, tangkap, jualan, panen, promosi, beraksi, rapat.
- `report_citizen(p_target_user)`, `seek_treatment()`
- Misi diselesaikan otomatis di dalam RPC aksi lewat `_mission_done()`. Tidak ada RPC "klaim misi" yang bisa dipanggil berulang.

### 3f. Presiden / admin (Tahap 4–5)

- `pres_approve(p_id)`, `pres_veto(p_id)`, `pres_open_district(p_id)`, `pres_set_tax(p_pct)`, `pres_announce(p_text)`, `pres_set_minister(p_user, p_on)`, `pres_release(p_user)`
- `admin_add_donation(p_name, p_amount, p_note)`, `admin_delete_donation(p_id)`, `admin_set_donation_goal(p_amount)`
- `admin_list_claims()`, `admin_review_claim(p_id, p_approve)` → bila disetujui: `residents.claimed_by` dan `profiles.resident_id` terisi, rumah NPC pindah ke akun itu, tokoh hilang dari daftar NPC pejalan kaki.
- `request_claim(p_resident_id, p_proof)`, `request_opt_out(...)`, `admin_review_optout(...)`
- `admin_delete_chat(p_id)`

### 3g. Pekerjaan terjadwal (pg_cron)

| Job | Jadwal | Isi |
|---|---|---|
| `netizenia-hourly` | menit 0 tiap jam | Selesaikan bangunan yang progresnya 100%. Tutup voting yang lewat 24 jam. Mulai bangun usulan `menunggu_kas` bila kas cukup. Gaji pegawai negara yang shift dalam 4 jam terakhir. Pendapatan usaha + pajak. PBB rumah. Perbarui `city_snapshot`. |
| `netizenia-cleanup` | 03:10 WIB tiap hari | Hapus chat > 7 hari, berita > 14 hari, cooldown dan pendapatan harian lama. |

Catatan: karena voting ditutup oleh cron tiap jam, hasil bisa terlambat sampai 59 menit setelah 24 jam. UI menampilkan "menunggu penghitungan". Bila ingin lebih cepat, jadwal penutupan voting bisa dibuat tiap 5 menit.

## 4. Skala untuk ribuan pengunjung HP

- **Tamu:** hanya `get_city_snapshot` + `get_buildings` untuk distrik yang terlihat. Polling 60 detik, berhenti saat tab tidak aktif. Tidak ada koneksi realtime.
- **Pemain login:** realtime hanya untuk `buildings`, `proposals`, `chat_messages`. Kebijakan SELECT tabel itu hanya `to authenticated`, jadi anon tidak bisa berlangganan.
- **Per distrik:** kolom `district` + indeks. Klien menghitung distrik yang terlihat dari kamera dan memuatnya sekali, lalu menyimpan cache.
- **Data pribadi:** tabel `profiles` hanya bisa dibaca pemiliknya. Data warga lain lewat RPC yang memilih kolom publik saja (nama, profesi, warna, status, jumlah laporan). Koin orang lain tidak terlihat.
- **Kas** adalah satu baris yang sering dikunci. Untuk skala game ini aman karena aksi dibatasi cooldown. Bila nanti macet, pajak bisa diakumulasi dan diselesaikan oleh cron.

## 5. Langkah dashboard Supabase (Anda yang melakukan)

1. **Authentication → Sign In / Providers → Email:** aktif. **Confirm email: OFF.** Minimum password 8. "Allow new users to sign up": ON.
2. **Authentication → Sign In / Providers → Google:** sudah aktif untuk presiden. Tidak perlu diubah; warga memakai provider yang sama.
3. **Authentication → URL Configuration:** Site URL = domain Pages Anda. Tambahkan Redirect URLs: `https://<proyek>.pages.dev/v2/**`, domain kustom `/v2/**`, dan `http://localhost:8788/**` untuk tes lokal.
4. **Database → Extensions:** aktifkan **pg_cron**.
5. **Authentication → Rate Limits:** periksa batas sign-up per IP (default cukup; turunkan bila ada banjir akun).
6. **(Opsional, perlu keputusan Anda) Authentication → Attack Protection → CAPTCHA (Cloudflare Turnstile):** mengurangi akun palsu. Ini butuh *site key* Turnstile di HTML. Site key itu publik, bukan rahasia, tapi aturan Anda hanya mengizinkan URL + publishable key, jadi saya tidak memakainya tanpa izin.
7. **SQL Editor:** jalankan `v2/supabase_v2.sql` (Tahap 2). Aman diulang.
8. **Database → Publications → supabase_realtime:** pastikan setelah SQL dijalankan isinya hanya `buildings`, `proposals`, `chat_messages` (plus tabel lama yang memang perlu).
9. **Cloudflare Pages:** build command kosong, output directory = root repo. v2 tersedia di `/v2/`. index.html lama tidak disentuh.

Risiko yang akan dites paling awal di Tahap 3: GoTrue harus menerima domain `@warga.netizenia.local`. Bila ditolak karena validasi domain, alternatifnya domain lain yang Anda miliki (misalnya subdomain sendiri) tanpa mengirim email apa pun.

## 6. Arah tampilan baru (menjawab "UI/UX lebih gampang, grafik terlalu polos")

### Grafik

- **Langit dan cahaya mengikuti jam WIB:** pagi keemasan, siang cerah, senja oranye, malam biru dengan jendela menyala, lampu jalan, dan bintang.
- **Warna lebih hidup:** tone mapping ACES + sRGB (tersedia di r128), rumput dengan variasi warna, trotoar bertepi, zebra cross, bayangan lembut yang lebih rapi.
- **Nuansa Indonesia:** atap genteng oranye, bendera merah putih berkibar, angkot, ojek, gerobak warung, pohon kelapa dan beringin, sawah bertingkat, sungai dengan jembatan di tepi kota.
- **Animasi bangun:** perancah naik bertahap, crane berputar, debu saat membangun, kembang api saat bangunan selesai.
- **Penduduk lebih berkarakter:** pejalan kaki dengan warna baju per profesi, rambut, dan nama NPC saat diketuk.
- **Mode hemat HP:** bayangan mati, pejalan lebih sedikit, pixel ratio dibatasi, otomatis bila FPS turun.

### UI/UX

- **Dock dari 9 tombol menjadi 5:** Bangun · Kerja · Voting · Kota · Chat. "Jalan-jalan" dan "Mode foto" jadi tombol mengambang.
- **Tombol "Langkah berikutnya"** yang selalu menunjukkan hal paling berguna: "Ambil rumah gratis", "Shift siap", "2 usulan menunggu suaramu".
- **Panduan awal 3 langkah** untuk pemain baru: rumah gratis → cari kerja → voting.
- **Panel bawah bisa ditarik** (setengah/penuh) di HP; panel samping kanan di desktop.
- **Umpan balik jelas:** koin "+25 NC" melayang, timer cooldown berbentuk lingkaran, bar energi dan kesehatan dengan ikon.
- **Tamu langsung melihat kota** tanpa layar login penuh. Ada spanduk kecil "Masuk untuk ikut membangun".
- **Login sederhana:** "Masuk dengan Google" atau satu form username + kata sandi dengan pilihan Daftar/Masuk.

Usulan penjadwalan: mesin grafik baru dan kerangka UI dikerjakan bersama Tahap 3. Polesan dan mode hemat di Tahap 6.

## 7. Yang saya butuhkan dari Anda untuk lanjut ke Tahap 2

1. **Upload index.html lama.**
2. **Jalankan `v2/cek_skema_lama.sql`** (baca saja) dan tempel hasilnya.
3. **Keputusan:**
   - "Minimal 5 suara" = minimal 5 **setuju** (seperti prototipe) atau minimal 5 **total suara**?
   - Batas harian koin dari aksi: 300 NC/hari cukup?
   - Waktu bangun di tabel 2d disetujui?
   - Pakai Turnstile (site key publik di HTML) atau tidak?
   - Suara dari akun yang umurnya kurang dari 24 jam: tetap dihitung, atau ditahan untuk mencegah akun palsu?
