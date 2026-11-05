# Republik Netizenia v2 — Tes Tahap 2 (database)

File yang dites: `v2/supabase_v2.sql`. Semua langkah di bawah Anda jalankan sendiri.

## A. Sebelum menjalankan SQL

1. **Database → Extensions → pg_cron: Enable.** Tanpa ini voting tidak pernah ditutup otomatis. File tetap jalan, tapi menampilkan NOTICE.
2. Buka **SQL Editor**, tempel seluruh isi `supabase_v2.sql`, lalu **Run**.
3. Hasil terakhir adalah tabel **"cek | objek"** dengan baris **`OK | v2 terpasang: … bangunan, … warga NPC, pg_cron aktif`**. Baris berawalan `INFO` boleh diabaikan. Bila tidak ada baris OK, atau muncul `ERROR` merah, kirim teksnya ke saya. Satu error membatalkan seluruh file, termasuk perbaikan celah.
4. Hasil `hasil_isi_dunia` kira-kira berisi 56 bangunan dan sekitar 326 NPC. Jumlah NPC tergantung isi `public.residents` Anda.
5. Jalankan file sekali lagi. Angka `rumah_npc_baru` harus 0 dan tidak ada error. Ini membuktikan file aman diulang.
6. Cek jadwal cron:
   ```sql
   select jobname, schedule, command from cron.job where jobname like 'netizenia%';
   ```
   Harus ada 2 baris: `netizenia-hourly` dan `netizenia-cleanup`.

## B. Akibat ke halaman lama (index.html lama)

Ini akibat langsung dari perbaikan celah yang Anda minta. File index.html lama tidak diubah.

| Fitur di halaman lama | Setelah SQL dijalankan |
|---|---|
| Daftar jadi rakyat (INSERT ke `residents` tanpa login) | Ditolak. Ini celah tulis publik. |
| Klaim nama, hapus nama (opt-out), vote usulan | Ditolak. Diganti versi v2 yang butuh login. |
| Kirim chat (`send_chat_message(p_username, p_text)`) | Fungsi lama dihapus. Chat lama 7 hari terakhir disalin ke chat v2. |
| Panel admin lama (donasi, setting, bangunan, impor nama, antrean klaim lama) | Tetap jalan. |
| Tampilan peta, papan donatur, realtime | Tetap jalan (hanya membaca). |

## C. Tes curang lewat console browser (sebagai warga)

Buka situs mana saja (misalnya halaman lama), tekan F12, lalu buka tab **Console**. Tempel baris per baris.

**1. Siapkan klien** (URL dan publishable key yang memang sudah publik di halaman lama):

```js
const { createClient } = await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.3/+esm');
const sb = createClient('https://bwubqnfvdxwhwwiibdzv.supabase.co', 'sb_publishable_cn9p-oE4k2FM9pdqF_tbcg_i0wqTWos');
```

**2. Buat akun tes.** Kata sandi diketik di jendela prompt, bukan ditulis di kode. Pakai kata sandi sekali pakai, minimal 8 karakter.

```js
await sb.auth.signUp({ email: 'tescurang1@warga.netizenia.local', password: prompt('Kata sandi tes') });
await sb.rpc('register_profile', { p_name: 'Tes Curang', p_profession: 'Warga' });
await sb.rpc('get_my_state');   // catat "coins": 400
```

Bila `signUp` gagal dengan pesan email tidak valid, Supabase menolak domain `.local`. Kirim pesannya ke saya; domain internal akan saya ganti di Tahap 3.

**3. Coba curang. SEMUA harus gagal:**

| # | Perintah | Hasil yang benar |
|---|---|---|
| 1 | `await sb.schema('nz').from('profiles').update({ coins: 999999 }).eq('display_name','Tes Curang')` | error schema tidak diizinkan |
| 2 | `await sb.schema('nz').from('settings').update({ kas: 0 }).eq('id', 1)` | error schema tidak diizinkan |
| 3 | `await sb.rpc('tx', { p_from_kind:'sistem', p_from_id:null, p_to_kind:'user', p_to_id:'x', p_amount:9999, p_reason:'x' })` | error fungsi tidak ditemukan |
| 4 | `await sb.rpc('change_profession', { p_profession: 'Presiden' })` | "Profesi tidak tersedia." |
| 5 | `await sb.rpc('change_profession', { p_profession: 'Menteri' })` | "Profesi tidak tersedia." |
| 6 | `await sb.rpc('pres_set_tax', { p_pct: 0 })` | "Khusus presiden." |
| 7 | `await sb.rpc('admin_run_tick')` | "Khusus presiden." |
| 8 | `await sb.from('residents').insert({ display_name: 'Spam', role: 'Warga', claimed: true })` | permission denied |
| 9 | `await sb.rpc('increment_proposal_vote', { p_id: 'p_istana', device_id: 'abc' })` | permission denied |
| 10 | `await sb.rpc('claim_resident', { p_name: 'David', p_ig: 'david' })` | permission denied |
| 11 | `await sb.rpc('opt_out_resident', { p_name: 'David' })` | permission denied |
| 12 | `await sb.rpc('vote_proposal', { p_id: 1, p_vote: 5 })` | "Suara harus setuju atau tolak." |
| 13 | `await sb.rpc('odd_job'); await sb.rpc('odd_job')` | panggilan kedua: "Kerja serabutan bisa lagi dalam 2 jam." |
| 14 | `await sb.rpc('send_chat_message', { p_text: 'a' }); await sb.rpc('send_chat_message', { p_text: 'b' })` | panggilan kedua: "Tunggu 5 detik…" |
| 15 | `await sb.rpc('send_chat_message', { p_username: 'Presiden', p_text: 'palsu' })` | error fungsi tidak ditemukan (nama bebas tidak bisa lagi) |
| 16 | `await sb.rpc('prof_action', { p_kind: 'tangkap', p_target: '<uuid siapa pun>' })` | "Aksi ini bukan untuk profesimu." |
| 17 | `await sb.rpc('demolish_building', { p_id: 1 })` | "Bangunan bersejarah tidak bisa dibongkar." |
| 18 | `await sb.rpc('get_my_state')` | koin tetap sesuai hasil aksi sah saja |

**4. Vote ganda.** Ambil id usulan dari `(await sb.rpc('get_city_snapshot')).data.proposals`:

```js
const id = (await sb.rpc('get_city_snapshot')).data.proposals[0].id;
await sb.rpc('vote_proposal', { p_id: id, p_vote: 1 });   // catat "yes"
await sb.rpc('vote_proposal', { p_id: id, p_vote: 1 });   // "yes" TIDAK bertambah
await sb.rpc('vote_proposal', { p_id: id, p_vote: -1 });  // yes turun 1, no naik 1 (ganti pilihan)
```

**5. Tamu tanpa login** (`await sb.auth.signOut()` dulu):

| Perintah | Hasil yang benar |
|---|---|
| `await sb.rpc('get_city_snapshot')` | berhasil (kas, berita, usulan, donatur, chat) |
| `await sb.rpc('get_buildings', { p_districts: ['pusat'] })` | berhasil |
| `await sb.rpc('vote_proposal', { p_id: 1, p_vote: 1 })` | permission denied |
| `await sb.rpc('send_chat_message', { p_text: 'hai' })` | permission denied |

## D. Tes fungsi (alur normal)

Masuk lagi sebagai akun tes (`sb.auth.signInWithPassword`).

1. **Rumah gratis:** cari kavling kosong lewat `get_buildings`. Contoh kavling yang biasanya kosong: i=11, j=13. Lalu `await sb.rpc('build_private', { p_type: 'rumah', p_i: 11, p_j: 13 })`. Hasilnya `"price": 0`.
2. **Rumah kedua berbayar:** `build_private` rumah di kavling lain. Harganya 170 NC (150 + tanah 20).
3. **Kavling dobel:** bangun lagi di 11,13. Hasilnya "Kavling sudah terisi."
4. **Distrik tertutup:** `build_private` di i=1, j=1. Hasilnya "Distrik Utara belum dibuka."
5. **Batas usulan:** `propose_public` taman 2 kali, lalu yang ketiga. Hasilnya "Maksimal 2 usulan aktif per warga."
6. **Voting selesai otomatis:** buat 5 akun tes, beri 5 suara setuju ke satu usulan. Lalu percepat di SQL Editor:
   ```sql
   update nz.proposals set ends_at = now() where status = 'voting' and id = <id>;
   select nz.tick_hourly();
   select id, status, yes, no from nz.proposals order by id desc limit 5;
   ```
   Usulan dengan setuju ≥ 5 dan setuju > tolak harus `lolos` (atau `menunggu_kas` bila kas kurang). Yang tidak memenuhi harus `ditolak`, dan sketsanya hilang dari peta.
7. **Polisi:** akun A berprofesi Polisi. Akun B dilaporkan oleh 1 akun lain, lalu A mencoba `prof_action('tangkap')`. Hasilnya gagal "minimal 2 akun berbeda". Setelah 2 akun lain (bukan A) melapor, penangkapan berhasil. B lalu tidak bisa aksi apa pun selama 3 jam.
   Catatan: kantor polisi dan penjara di peta masih dalam pembangunan (60% dan 50%). Penangkapan baru bisa setelah keduanya jadi, atau setelah Anda percepat di SQL Editor:
   `update nz.buildings set stage='jadi' where seed_key in ('polisi','penjara');`
8. **Batas harian:** di SQL Editor isi `insert into nz.daily_earnings values ('<uuid akun>', (now() at time zone 'Asia/Jakarta')::date, 300) on conflict (user_id, day) do update set earned = 300;`. Lalu dari console panggil `odd_job`. Hasilnya "Batas harian koin dari aksi (300 NC) sudah tercapai."

## E. Tes presiden

Masuk dengan Google memakai akun yang ada di `public.admins`, lalu jalankan:

1. `register_profile('Pak Mulyo')`. Profesinya otomatis Presiden dan rumahnya Rumah Pak Mulyo.
2. `pres_set_tax({ p_pct: 12 })`, `pres_announce({ p_text: 'Halo rakyat' })`, `pres_veto`, dan `pres_approve` pada usulan aktif.
3. Antrean: `admin_list_queue()`, lalu `admin_review_claim({ p_request_id, p_approve: true })`. Tokoh harus tertaut ke akun pengklaim.

## F. Bersih-bersih akun tes

Di SQL Editor:

```sql
delete from auth.users where email like 'tescurang%@warga.netizenia.local';
```

Profil, bangunan, suara, dan laporan akun tes ikut terhapus otomatis.

## G. Yang sudah saya uji sendiri

Saya menguji di Postgres 16 lokal dengan tiruan Supabase: role anon/authenticated, `auth.uid()`, publikasi realtime, dan skema lama dari dua file migrasi Anda. Hasilnya:

- **File dijalankan dua kali:** tanpa error dan tanpa data ganda.
- **Semua tes curang di bagian C:** gagal seperti seharusnya.
- **Voting:** 5 setuju lolos, 3 setuju ditolak, ekonomi tidak dobel saat tick dipanggil ulang.
- **Penangkapan:** butuh 2 pelapor selain polisi yang menangkap.
- **Chat:** jeda 5 detik dan sensor kata kasar berjalan.
- **Klaim:** tokoh tertaut ke akun, dan tabel lama ikut ditandai.
- **Opt-out:** nama disembunyikan dan tabel lama ikut ditandai.

Yang **tidak** bisa saya uji di sini adalah Supabase Auth sungguhan, Realtime sungguhan, dan pg_cron. Ketiganya tercakup di langkah A dan C.
