-- Republik Netizenia v2 · cek skema lama (BACA SAJA)
-- Tidak mengubah apa pun. Jalankan di Supabase SQL Editor, lalu salin hasil
-- setiap bagian (atau satu hasil jsonb di akhir) ke chat.
-- Tidak menampilkan isi data warga, hanya struktur.

select jsonb_pretty(jsonb_build_object(
  'tables', (
    select jsonb_agg(jsonb_build_object(
      'table', c.relname,
      'rls', c.relrowsecurity,
      'rows_estimate', c.reltuples::bigint,
      'columns', (
        select jsonb_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod) order by a.attnum)
        from pg_attribute a
        where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
      )
    ) order by c.relname)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r','v','m')
  ),
  'functions', (
    select jsonb_agg(jsonb_build_object(
      'fn', p.oid::regprocedure::text,
      'security_definer', p.prosecdef,
      'returns', pg_get_function_result(p.oid),
      'execute_anon', has_function_privilege('anon', p.oid, 'execute'),
      'execute_authenticated', has_function_privilege('authenticated', p.oid, 'execute')
    ) order by p.proname)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
  ),
  'policies', (
    select jsonb_agg(jsonb_build_object(
      'table', tablename, 'name', policyname, 'cmd', cmd,
      'roles', roles, 'using', qual, 'check', with_check
    ) order by tablename, policyname)
    from pg_policies where schemaname = 'public'
  ),
  'table_grants', (
    select jsonb_agg(jsonb_build_object(
      'table', table_name, 'role', grantee, 'privilege', privilege_type
    ) order by table_name, grantee, privilege_type)
    from information_schema.role_table_grants
    where table_schema = 'public' and grantee in ('anon','authenticated')
  ),
  'realtime_tables', (
    select jsonb_agg(schemaname || '.' || tablename)
    from pg_publication_tables where pubname = 'supabase_realtime'
  ),
  'extensions', (select jsonb_agg(extname) from pg_extension),
  'triggers', (
    select jsonb_agg(jsonb_build_object('table', event_object_table, 'trigger', trigger_name, 'timing', action_timing, 'event', event_manipulation))
    from information_schema.triggers where trigger_schema = 'public'
  )
)) as skema_lama;

-- Bagian opsional: definisi lengkap fungsi lama yang akan diperbaiki.
-- Jalankan juga dan tempel hasilnya bila tidak terlalu panjang.
select p.oid::regprocedure as fn, pg_get_functiondef(p.oid) as def
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and (p.proname in ('claim_resident','opt_out_resident','send_chat_message')
       or p.proname ilike '%vote%'
       or p.proname ilike '%claim%'
       or p.proname ilike '%admin%');
