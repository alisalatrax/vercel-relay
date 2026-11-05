-- ============================================================================
-- PROYEK LAMA siyknwzzjtyykwhiqmeu SAJA (situs v1). JANGAN dijalankan di proyek v2.
-- BELUM DIJALANKAN. Jalankan hanya setelah disetujui pemilik proyek.
-- Aman diulang. Tidak menghapus data, tidak mengubah tabel.
--
-- Isi: mencabut hak panggil dua RPC lama yang tidak dibutuhkan halaman v1.
--   1. claim_resident(text, text)
--      Halaman v1 tidak pernah memanggilnya (klaim v1 lewat request_claim + persetujuan
--      presiden). Saat ini siapa pun bisa langsung mengklaim nama warga mana pun.
--   2. increment_proposal_vote(text, text)
--      Vote per device_id bisa digelembungkan. Tabel proposals terlihat kosong dari akses
--      publik, jadi RPC ini selalu menjawab not_found dan halaman v1 sudah memakai
--      vote lokal. Setelah dicabut, halaman v1 masuk ke jalur cadangan yang sama
--      (vote lokal), jadi tampilan pengguna tidak berubah.
--
-- Yang SENGAJA tidak disentuh karena dipakai fitur v1:
--   INSERT residents (daftar jadi rakyat), opt_out_resident (hapus nama),
--   request_claim (antrean klaim), send_chat_message (chat), dan semua RPC admin.
-- ============================================================================

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('claim_resident', 'increment_proposal_vote')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

-- Cek (hasil benar: kolom anon dan login bernilai false untuk kedua fungsi).
select p.oid::regprocedure as fungsi,
       has_function_privilege('anon', p.oid, 'execute') as anon,
       has_function_privilege('authenticated', p.oid, 'execute') as login
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('claim_resident', 'increment_proposal_vote');

-- Untuk membatalkan (mengembalikan seperti semula):
-- grant execute on function public.claim_resident(text, text) to anon, authenticated;
-- grant execute on function public.increment_proposal_vote(text, text) to anon, authenticated;
