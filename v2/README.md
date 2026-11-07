# Republik Netizenia v2

Kota 3D bersama yang dibangun warga dari komen Instagram. Halaman statis (`v2/index.html`) untuk Cloudflare Pages, dengan semua aturan game ditegakkan di Supabase.

## Isi folder

| File | Fungsi |
|---|---|
| `index.html` | Halaman game. Satu file statis, tanpa build. three r128 + supabase-js 2.117.3 (versi dikunci). Hanya berisi URL Supabase dan publishable key. |
| `supabase_v2.sql` | Seluruh database v2. Aman dijalankan berulang. Jalankan dengan kode pemuat (lihat di bawah). |
| `RENCANA.md` | Rencana awal, keputusan, dan perubahan rancangan. |
| `TES_TAHAP2.md` … `TES_TAHAP6.md` | Daftar tes per tahap, termasuk tes curang. |
| `cek_skema_lama.sql` | Kueri baca-saja untuk memeriksa skema proyek lama. |
| `proyek_lama_tutup_celah_minimal.sql` | Usulan menutup 2 RPC lama di proyek v1. **Belum dijalankan.** |
| `tools/parse_komen.py` | Pengurai PDF komentar menjadi nama + profesi warga NPC. |

## Arsitektur singkat

- **Database** di schema privat `nz` (tidak terbuka lewat Data API). RLS aktif di semua tabel. Browser tidak bisa menulis tabel apa pun; semua aksi lewat RPC `SECURITY DEFINER` di schema `public` yang memeriksa `auth.uid()`, saldo, jeda, energi, profesi, dan status ditahan.
- **Koin** hanya berpindah lewat satu fungsi buku besar (`nz.tx`), tercatat di `nz.transactions`, dengan batas 300 NC per hari dari aksi.
- **Waktu game = jam WIB nyata.** Progres bangunan dihitung dari `started_at` dan `build_hours`. pg_cron tiap jam menutup voting (lolos bila setuju > tolak dan minimal 5 setuju), membayar gaji negara, pendapatan usaha, dan PBB. Chat lebih dari 7 hari dihapus harian.
- **Skala:** tamu hanya memanggil `get_city_snapshot` + `get_buildings` per distrik yang terlihat, tanpa realtime. Realtime hanya untuk pemain login (`nz.buildings`, `nz.proposals`, `nz.chat_messages`). Data warga NPC di-cache 10 menit di perangkat.

## Proyek dan situs

- **Supabase:** `bwubqnfvdxwhwwiibdzv` (proyek v2). Proyek lama `siyknwzzjtyykwhiqmeu` hanya dipakai `site/index.html` (v1).
- **Cloudflare Pages:** branch `main`, output directory root. `v2/index.html` dan `site/v2/index.html` harus selalu sama. Pratinjau branch kerja: `claude-netizenia-v2-integrat.republiknetizenia.pages.dev`.

## Memperbarui database

Di SQL Editor, jalankan kode pemuat dengan SHA commit yang berisi `supabase_v2.sql` terbaru:

```sql
create extension if not exists http with schema extensions;
do $$
begin
  execute (select content from extensions.http_get(
    'https://raw.githubusercontent.com/alisalatrax/vercel-relay/<SHA>/v2/supabase_v2.sql'));
end $$;
```

## Akun

- **Warga:** Google (bila provider Google aktif; tombolnya otomatis tersembunyi bila belum) atau username + kata sandi (email internal `<username>@warga.netizenia.local`, Confirm email OFF). Kata sandi akun username tidak bisa direset lewat email; presiden bisa menghapus akun di Authentication → Users atau mengganti kata sandi lewat SQL Editor.
- **Presiden:** akun mana pun yang `user_id`-nya ada di `public.admins`.
