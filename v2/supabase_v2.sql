-- ============================================================================
-- REPUBLIK NETIZENIA v2 · supabase_v2.sql
-- Jalankan sendiri di Supabase SQL Editor. Aman dijalankan berulang.
--
-- ISI FILE
--   Bagian 0  Perbaikan celah lama (schema public)
--   Bagian 1  Schema privat "nz" + tabel game v2
--   Bagian 2  Data awal: katalog, distrik, setelan, fasilitas lama, warga NPC
--   Bagian 3  Fungsi internal (nz.*), tidak bisa dipanggil dari browser
--   Bagian 4  RPC publik (public.*), satu-satunya pintu dari browser
--   Bagian 5  Jadwal pg_cron, realtime, hak akses, pemeriksaan akhir
--
-- KEAMANAN
--   * Semua tabel game v2 ada di schema "nz". Schema ini TIDAK dibuka lewat
--     Data API, jadi browser tidak bisa SELECT/INSERT/UPDATE/DELETE langsung.
--   * Browser hanya bisa memanggil RPC di Bagian 4. Semua RPC SECURITY DEFINER
--     dan memeriksa auth.uid(), saldo, cooldown, energi, profesi, status ditahan.
--   * Hanya pemain login (role authenticated) yang boleh SELECT tiga tabel
--     untuk realtime: nz.buildings, nz.proposals, nz.chat_messages.
--   * File ini tidak berisi kunci, token, atau kata sandi apa pun.
-- ============================================================================


-- ============================================================================
-- BAGIAN 0 · PERBAIKAN CELAH LAMA
-- ============================================================================

-- 0.1  Cabut RPC lama yang bisa dipanggil tanpa login.
--      claim_resident     : klaim langsung tanpa persetujuan presiden.
--      opt_out_resident   : siapa pun bisa menghapus nama orang lain.
--      increment_proposal_vote : vote per device_id (bisa diakali).
--      request_claim      : antrean klaim tanpa akun. Diganti request_claim_v2.
--      Fungsi tidak di-drop supaya data dan riwayat tetap utuh; hanya
--      hak EXECUTE dicabut, untuk semua overload.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('claim_resident', 'opt_out_resident', 'increment_proposal_vote', 'request_claim')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

-- 0.2  send_chat_message lama menerima nama yang diketik bebas
--      (p_username, p_text). Semua overload lama di-drop. Versi baru
--      send_chat_message(p_text) dibuat di Bagian 4: nama diambil dari
--      profil akun dan dibatasi 1 pesan per 5 detik per akun.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'send_chat_message'
      and pg_get_function_identity_arguments(p.oid) <> 'p_text text'
  loop
    execute format('drop function %s', r.sig);
  end loop;
end $$;

-- 0.3  Tidak ada lagi tulis langsung dari browser ke tabel lama.
--      Sebelumnya anon bisa INSERT ke public.residents (daftar rakyat).
--      Semua hak INSERT/UPDATE/DELETE/TRUNCATE untuk anon dan authenticated
--      dicabut di semua tabel public. RPC SECURITY DEFINER lama milik admin
--      (admin_add_donation, admin_set_setting, dll.) tetap jalan karena
--      dijalankan sebagai pemilik tabel.
--      Tabel public yang belum ber-RLS dinyalakan RLS-nya dengan kebijakan
--      baca publik, supaya perilaku baca halaman lama tidak berubah.
do $$
declare t record;
begin
  for t in
    select c.relname, c.relrowsecurity
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
  loop
    begin
      execute format('revoke insert, update, delete, truncate on public.%I from anon, authenticated', t.relname);
      if not t.relrowsecurity then
        execute format('alter table public.%I enable row level security', t.relname);
        execute format('drop policy if exists "v2 baca publik" on public.%I', t.relname);
        execute format('create policy "v2 baca publik" on public.%I for select using (true)', t.relname);
      end if;
    exception when others then
      -- Tabel milik role lain (mis. dari ekstensi) dilewati; dilaporkan di pemeriksaan akhir.
      raise notice 'Tabel public.% dilewati: %', t.relname, sqlerrm;
    end;
  end loop;
end $$;

-- 0.4  Tabel admins dipertahankan (presiden = baris di tabel ini).
create table if not exists public.admins (
  user_id uuid primary key,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;

-- 0.5  Antrean klaim lama dipakai lagi, ditambah kolom penaut akun.
create table if not exists public.claim_requests (
  id bigint generated always as identity primary key,
  display_name text not null,
  ig_username text not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now()
);
alter table public.claim_requests enable row level security;
alter table public.claim_requests add column if not exists user_id uuid;
alter table public.claim_requests add column if not exists npc_id bigint;
alter table public.claim_requests add column if not exists note text;
alter table public.claim_requests add column if not exists reviewed_at timestamptz;
create index if not exists claim_requests_pending_idx on public.claim_requests (status, created_at);


-- ============================================================================
-- BAGIAN 1 · SCHEMA PRIVAT nz + TABEL GAME
-- ============================================================================

create schema if not exists nz;
revoke all on schema nz from public, anon;
-- USAGE hanya untuk realtime (authenticated membaca 3 tabel lewat RLS).
grant usage on schema nz to authenticated;
alter default privileges in schema nz revoke execute on functions from public;

create table if not exists nz.meta (
  key text primary key,
  value jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists nz.settings (
  id int primary key default 1 check (id = 1),
  kas bigint not null default 9000 check (kas >= 0),
  tax_pct int not null default 10 check (tax_pct between 0 and 30),
  vote_hours int not null default 24 check (vote_hours between 1 and 168),
  min_yes int not null default 5 check (min_yes >= 1),
  daily_cap int not null default 300 check (daily_cap >= 0),
  vote_min_account_age_hours int not null default 0 check (vote_min_account_age_hours >= 0),
  npc_tile_budget int not null default 60 check (npc_tile_budget >= 0),
  donation_goal bigint not null default 0 check (donation_goal >= 0),
  morale int not null default 0,
  morale_until timestamptz,
  last_econ_at timestamptz,
  updated_at timestamptz not null default now()
);

-- Tahap 5: tautan Saweria disimpan di setelan negara.
alter table nz.settings add column if not exists saweria_url text;

create table if not exists nz.catalog (
  type text primary key,
  name text not null,
  kind text not null check (kind in ('pribadi', 'umum', 'negara')),
  grp text not null,
  w int not null check (w between 1 and 4),
  h int not null check (h between 1 and 4),
  cost int not null default 0,
  jobs int not null default 0,
  job_prof text,
  rev numeric not null default 0,
  res int not null default 0,
  svc text,
  req text,
  build_hours numeric not null default 2,
  trade boolean not null default false,
  farm boolean not null default false,
  proposable boolean not null default false
);

create table if not exists nz.districts (
  key text primary key,
  name text not null,
  cost int not null default 0,
  is_open boolean not null default false,
  opened_at timestamptz
);

create table if not exists nz.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text unique,
  display_name text not null,
  name_key text generated always as (lower(btrim(display_name))) stored unique,
  profession text not null,
  prev_profession text,
  color text not null default '#D9483B',
  coins bigint not null default 0 check (coins >= 0),
  energy numeric not null default 100 check (energy >= 0 and energy <= 100),
  energy_at timestamptz not null default now(),
  health int not null default 100 check (health between 0 and 100),
  xp int not null default 0 check (xp >= 0),
  jail_until timestamptz,
  home_building_id bigint,
  npc_id bigint unique,
  free_house_used boolean not null default false,
  promo_until timestamptz,
  last_chat_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists nz.buildings (
  id bigint generated always as identity primary key,
  seed_key text unique,
  type text not null references nz.catalog (type),
  label text,
  i int not null,
  j int not null,
  w int not null,
  h int not null,
  district text not null,
  owner_id uuid references nz.profiles (id) on delete cascade,
  npc_owner_id bigint,
  stage text not null check (stage in ('sketsa', 'disetujui', 'bangun', 'jadi')),
  started_at timestamptz,
  build_hours numeric not null default 2 check (build_hours > 0),
  boost numeric not null default 0 check (boost >= 0),
  wage int not null default 30 check (wage between 0 and 200),
  job_open boolean not null default true,
  npc_staff int not null default 0 check (npc_staff >= 0),
  protected boolean not null default false,
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  updated_at timestamptz not null default now()
);
create index if not exists buildings_district_idx on nz.buildings (district);
create index if not exists buildings_owner_idx on nz.buildings (owner_id);
create index if not exists buildings_stage_idx on nz.buildings (stage);

create table if not exists nz.building_tiles (
  i int not null,
  j int not null,
  building_id bigint not null references nz.buildings (id) on delete cascade,
  primary key (i, j)
);
create index if not exists building_tiles_b_idx on nz.building_tiles (building_id);

create table if not exists nz.npcs (
  id bigint generated always as identity primary key,
  name text not null,
  name_key text generated always as (lower(btrim(name))) stored unique,
  profession text not null default 'Warga',
  color text not null default '#79B94F',
  health int not null default 88 check (health between 0 and 100),
  ig_username text,
  legacy_id text,
  home_building_id bigint references nz.buildings (id) on delete set null,
  claimed_by uuid unique references nz.profiles (id) on delete set null,
  hidden boolean not null default false,
  source text,
  created_at timestamptz not null default now()
);
create index if not exists npcs_home_idx on nz.npcs (home_building_id);

-- Kunci asing melingkar ditambahkan setelah semua tabel ada.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_home_fk') then
    alter table nz.profiles add constraint profiles_home_fk
      foreign key (home_building_id) references nz.buildings (id) on delete set null;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_npc_fk') then
    alter table nz.profiles add constraint profiles_npc_fk
      foreign key (npc_id) references nz.npcs (id) on delete set null;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'buildings_npc_owner_fk') then
    alter table nz.buildings add constraint buildings_npc_owner_fk
      foreign key (npc_owner_id) references nz.npcs (id) on delete set null;
  end if;
end $$;

create table if not exists nz.jobs (
  user_id uuid primary key references nz.profiles (id) on delete cascade,
  building_id bigint not null references nz.buildings (id) on delete cascade,
  started_at timestamptz not null default now(),
  last_shift_at timestamptz,
  paid_hours int not null default 0
);
create index if not exists jobs_building_idx on nz.jobs (building_id);

create table if not exists nz.proposals (
  id bigint generated always as identity primary key,
  building_id bigint references nz.buildings (id) on delete set null,
  type text not null references nz.catalog (type),
  proposer_id uuid references nz.profiles (id) on delete set null,
  proposer_label text,
  cost int not null,
  discount numeric not null default 0 check (discount between 0 and 0.5),
  rancang_by uuid references nz.profiles (id) on delete set null,
  yes int not null default 0,
  no int not null default 0,
  status text not null default 'voting' check (status in ('voting', 'menunggu_kas', 'lolos', 'ditolak', 'veto')),
  created_at timestamptz not null default now(),
  ends_at timestamptz not null,
  resolved_at timestamptz
);
create index if not exists proposals_status_idx on nz.proposals (status, ends_at);
create index if not exists proposals_proposer_idx on nz.proposals (proposer_id) where status = 'voting';

create table if not exists nz.proposal_votes (
  proposal_id bigint not null references nz.proposals (id) on delete cascade,
  user_id uuid not null references nz.profiles (id) on delete cascade,
  vote smallint not null check (vote in (-1, 1)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (proposal_id, user_id)
);
create index if not exists proposal_votes_user_idx on nz.proposal_votes (user_id);

create table if not exists nz.district_proposals (
  id bigint generated always as identity primary key,
  district text not null references nz.districts (key),
  proposer_id uuid references nz.profiles (id) on delete set null,
  cost int not null,
  yes int not null default 0,
  no int not null default 0,
  status text not null default 'voting' check (status in ('voting', 'menunggu_kas', 'lolos', 'ditolak', 'veto')),
  created_at timestamptz not null default now(),
  ends_at timestamptz not null,
  resolved_at timestamptz
);
create unique index if not exists district_proposals_active_uq
  on nz.district_proposals (district) where status in ('voting', 'menunggu_kas');

create table if not exists nz.district_votes (
  proposal_id bigint not null references nz.district_proposals (id) on delete cascade,
  user_id uuid not null references nz.profiles (id) on delete cascade,
  vote smallint not null check (vote in (-1, 1)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (proposal_id, user_id)
);

create table if not exists nz.reports (
  id bigint generated always as identity primary key,
  reporter_id uuid not null references nz.profiles (id) on delete cascade,
  target_id uuid not null references nz.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_reason text,
  check (reporter_id <> target_id)
);
create unique index if not exists reports_open_uq on nz.reports (reporter_id, target_id) where resolved_at is null;
create index if not exists reports_target_idx on nz.reports (target_id) where resolved_at is null;

create table if not exists nz.transactions (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  from_kind text not null check (from_kind in ('user', 'negara', 'sistem', 'npc')),
  from_id text,
  to_kind text not null check (to_kind in ('user', 'negara', 'sistem', 'npc')),
  to_id text,
  amount bigint not null check (amount > 0),
  tax bigint not null default 0 check (tax >= 0),
  reason text not null,
  ref text
);
create index if not exists transactions_to_idx on nz.transactions (to_id, at desc);
create index if not exists transactions_from_idx on nz.transactions (from_id, at desc);

create table if not exists nz.cooldowns (
  user_id uuid not null references nz.profiles (id) on delete cascade,
  action text not null,
  ready_at timestamptz not null,
  primary key (user_id, action)
);

create table if not exists nz.daily_earnings (
  user_id uuid not null references nz.profiles (id) on delete cascade,
  day date not null,
  earned int not null default 0,
  primary key (user_id, day)
);

create table if not exists nz.missions (
  user_id uuid not null references nz.profiles (id) on delete cascade,
  day date not null,
  key text not null,
  done_at timestamptz not null default now(),
  primary key (user_id, day, key)
);

create table if not exists nz.announcements (
  id bigint generated always as identity primary key,
  text text not null,
  by_user uuid references nz.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists nz.news (
  id bigint generated always as identity primary key,
  text text not null,
  kind text not null default 'info',
  actor_name text,
  created_at timestamptz not null default now()
);
create index if not exists news_created_idx on nz.news (created_at desc);

create table if not exists nz.chat_messages (
  id bigint generated always as identity primary key,
  user_id uuid references nz.profiles (id) on delete cascade,
  name text not null,
  profession text,
  text text not null,
  created_at timestamptz not null default now()
);
create index if not exists chat_created_idx on nz.chat_messages (created_at desc);

-- Tahap 5: papan donatur Saweria. Dicatat manual oleh presiden, TIDAK menghasilkan koin.
create table if not exists nz.donations (
  id bigint generated always as identity primary key,
  donor_name text not null,
  amount bigint not null check (amount >= 0),
  message text,
  donated_at timestamptz not null default now(),
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists donations_at_idx on nz.donations (donated_at desc);

create table if not exists nz.optout_requests (
  id bigint generated always as identity primary key,
  npc_id bigint not null references nz.npcs (id) on delete cascade,
  user_id uuid not null,
  reason text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create unique index if not exists optout_pending_uq on nz.optout_requests (npc_id, user_id) where status = 'pending';

create table if not exists nz.city_snapshot (
  id int primary key default 1 check (id = 1),
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- RLS aktif di SEMUA tabel nz; hak tabel dicabut, hanya 3 tabel boleh dibaca
-- pemain login (untuk realtime).
do $$
declare t record;
begin
  for t in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'nz' and c.relkind = 'r'
  loop
    execute format('alter table nz.%I enable row level security', t.relname);
    execute format('revoke all on nz.%I from public, anon, authenticated', t.relname);
  end loop;
end $$;
revoke all on all sequences in schema nz from public, anon, authenticated;

grant select on nz.buildings, nz.proposals, nz.chat_messages to authenticated;
drop policy if exists "pemain login baca" on nz.buildings;
create policy "pemain login baca" on nz.buildings for select to authenticated using (true);
drop policy if exists "pemain login baca" on nz.proposals;
create policy "pemain login baca" on nz.proposals for select to authenticated using (true);
drop policy if exists "pemain login baca" on nz.chat_messages;
create policy "pemain login baca" on nz.chat_messages for select to authenticated using (true);


-- ============================================================================
-- BAGIAN 2 · DATA AWAL
-- ============================================================================

-- 2.1  Katalog bangunan. Harga, ukuran, lowongan, pendapatan sama dengan
--      prototipe. build_hours = jam nyata. Diperbarui setiap file dijalankan.
insert into nz.catalog (type, name, kind, grp, w, h, cost, jobs, job_prof, rev, res, svc, req, build_hours, trade, farm, proposable) values
  ('rumah',     'Rumah Kecil',         'pribadi', 'rumah', 1, 1,  150,  0, null,      0,  4, null,      null,        2, false, false, false),
  ('rumah2',    'Rumah Tingkat',       'pribadi', 'rumah', 1, 1,  320,  0, null,      0,  8, null,      null,        4, false, false, false),
  ('kos',       'Kos-kosan',           'pribadi', 'rumah', 2, 1,  700,  1, null,      7, 14, null,      null,        6, false, false, false),
  ('warung',    'Warung',              'pribadi', 'usaha', 1, 1,  200,  2, null,      8,  0, null,      null,        3, true,  false, false),
  ('kafe',      'Kafe Kopi',           'pribadi', 'usaha', 1, 1,  300,  3, null,     11,  0, null,      null,        4, true,  false, false),
  ('toko',      'Toko Kelontong',      'pribadi', 'usaha', 2, 1,  450,  4, null,     15,  0, null,      null,        6, true,  false, false),
  ('bengkel',   'Bengkel',             'pribadi', 'usaha', 2, 1,  500,  4, null,     16,  0, null,      null,        6, false, false, false),
  ('sawah',     'Sawah',               'pribadi', 'usaha', 2, 1,  120,  2, null,      6,  0, null,      null,        2, false, true,  false),
  ('kantor',    'Kantor',              'pribadi', 'usaha', 2, 2, 1200, 12, null,     42,  0, null,      'Pengusaha',12, false, false, false),
  ('taman',     'Taman',               'umum',    'umum',  1, 1,  300,  0, null,      0,  0, 'taman',   null,        6, false, false, true),
  ('lapangan',  'Tanah Lapang',        'umum',    'umum',  2, 2,  600,  0, null,      0,  0, 'taman',   null,        8, false, false, true),
  ('sekolah',   'Sekolah',             'umum',    'umum',  2, 2, 1500,  6, 'Guru',    0,  0, 'sekolah', null,       24, false, false, true),
  ('rs',        'Rumah Sakit',         'umum',    'umum',  2, 2, 2000,  8, 'Dokter',  0,  0, 'rs',      null,       36, false, false, true),
  ('polisi',    'Kantor Polisi',       'umum',    'umum',  2, 1, 1200,  6, 'Polisi',  0,  0, 'polisi',  null,       24, false, false, true),
  ('penjara',   'Penjara',             'umum',    'umum',  2, 1, 1000,  2, null,      0,  0, 'penjara', null,       24, false, false, true),
  ('pasar',     'Pasar Rakyat',        'umum',    'umum',  2, 2, 1000,  4, null,      0,  0, 'pasar',   null,       24, false, false, true),
  ('ibadah',    'Tempat Ibadah',       'umum',    'umum',  2, 1,  800,  0, null,      0,  0, 'ibadah',  null,       18, false, false, true),
  ('pln',       'Gardu PLN',           'umum',    'umum',  1, 1,  600,  2, null,      0,  0, 'pln',     null,       12, false, false, true),
  ('stadion',   'Stadion',             'umum',    'umum',  4, 2, 3500, 10, null,      0,  0, 'stadion', null,       48, false, false, true),
  ('istana',    'Istana Negara',       'umum',    'umum',  2, 2, 4000,  6, null,      0,  0, 'istana',  null,       72, false, false, true),
  ('tugu',      'Alun-alun Tugu Kuda', 'umum',    'umum',  2, 2,  900,  0, null,      0,  0, 'taman',   null,       12, false, false, true),
  ('mulyo',     'Rumah Pak Mulyo',     'negara',  'none',  2, 2,    0,  0, null,      0,  0, 'istana',  null,        1, false, false, false),
  ('posko',     'Posko Tukang',        'negara',  'none',  1, 1,    0,  0, null,      0,  0, null,      null,        1, false, false, false),
  ('bank',      'Bank Negara',         'negara',  'none',  2, 1,    0,  4, null,      0,  0, 'bank',    null,       24, false, false, false),
  ('barak',     'Barak TNI',           'negara',  'none',  2, 2,    0,  6, null,      0,  0, 'polisi',  null,       24, false, false, false),
  ('waduk',     'Bendungan & Sungai',  'negara',  'none',  2, 2,    0,  0, null,      0,  0, 'air',     null,       24, false, false, false),
  ('apartemen', 'Apartemen Netizenia', 'negara',  'none',  2, 2,    0,  2, null,      0, 24, null,      null,       24, false, false, false),
  ('pabrik',    'Pabrik & Bengkel',    'negara',  'none',  2, 2,    0,  8, null,      0,  0, null,      null,       24, false, false, false),
  ('pkl',       'Zona PKL',            'negara',  'none',  2, 1,    0,  0, null,      0,  0, 'pasar',   null,        6, false, false, false)
on conflict (type) do update set
  name = excluded.name, kind = excluded.kind, grp = excluded.grp, w = excluded.w, h = excluded.h,
  cost = excluded.cost, jobs = excluded.jobs, job_prof = excluded.job_prof, rev = excluded.rev,
  res = excluded.res, svc = excluded.svc, req = excluded.req, build_hours = excluded.build_hours,
  trade = excluded.trade, farm = excluded.farm, proposable = excluded.proposable;

-- 2.2  Distrik. Pusat terbuka; lainnya dibuka lewat voting.
insert into nz.districts (key, name, cost, is_open, opened_at) values
  ('pusat',   'Distrik Pusat',      0, true,  now()),
  ('utara',   'Distrik Utara',   2500, false, null),
  ('selatan', 'Distrik Selatan', 2500, false, null),
  ('barat',   'Distrik Barat',   2000, false, null),
  ('timur',   'Distrik Timur',   2000, false, null)
on conflict (key) do nothing;

-- 2.3  Setelan negara (satu baris). Batas harian 300 NC, minimal 5 setuju.
insert into nz.settings (id) values (1) on conflict (id) do nothing;
insert into nz.city_snapshot (id) values (1) on conflict (id) do nothing;


-- ============================================================================
-- BAGIAN 3 · FUNGSI INTERNAL (schema nz)
-- Tidak bisa dipanggil dari browser: schema nz tidak dibuka lewat Data API
-- dan hak EXECUTE dicabut dari public/anon/authenticated di Bagian 5.
-- ============================================================================

-- Segarkan semua fungsi nz setiap file dijalankan (aman diulang).
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'nz' and p.prokind = 'f'
  loop
    execute format('drop function if exists %s cascade', r.sig);
  end loop;
end $$;

-- ---------- utilitas ----------
create function nz.wib_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Jakarta')::date $$;

create function nz.fmt_wib(t timestamptz) returns text
language sql stable as $$ select to_char(t at time zone 'Asia/Jakarta', 'HH24:MI') || ' WIB' $$;

create function nz.fmt_left(iv interval) returns text
language sql immutable as $$
  select case when extract(epoch from iv) >= 3600
              then ceil(extract(epoch from iv) / 3600)::int || ' jam'
              else greatest(1, ceil(extract(epoch from iv) / 60))::int || ' menit' end
$$;

create function nz.is_lot(p_i int, p_j int) returns boolean
language sql immutable as $$
  select p_i > 0 and p_j > 0 and p_i < 40 and p_j < 40 and p_i % 5 <> 0 and p_j % 5 <> 0
$$;

create function nz.district_of(p_i int, p_j int) returns text
language sql immutable as $$
  select case
    when p_i / 5 between 2 and 5 and p_j / 5 between 2 and 5 then 'pusat'
    when p_j / 5 < 2 then 'utara'
    when p_j / 5 > 5 then 'selatan'
    when p_i / 5 < 2 then 'barat'
    else 'timur' end
$$;

create function nz.palette() returns text[]
language sql immutable as $$
  select array['#D9483B','#2F8F5B','#3E6FB0','#E2A21F','#7A5AA6','#C8553D','#2E7D6B','#B5473A','#1F8AA8','#D0638A']
$$;

create function nz.player_professions() returns text[]
language sql immutable as $$
  select array['Warga','Tukang','Mandor','Arsitek','Guru','Murid','Dokter','Polisi','Pedagang','Petani','Pengusaha','Penjahat']
$$;

create function nz.censor(p text) returns text
language sql immutable as $$
  select regexp_replace(p, '\m(anjing|bangsat|babi|kontol|memek|tolol|goblok|asu|jancok|kampret|brengsek|tai|bajingan)\M', '***', 'gi')
$$;

create function nz.clean_text(p text, p_max int) returns text
language sql immutable as $$
  select left(btrim(regexp_replace(coalesce(p, ''), '[[:cntrl:]]+', ' ', 'g')), p_max)
$$;

create function nz.is_admin() returns boolean
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select auth.uid() is not null and exists (select 1 from public.admins a where a.user_id = auth.uid())
$$;

create function nz.progress(b nz.buildings) returns numeric
language sql stable as $$
  select case b.stage
    when 'jadi' then 1::numeric
    when 'bangun' then least(1, greatest(0,
      extract(epoch from (now() - coalesce(b.started_at, now()))) / 3600.0 / greatest(b.build_hours, 0.01) + b.boost))
    else 0::numeric end
$$;

create function nz.has_svc(p_svc text) returns boolean
language sql stable as $$
  select exists (select 1 from nz.buildings b join nz.catalog c on c.type = b.type
                 where b.stage = 'jadi' and c.svc = p_svc)
$$;

create function nz.mission_keys(d date) returns text[]
language sql immutable as $$
  select array(select k from unnest(array['kerja','vote','aksi','bantu','bangun','lapor']) k
               order by md5(d::text || k) limit 3)
$$;

create function nz.mission_label(k text) returns text
language sql immutable as $$
  select case k
    when 'kerja'  then 'Masuk kerja atau kerja serabutan'
    when 'vote'   then 'Beri suara pada 1 usulan'
    when 'aksi'   then 'Lakukan 1 aksi profesi'
    when 'bantu'  then 'Bantu 1 pembangunan'
    when 'bangun' then 'Bangun atau usulkan 1 bangunan'
    when 'lapor'  then 'Bantu warga lain (ajar, obati, atau lapor)'
    else k end
$$;

-- ---------- identitas dan status pemain ----------
create function nz.uid() returns uuid
language plpgsql stable as $$
declare v uuid := auth.uid();
begin
  if v is null then raise exception 'Masuk dulu untuk melakukan ini.'; end if;
  return v;
end $$;

-- Mengunci baris profil sampai akhir transaksi. Semua aksi memanggil ini
-- lebih dulu, jadi dua klik bersamaan dari akun yang sama diproses berurutan.
create function nz.me(p_uid uuid) returns nz.profiles
language plpgsql as $$
declare p nz.profiles;
begin
  select * into p from nz.profiles where id = p_uid for update;
  if not found then raise exception 'Buat tokohmu dulu.'; end if;
  return p;
end $$;

create function nz.require_free(p nz.profiles) returns void
language plpgsql stable as $$
begin
  if p.jail_until is not null and p.jail_until > now() then
    raise exception 'Kamu sedang ditahan sampai %.', nz.fmt_wib(p.jail_until);
  end if;
end $$;

create function nz.require_admin() returns void
language plpgsql stable as $$
begin
  if not nz.is_admin() then raise exception 'Khusus presiden.'; end if;
end $$;

create function nz.energy_now(p nz.profiles) returns numeric
language sql stable as $$
  select least(100, p.energy + 12 * extract(epoch from (now() - p.energy_at)) / 3600.0)
$$;

create function nz.use_energy(p_uid uuid, p_n int) returns void
language plpgsql as $$
declare e numeric;
begin
  select nz.energy_now(p) into e from nz.profiles p where p.id = p_uid;
  if e < p_n then
    raise exception 'Energimu tinggal %, butuh %. Energi pulih 12 per jam.', floor(e)::int, p_n;
  end if;
  update nz.profiles set energy = e - p_n, energy_at = now() where id = p_uid;
end $$;

create function nz.cooldown(p_uid uuid, p_action text, p_minutes int, p_label text) returns void
language plpgsql as $$
declare r timestamptz;
begin
  select ready_at into r from nz.cooldowns where user_id = p_uid and action = p_action;
  if r is not null and r > now() then
    raise exception '% bisa lagi dalam %.', p_label, nz.fmt_left(r - now());
  end if;
  insert into nz.cooldowns (user_id, action, ready_at)
  values (p_uid, p_action, now() + make_interval(mins => p_minutes))
  on conflict (user_id, action) do update set ready_at = excluded.ready_at;
end $$;

create function nz.cap_left(p_uid uuid) returns int
language sql stable as $$
  select greatest(0, s.daily_cap - coalesce((select earned from nz.daily_earnings
                                             where user_id = p_uid and day = nz.wib_today()), 0))
  from nz.settings s where s.id = 1
$$;

create function nz.require_cap(p_uid uuid) returns void
language plpgsql stable as $$
begin
  if nz.cap_left(p_uid) <= 0 then
    raise exception 'Batas harian koin dari aksi (% NC) sudah tercapai. Coba lagi besok.',
      (select daily_cap from nz.settings where id = 1);
  end if;
end $$;

-- ---------- buku besar: SATU-SATUNYA jalan koin berpindah ----------
-- p_cap: 'none'   = tidak dihitung batas harian (transfer, pendapatan usaha)
--        'strict' = ditolak bila batas harian habis
--        'soft'   = dipotong sampai sisa batas (bisa 0), tanpa error
-- Mengembalikan jumlah bersih yang diterima.
create function nz.tx(p_from_kind text, p_from_id text, p_to_kind text, p_to_id text,
                      p_amount bigint, p_reason text,
                      p_taxed boolean default false, p_cap text default 'none', p_ref text default null)
returns bigint
language plpgsql as $$
declare
  v_amt bigint := p_amount; v_tax bigint := 0; v_net bigint;
  v_pct int; v_rem int;
begin
  if v_amt is null or v_amt <= 0 then return 0; end if;
  select tax_pct into v_pct from nz.settings where id = 1;
  if p_taxed and p_to_kind = 'user' then v_tax := round(v_amt * v_pct / 100.0); end if;
  v_net := v_amt - v_tax;

  if p_cap <> 'none' and p_to_kind = 'user' then
    v_rem := nz.cap_left(p_to_id::uuid);
    if v_rem <= 0 then
      if p_cap = 'strict' then perform nz.require_cap(p_to_id::uuid); end if;
      return 0;
    end if;
    if v_net > v_rem then
      v_net := v_rem;
      v_tax := case when p_taxed and v_pct < 100 then round(v_net * v_pct / (100.0 - v_pct)) else 0 end;
      v_amt := v_net + v_tax;
    end if;
  end if;

  if p_from_kind = 'user' then
    update nz.profiles set coins = coins - v_amt where id = p_from_id::uuid and coins >= v_amt;
    if not found then raise exception 'Koin tidak cukup.'; end if;
  elsif p_from_kind = 'negara' then
    update nz.settings set kas = kas - v_amt where id = 1 and kas >= v_amt;
    if not found then raise exception 'Kas negara tidak cukup.'; end if;
  end if;

  if p_to_kind = 'user' then
    update nz.profiles set coins = coins + v_net where id = p_to_id::uuid;
    if not found then raise exception 'Penerima tidak ditemukan.'; end if;
    if v_tax > 0 then update nz.settings set kas = kas + v_tax where id = 1; end if;
  elsif p_to_kind = 'negara' then
    update nz.settings set kas = kas + v_amt where id = 1;
  end if;

  if p_cap <> 'none' and p_to_kind = 'user' and v_net > 0 then
    insert into nz.daily_earnings (user_id, day, earned) values (p_to_id::uuid, nz.wib_today(), v_net)
    on conflict (user_id, day) do update set earned = nz.daily_earnings.earned + excluded.earned;
  end if;

  insert into nz.transactions (from_kind, from_id, to_kind, to_id, amount, tax, reason, ref)
  values (p_from_kind, p_from_id, p_to_kind, p_to_id, v_amt, v_tax, left(p_reason, 120), p_ref);
  return v_net;
end $$;

-- Bayar dari kas bila cukup; tidak error bila kas kurang (aksi tetap sah).
create function nz.pay_from_kas(p_uid uuid, p_amount int, p_reason text) returns bigint
language plpgsql as $$
begin
  if (select kas from nz.settings where id = 1) < p_amount then return 0; end if;
  return nz.tx('negara', null, 'user', p_uid::text, p_amount, p_reason, true, 'soft');
end $$;

create function nz.news(p_text text, p_kind text default 'info', p_actor text default null) returns void
language sql as $$
  insert into nz.news (text, kind, actor_name) values (left(p_text, 300), p_kind, p_actor)
$$;

create function nz.mission_done(p_uid uuid, p_key text) returns bigint
language plpgsql as $$
declare v_rows int; v_prof text;
begin
  if not (p_key = any (nz.mission_keys(nz.wib_today()))) then return 0; end if;
  select profession into v_prof from nz.profiles where id = p_uid;
  if v_prof = 'Presiden' then return 0; end if;
  insert into nz.missions (user_id, day, key) values (p_uid, nz.wib_today(), p_key) on conflict do nothing;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then return 0; end if;
  return nz.tx('sistem', null, 'user', p_uid::text, 40, 'misi: ' || p_key, false, 'soft');
end $$;

-- ---------- peta dan bangunan ----------
-- Menempatkan bangunan di kavling. Primary key (i, j) di building_tiles
-- menjamin dua bangunan tidak pernah menempati kavling yang sama, walau
-- dua orang menekan "Bangun" pada detik yang sama.
create function nz.place(p_bid bigint, p_i int, p_j int, p_w int, p_h int, p_check_open boolean default true)
returns void
language plpgsql as $$
declare a int; c int; d text;
begin
  if p_i is null or p_j is null then raise exception 'Pilih kavling dulu.'; end if;
  if p_i < 1 or p_j < 1 or p_i + p_w - 1 > 39 or p_j + p_h - 1 > 39 then raise exception 'Di luar peta.'; end if;
  if p_i / 5 <> (p_i + p_w - 1) / 5 or p_j / 5 <> (p_j + p_h - 1) / 5 then
    raise exception 'Harus muat dalam satu blok, tidak boleh melewati jalan.';
  end if;
  for a in 0 .. p_w - 1 loop
    for c in 0 .. p_h - 1 loop
      if not nz.is_lot(p_i + a, p_j + c) then raise exception 'Tidak bisa di atas jalan.'; end if;
    end loop;
  end loop;
  d := nz.district_of(p_i, p_j);
  if p_check_open and not exists (select 1 from nz.districts where key = d and is_open) then
    raise exception '% belum dibuka.', (select name from nz.districts where key = d);
  end if;
  begin
    insert into nz.building_tiles (i, j, building_id)
    select p_i + ga, p_j + gc, p_bid from generate_series(0, p_w - 1) ga, generate_series(0, p_h - 1) gc;
  exception when unique_violation then
    raise exception 'Kavling sudah terisi.';
  end;
end $$;

create function nz.building_name(p_bid bigint) returns text
language sql stable as $$
  select coalesce(b.label, c.name) from nz.buildings b join nz.catalog c on c.type = b.type where b.id = p_bid
$$;

create function nz.finish_building(p_bid bigint) returns void
language plpgsql as $$
declare v_owner text;
begin
  update nz.buildings set stage = 'jadi', finished_at = now(), updated_at = now()
  where id = p_bid and stage = 'bangun';
  if found then
    select coalesce(p.display_name, 'negara') into v_owner
    from nz.buildings b left join nz.profiles p on p.id = b.owner_id where b.id = p_bid;
    perform nz.news(nz.building_name(p_bid) || ' selesai dibangun! Milik ' || v_owner || '.', 'bangun');
  end if;
end $$;

-- Selesaikan bangunan yang progresnya sudah 100% (dipanggil RPC dan cron).
create function nz.settle_building(p_bid bigint) returns void
language plpgsql as $$
declare b nz.buildings;
begin
  select * into b from nz.buildings where id = p_bid;
  if found and b.stage = 'bangun' and nz.progress(b) >= 1 then perform nz.finish_building(p_bid); end if;
end $$;

-- Menyetujui usulan bangunan: bayar dari kas lalu mulai bangun,
-- atau tandai menunggu kas. p_quiet = jangan tulis berita bila tetap menunggu.
create function nz.approve_proposal(p_pid bigint, p_by_pres boolean, p_quiet boolean default false) returns text
language plpgsql as $$
declare pr nz.proposals; v_cost int; v_name text;
begin
  select * into pr from nz.proposals where id = p_pid for update;
  if not found or pr.status not in ('voting', 'menunggu_kas') or pr.building_id is null then return 'skip'; end if;
  v_cost := pr.cost - round(pr.cost * pr.discount);
  v_name := nz.building_name(pr.building_id);
  if (select kas from nz.settings where id = 1) >= v_cost then
    perform nz.tx('negara', null, 'sistem', null, v_cost, 'bangun umum: ' || v_name, false, 'none', 'proposal:' || pr.id);
    update nz.buildings set stage = 'bangun', started_at = now(), updated_at = now() where id = pr.building_id;
    update nz.proposals set status = 'lolos', resolved_at = now() where id = pr.id;
    perform nz.news(v_name || ' disetujui ' || case when p_by_pres then 'presiden' else 'warga' end
                    || ' dan mulai dibangun.', 'voting');
    return 'bangun';
  end if;
  update nz.buildings set stage = 'disetujui', updated_at = now() where id = pr.building_id;
  if pr.status = 'voting' then
    update nz.proposals set status = 'menunggu_kas' where id = pr.id;
    if not p_quiet then perform nz.news(v_name || ' disetujui, menunggu kas negara cukup.', 'voting'); end if;
  end if;
  return 'menunggu_kas';
end $$;

create function nz.reject_proposal(p_pid bigint, p_status text, p_text text) returns void
language plpgsql as $$
declare v_bid bigint;
begin
  select building_id into v_bid from nz.proposals where id = p_pid for update;
  update nz.proposals set status = p_status, resolved_at = now(), building_id = null where id = p_pid;
  if v_bid is not null then delete from nz.buildings where id = v_bid; end if;
  perform nz.news(p_text, 'voting');
end $$;

create function nz.open_district(p_key text, p_by_pres boolean) returns text
language plpgsql as $$
declare d nz.districts;
begin
  select * into d from nz.districts where key = p_key for update;
  if not found then raise exception 'Distrik tidak dikenal.'; end if;
  if d.is_open then return 'sudah'; end if;
  if (select kas from nz.settings where id = 1) < d.cost then return 'menunggu_kas'; end if;
  perform nz.tx('negara', null, 'sistem', null, d.cost, 'buka ' || d.name);
  update nz.districts set is_open = true, opened_at = now() where key = p_key;
  update nz.district_proposals set status = 'lolos', resolved_at = now()
  where district = p_key and status in ('voting', 'menunggu_kas');
  perform nz.news(d.name || ' resmi dibuka' || case when p_by_pres then ' oleh presiden' else '' end
                  || '! Kavling baru tersedia.', 'distrik');
  return 'dibuka';
end $$;

-- ---------- statistik kota (port dari stats() prototipe) ----------
create function nz.compute_stats() returns jsonb
language plpgsql stable as $$
declare
  v_houses int; v_pop int; c_sek numeric; c_rs numeric; c_pol numeric; c_tam numeric;
  v_players int; v_npcs int; v_jobs int; v_npc_staff int; v_emp numeric; v_happy int;
  v_tax int; v_morale int; s nz.settings;
begin
  select * into s from nz.settings where id = 1;
  with h as (
    select b.i, b.j, c.res from nz.buildings b join nz.catalog c on c.type = b.type
    where b.stage = 'jadi' and c.res > 0
  ), sv as (
    select b.i, b.j, c.svc from nz.buildings b join nz.catalog c on c.type = b.type
    where b.stage = 'jadi' and c.svc in ('sekolah', 'rs', 'polisi', 'taman')
  )
  select count(*), coalesce(sum(h.res), 0),
    coalesce(avg((exists (select 1 from sv where sv.svc = 'sekolah' and abs(sv.i - h.i) + abs(sv.j - h.j) <= 9))::int), 0),
    coalesce(avg((exists (select 1 from sv where sv.svc = 'rs'      and abs(sv.i - h.i) + abs(sv.j - h.j) <= 9))::int), 0),
    coalesce(avg((exists (select 1 from sv where sv.svc = 'polisi'  and abs(sv.i - h.i) + abs(sv.j - h.j) <= 9))::int), 0),
    coalesce(avg((exists (select 1 from sv where sv.svc = 'taman'   and abs(sv.i - h.i) + abs(sv.j - h.j) <= 9))::int), 0)
  into v_houses, v_pop, c_sek, c_rs, c_pol, c_tam
  from h;

  select count(*) into v_players from nz.profiles where profession <> 'Presiden';
  select count(*) into v_npcs from nz.npcs where not hidden and claimed_by is null;
  select count(*) into v_jobs from nz.jobs;
  select coalesce(sum(least(b.npc_staff, greatest(0, c.jobs - (select count(*) from nz.jobs j where j.building_id = b.id)))), 0)
    into v_npc_staff
  from nz.buildings b join nz.catalog c on c.type = b.type where b.stage = 'jadi';
  v_emp := least(1, (v_jobs + v_npc_staff)::numeric / greatest(1, v_players + v_npcs));
  v_tax := s.tax_pct;
  v_morale := case when s.morale_until > now() then s.morale else 0 end;
  v_happy := greatest(0, least(100, round(30 + 13 * c_sek + 15 * c_rs + 11 * c_pol + 9 * c_tam + 16 * v_emp
              - greatest(0, v_tax - 10) * 1.3 + v_morale
              + case when nz.has_svc('istana') then 4 else 0 end
              + case when nz.has_svc('stadion') then 3 else 0 end)));
  return jsonb_build_object(
    'pop', v_pop, 'houses', v_houses, 'happy', v_happy,
    'cov', jsonb_build_object('sekolah', round(c_sek, 3), 'rs', round(c_rs, 3), 'polisi', round(c_pol, 3),
                              'taman', round(c_tam, 3), 'kerja', round(v_emp, 3)),
    'players', v_players, 'npcs', v_npcs,
    'buildings', (select count(*) from nz.buildings where stage = 'jadi'),
    'building_now', (select count(*) from nz.buildings where stage = 'bangun'),
    'at', now());
end $$;

create function nz.refresh_snapshot() returns jsonb
language plpgsql as $$
declare v jsonb := nz.compute_stats();
begin
  update nz.city_snapshot set data = v, updated_at = now() where id = 1;
  return v;
end $$;

-- ---------- tick: penyelesaian voting, gaji, pendapatan (pg_cron tiap jam) ----------
create function nz.tick_hourly() returns jsonb
language plpgsql as $$
declare
  s nz.settings; r record; v_y int; v_n int; v_hour timestamptz := date_trunc('hour', now());
  st jsonb; v_happyf numeric; v_popf numeric; v_pasar numeric; v_rev numeric; v_staff int;
  v_done int := 0; v_props int := 0; v_paid int := 0; v_econ boolean := false; v_amt int;
  v_quotes text[]; v_npc record;
begin
  select * into s from nz.settings where id = 1 for update;

  -- 1. Bangunan yang progresnya sudah 100%.
  for r in select b.id from nz.buildings b where b.stage = 'bangun' and nz.progress(b) >= 1 loop
    perform nz.finish_building(r.id); v_done := v_done + 1;
  end loop;

  -- 2. Voting bangunan yang lewat batas waktu.
  for r in select * from nz.proposals where status = 'voting' and ends_at <= now() order by ends_at loop
    select count(*) filter (where vote = 1), count(*) filter (where vote = -1) into v_y, v_n
    from nz.proposal_votes where proposal_id = r.id;
    update nz.proposals set yes = v_y, no = v_n where id = r.id;
    if v_y > v_n and v_y >= s.min_yes then
      perform nz.approve_proposal(r.id, false);
    else
      perform nz.reject_proposal(r.id, 'ditolak', 'Usulan ' || coalesce(nz.building_name(r.building_id), r.type)
        || ' ditolak warga (' || v_y || ' setuju, ' || v_n || ' tolak; butuh setuju lebih banyak dan minimal '
        || s.min_yes || ' setuju).');
    end if;
    v_props := v_props + 1;
  end loop;

  -- 3. Usulan yang menunggu kas, urut dari yang paling lama.
  for r in select id from nz.proposals where status = 'menunggu_kas' order by created_at loop
    perform nz.approve_proposal(r.id, false, true);
  end loop;

  -- 4. Voting distrik.
  for r in select * from nz.district_proposals where status = 'voting' and ends_at <= now() order by ends_at loop
    select count(*) filter (where vote = 1), count(*) filter (where vote = -1) into v_y, v_n
    from nz.district_votes where proposal_id = r.id;
    update nz.district_proposals set yes = v_y, no = v_n where id = r.id;
    if v_y > v_n and v_y >= s.min_yes then
      if nz.open_district(r.district, false) = 'menunggu_kas' then
        update nz.district_proposals set status = 'menunggu_kas' where id = r.id;
        perform nz.news('Pembukaan ' || (select name from nz.districts where key = r.district)
                        || ' disetujui, menunggu kas negara cukup.', 'distrik');
      end if;
    else
      update nz.district_proposals set status = 'ditolak', resolved_at = now() where id = r.id;
      perform nz.news('Usulan pembukaan ' || (select name from nz.districts where key = r.district)
                      || ' ditolak warga (' || v_y || ' setuju, ' || v_n || ' tolak).', 'distrik');
    end if;
  end loop;
  for r in select * from nz.district_proposals where status = 'menunggu_kas' order by created_at loop
    perform nz.open_district(r.district, false);
  end loop;

  -- 5. Ekonomi: hanya sekali per jam walau fungsi ini dipanggil berkali-kali.
  if s.last_econ_at is null or s.last_econ_at < v_hour then
    v_econ := true;
    update nz.settings set last_econ_at = v_hour where id = 1;
    st := nz.compute_stats();
    v_happyf := 0.55 + (st->>'happy')::numeric / 100 * 0.75;
    v_popf := least(1.3, greatest(0.4, (st->>'pop')::numeric / 600));
    v_pasar := case when nz.has_svc('pasar') then 1.15 else 1 end;

    -- 5a. Pendapatan usaha pemain (dipotong pajak ke kas).
    for r in
      select b.id, b.owner_id, b.type, c.rev, c.jobs, c.trade, c.farm, p.profession, p.promo_until
      from nz.buildings b join nz.catalog c on c.type = b.type join nz.profiles p on p.id = b.owner_id
      where b.stage = 'jadi' and c.rev > 0
    loop
      select count(*) into v_staff from nz.jobs where building_id = r.id;
      v_rev := r.rev * (0.45 + 0.55 * case when r.jobs > 0 then least(1, v_staff::numeric / r.jobs) else 1 end)
               * v_happyf * case when r.trade then v_popf * v_pasar else 1 end;
      if r.trade and r.profession = 'Pedagang' then v_rev := v_rev * 1.3; end if;
      if r.farm and r.profession = 'Petani' then v_rev := v_rev * 1.6; end if;
      if r.type in ('kantor', 'bengkel') and r.profession = 'Pengusaha' then v_rev := v_rev * 1.3; end if;
      if r.promo_until > now() then v_rev := v_rev * 1.5; end if;
      if round(v_rev) >= 1 then
        perform nz.tx('sistem', null, 'user', r.owner_id::text, round(v_rev)::bigint,
                      'pendapatan ' || coalesce(nz.building_name(r.id), r.type), true, 'none', 'building:' || r.id);
      end if;
    end loop;

    -- 5b. PBB rumah masuk kas.
    select round(coalesce(sum(c.res * 0.25 * s.tax_pct / 10.0), 0)) into v_amt
    from nz.buildings b join nz.catalog c on c.type = b.type where b.stage = 'jadi' and c.res > 0;
    if v_amt > 0 then perform nz.tx('sistem', null, 'negara', null, v_amt, 'PBB rumah'); end if;

    -- 5c. Gaji pegawai negara: 1/4 gaji per jam selama 4 jam setelah shift.
    for r in
      select j.user_id, j.building_id, b.wage, p.jail_until
      from nz.jobs j join nz.buildings b on b.id = j.building_id join nz.profiles p on p.id = j.user_id
      where b.owner_id is null and j.last_shift_at > now() - interval '4 hours' and j.paid_hours < 4
      for update of j
    loop
      update nz.jobs set paid_hours = paid_hours + 1 where user_id = r.user_id;
      if r.jail_until is not null and r.jail_until > now() then continue; end if;
      v_amt := round(r.wage / 4.0);
      if v_amt > 0 and (select kas from nz.settings where id = 1) >= v_amt then
        perform nz.tx('negara', null, 'user', r.user_id::text, v_amt,
                      'gaji negara: ' || coalesce(nz.building_name(r.building_id), ''), true, 'soft');
        v_paid := v_paid + 1;
      end if;
    end loop;

    -- 5d. Kehidupan NPC: sebagian kecil jatuh sakit, yang sakit pelan-pelan pulih.
    update nz.npcs set health = least(100, health + 2) where health < 100 and not hidden;
    update nz.npcs set health = 30 + floor(random() * 15)::int
    where not hidden and claimed_by is null and health > 50 and random() < 0.01;

    -- 5e. Celoteh NPC untuk ticker.
    if random() < 0.45 then
      select id, name, profession into v_npc from nz.npcs
      where not hidden and claimed_by is null order by random() limit 1;
      if found then
        v_quotes := (case v_npc.profession
          when 'Tukang'   then array['Satu bata lagi, satu usulan netizen jadi.', 'Proyek hari ini lancar, semen cukup.']
          when 'Guru'     then array['Murid makin banyak, kelas butuh tambahan.', 'Pelajaran hari ini: antre yang rapi.']
          when 'Dokter'   then array['RS buka 24 jam, pasien dilayani gratis.', 'Jangan lupa minum air putih, warga!']
          when 'Polisi'   then array['Patroli aman terkendali.', 'Lapor kalau ada yang mencurigakan.']
          when 'Pedagang' then array['Kopi dingin siap, mampir dulu!', 'Dagangan laris, kota makin ramai.']
          when 'Penjahat' then array['Sst, jangan bilang polisi.']
          when 'Petani'   then array['Panen padi tahun ini bagus.']
          when 'Menteri'  then array['Anggaran negara harus hemat.']
          else array['Enak tinggal di negara yang dibangun dari komen.', 'Semoga usulan istana lolos voting.', 'Kapan distrik baru dibuka?']
        end);
        perform nz.news(v_quotes[1 + floor(random() * array_length(v_quotes, 1))::int], 'kutipan', v_npc.name);
      end if;
    end if;
  end if;

  perform nz.refresh_snapshot();
  return jsonb_build_object('selesai_dibangun', v_done, 'usulan_ditutup', v_props,
                            'ekonomi_jalan', v_econ, 'gaji_negara_dibayar', v_paid);
end $$;

create function nz.cleanup_daily() returns jsonb
language plpgsql as $$
declare v_chat int; v_news int;
begin
  delete from nz.chat_messages where created_at < now() - interval '7 days';
  get diagnostics v_chat = row_count;
  delete from nz.news where created_at < now() - interval '14 days';
  get diagnostics v_news = row_count;
  delete from nz.cooldowns where ready_at < now() - interval '1 day';
  delete from nz.daily_earnings where day < nz.wib_today() - 7;
  delete from nz.missions where day < nz.wib_today() - 7;
  return jsonb_build_object('chat_dihapus', v_chat, 'berita_dihapus', v_news);
end $$;

-- ---------- warga NPC dari komen IG ----------
-- Menyalin warga dari public.residents (tabel lama) ke nz.npcs.
-- Nama yang opt_out di tabel lama ikut disembunyikan. Aman diulang.
create function nz.sync_npcs() returns int
language plpgsql as $$
declare v_before int; v_after int;
begin
  select count(*) into v_before from nz.npcs;
  if to_regclass('public.residents') is not null then
    execute $q$
      insert into nz.npcs (name, profession, color, health, ig_username, legacy_id, hidden, source)
      select btrim(r.display_name),
             case when r.role = 'Pasien' then 'Warga'
                  when r.role = any (nz.player_professions() || array['Menteri']) then r.role
                  else 'Warga' end,
             (nz.palette())[1 + abs(hashtext(btrim(r.display_name))) % 10],
             case when r.role = 'Pasien' then 35 else 88 end,
             case when r.claimed then r.ig_username end,
             r.id::text,
             coalesce(r.opt_out, false),
             'residents'
      from (
        -- Nama ganda di tabel lama (beda huruf besar/spasi) diambil satu saja.
        select distinct on (lower(btrim(x.display_name))) x.*
        from public.residents x
        where x.display_name is not null and btrim(x.display_name) <> '' and coalesce(x.role, '') <> 'Presiden'
        order by lower(btrim(x.display_name)), x.claimed desc nulls last, x.id
      ) r
      on conflict (name_key) do update set
        hidden = nz.npcs.hidden or excluded.hidden,
        ig_username = coalesce(nz.npcs.ig_username, excluded.ig_username),
        legacy_id = coalesce(nz.npcs.legacy_id, excluded.legacy_id)
    $q$;
  end if;
  select count(*) into v_after from nz.npcs;
  return v_after - v_before;
end $$;

-- Membangun rumah NPC di Distrik Pusat dengan anggaran kavling terbatas
-- (settings.npc_tile_budget, bawaan 60) supaya kavling pemain tetap banyak.
-- Kos (2x1) menampung 14 warga, Rumah Tingkat 8. Sisanya tinggal di Apartemen.
create function nz.seed_npc_homes() returns int
language plpgsql as $$
declare
  v_budget int; v_used int; v_ids bigint[]; v_k int := 1; v_total int; v_cap int; v_bid bigint;
  v_type text; v_w int; v_houses int := 0; v_apt bigint; lot record; v_alt boolean := true;
begin
  select npc_tile_budget into v_budget from nz.settings where id = 1;
  select coalesce(sum(b.w * b.h), 0) into v_used from nz.buildings b where b.npc_owner_id is not null;
  v_budget := v_budget - v_used;
  select array_agg(id order by id) into v_ids from nz.npcs
  where home_building_id is null and not hidden and claimed_by is null;
  v_total := coalesce(array_length(v_ids, 1), 0);
  if v_total = 0 then return 0; end if;

  for lot in
    select gi as i, gj as j from generate_series(11, 29) gi, generate_series(11, 29) gj
    where nz.is_lot(gi, gj) and nz.district_of(gi, gj) = 'pusat'
    order by md5(gi || '-' || gj)
  loop
    exit when v_k > v_total or v_budget <= 0;
    continue when exists (select 1 from nz.building_tiles t where t.i = lot.i and t.j = lot.j);
    if v_alt and v_budget >= 2 and nz.is_lot(lot.i + 1, lot.j) and (lot.i + 1) / 5 = lot.i / 5
       and not exists (select 1 from nz.building_tiles t where t.i = lot.i + 1 and t.j = lot.j) then
      v_type := 'kos'; v_w := 2; v_cap := 14;
    else
      v_type := 'rumah2'; v_w := 1; v_cap := 8;
    end if;
    v_alt := not v_alt;
    insert into nz.buildings (type, i, j, w, h, district, npc_owner_id, stage, started_at, build_hours, finished_at)
    values (v_type, lot.i, lot.j, v_w, 1, 'pusat', v_ids[v_k], 'jadi', now(), 1, now())
    returning id into v_bid;
    perform nz.place(v_bid, lot.i, lot.j, v_w, 1, false);
    update nz.npcs set home_building_id = v_bid where id = any (v_ids[v_k : least(v_total, v_k + v_cap - 1)]);
    v_k := v_k + v_cap; v_budget := v_budget - v_w; v_houses := v_houses + 1;
  end loop;

  if v_k <= v_total then
    select id into v_apt from nz.buildings where type = 'apartemen' order by id limit 1;
    if v_apt is not null then
      update nz.npcs set home_building_id = v_apt where id = any (v_ids[v_k : v_total]);
    end if;
  end if;
  return v_houses;
end $$;

-- Fasilitas lama dari index.html lama, ditempatkan di grid baru sebagai
-- bangunan negara yang dilindungi (tidak bisa dibongkar). Status lama:
-- jadi -> berdiri; sebagian -> sedang dibangun dengan progres yang sama;
-- usulan -> usulan baru yang divoting 24 jam (suara per perangkat lama tidak
-- bisa dipindahkan karena tidak terikat akun).
create function nz.seed_world(p_seed jsonb) returns jsonb
language plpgsql as $$
declare r record; v_bid bigint; v_npcs int; v_houses int; v_hours numeric;
begin
  for r in
    select * from (values
      ('kantor',    'mulyo',     'Rumah Pak Mulyo',               18, 18, 2, 2, 'jadi',     1.00, 0),
      ('tugu',      'tugu',      'Alun-Alun & Tugu Kuda',         21, 21, 2, 2, 'jadi',     1.00, 0),
      ('rs',        'rs',        'Rumah Sakit Gratis',            26, 16, 2, 2, 'jadi',     1.00, 4),
      ('polisi',    'polisi',    'Kantor Polisi & Damkar',        26, 21, 2, 1, 'sebagian', 0.60, 3),
      ('bank',      'bank',      'Bank Negara & Kas',             28, 21, 2, 1, 'sebagian', 0.40, 2),
      ('penjara',   'penjara',   'Penjara Netizenia',             26, 23, 2, 1, 'sebagian', 0.50, 1),
      ('pasar',     'pasar',     'Ruko UMKM & Kopi',              23, 21, 2, 2, 'jadi',     1.00, 3),
      ('posko',     'posko',     'Posko Tukang',                  23, 24, 1, 1, 'jadi',     1.00, 0),
      ('pln',       'pln',       'Gardu Induk PLN & WiFi',        29, 14, 1, 1, 'jadi',     1.00, 1),
      ('barak',     'barak',     'Barak TNI Kaki Gunung',         28, 11, 2, 2, 'sebagian', 0.50, 3),
      ('tamanlove', 'taman',     'Taman Love Pencari Jodoh',      14, 21, 1, 1, 'jadi',     1.00, 0),
      ('tamankota', 'taman',     'Taman Kota',                    19, 24, 1, 1, 'jadi',     1.00, 0),
      ('lapangan',  'lapangan',  'Tanah Lapang',                  11, 21, 2, 2, 'jadi',     1.00, 0),
      ('sekolah',   'sekolah',   'Sekolah',                       13, 16, 2, 2, 'sebagian', 0.55, 3),
      ('kosan',     'kos',       'Kosan & Daycare Sekolah',       16, 16, 2, 1, 'jadi',     1.00, 1),
      ('ibadah',    'ibadah',    'Tempat Ibadah 6 Agama',         16, 21, 2, 1, 'sebagian', 0.45, 0),
      ('istana',    'istana',    'Istana Negara',                 21, 16, 2, 2, 'usulan',   0.00, 0),
      ('stadion',   'stadion',   'Stadion Netizenia FC',          11, 26, 4, 2, 'usulan',   0.00, 0),
      ('waduk',     'waduk',     'Bendungan & Sungai',            11, 11, 2, 2, 'jadi',     1.00, 0),
      ('tani',      'sawah',     'Zona Pangan & Ternak',          13, 11, 2, 2, 'jadi',     1.00, 2),
      ('pkl',       'pkl',       'Zona PKL Pinggir Jalan',        21, 26, 2, 1, 'jadi',     1.00, 0),
      ('apartemen', 'apartemen', 'Apartemen Netizenia',           16, 26, 2, 2, 'jadi',     1.00, 1),
      ('pabrik',    'pabrik',    'Pabrik & Bengkel Otomotif',     28, 26, 2, 2, 'sebagian', 0.50, 4)
    ) as t(seed_key, type, label, i, j, w, h, st, pr, staff)
  loop
    continue when exists (select 1 from nz.buildings where seed_key = r.seed_key);
    select build_hours into v_hours from nz.catalog where type = r.type;
    insert into nz.buildings (seed_key, type, label, i, j, w, h, district, stage, started_at, build_hours,
                              protected, npc_staff, finished_at)
    values (r.seed_key, r.type, r.label, r.i, r.j, r.w, r.h, nz.district_of(r.i, r.j),
            case r.st when 'jadi' then 'jadi' when 'sebagian' then 'bangun' else 'sketsa' end,
            case r.st when 'usulan' then null else now() - make_interval(secs => r.pr * v_hours * 3600) end,
            v_hours, true, r.staff,
            case when r.st = 'jadi' then now() end)
    returning id into v_bid;
    perform nz.place(v_bid, r.i, r.j, r.w, r.h, false);
    if r.st = 'usulan' then
      insert into nz.proposals (building_id, type, proposer_label, cost, ends_at)
      values (v_bid, r.type,
              case r.seed_key when 'istana' then 'V, Sukma Syari, PAPITO CUAN' else 'Abu Kurir Gowa, 44yyiii' end,
              (select cost from nz.catalog where type = r.type), now() + interval '24 hours');
    end if;
  end loop;

  -- Warga benih dari rekap komentar (index.html lama), lalu dari public.residents.
  insert into nz.npcs (name, profession, color, health, source)
  select btrim(x ->> 0), x ->> 1, (nz.palette())[1 + abs(hashtext(btrim(x ->> 0))) % 10], (x ->> 2)::int, 'seed'
  from jsonb_array_elements(p_seed) x
  on conflict (name_key) do nothing;
  v_npcs := nz.sync_npcs();
  v_houses := nz.seed_npc_homes();

  if not exists (select 1 from nz.news) then
    perform nz.news('Selamat datang di Republik Netizenia v2! Satu negara, dibangun bersama dari komen.', 'info');
  end if;
  perform nz.refresh_snapshot();
  return jsonb_build_object('npc_baru_dari_residents', v_npcs, 'rumah_npc_baru', v_houses,
                            'total_npc', (select count(*) from nz.npcs),
                            'total_bangunan', (select count(*) from nz.buildings));
end $$;

-- Data publik ringkas satu bangunan (dipakai get_buildings dan get_building).
create function nz.building_json(b nz.buildings, p_uid uuid) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'id', b.id, 'type', b.type, 'label', b.label, 'i', b.i, 'j', b.j, 'w', b.w, 'h', b.h, 'd', b.district,
    'owner_id', b.owner_id,
    'owner', coalesce(p.display_name, n.name),
    'owner_color', p.color,
    'owner_kind', case when b.owner_id is not null then 'warga' when b.npc_owner_id is not null then 'npc' else 'negara' end,
    'stage', b.stage, 'started_at', b.started_at, 'build_hours', b.build_hours, 'boost', round(b.boost, 4),
    'progress', round(nz.progress(b), 4), 'wage', b.wage, 'job_open', b.job_open,
    'workers', (select count(*) from nz.jobs j where j.building_id = b.id),
    'npc_staff', least(b.npc_staff, greatest(0, c.jobs - (select count(*) from nz.jobs j where j.building_id = b.id))),
    'protected', b.protected,
    'proposal', (select jsonb_build_object('id', pr.id, 'yes', pr.yes, 'no', pr.no, 'ends_at', pr.ends_at,
                   'status', pr.status, 'cost', pr.cost, 'discount', pr.discount,
                   'proposer', coalesce(pp.display_name, pr.proposer_label),
                   'my_vote', (select v.vote from nz.proposal_votes v where v.proposal_id = pr.id and v.user_id = p_uid))
                 from nz.proposals pr left join nz.profiles pp on pp.id = pr.proposer_id
                 where pr.building_id = b.id and pr.status in ('voting', 'menunggu_kas')
                 order by pr.id desc limit 1))
  from nz.catalog c
  left join nz.profiles p on p.id = b.owner_id
  left join nz.npcs n on n.id = b.npc_owner_id
  where c.type = b.type
$$;


-- ============================================================================
-- BAGIAN 4 · RPC PUBLIK (schema public)
-- Satu-satunya pintu dari browser. Semua SECURITY DEFINER dengan
-- search_path terkunci. Pesan error berbahasa Indonesia dan aman ditampilkan.
-- ============================================================================

-- Hapus versi lama RPC v2 supaya perubahan tanda tangan tidak menumpuk overload.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'get_city_snapshot','get_buildings','get_building','get_npcs','username_available','get_my_state',
      'register_profile','change_profession','set_color','get_citizens',
      'build_private','propose_public','vote_proposal','propose_district','vote_district',
      'help_build','demolish_building','set_wage','set_job_open',
      'apply_job','quit_job','do_shift','odd_job','prof_action','report_citizen','seek_treatment',
      'send_chat_message','get_chat','request_claim_v2','request_opt_out',
      'pres_approve','pres_veto','pres_open_district','pres_set_tax','pres_announce',
      'pres_set_minister','pres_release',
      'admin_list_queue','admin_review_claim','admin_review_optout','admin_delete_donation',
      'admin_set_donation_goal','admin_delete_chat','admin_sync_npcs','admin_run_tick',
      'pres_add_donation','pres_set_saweria')
  loop
    execute format('drop function if exists %s', r.sig);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4.1  BACA (tamu dan pemain). Tamu tidak memakai realtime; cukup ini.
-- ---------------------------------------------------------------------------

create function public.get_city_snapshot() returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, nz, pg_temp as $$
declare s nz.settings; v_don jsonb := '[]'; v_total bigint := 0; v_saweria text; v_legacy jsonb := '{}';
begin
  select * into s from nz.settings where id = 1;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.donor_name, 'amount', x.amount,
                                               'message', x.message, 'at', x.donated_at) order by x.donated_at desc), '[]'::jsonb)
    into v_don from (select * from nz.donations order by donated_at desc limit 30) x;
  select coalesce(sum(amount), 0)::bigint into v_total from nz.donations;
  if to_regclass('public.settings') is not null then
    execute $q$ select (select value #>> '{}' from public.settings where key = 'saweria_url'),
                       coalesce((select jsonb_object_agg(key, value) from public.settings
                                 where key in ('hari', 'stats_rakyat', 'followers')), '{}'::jsonb) $q$
      into v_saweria, v_legacy;
  end if;
  return jsonb_build_object(
    'now', now(),
    'kas', s.kas, 'tax', s.tax_pct, 'daily_cap', s.daily_cap, 'vote_hours', s.vote_hours, 'min_yes', s.min_yes,
    'morale', case when s.morale_until > now() then s.morale else 0 end,
    'stats', (select data from nz.city_snapshot where id = 1),
    'districts', (select jsonb_agg(jsonb_build_object('key', key, 'name', name, 'cost', cost, 'open', is_open) order by key)
                  from nz.districts),
    'news', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'text', text, 'kind', kind, 'actor', actor_name, 'at', created_at)
                     order by id desc), '[]') from (select * from nz.news order by id desc limit 15) x),
    'announcements', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'text', text, 'at', created_at) order by id desc), '[]')
                      from (select * from nz.announcements order by id desc limit 3) x),
    'proposals', (select coalesce(jsonb_agg(jsonb_build_object(
                     'id', pr.id, 'building_id', pr.building_id, 'type', pr.type,
                     'name', coalesce(nz.building_name(pr.building_id), c.name),
                     'yes', pr.yes, 'no', pr.no, 'ends_at', pr.ends_at, 'status', pr.status,
                     'cost', pr.cost, 'discount', pr.discount,
                     'proposer', coalesce(p.display_name, pr.proposer_label, 'warga'),
                     'i', b.i, 'j', b.j, 'w', b.w, 'h', b.h, 'd', b.district) order by pr.created_at), '[]')
                  from nz.proposals pr join nz.catalog c on c.type = pr.type
                  left join nz.buildings b on b.id = pr.building_id
                  left join nz.profiles p on p.id = pr.proposer_id
                  where pr.status in ('voting', 'menunggu_kas')),
    'district_proposals', (select coalesce(jsonb_agg(jsonb_build_object(
                     'id', dp.id, 'district', dp.district, 'name', d.name, 'yes', dp.yes, 'no', dp.no,
                     'ends_at', dp.ends_at, 'status', dp.status, 'cost', dp.cost,
                     'proposer', coalesce(p.display_name, 'warga')) order by dp.created_at), '[]')
                  from nz.district_proposals dp join nz.districts d on d.key = dp.district
                  left join nz.profiles p on p.id = dp.proposer_id
                  where dp.status in ('voting', 'menunggu_kas')),
    'donations', v_don, 'donation_total', v_total, 'donation_goal', s.donation_goal, 'saweria_url', coalesce(s.saweria_url, v_saweria),
    'legacy', v_legacy,
    'chat', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'prof', profession, 'text', text, 'at', created_at)
                    order by id), '[]') from (select * from nz.chat_messages order by id desc limit 30) x)
  );
end $$;

-- Bangunan per distrik yang terlihat (maks 5 distrik per panggilan).
create function public.get_buildings(p_districts text[] default array['pusat']) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := auth.uid();
begin
  if p_districts is null or cardinality(p_districts) = 0 or cardinality(p_districts) > 5 then
    raise exception 'Pilih 1 sampai 5 distrik.';
  end if;
  return (select coalesce(jsonb_agg(nz.building_json(b, v_uid) order by b.id), '[]')
          from nz.buildings b where b.district = any (p_districts));
end $$;

create function public.get_building(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, nz, pg_temp as $$
declare b nz.buildings; v jsonb;
begin
  select * into b from nz.buildings where id = p_id;
  if not found then return null; end if;
  v := nz.building_json(b, auth.uid());
  if auth.uid() is not null then
    v := v || jsonb_build_object(
      'staff', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.display_name, 'prof', p.profession)), '[]')
                from nz.jobs j join nz.profiles p on p.id = j.user_id where j.building_id = b.id),
      'residents', (select coalesce(jsonb_agg(n.name order by n.id), '[]')
                    from (select name, id from nz.npcs where home_building_id = b.id and not hidden order by id limit 30) n));
  end if;
  return v;
end $$;

-- Warga NPC (nama dari komen IG) untuk pejalan kaki dan penghuni rumah.
create function public.get_npcs() returns jsonb
language sql stable security definer set search_path = pg_catalog, nz, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_array(n.id, n.name, n.profession, n.color, n.home_building_id,
                                              n.health < 60, n.ig_username) order by n.id), '[]')
  from nz.npcs n where not n.hidden and n.claimed_by is null
$$;

create function public.username_available(p_username text) returns boolean
language plpgsql stable security definer set search_path = pg_catalog, nz, pg_temp as $$
declare u text := lower(btrim(coalesce(p_username, '')));
begin
  if u !~ '^[a-z0-9_.]{3,20}$' then return false; end if;
  return not exists (select 1 from auth.users where lower(email) = u || '@warga.netizenia.local')
     and not exists (select 1 from nz.profiles where username = u);
end $$;

create function public.get_my_state() returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := auth.uid(); p nz.profiles; v_email text; v_job jsonb; v_today date := nz.wib_today();
begin
  if v_uid is null then return jsonb_build_object('logged_in', false); end if;
  select * into p from nz.profiles where id = v_uid;
  if not found then
    select email into v_email from auth.users where id = v_uid;
    return jsonb_build_object('logged_in', true, 'registered', false, 'is_admin', nz.is_admin(),
      'username', case when v_email like '%@warga.netizenia.local' then split_part(v_email, '@', 1) end,
      'professions', to_jsonb(nz.player_professions()), 'colors', to_jsonb(nz.palette()));
  end if;
  select jsonb_build_object('building_id', j.building_id, 'type', b.type, 'name', nz.building_name(b.id),
                            'owner', coalesce(o.display_name, 'Negara'), 'state', b.owner_id is null,
                            'wage', b.wage, 'last_shift_at', j.last_shift_at, 'paid_hours', j.paid_hours)
    into v_job
  from nz.jobs j join nz.buildings b on b.id = j.building_id left join nz.profiles o on o.id = b.owner_id
  where j.user_id = v_uid;
  return jsonb_build_object(
    'logged_in', true, 'registered', true, 'is_admin', nz.is_admin(),
    'id', p.id, 'username', p.username, 'name', p.display_name, 'profession', p.profession, 'color', p.color,
    'coins', p.coins, 'energy', floor(nz.energy_now(p)), 'health', p.health, 'xp', p.xp,
    'level', 1 + p.xp / 100,
    'jail_until', case when p.jail_until > now() then p.jail_until end,
    'home_building_id', p.home_building_id, 'free_house_used', p.free_house_used,
    'promo_until', case when p.promo_until > now() then p.promo_until end,
    'npc', (select jsonb_build_object('id', n.id, 'name', n.name) from nz.npcs n where n.id = p.npc_id),
    'cooldowns', (select coalesce(jsonb_object_agg(action, ready_at), '{}') from nz.cooldowns
                  where user_id = v_uid and ready_at > now()),
    'missions', (select jsonb_agg(jsonb_build_object('key', k, 'label', nz.mission_label(k),
                   'done', exists (select 1 from nz.missions m where m.user_id = v_uid and m.day = v_today and m.key = k)))
                 from unnest(nz.mission_keys(v_today)) k),
    'earned_today', (select coalesce(earned, 0) from nz.daily_earnings where user_id = v_uid and day = v_today),
    'daily_cap', (select daily_cap from nz.settings where id = 1),
    'job', v_job,
    'owned', (select count(*) from nz.buildings where owner_id = v_uid),
    'active_proposals', (select count(*) from nz.proposals where proposer_id = v_uid and status = 'voting')
                      + (select count(*) from nz.district_proposals where proposer_id = v_uid and status = 'voting'),
    'my_votes', (select coalesce(jsonb_object_agg(v.proposal_id::text, v.vote), '{}') from nz.proposal_votes v
                 join nz.proposals pr on pr.id = v.proposal_id where v.user_id = v_uid and pr.status = 'voting'),
    'my_district_votes', (select coalesce(jsonb_object_agg(v.proposal_id::text, v.vote), '{}') from nz.district_votes v
                 join nz.district_proposals pr on pr.id = v.proposal_id where v.user_id = v_uid and pr.status = 'voting'),
    'reports_on_me', (select count(distinct reporter_id) from nz.reports where target_id = v_uid and resolved_at is null),
    'claim_pending', exists (select 1 from public.claim_requests where user_id = v_uid and status = 'pending'),
    'professions', to_jsonb(nz.player_professions()), 'colors', to_jsonb(nz.palette())
  );
end $$;

-- ---------------------------------------------------------------------------
-- 4.2  PROFIL
-- ---------------------------------------------------------------------------

create function public.register_profile(p_name text, p_profession text default 'Warga', p_color text default null)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare
  v_uid uuid := nz.uid(); v_name text := nz.clean_text(p_name, 24); v_admin boolean := nz.is_admin();
  v_email text; v_user text; v_prof text; v_color text; v_home bigint;
begin
  if exists (select 1 from nz.profiles where id = v_uid) then raise exception 'Profil sudah ada.'; end if;
  if char_length(v_name) < 2 then raise exception 'Nama minimal 2 huruf.'; end if;
  if not v_admin and lower(v_name) in ('pak mulyo', 'presiden', 'admin', 'negara') then
    raise exception 'Nama itu dicadangkan.';
  end if;
  if exists (select 1 from nz.profiles where name_key = lower(v_name)) then
    raise exception 'Nama sudah dipakai warga lain.';
  end if;
  if exists (select 1 from nz.npcs where name_key = lower(v_name) and claimed_by is null and not hidden) then
    raise exception 'Nama itu milik warga lama dari komen. Kalau itu kamu, pakai nama lain dulu lalu ajukan klaim.';
  end if;
  select email into v_email from auth.users where id = v_uid;
  if v_email like '%@warga.netizenia.local' then
    v_user := lower(split_part(v_email, '@', 1));
    if v_user !~ '^[a-z0-9_.]{3,20}$' then v_user := null; end if;
  end if;
  if v_admin then
    v_prof := 'Presiden';
    select id into v_home from nz.buildings where seed_key = 'kantor';
  else
    v_prof := coalesce(p_profession, 'Warga');
    if not (v_prof = any (nz.player_professions())) then raise exception 'Profesi tidak tersedia.'; end if;
  end if;
  v_color := case when p_color = any (nz.palette()) then p_color else (nz.palette())[1] end;
  if v_admin then v_color := '#1E2A44'; end if;

  insert into nz.profiles (id, username, display_name, profession, color, home_building_id)
  values (v_uid, v_user, v_name, v_prof, v_color, v_home);
  if not v_admin then
    perform nz.tx('sistem', null, 'user', v_uid::text, 400, 'modal awal warga baru');
    perform nz.news(v_name || ' pindah ke Republik Netizenia sebagai ' || v_prof || '.', 'warga', v_name);
  else
    perform nz.news('Presiden ' || v_name || ' masuk ke kantor.', 'presiden', v_name);
  end if;
  return public.get_my_state();
end $$;

create function public.change_profession(p_profession text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); p nz.profiles; v_jp text;
begin
  p := nz.me(v_uid); perform nz.require_free(p);
  if p.profession in ('Presiden', 'Menteri') then raise exception 'Profesimu ditetapkan presiden.'; end if;
  if not (p_profession = any (nz.player_professions())) then raise exception 'Profesi tidak tersedia.'; end if;
  if p.profession = p_profession then raise exception 'Itu sudah profesimu.'; end if;
  perform nz.tx('user', v_uid::text, 'negara', null, 100, 'ganti profesi ke ' || p_profession);
  select c.job_prof into v_jp from nz.jobs j join nz.buildings b on b.id = j.building_id
    join nz.catalog c on c.type = b.type where j.user_id = v_uid;
  if v_jp is not null then delete from nz.jobs where user_id = v_uid; end if;
  update nz.profiles set profession = p_profession where id = v_uid;
  return jsonb_build_object('msg', 'Profesimu sekarang ' || p_profession || '.' ||
                            case when v_jp is not null then ' Kamu keluar dari pekerjaan khusus ' || v_jp || '.' else '' end);
end $$;

create function public.set_color(p_color text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); p nz.profiles;
begin
  p := nz.me(v_uid);
  if not (p_color = any (nz.palette())) or p.profession = 'Presiden' then raise exception 'Warna tidak tersedia.'; end if;
  update nz.profiles set color = p_color where id = v_uid;
  return jsonb_build_object('msg', 'Warna disimpan.');
end $$;

-- Daftar warga untuk tab Warga (hanya data publik; koin orang lain tidak terlihat).
create function public.get_citizens(p_query text default '', p_filter text default 'semua', p_limit int default 60)
returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); q text := '%' || lower(nz.clean_text(p_query, 40)) || '%'; v_lim int := least(greatest(p_limit, 1), 100);
begin
  return (select coalesce(jsonb_agg(x), '[]') from (
    select * from (
      select jsonb_build_object('kind', 'warga', 'id', p.id, 'name', p.display_name, 'prof', p.profession, 'color', p.color,
               'sick', p.health < 60, 'jailed', coalesce(p.jail_until > now(), false),
               'reports', (select count(distinct r.reporter_id) from nz.reports r where r.target_id = p.id and r.resolved_at is null),
               'i_reported', exists (select 1 from nz.reports r where r.target_id = p.id and r.reporter_id = v_uid and r.resolved_at is null),
               'job', (select nz.building_name(j.building_id) from nz.jobs j where j.user_id = p.id)) as x,
             (select count(*) from nz.reports r where r.target_id = p.id and r.resolved_at is null) as sort_r, p.health as sort_h
      from nz.profiles p
      where p.id <> v_uid and (lower(p.display_name) like q or lower(p.profession) like q)
        and (p_filter = 'semua' or p_filter = 'warga'
             or (p_filter = 'sakit' and p.health < 60)
             or (p_filter = 'lapor' and exists (select 1 from nz.reports r where r.target_id = p.id and r.resolved_at is null)))
      union all
      select jsonb_build_object('kind', 'npc', 'id', n.id, 'name', n.name, 'prof', n.profession, 'color', n.color,
               'sick', n.health < 60, 'jailed', false, 'reports', 0, 'i_reported', false, 'job', null),
             0, n.health
      from nz.npcs n
      where not n.hidden and n.claimed_by is null and p_filter in ('semua', 'sakit')
        and (lower(n.name) like q or lower(n.profession) like q)
        and (p_filter = 'semua' or n.health < 60)
    ) u order by sort_r desc, sort_h asc limit v_lim) t(x, sort_r, sort_h));
end $$;

-- ---------------------------------------------------------------------------
-- 4.3  BANGUN DAN VOTING
-- ---------------------------------------------------------------------------

create function public.build_private(p_type text, p_i int, p_j int, p_rotated boolean default false) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare
  v_uid uuid := nz.uid(); p nz.profiles; c nz.catalog; v_w int; v_h int; v_free boolean; v_price bigint;
  v_land bigint; v_id bigint;
begin
  p := nz.me(v_uid); perform nz.require_free(p);
  if p.profession = 'Presiden' then raise exception 'Presiden membangun lewat usulan umum, bukan bangunan pribadi.'; end if;
  select * into c from nz.catalog where type = p_type and kind = 'pribadi';
  if not found then raise exception 'Jenis bangunan tidak dikenal.'; end if;
  if c.req is not null and p.profession <> c.req then raise exception 'Khusus profesi %.', c.req; end if;
  if (select count(*) from nz.buildings where owner_id = v_uid) >= 6 then raise exception 'Maksimal 6 bangunan pribadi.'; end if;
  v_w := case when coalesce(p_rotated, false) then c.h else c.w end;
  v_h := case when coalesce(p_rotated, false) then c.w else c.h end;
  v_free := p_type = 'rumah' and not p.free_house_used;
  v_price := case when v_free then 0 else c.cost + 20 * c.w * c.h end;
  if p.coins < v_price then raise exception 'Koinmu belum cukup. Butuh % NC.', v_price; end if;

  insert into nz.buildings (type, i, j, w, h, district, owner_id, stage, started_at, build_hours)
  values (p_type, p_i, p_j, v_w, v_h, nz.district_of(p_i, p_j), v_uid, 'bangun', now(), c.build_hours)
  returning id into v_id;
  perform nz.place(v_id, p_i, p_j, v_w, v_h);

  if v_price > 0 then
    v_land := round(v_price * 0.1);
    perform nz.tx('user', v_uid::text, 'negara', null, v_land, 'pajak tanah ' || c.name, false, 'none', 'building:' || v_id);
    perform nz.tx('user', v_uid::text, 'sistem', null, v_price - v_land, 'beli ' || c.name, false, 'none', 'building:' || v_id);
  end if;
  update nz.profiles set
    free_house_used = free_house_used or v_free,
    home_building_id = case when c.res > 0 and home_building_id is null then v_id else home_building_id end
  where id = v_uid;
  perform nz.mission_done(v_uid, 'bangun');
  perform nz.news(p.display_name || ' mulai membangun ' || c.name || '.', 'bangun', p.display_name);
  return jsonb_build_object('id', v_id, 'price', v_price,
    'msg', c.name || ' mulai dibangun (' || c.build_hours || ' jam). Tukang bisa membantu mempercepat.');
end $$;

create function public.propose_public(p_type text, p_i int, p_j int, p_rotated boolean default false) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare
  v_uid uuid := nz.uid(); p nz.profiles; c nz.catalog; s nz.settings; v_w int; v_h int; v_id bigint; v_pid bigint;
begin
  p := nz.me(v_uid); perform nz.require_free(p);
  select * into s from nz.settings where id = 1;
  select * into c from nz.catalog where type = p_type and kind = 'umum' and proposable;
  if not found then raise exception 'Bangunan ini tidak bisa diusulkan.'; end if;
  if not nz.is_admin() and
     (select count(*) from nz.proposals where proposer_id = v_uid and status = 'voting')
     + (select count(*) from nz.district_proposals where proposer_id = v_uid and status = 'voting') >= 2 then
    raise exception 'Maksimal 2 usulan aktif per warga.';
  end if;
  v_w := case when coalesce(p_rotated, false) then c.h else c.w end;
  v_h := case when coalesce(p_rotated, false) then c.w else c.h end;
  insert into nz.buildings (type, i, j, w, h, district, stage, build_hours)
  values (p_type, p_i, p_j, v_w, v_h, nz.district_of(p_i, p_j), 'sketsa', c.build_hours)
  returning id into v_id;
  perform nz.place(v_id, p_i, p_j, v_w, v_h);
  insert into nz.proposals (building_id, type, proposer_id, cost, yes, ends_at)
  values (v_id, p_type, v_uid, c.cost, 1, now() + make_interval(hours => s.vote_hours))
  returning id into v_pid;
  insert into nz.proposal_votes (proposal_id, user_id, vote) values (v_pid, v_uid, 1);
  perform nz.mission_done(v_uid, 'bangun');
  perform nz.news(p.display_name || ' mengusulkan ' || c.name || '. Voting dibuka ' || s.vote_hours || ' jam.', 'voting', p.display_name);
  return jsonb_build_object('id', v_id, 'proposal_id', v_pid, 'msg', 'Usulan diajukan. Ajak warga lain memberi suara!');
end $$;

create function public.vote_proposal(p_id bigint, p_vote int) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); p nz.profiles; pr nz.proposals; v_first boolean; v_age int;
begin
  p := nz.me(v_uid); perform nz.require_free(p);
  if p_vote is null or p_vote not in (-1, 1) then raise exception 'Suara harus setuju atau tolak.'; end if;
  select vote_min_account_age_hours into v_age from nz.settings where id = 1;
  if v_age > 0 and p.created_at > now() - make_interval(hours => v_age) then
    raise exception 'Akun baru bisa memberi suara setelah % jam.', v_age;
  end if;
  select * into pr from nz.proposals where id = p_id for update;
  if not found then raise exception 'Usulan tidak ditemukan.'; end if;
  if pr.status <> 'voting' or pr.ends_at <= now() then raise exception 'Voting usulan ini sudah ditutup.'; end if;
  insert into nz.proposal_votes as v (proposal_id, user_id, vote) values (p_id, v_uid, p_vote)
  on conflict (proposal_id, user_id) do update set vote = excluded.vote, updated_at = now()
  returning (v.xmax = 0) into v_first;
  update nz.proposals set
    yes = (select count(*) from nz.proposal_votes where proposal_id = p_id and vote = 1),
    no  = (select count(*) from nz.proposal_votes where proposal_id = p_id and vote = -1)
  where id = p_id returning * into pr;
  if v_first then perform nz.mission_done(v_uid, 'vote'); end if;
  return jsonb_build_object('yes', pr.yes, 'no', pr.no, 'my_vote', p_vote,
                            'msg', case when p_vote > 0 then 'Suara setuju tercatat.' else 'Suara tolak tercatat.' end);
end $$;

create function public.propose_district(p_district text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); p nz.profiles; d nz.districts; s nz.settings; v_pid bigint;
begin
  p := nz.me(v_uid); perform nz.require_free(p);
  select * into s from nz.settings where id = 1;
  select * into d from nz.districts where key = p_district;
  if not found then raise exception 'Distrik tidak dikenal.'; end if;
  if d.is_open then raise exception '% sudah terbuka.', d.name; end if;
  if exists (select 1 from nz.district_proposals where district = p_district and status in ('voting', 'menunggu_kas')) then
    raise exception 'Usulan pembukaan % sudah ada. Beri suaramu di menu Voting.', d.name;
  end if;
  if not nz.is_admin() and
     (select count(*) from nz.proposals where proposer_id = v_uid and status = 'voting')
     + (select count(*) from nz.district_proposals where proposer_id = v_uid and status = 'voting') >= 2 then
    raise exception 'Maksimal 2 usulan aktif per warga.';
  end if;
  insert into nz.district_proposals (district, proposer_id, cost, yes, ends_at)
  values (p_district, v_uid, d.cost, 1, now() + make_interval(hours => s.vote_hours)) returning id into v_pid;
  insert into nz.district_votes (proposal_id, user_id, vote) values (v_pid, v_uid, 1);
  perform nz.mission_done(v_uid, 'bangun');
  perform nz.news(p.display_name || ' mengusulkan pembukaan ' || d.name || '.', 'distrik', p.display_name);
  return jsonb_build_object('id', v_pid, 'msg', 'Usulan pembukaan ' || d.name || ' diajukan.');
end $$;

create function public.vote_district(p_id bigint, p_vote int) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); p nz.profiles; dp nz.district_proposals; v_first boolean; v_age int;
begin
  p := nz.me(v_uid); perform nz.require_free(p);
  if p_vote is null or p_vote not in (-1, 1) then raise exception 'Suara harus setuju atau tolak.'; end if;
  select vote_min_account_age_hours into v_age from nz.settings where id = 1;
  if v_age > 0 and p.created_at > now() - make_interval(hours => v_age) then
    raise exception 'Akun baru bisa memberi suara setelah % jam.', v_age;
  end if;
  select * into dp from nz.district_proposals where id = p_id for update;
  if not found then raise exception 'Usulan tidak ditemukan.'; end if;
  if dp.status <> 'voting' or dp.ends_at <= now() then raise exception 'Voting usulan ini sudah ditutup.'; end if;
  insert into nz.district_votes as v (proposal_id, user_id, vote) values (p_id, v_uid, p_vote)
  on conflict (proposal_id, user_id) do update set vote = excluded.vote, updated_at = now()
  returning (v.xmax = 0) into v_first;
  update nz.district_proposals set
    yes = (select count(*) from nz.district_votes where proposal_id = p_id and vote = 1),
    no  = (select count(*) from nz.district_votes where proposal_id = p_id and vote = -1)
  where id = p_id returning * into dp;
  if v_first then perform nz.mission_done(v_uid, 'vote'); end if;
  return jsonb_build_object('yes', dp.yes, 'no', dp.no, 'my_vote', p_vote, 'msg', 'Suara tercatat.');
end $$;

create function public.help_build(p_building_id bigint) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare
  v_uid uuid := nz.uid(); p nz.profiles; b nz.buildings; v_boost numeric; v_wage int; v_paid bigint := 0;
  v_prog numeric; v_name text;
begin
  p := nz.me(v_uid); perform nz.require_free(p);
  if p.profession = 'Presiden' then raise exception 'Presiden tidak ikut mengangkat bata.'; end if;
  select * into b from nz.buildings where id = p_building_id for update;
  if not found or b.stage <> 'bangun' then raise exception 'Bangunan ini tidak sedang dibangun.'; end if;
  v_name := nz.building_name(b.id);
  if nz.progress(b) >= 1 then
    perform nz.finish_building(b.id);
    return jsonb_build_object('progress', 1, 'msg', v_name || ' ternyata sudah selesai.');
  end if;
  perform nz.cooldown(v_uid, 'bantu', 60, 'Bantu bangun');
  perform nz.use_energy(v_uid, 15);
  v_boost := case p.profession when 'Tukang' then 0.16 when 'Mandor' then 0.11 else 0.05 end;
  v_wage  := case p.profession when 'Tukang' then 25 when 'Mandor' then 30 else 8 end;
  update nz.buildings set boost = boost + v_boost, updated_at = now() where id = b.id returning * into b;
  if b.owner_id is distinct from v_uid then
    if b.owner_id is null then
      v_paid := nz.pay_from_kas(v_uid, v_wage, 'upah bantu bangun ' || v_name);
    elsif (select coins from nz.profiles where id = b.owner_id) >= v_wage then
      v_paid := nz.tx('user', b.owner_id::text, 'user', v_uid::text, v_wage, 'upah bantu bangun ' || v_name, true, 'soft');
    end if;
  end if;
  v_prog := nz.progress(b);
  if v_prog >= 1 then perform nz.finish_building(b.id); end if;
  perform nz.mission_done(v_uid, 'bantu');
  if p.profession in ('Tukang', 'Mandor') then perform nz.mission_done(v_uid, 'aksi'); end if;
  return jsonb_build_object('progress', round(v_prog, 4), 'paid', v_paid,
    'msg', 'Pembangunan ' || v_name || ' +' || round(v_boost * 100) || '%' ||
           case when v_paid > 0 then ', upah ' || v_paid || ' NC.' else '.' end);
end $$;

create function public.demolish_building(p_id bigint) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); p nz.profiles; b nz.buildings; v_name text;
begin
  p := nz.me(v_uid); perform nz.require_free(p);
  select * into b from nz.buildings where id = p_id for update;
  if not found then raise exception 'Bangunan tidak ditemukan.'; end if;
  if b.stage in ('sketsa', 'disetujui') then raise exception 'Usulan tidak bisa dibongkar. Presiden bisa memveto.'; end if;
  if b.protected then raise exception 'Bangunan bersejarah tidak bisa dibongkar.'; end if;
  if not (b.owner_id = v_uid or (b.owner_id is null and b.npc_owner_id is null and nz.is_admin())) then
    raise exception 'Kamu tidak berhak membongkar bangunan ini.';
  end if;
  v_name := nz.building_name(b.id);
  delete from nz.buildings where id = p_id;
  perform nz.news(v_name || ' milik ' || case when b.owner_id is null then 'negara' else p.display_name end || ' dibongkar.', 'bangun');
  return jsonb_build_object('msg', v_name || ' dibongkar.');
end $$;

create function public.set_wage(p_building_id bigint, p_wage int) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); p nz.profiles; b nz.buildings;
begin
  p := nz.me(v_uid);
  select * into b from nz.buildings where id = p_building_id for update;
  if not found or (b.owner_id is distinct from v_uid and not (b.owner_id is null and nz.is_admin())) then
    raise exception 'Hanya pemilik yang bisa mengatur gaji.';
  end if;
  if p_wage is null or p_wage < 10 or p_wage > 80 or p_wage % 5 <> 0 then raise exception 'Gaji 10 sampai 80 NC, kelipatan 5.'; end if;
  update nz.buildings set wage = p_wage, updated_at = now() where id = b.id;
  return jsonb_build_object('msg', 'Gaji per shift sekarang ' || p_wage || ' NC.');
end $$;

create function public.set_job_open(p_building_id bigint, p_open boolean) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); p nz.profiles; b nz.buildings;
begin
  p := nz.me(v_uid);
  select * into b from nz.buildings where id = p_building_id for update;
  if not found or (b.owner_id is distinct from v_uid and not (b.owner_id is null and nz.is_admin())) then
    raise exception 'Hanya pemilik yang bisa mengatur lowongan.';
  end if;
  update nz.buildings set job_open = coalesce(p_open, true), updated_at = now() where id = b.id;
  return jsonb_build_object('msg', case when coalesce(p_open, true) then 'Lowongan dibuka.' else 'Lowongan ditutup.' end);
end $$;

-- ---------------------------------------------------------------------------
-- 4.4  KERJA, PROFESI, LAPORAN, MISI
-- ---------------------------------------------------------------------------

create function public.apply_job(p_building_id bigint) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); p nz.profiles; b nz.buildings; c nz.catalog; v_name text;
begin
  p := nz.me(v_uid); perform nz.require_free(p);
  if p.profession = 'Presiden' then raise exception 'Presiden tidak mengambil pekerjaan.'; end if;
  perform nz.settle_building(p_building_id);
  select * into b from nz.buildings where id = p_building_id for update;
  if not found then raise exception 'Bangunan tidak ditemukan.'; end if;
  select * into c from nz.catalog where type = b.type;
  if b.stage <> 'jadi' then raise exception 'Bangunan ini belum selesai dibangun.'; end if;
  if c.jobs = 0 then raise exception 'Tidak ada lowongan di sini.'; end if;
  if b.owner_id = v_uid then raise exception 'Kamu pemilik usaha ini.'; end if;
  if not b.job_open then raise exception 'Lowongan sedang ditutup.'; end if;
  if c.job_prof is not null and p.profession <> c.job_prof then raise exception 'Lowongan ini khusus %.', c.job_prof; end if;
  if exists (select 1 from nz.jobs where user_id = v_uid and building_id = b.id) then raise exception 'Kamu sudah bekerja di sini.'; end if;
  if (select count(*) from nz.jobs where building_id = b.id) >= c.jobs then raise exception 'Lowongan sudah penuh.'; end if;
  insert into nz.jobs (user_id, building_id) values (v_uid, b.id)
  on conflict (user_id) do update set building_id = excluded.building_id, started_at = now(), last_shift_at = null, paid_hours = 0;
  v_name := nz.building_name(b.id);
  perform nz.news(p.display_name || ' mulai bekerja di ' || v_name || '.', 'kerja', p.display_name);
  return jsonb_build_object('msg', 'Diterima di ' || v_name || '. Gaji ' || b.wage || ' NC per shift.');
end $$;

create function public.quit_job() returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); p nz.profiles;
begin
  p := nz.me(v_uid);
  delete from nz.jobs where user_id = v_uid;
  if not found then raise exception 'Kamu belum bekerja.'; end if;
  return jsonb_build_object('msg', 'Kamu berhenti bekerja.');
end $$;

create function public.do_shift() returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); p nz.profiles; j nz.jobs; b nz.buildings; v_name text; v_net bigint;
begin
  p := nz.me(v_uid); perform nz.require_free(p);
  select * into j from nz.jobs where user_id = v_uid;
  if not found then raise exception 'Kamu belum bekerja. Lamar lowongan atau kerja serabutan.'; end if;
  select * into b from nz.buildings where id = j.building_id;
  v_name := nz.building_name(b.id);
  perform nz.cooldown(v_uid, 'shift', 240, 'Shift berikutnya');
  perform nz.use_energy(v_uid, 20);
  update nz.profiles set health = greatest(0, health - floor(random() * 7)::int), xp = xp + 4 where id = v_uid;
  perform nz.mission_done(v_uid, 'kerja');
  if b.owner_id is null then
    update nz.jobs set last_shift_at = now(), paid_hours = 0 where user_id = v_uid;
    return jsonb_build_object('msg', 'Shift dimulai di ' || v_name || '. Gaji ' || b.wage
      || ' NC dibayar kas negara bertahap tiap jam selama 4 jam.');
  end if;
  if (select coins from nz.profiles where id = b.owner_id) < b.wage then
    raise exception 'Pemilik usaha tidak sanggup menggaji. Coba lagi nanti atau cari kerja lain.';
  end if;
  update nz.jobs set last_shift_at = now() where user_id = v_uid;
  v_net := nz.tx('user', b.owner_id::text, 'user', v_uid::text, b.wage, 'gaji ' || v_name, true, 'none', 'building:' || b.id);
  return jsonb_build_object('gained', v_net, 'msg', 'Shift selesai di ' || v_name || ': +' || v_net || ' NC setelah pajak.');
end $$;

create function public.odd_job() returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); p nz.profiles; v_net bigint;
begin
  p := nz.me(v_uid); perform nz.require_free(p);
  if p.profession = 'Presiden' then raise exception 'Presiden tidak kerja serabutan.'; end if;
  perform nz.require_cap(v_uid);
  perform nz.cooldown(v_uid, 'serabutan', 120, 'Kerja serabutan');
  perform nz.use_energy(v_uid, 15);
  v_net := nz.tx('sistem', null, 'user', v_uid::text, 12, 'kerja serabutan', false, 'strict');
  perform nz.mission_done(v_uid, 'kerja');
  return jsonb_build_object('gained', v_net, 'msg', 'Kerja serabutan: +' || v_net || ' NC.');
end $$;

-- Aksi profesi. p_target = akun warga, p_target_id = id NPC (obati/ajar) atau id usulan (rancang).
create function public.prof_action(p_kind text, p_target uuid default null, p_target_id bigint default null) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare
  v_uid uuid := nz.uid(); p nz.profiles; t nz.profiles; n nz.npcs; pr nz.proposals;
  v_allowed text; v_gain bigint := 0; v_msg text; v_rep int; v_n int; s nz.settings;
begin
  p := nz.me(v_uid); perform nz.require_free(p);
  v_allowed := case p.profession
    when 'Warga' then 'bakti' when 'Arsitek' then 'rancang' when 'Guru' then 'ajar' when 'Murid' then 'belajar'
    when 'Dokter' then 'obati' when 'Polisi' then 'tangkap' when 'Pedagang' then 'jualan' when 'Petani' then 'panen'
    when 'Pengusaha' then 'promosi' when 'Penjahat' then 'beraksi' when 'Menteri' then 'rapat' end;
  if p_kind is distinct from v_allowed then raise exception 'Aksi ini bukan untuk profesimu.'; end if;

  -- Syarat sebelum cooldown dan energi dipakai.
  if p_kind in ('ajar', 'belajar') and not nz.has_svc('sekolah') then raise exception 'Butuh sekolah yang sudah jadi.'; end if;
  if p_kind = 'obati' and not nz.has_svc('rs') then raise exception 'Butuh rumah sakit yang sudah jadi.'; end if;
  if p_kind = 'tangkap' and not (nz.has_svc('polisi') and nz.has_svc('penjara')) then
    raise exception 'Butuh kantor polisi dan penjara yang sudah jadi.';
  end if;
  if p_kind in ('bakti', 'belajar', 'jualan', 'panen', 'beraksi') then perform nz.require_cap(v_uid); end if;

  if p_kind in ('obati', 'ajar') then
    if p_target is not null then
      if p_target = v_uid then raise exception 'Pilih warga lain.'; end if;
      select * into t from nz.profiles where id = p_target for update;
      if not found then raise exception 'Warga tidak ditemukan.'; end if;
      if p_kind = 'obati' and t.health >= 60 then raise exception 'Warga ini tidak sedang sakit.'; end if;
    elsif p_target_id is not null then
      select * into n from nz.npcs where id = p_target_id and not hidden and claimed_by is null for update;
      if not found then raise exception 'Warga tidak ditemukan.'; end if;
      if p_kind = 'obati' and n.health >= 60 then raise exception 'Warga ini tidak sedang sakit.'; end if;
    else
      raise exception 'Pilih warga dulu.';
    end if;
  end if;
  if p_kind = 'tangkap' then
    if p_target is null or p_target = v_uid then raise exception 'Pilih tersangka dulu.'; end if;
    select * into t from nz.profiles where id = p_target for update;
    if not found or t.profession = 'Presiden' then raise exception 'Warga tidak ditemukan.'; end if;
    if t.jail_until > now() then raise exception 'Warga ini sudah ditahan.'; end if;
    select count(distinct reporter_id) into v_rep from nz.reports
    where target_id = t.id and resolved_at is null and reporter_id <> v_uid;
    if v_rep < 2 then
      raise exception 'Hanya bisa menangkap warga yang dilaporkan minimal 2 akun berbeda (laporanmu sendiri tidak dihitung). Saat ini %.', v_rep;
    end if;
  end if;
  if p_kind = 'rancang' then
    if p_target_id is not null then
      select * into pr from nz.proposals where id = p_target_id and status = 'voting' and discount = 0 for update;
    else
      select * into pr from nz.proposals where status = 'voting' and discount = 0 order by ends_at limit 1 for update;
    end if;
    if not found then raise exception 'Tidak ada usulan yang bisa dirancang ulang.'; end if;
  end if;

  perform nz.cooldown(v_uid, 'aksi', 60, 'Aksi profesi');
  perform nz.use_energy(v_uid, 10);
  select * into s from nz.settings where id = 1;

  case p_kind
    when 'bakti' then
      update nz.settings set morale = greatest(2, case when morale_until > now() then morale else 0 end),
                             morale_until = greatest(coalesce(morale_until, now()), now() + interval '4 hours') where id = 1;
      v_gain := nz.tx('sistem', null, 'user', v_uid::text, 8, 'kerja bakti', false, 'strict');
      v_msg := 'Kerja bakti: lingkungan bersih, kepuasan naik. +' || v_gain || ' NC.';
    when 'rancang' then
      update nz.proposals set discount = 0.1, rancang_by = v_uid where id = pr.id;
      v_gain := nz.pay_from_kas(v_uid, 20, 'rancang denah');
      v_msg := 'Denah ' || coalesce(nz.building_name(pr.building_id), pr.type) || ' lebih efisien: biaya -10%. +' || v_gain || ' NC.';
    when 'ajar' then
      if t.id is not null then update nz.profiles set xp = xp + 15 where id = t.id; end if;
      v_gain := nz.pay_from_kas(v_uid, 25, 'mengajar');
      perform nz.mission_done(v_uid, 'lapor');
      perform nz.news(p.display_name || ' mengajar ' || coalesce(t.display_name, n.name) || ' di sekolah.', 'aksi', p.display_name);
      v_msg := coalesce(t.display_name, n.name) || ' +15 XP. Kamu +' || v_gain || ' NC.';
    when 'belajar' then
      update nz.profiles set xp = xp + 15 where id = v_uid;
      v_gain := nz.tx('sistem', null, 'user', v_uid::text, 5, 'uang saku belajar', false, 'strict');
      v_msg := 'Belajar: +15 XP, +' || v_gain || ' NC uang saku.';
    when 'obati' then
      if t.id is not null then update nz.profiles set health = 100 where id = t.id;
      else update nz.npcs set health = 100 where id = n.id; end if;
      v_gain := nz.pay_from_kas(v_uid, 30, 'mengobati pasien');
      perform nz.mission_done(v_uid, 'lapor');
      perform nz.news('Dokter ' || p.display_name || ' mengobati ' || coalesce(t.display_name, n.name) || '.', 'aksi', p.display_name);
      v_msg := coalesce(t.display_name, n.name) || ' sembuh. Kamu +' || v_gain || ' NC.';
    when 'tangkap' then
      update nz.profiles set jail_until = now() + interval '3 hours' where id = t.id;
      update nz.reports set resolved_at = now(), resolved_reason = 'ditangkap' where target_id = t.id and resolved_at is null;
      v_gain := nz.pay_from_kas(v_uid, 30, 'menangkap tersangka');
      perform nz.news(p.display_name || ' menangkap ' || t.display_name || '. Ditahan 3 jam.', 'polisi', p.display_name);
      v_msg := t.display_name || ' ditahan 3 jam. Kamu +' || v_gain || ' NC.';
    when 'jualan' then
      v_gain := nz.tx('sistem', null, 'user', v_uid::text,
                      12 + floor(coalesce((select (data->>'pop')::int from nz.city_snapshot where id = 1), 0) / 80.0)::int,
                      'jualan keliling', false, 'strict');
      v_msg := 'Jualan keliling laku: +' || v_gain || ' NC.';
    when 'panen' then
      select count(*) into v_n from nz.buildings where owner_id = v_uid and type = 'sawah' and stage = 'jadi';
      v_gain := nz.tx('sistem', null, 'user', v_uid::text, case when v_n > 0 then 22 * v_n else 10 end, 'panen', false, 'strict');
      v_msg := case when v_n > 0 then 'Panen ' || v_n || ' sawah: +' else 'Bantu panen di sawah tetangga: +' end || v_gain || ' NC.';
    when 'promosi' then
      update nz.profiles set promo_until = now() + interval '2 hours' where id = v_uid;
      v_msg := 'Promosi jalan: pendapatan usahamu +50% selama 2 jam.';
    when 'beraksi' then
      v_gain := nz.tx('npc', null, 'user', v_uid::text, 20 + floor(random() * 25)::int, 'beraksi', false, 'strict');
      if random() < 0.45 then
        perform nz.news('Warga melihat ' || p.display_name || ' mengendap-endap di dekat pasar. Laporkan bila curiga!', 'polisi');
        v_msg := 'Dapat ' || v_gain || ' NC, tapi ada saksi yang melihatmu! Hati-hati dilaporkan.';
      else
        v_msg := 'Aksi berhasil: +' || v_gain || ' NC. Hati-hati, polisi berpatroli.';
      end if;
    when 'rapat' then
      update nz.settings set morale = 4, morale_until = now() + interval '6 hours' where id = 1;
      v_gain := nz.pay_from_kas(v_uid, 25, 'rapat negara');
      v_msg := 'Rapat negara: kepuasan warga naik selama 6 jam. +' || v_gain || ' NC.';
  end case;
  perform nz.mission_done(v_uid, 'aksi');
  return jsonb_build_object('gained', v_gain, 'msg', v_msg);
end $$;

create function public.report_citizen(p_target uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); p nz.profiles; t nz.profiles; v_cnt int;
begin
  p := nz.me(v_uid); perform nz.require_free(p);
  if p_target is null or p_target = v_uid then raise exception 'Pilih warga lain.'; end if;
  select * into t from nz.profiles where id = p_target;
  if not found or t.profession = 'Presiden' then raise exception 'Warga tidak ditemukan.'; end if;
  if (select count(*) from nz.reports where reporter_id = v_uid and created_at >= (nz.wib_today()::timestamp at time zone 'Asia/Jakarta')) >= 5 then
    raise exception 'Maksimal 5 laporan per hari.';
  end if;
  begin
    insert into nz.reports (reporter_id, target_id) values (v_uid, p_target);
  exception when unique_violation then
    raise exception 'Kamu sudah melaporkan warga ini.';
  end;
  select count(distinct reporter_id) into v_cnt from nz.reports where target_id = p_target and resolved_at is null;
  perform nz.mission_done(v_uid, 'lapor');
  perform nz.news(p.display_name || ' melaporkan ' || t.display_name || ' ke polisi.', 'polisi', p.display_name);
  return jsonb_build_object('reports', v_cnt, 'msg', 'Laporan terkirim (' || v_cnt || ' akun melapor).');
end $$;

create function public.seek_treatment() returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); p nz.profiles;
begin
  p := nz.me(v_uid);
  if not nz.has_svc('rs') then raise exception 'Belum ada rumah sakit.'; end if;
  if p.health >= 100 then raise exception 'Kamu sehat.'; end if;
  perform nz.tx('user', v_uid::text, 'negara', null, 20, 'berobat di RS');
  update nz.profiles set health = 100 where id = v_uid;
  return jsonb_build_object('msg', 'Berobat di RS: sehat kembali. -20 NC.');
end $$;

-- ---------------------------------------------------------------------------
-- 4.5  CHAT, KLAIM, OPT-OUT
-- ---------------------------------------------------------------------------

create function public.send_chat_message(p_text text) returns text
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); p nz.profiles; v_text text := nz.clean_text(p_text, 200);
begin
  p := nz.me(v_uid);
  if char_length(v_text) < 1 then raise exception 'Pesan kosong.'; end if;
  if char_length(coalesce(p_text, '')) > 200 then raise exception 'Pesan maksimal 200 karakter.'; end if;
  if p.last_chat_at is not null and p.last_chat_at > now() - interval '5 seconds' then
    raise exception 'Tunggu 5 detik sebelum mengirim pesan lagi.';
  end if;
  insert into nz.chat_messages (user_id, name, profession, text) values (v_uid, p.display_name, p.profession, nz.censor(v_text));
  update nz.profiles set last_chat_at = now() where id = v_uid;
  return 'ok';
end $$;

create function public.get_chat(p_before bigint default null, p_limit int default 30) returns jsonb
language sql stable security definer set search_path = pg_catalog, nz, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'prof', profession, 'text', text, 'at', created_at) order by id), '[]')
  from (select * from nz.chat_messages where p_before is null or id < p_before
        order by id desc limit least(greatest(p_limit, 1), 50)) x
$$;

-- Klaim tokoh lama (warga dari komen IG) oleh pemilik aslinya.
-- Masuk antrean public.claim_requests yang sudah ada; presiden menyetujui.
create function public.request_claim_v2(p_npc_id bigint, p_ig text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); p nz.profiles; n nz.npcs; v_ig text := nullif(btrim(coalesce(p_ig, '')), '');
begin
  p := nz.me(v_uid);
  if p.npc_id is not null then raise exception 'Akunmu sudah tertaut ke tokoh lain.'; end if;
  select * into n from nz.npcs where id = p_npc_id and not hidden;
  if not found then raise exception 'Tokoh tidak ditemukan.'; end if;
  if n.claimed_by is not null then raise exception 'Tokoh ini sudah diklaim.'; end if;
  if v_ig is not null then
    v_ig := ltrim(v_ig, '@');
    if v_ig !~ '^[A-Za-z0-9._]{1,30}$' then raise exception 'Username Instagram tidak valid.'; end if;
  end if;
  if exists (select 1 from public.claim_requests where user_id = v_uid and status = 'pending') then
    raise exception 'Kamu masih punya klaim yang menunggu persetujuan.';
  end if;
  insert into public.claim_requests (display_name, ig_username, status, user_id, npc_id, note)
  values (n.name, coalesce(v_ig, '-'), 'pending', v_uid, n.id, nz.clean_text(p_note, 200));
  return jsonb_build_object('msg', 'Klaim untuk ' || n.name || ' dikirim. Presiden akan memeriksanya.');
end $$;

-- Pengganti opt_out_resident publik: hanya permintaan, presiden yang memutuskan.
create function public.request_opt_out(p_npc_id bigint, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_uid uuid := nz.uid(); n nz.npcs;
begin
  select * into n from nz.npcs where id = p_npc_id and not hidden;
  if not found then raise exception 'Nama tidak ditemukan.'; end if;
  if (select count(*) from nz.optout_requests where user_id = v_uid and status = 'pending') >= 3 then
    raise exception 'Kamu masih punya 3 permintaan yang menunggu.';
  end if;
  begin
    insert into nz.optout_requests (npc_id, user_id, reason) values (n.id, v_uid, nz.clean_text(p_reason, 200));
  exception when unique_violation then
    raise exception 'Permintaan untuk nama ini sudah dikirim.';
  end;
  return jsonb_build_object('msg', 'Permintaan hapus nama ' || n.name || ' dikirim ke presiden.');
end $$;

-- ---------------------------------------------------------------------------
-- 4.6  PRESIDEN DAN ADMIN (semua memeriksa tabel public.admins)
-- ---------------------------------------------------------------------------

create function public.pres_approve(p_id bigint) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v text;
begin
  perform nz.require_admin();
  if not exists (select 1 from nz.proposals where id = p_id and status in ('voting', 'menunggu_kas')) then
    raise exception 'Usulan tidak aktif.';
  end if;
  v := nz.approve_proposal(p_id, true);
  return jsonb_build_object('result', v, 'msg', case v when 'bangun' then 'Disetujui, mulai dibangun.' else 'Disetujui, menunggu kas cukup.' end);
end $$;

create function public.pres_veto(p_id bigint) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare pr nz.proposals;
begin
  perform nz.require_admin();
  select * into pr from nz.proposals where id = p_id and status in ('voting', 'menunggu_kas');
  if not found then raise exception 'Usulan tidak aktif.'; end if;
  perform nz.reject_proposal(p_id, 'veto', 'Presiden memveto usulan ' || coalesce(nz.building_name(pr.building_id), pr.type) || '.');
  return jsonb_build_object('msg', 'Usulan diveto.');
end $$;

create function public.pres_open_district(p_district text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v text;
begin
  perform nz.require_admin();
  v := nz.open_district(p_district, true);
  if v = 'menunggu_kas' then raise exception 'Kas negara belum cukup.'; end if;
  return jsonb_build_object('result', v, 'msg', case v when 'sudah' then 'Distrik sudah terbuka.' else 'Distrik dibuka.' end);
end $$;

create function public.pres_set_tax(p_pct int) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
begin
  perform nz.require_admin();
  if p_pct is null or p_pct < 0 or p_pct > 30 then raise exception 'Pajak 0 sampai 30%%.'; end if;
  update nz.settings set tax_pct = p_pct, updated_at = now() where id = 1;
  perform nz.news('Presiden menetapkan pajak ' || p_pct || '%.', 'presiden');
  perform nz.refresh_snapshot();
  return jsonb_build_object('msg', 'Pajak sekarang ' || p_pct || '%.');
end $$;

create function public.pres_announce(p_text text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v text := nz.clean_text(p_text, 160);
begin
  perform nz.require_admin();
  if char_length(v) < 3 then raise exception 'Pengumuman terlalu pendek.'; end if;
  insert into nz.announcements (text, by_user) values (v, auth.uid());
  perform nz.news('Pengumuman Presiden: ' || v, 'presiden');
  return jsonb_build_object('msg', 'Pengumuman disiarkan.');
end $$;

create function public.pres_set_minister(p_user uuid, p_on boolean) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare t nz.profiles;
begin
  perform nz.require_admin();
  select * into t from nz.profiles where id = p_user for update;
  if not found or t.profession = 'Presiden' then raise exception 'Warga tidak ditemukan.'; end if;
  if p_on then
    if t.profession = 'Menteri' then raise exception 'Sudah Menteri.'; end if;
    update nz.profiles set prev_profession = profession, profession = 'Menteri' where id = t.id;
    delete from nz.jobs j using nz.buildings b, nz.catalog c
      where j.user_id = t.id and b.id = j.building_id and c.type = b.type and c.job_prof is not null;
    perform nz.news('Presiden mengangkat ' || t.display_name || ' sebagai Menteri.', 'presiden');
  else
    if t.profession <> 'Menteri' then raise exception 'Warga ini bukan Menteri.'; end if;
    update nz.profiles set profession = coalesce(prev_profession, 'Warga'), prev_profession = null where id = t.id;
    perform nz.news(t.display_name || ' tidak lagi menjabat Menteri.', 'presiden');
  end if;
  return jsonb_build_object('msg', 'Disimpan.');
end $$;

create function public.pres_release(p_user uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
begin
  perform nz.require_admin();
  update nz.profiles set jail_until = null where id = p_user and jail_until > now();
  if not found then raise exception 'Warga ini tidak sedang ditahan.'; end if;
  return jsonb_build_object('msg', 'Tahanan dibebaskan.');
end $$;

create function public.admin_list_queue() returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, nz, pg_temp as $$
begin
  perform nz.require_admin();
  return jsonb_build_object(
    'claims', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'npc_id', r.npc_id, 'name', r.display_name,
                 'ig', nullif(r.ig_username, '-'), 'note', r.note, 'account', p.display_name, 'username', p.username,
                 'linked', r.user_id is not null, 'at', r.created_at) order by r.created_at), '[]')
               from public.claim_requests r left join nz.profiles p on p.id = r.user_id where r.status = 'pending'),
    'optouts', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'npc_id', o.npc_id, 'name', n.name,
                 'reason', o.reason, 'account', p.display_name, 'at', o.created_at) order by o.created_at), '[]')
                from nz.optout_requests o join nz.npcs n on n.id = o.npc_id left join nz.profiles p on p.id = o.user_id
                where o.status = 'pending'),
    'jailed', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', display_name, 'until', jail_until)), '[]')
               from nz.profiles where jail_until > now()));
end $$;

create function public.admin_review_claim(p_request_id bigint, p_approve boolean) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare r record; n nz.npcs; p nz.profiles; v_home nz.buildings;
begin
  perform nz.require_admin();
  select * into r from public.claim_requests where id = p_request_id for update;
  if not found then raise exception 'Klaim tidak ditemukan.'; end if;
  if r.status <> 'pending' then raise exception 'Klaim sudah diputuskan.'; end if;
  if not p_approve then
    update public.claim_requests set status = 'rejected', reviewed_at = now() where id = r.id;
    return jsonb_build_object('msg', 'Klaim ditolak.');
  end if;

  if r.user_id is null then
    -- Klaim lama tanpa akun (dari halaman lama): hanya tandai @ig seperti dulu.
    if r.ig_username ~ '^[A-Za-z0-9._]{1,30}$' then
      if to_regclass('public.residents') is not null then
        execute 'update public.residents set ig_username = $1, claimed = true where display_name = $2' using r.ig_username, r.display_name;
      end if;
      update nz.npcs set ig_username = r.ig_username where name_key = lower(btrim(r.display_name));
    end if;
    update public.claim_requests set status = 'approved', reviewed_at = now() where id = r.id;
    return jsonb_build_object('msg', 'Klaim lama disetujui (belum tertaut akun).');
  end if;

  select * into n from nz.npcs where id = r.npc_id for update;
  if not found then raise exception 'Tokoh tidak ditemukan.'; end if;
  if n.claimed_by is not null then raise exception 'Tokoh ini sudah diklaim akun lain.'; end if;
  select * into p from nz.profiles where id = r.user_id for update;
  if not found then raise exception 'Akun pengklaim belum membuat tokoh.'; end if;
  if p.npc_id is not null then raise exception 'Akun ini sudah tertaut ke tokoh lain.'; end if;

  update nz.npcs set claimed_by = p.id, ig_username = coalesce(nullif(r.ig_username, '-'), ig_username) where id = n.id;
  update nz.profiles set npc_id = n.id where id = p.id;
  if not exists (select 1 from nz.profiles where name_key = n.name_key and id <> p.id) then
    update nz.profiles set display_name = n.name where id = p.id;
  end if;
  -- Rumah NPC yang dimiliki tokoh ini pindah ke akunnya (bila belum 6 bangunan).
  select * into v_home from nz.buildings where npc_owner_id = n.id order by id limit 1 for update;
  if found and (select count(*) from nz.buildings where owner_id = p.id) < 6 then
    update nz.buildings set owner_id = p.id, npc_owner_id = null, updated_at = now() where id = v_home.id;
  end if;
  update nz.profiles set home_building_id = coalesce(home_building_id, n.home_building_id) where id = p.id;
  if r.ig_username ~ '^[A-Za-z0-9._]{1,30}$' and to_regclass('public.residents') is not null then
    execute 'update public.residents set ig_username = $1, claimed = true where display_name = $2' using r.ig_username, n.name;
  end if;
  update public.claim_requests set status = 'approved', reviewed_at = now() where id = r.id;
  update public.claim_requests set status = 'rejected', reviewed_at = now()
  where npc_id = n.id and status = 'pending' and id <> r.id;
  perform nz.news(n.name || ' kini dimainkan langsung oleh pemiliknya!', 'warga', n.name);
  return jsonb_build_object('msg', 'Klaim disetujui. ' || n.name || ' tertaut ke akun ' || p.display_name || '.');
end $$;

create function public.admin_review_optout(p_id bigint, p_approve boolean) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare o nz.optout_requests; n nz.npcs;
begin
  perform nz.require_admin();
  select * into o from nz.optout_requests where id = p_id for update;
  if not found or o.status <> 'pending' then raise exception 'Permintaan tidak aktif.'; end if;
  if not p_approve then
    update nz.optout_requests set status = 'rejected', reviewed_at = now() where id = o.id;
    return jsonb_build_object('msg', 'Permintaan ditolak.');
  end if;
  update nz.npcs set hidden = true, home_building_id = null where id = o.npc_id returning * into n;
  update nz.buildings set label = null where npc_owner_id = n.id;
  if to_regclass('public.residents') is not null then
    execute 'update public.residents set opt_out = true where display_name = $1' using n.name;
  end if;
  update nz.optout_requests set status = 'approved', reviewed_at = now() where npc_id = o.npc_id and status = 'pending';
  return jsonb_build_object('msg', 'Nama ' || n.name || ' dihapus dari kota.');
end $$;

create function public.admin_delete_donation(p_id bigint) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
begin
  perform nz.require_admin();
  delete from nz.donations where id = p_id;
  if not found then raise exception 'Donasi tidak ditemukan.'; end if;
  return jsonb_build_object('msg', 'Donasi dihapus.');
end $$;

-- Mencatat donasi Saweria secara manual. Tidak menghasilkan koin apa pun.
create function public.pres_add_donation(p_name text, p_amount bigint, p_message text default null,
                                         p_donated_at timestamptz default null) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_name text := nz.clean_text(p_name, 40); v_msg text := nullif(nz.censor(nz.clean_text(p_message, 200)), ''); v_id bigint;
begin
  perform nz.require_admin();
  if char_length(v_name) < 1 then raise exception 'Nama donatur kosong.'; end if;
  if p_amount is null or p_amount < 0 or p_amount > 1000000000 then raise exception 'Nominal tidak valid.'; end if;
  if p_donated_at is not null and p_donated_at > now() + interval '1 day' then raise exception 'Tanggal donasi tidak valid.'; end if;
  insert into nz.donations (donor_name, amount, message, donated_at, created_by)
  values (v_name, p_amount, v_msg, coalesce(p_donated_at, now()), auth.uid()) returning id into v_id;
  perform nz.news('Terima kasih ' || v_name || ' atas dukungan Rp' || replace(to_char(p_amount, 'FM999,999,999,999'), ',', '.') || ' untuk Republik Netizenia!', 'donasi', v_name);
  return jsonb_build_object('id', v_id, 'msg', 'Donasi ' || v_name || ' dicatat.');
end $$;

create function public.pres_set_saweria(p_url text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v text := btrim(coalesce(p_url, ''));
begin
  perform nz.require_admin();
  if v <> '' and v !~ '^https://(www\.)?saweria\.co/[A-Za-z0-9_.-]{1,40}/?$' then
    raise exception 'Tautan harus berbentuk https://saweria.co/namakamu';
  end if;
  update nz.settings set saweria_url = nullif(v, ''), updated_at = now() where id = 1;
  return jsonb_build_object('msg', case when v = '' then 'Tautan Saweria dihapus.' else 'Tautan Saweria disimpan.' end);
end $$;

create function public.admin_set_donation_goal(p_amount bigint) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
begin
  perform nz.require_admin();
  if p_amount is null or p_amount < 0 then raise exception 'Target tidak valid.'; end if;
  update nz.settings set donation_goal = p_amount, updated_at = now() where id = 1;
  return jsonb_build_object('msg', 'Target donasi disimpan.');
end $$;

create function public.admin_delete_chat(p_id bigint) returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
begin
  perform nz.require_admin();
  delete from nz.chat_messages where id = p_id;
  if not found then raise exception 'Pesan tidak ditemukan.'; end if;
  return jsonb_build_object('msg', 'Pesan dihapus.');
end $$;

-- Setelah presiden mengimpor nama lewat admin_import_residents (panel lama),
-- jalankan ini supaya warga baru ikut muncul di v2.
create function public.admin_sync_npcs() returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
declare v_new int; v_h int;
begin
  perform nz.require_admin();
  v_new := nz.sync_npcs();
  v_h := nz.seed_npc_homes();
  return jsonb_build_object('npc_baru', v_new, 'rumah_baru', v_h, 'msg', v_new || ' warga baru, ' || v_h || ' rumah baru.');
end $$;

-- Jalankan tick sekarang (aman: bagian ekonomi tetap sekali per jam).
create function public.admin_run_tick() returns jsonb
language plpgsql security definer set search_path = pg_catalog, nz, pg_temp as $$
begin
  perform nz.require_admin();
  return nz.tick_hourly();
end $$;


-- ============================================================================
-- BAGIAN 5 · JADWAL, REALTIME, HAK AKSES, DATA AWAL DUNIA
-- ============================================================================

-- 5.1  Hak EXECUTE. Fungsi internal nz.* tertutup untuk semua role web.
--      RPC publik: tamu (anon) hanya fungsi baca; aksi butuh login.
do $$
declare
  r record;
  v_anon text[] := array['get_city_snapshot', 'get_buildings', 'get_building', 'get_npcs', 'username_available', 'get_my_state'];
  v_auth text[] := array[
    'register_profile','change_profession','set_color','get_citizens',
    'build_private','propose_public','vote_proposal','propose_district','vote_district',
    'help_build','demolish_building','set_wage','set_job_open',
    'apply_job','quit_job','do_shift','odd_job','prof_action','report_citizen','seek_treatment',
    'send_chat_message','get_chat','request_claim_v2','request_opt_out',
    'pres_approve','pres_veto','pres_open_district','pres_set_tax','pres_announce','pres_set_minister','pres_release',
    'admin_list_queue','admin_review_claim','admin_review_optout','admin_delete_donation',
    'admin_set_donation_goal','admin_delete_chat','admin_sync_npcs','admin_run_tick',
    'pres_add_donation','pres_set_saweria'];
begin
  for r in
    select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = any (v_anon || v_auth)
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
    if r.proname = any (v_anon) then
      execute format('grant execute on function %s to anon', r.sig);
    end if;
  end loop;
  for r in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'nz'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

-- 5.2  Realtime hanya untuk tiga tabel v2 yang perlu (pemain login saja,
--      karena hanya authenticated yang punya SELECT di tabel itu).
do $$
declare t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    raise notice 'Publikasi supabase_realtime tidak ditemukan; realtime dilewati.';
    return;
  end if;
  foreach t in array array['buildings', 'proposals', 'chat_messages'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'nz' and tablename = t) then
      begin
        execute format('alter publication supabase_realtime add table nz.%I', t);
      exception when others then
        raise notice 'Realtime nz.% gagal ditambahkan: %. Tambahkan manual di Database > Publications.', t, sqlerrm;
      end;
    end if;
  end loop;
end $$;

-- 5.3  Isi dunia: fasilitas lama, warga benih dari komen, rumah NPC.
--      Aman diulang: yang sudah ada dilewati.
select nz.seed_world($seed$[["David", "Tukang", 88], ["Ali Akbar Rafsanjani", "Warga", 88], ["Dion Gabriel S.Parhusip", "Dokter", 88], ["korizen_Diya🤍💛", "Dokter", 88], ["KarShikii", "Dokter", 88], ["adtya_", "Dokter", 88], ["kyutt_👅", "Dokter", 88], ["raaa", "Dokter", 88], ["bg_bhy", "Dokter", 88], ["Eliya J.M", "Dokter", 88], ["riri rianty💞", "Dokter", 88], ["Octa Galuh", "Dokter", 88], ["apiin_", "Dokter", 88], ["fiii", "Dokter", 88], ["AZ - Zahra", "Dokter", 88], ["princess anggian", "Dokter", 88], ["Aiccio", "Dokter", 88], ["Putra Anfield", "Dokter", 88], ["Tiara Putri Cikita", "Dokter", 88], ["Agus Susanto", "Dokter", 88], ["Darlene Winata Ho", "Dokter", 88], ["pitsby hsvau", "Dokter", 88], ["kentung", "Dokter", 88], ["qheyra athalita", "Dokter", 88], ["£SM₱S_$D€L", "Dokter", 88], ["fabian", "Dokter", 88], ["Airin Indrianingsih", "Dokter", 88], ["dadaaa_zflaa", "Dokter", 88], ["bim_boysss", "Dokter", 88], ["jungkook wife♡🩷", "Dokter", 88], ["Raniaairaa", "Dokter", 88], ["Gavrilla Anabel juniko", "Dokter", 88], ["Dyajeng Rahayu", "Dokter", 88], ["Wahyu Latipah", "Dokter", 88], ["Sekedar Hobi", "Warga", 88], ["Firzz Ajh", "Warga", 88], ["ell🐣", "Warga", 88], ["Hasby Shohibul Risky", "Warga", 88], ["Alqias Kurniawan", "Warga", 88], ["tamaa_stronggboyss", "Warga", 88], ["𝕬𝖓𝖙𝖊𝖝𝖝 𝕸𝖚𝖘𝖆𝖉𝖉", "Warga", 88], ["Zulfan", "Warga", 88], ["YES", "Warga", 88], ["dho", "Warga", 88], ["Ugal", "Warga", 88], ["deentaabotolyakultt🐾🐧", "Warga", 88], ["Rahmad Rinaldo Rais", "Warga", 88], ["sigit", "Warga", 88], ["Da Ar", "Warga", 88], ["elang", "Warga", 88], ["Anggi Senja", "Warga", 88], ["Deni Syahputra", "Warga", 88], ["Bang Pais", "Warga", 88], ["Harry Axl Il Principino", "Warga", 88], ["Muhammad Rizky", "Warga", 88], ["alfi_gt1", "Warga", 88], ["Muh Arie", "Warga", 88], ["Ardi Ris", "Warga", 88], ["maal_dii", "Warga", 88], ["𝘕𝘦𝘵𝘸𝘰𝘳𝘬 𝘌𝘯𝘨𝘪𝘯𝘦𝘦𝘳", "Warga", 88], ["Bangun Dwi Wiratomo", "Warga", 88], ["Arka Masrizal", "Warga", 88], ["esjeeee", "Warga", 88], ["أندي إلهام", "Warga", 88], ["rafiii", "Warga", 88], ["Saragih Faudi", "Warga", 88], ["Udo iam", "Warga", 88], ["Hengky Situmorang", "Warga", 88], ["Oddysey Hub", "Warga", 88], ["TEMANBAIKBAPAK.", "Warga", 88], ["chrs", "Petani", 88], ["Jaa", "Petani", 88], ["danda", "Petani", 88], ["Yeremia Malaru", "Petani", 88], ["mut", "Petani", 88], ["Mochamad Deanira Magustira", "Petani", 88], ["rafi", "Petani", 88], ["RIN 1%", "Petani", 88], ["A----17", "Warga", 88], ["Andri.", "Warga", 88], ["si kasep", "Warga", 88], ["Bintang Utama Putra", "Warga", 88], ["ヨリム", "Warga", 88], ["Amel Ramadhani", "Warga", 88], ["Maz Kun", "Warga", 88], ["ttt", "Warga", 88], ["דוטה", "Warga", 88], ["Faldi Kase", "Warga", 88], ["ANCU jhi", "Warga", 88], ["Nathan ardra faviandigna", "Warga", 88], ["Pi Yan", "Warga", 88], ["ʚɞ miraa || pretty ʚɞ", "Warga", 88], ["Imam IJ", "Warga", 88], ["Spotting Cars Batam", "Warga", 88], ["larassukamatch", "Warga", 88], ["wahyu", "Warga", 88], ["Conell Grip", "Warga", 88], ["putra sarusuk", "Warga", 88], ["Fahri 27", "Warga", 88], ["oktaviajiwo", "Warga", 88], ["Muh.reyhan rafid", "Warga", 88], ["Dissleksia!", "Warga", 88], ["Yura", "Warga", 88], ["Abu Kurir Gowa", "Warga", 88], ["yoGex", "Warga", 88], ["Mj fishing", "Warga", 88], ["J4sunn__", "Warga", 88], ["rnda_zahrial", "Warga", 88], ["Ahmad Afani", "Warga", 88], ["Siti Fatimah", "Warga", 88], ["Baale", "Warga", 88], ["Babah Zharif", "Warga", 88], ["Fakri Nur", "Warga", 88], ["Qhotim Salavizer", "Warga", 88], ["Herin Supardi", "Warga", 88], ["Wahyu S", "Warga", 88], ["Jonatan Natan", "Warga", 88], ["KakLOOK", "Warga", 88], ["ANGGI", "Warga", 88], ["Betaubun", "Warga", 88], ["Sifak Ardi", "Warga", 88], ["Abdul Ghoni Muzakki", "Warga", 88], ["Fajar Mitha", "Warga", 88], ["م. ريزال فاه‍مي", "Warga", 88], ["Richie Mikyano", "Warga", 88], ["Zulfikar", "Warga", 88], ["Rerey Rio Lia", "Guru", 88], ["Wahyu YU", "Guru", 88], ["Mapril Van Lapan", "Guru", 88], ["rulli amarullah", "Guru", 88], ["a fizh 🐟🐠", "Guru", 88], ["24_Sul💫", "Guru", 88], ["acha_chaa", "Guru", 88], ["Fazril", "Guru", 88], ["Hanna Digital Printing", "Guru", 88], ["aisyhn", "Guru", 88], ["Ilham Siregar", "Guru", 88], ["@Ahmad 20", "Guru", 88], ["~pukiszz!", "Guru", 88], ["aboutzaaaaa", "Guru", 88], ["_COBRA_", "Guru", 88], ["إندر ملك", "Guru", 88], ["manggong_72", "Guru", 88], ["vian", "Guru", 88], ["Siswandi Fathurrahman", "Guru", 88], ["yiddd____zzz", "Guru", 88], ["maul_uull", "Guru", 88], ["𝓡𝓸𝓯𝓲𝓷𝓪 𝓔𝓵𝓲𝓼𝓪𝓫𝓮𝓽𝓱 𝓜𝓲𝓵𝓪𝓷𝓲𝓼𝓽𝔂 𝓒𝓸𝓶𝓮", "Guru", 88], ["norainah", "Guru", 88], ["Gery Ramadhan Pamungkas", "Guru", 88], ["Ari Pangestu II", "Guru", 88], ["иваль Джульфикар", "Guru", 88], ["୨୧˙˚", "Guru", 88], ["Iqlima Salsabila Oktaviani", "Guru", 88], ["Ginanjar Eka Saputra", "Guru", 88], ["Egi Walker", "Guru", 88], ["basap_wau", "Guru", 88], ["883176", "Guru", 88], ["atifa meisya", "Guru", 88], ["@#48", "Guru", 88], ["bee", "Guru", 88], ["rilla", "Guru", 88], ["Deni Elva Riani", "Guru", 88], ["𝓐𝓵𝓭𝓸𝓿𝓪", "Guru", 88], ["ubai_da", "Guru", 88], ["laetampu", "Guru", 88], ["dw_arfafebrian_211", "Guru", 88], ["alinda", "Menteri", 88], ["Budhi Sutanto Nugroho", "Menteri", 88], ["Nata", "Menteri", 88], ["m. rizky aulia pratama", "Menteri", 88], ["wait for my revenge", "Pengusaha", 88], ["mesak_m@rin_", "Pengusaha", 88], ["raymondsss", "Pengusaha", 88], ["T W Riau", "Pengusaha", 88], ["Kha_ka13", "Menteri", 88], ["Muhammad Asril", "Menteri", 88], ["Nehemia Edoard legi", "Menteri", 88], ["Febri Muchdian Kusuma", "Menteri", 88], ["Muhammad Nur Ichsan", "Menteri", 88], ["Ahmad Fausan", "Menteri", 88], ["Raga Alif", "Menteri", 88], ["Yulie Bilqis", "Menteri", 88], ["rafycoa02", "Menteri", 88], ["DwiPangestu", "Menteri", 88], ["Elv Riani", "Menteri", 88], ["Sfyn Thok", "Menteri", 88], ["Danexh", "Menteri", 88], ["Chu_Chan🌼🍀", "Menteri", 88], ["Heryyadriaan", "Menteri", 88], ["𝓶𝓾𝓱𝓪𝓶𝓶𝓪𝓭 𝓱𝓪𝓭𝓲 𝓳𝓪𝓷𝓾𝓪𝓻", "Menteri", 88], ["Wancutrss", "Menteri", 88], ["dek relll", "Menteri", 88], ["Ryan Moh Rizqi", "Menteri", 88], ["𝕸𝖚𝖍𝖆𝖒𝖆𝖉 𝕱𝖆𝖏𝖆𝖗 𝕬𝖑 𝕻𝖆𝖘𝖑𝖆🐧", "Menteri", 88], ["Warwer _Yit", "Menteri", 88], ["yusrilihzmhndra", "Menteri", 88], ["Mentri_Keuang4n", "Menteri", 88], ["Menyerah", "Menteri", 88], ["Zulfahmi_375", "Menteri", 88], ["jangga", "Menteri", 88], ["Dooo!", "Menteri", 88], ["Bagus Baseperi", "Menteri", 88], ["andrean", "Menteri", 88], ["Wawasan Luas", "Menteri", 88], ["Fahdya'Sub Farras", "Menteri", 88], ["Farial", "Menteri", 88], ["M'nakang", "Menteri", 88], ["Egy Nopranda", "Menteri", 88], ["mas", "Menteri", 88], ["Azhari_nst", "Tukang", 88], ["David🧢", "Tukang", 88], ["yo  aj", "Tukang", 88], ["pijat cianjur", "Tukang", 88], ["محمد الفاتح ناز", "Tukang", 88], ["fathur", "Tukang", 88], ["Arifinzzz", "Tukang", 88], ["Apu", "Tukang", 88], ["alexa dra nur dinissa", "Tukang", 88], ["JOSUA GANTENG", "Tukang", 88], ["Bayzur Rohman", "Tukang", 88], ["AONE ☁️", "Tukang", 88], ["piziinyalagibobo", "Tukang", 88], ["Aditya Fadjar Wullan", "Tukang", 88], ["fr1d4snn_", "Tukang", 88], ["utramen", "Tukang", 88], ["denzzbrengsekk👾", "Tukang", 88], ["Bihar Efendi", "Tukang", 88], ["R17", "Tukang", 88], ["Ahmad D4RIZZZ", "Tukang", 88], ["Netizen +62", "Tukang", 88], ["Dwi Yansyah Putra", "Tukang", 88], ["Púťŕ4śóháńďšömë", "Tukang", 88], ["Mohong", "Tukang", 88], ["anotherm4nn⚜️", "Tukang", 88], ["heri septian", "Tukang", 88], ["wolf_the_balck", "Tukang", 88], ["toto__pamalastenar", "Tukang", 88], ["Ibnu Muzacky", "Tukang", 88], ["pecintaamericogabegula", "Tukang", 88], ["Kholip Farzeky", "Tukang", 88], ["Ruby Ahmad", "Tukang", 88], ["Muhammad Aditya Wanzir", "Tukang", 88], ["Rikki rikardo Napitupulu", "Tukang", 88], ["Dion Tempalo", "Tukang", 88], ["KRISTIAN SILALAHI", "Tukang", 88], ["San7", "Tukang", 88], ["Muhammad Ridhuan", "Tukang", 88], ["JAISYUL USRAH", "Tukang", 88], ["yuspun_06", "Tukang", 88], ["Jack Kurnia Pratama", "Tukang", 88], ["Bangeza.s__", "Tukang", 88], ["resha mokong", "Mandor", 88], ["al", "Mandor", 88], ["Berseri_", "Mandor", 88], ["Imam Herman", "Mandor", 88], ["Afif Musthafa", "Mandor", 88], ["alex", "Mandor", 88], ["Nothing", "Polisi", 88], ["rayan.jak", "Polisi", 88], ["Fanji Giovanski", "Polisi", 88], ["Tarigan", "Polisi", 88], ["Bintang", "Polisi", 88], ["Arham's DarkSide", "Polisi", 88], ["Ilham Harahap", "Polisi", 88], ["Shendy Ongkowijaya", "Polisi", 88], ["#speedwil", "Polisi", 88], ["bang ris", "Polisi", 88], ["Leman Sopiyan", "Polisi", 88], ["Fitrah", "Polisi", 88], ["Samsari Smsari", "Polisi", 88], ["Ilham aja sih", "Polisi", 88], ["Adi Wijaya", "Polisi", 88], ["dullll", "Polisi", 88], ["BigStar", "Polisi", 88], ["★~-Anugerahh-~★", "Polisi", 88], ["David🌻", "Polisi", 88], ["walid", "Polisi", 88], [">mobil mbg<", "Polisi", 88], ["Wahyu April Putra", "Arsitek", 88], ["chocolate luv matcha🍫🍵", "Arsitek", 88], ["Rafka Febrian", "Arsitek", 88], ["Z", "Arsitek", 88], ["271210___", "Murid", 88], ["CARI_TAU_SENDIRI", "Murid", 88], ["si botak kyo kiano", "Murid", 88], ["fanny", "Murid", 88], ["namanya4adel🍃", "Murid", 88], ["pnggil_aj_Sr.Mariaellah", "Warga", 35], ["l0vlyara🦖", "Warga", 35], ["Didia elan", "Warga", 35], ["YR", "Penjahat", 88], ["the bung's", "Penjahat", 88], ["Jull", "Penjahat", 88], ["soekamto", "Penjahat", 88], ["M Bachrull Ulum", "Penjahat", 88], ["aby", "Penjahat", 88], ["Fory Coffee", "Pedagang", 88], ["Jhoon", "Pedagang", 88], ["s", "Pedagang", 88], ["Pelajar Cupang", "Pedagang", 88], ["Alfie Rizkiyansyah", "Pedagang", 88], ["manusia favorit 🤍", "Pedagang", 88], ["Murialdo", "Pedagang", 88], ["Nhidea Dzaffira", "Pedagang", 88], ["Z 41 N", "Pedagang", 88], ["apa aja", "Pedagang", 88], ["incov", "Pedagang", 88], ["Raffi", "Pedagang", 88], ["Bengki Gustiawan", "Pedagang", 88], ["Rangga", "Pedagang", 88], ["Ahmad fajar risky", "Pedagang", 88], ["Aras", "Pedagang", 88], ["lutpit", "Pedagang", 88], ["dede.", "Pedagang", 88], ["Mura_Cloth", "Pedagang", 88], ["Maru", "Pedagang", 88], ["Nadhy Badhol", "Pedagang", 88], ["RIZKI SEPTIYANTO", "Pedagang", 88], ["𝒊𝒕𝒔_𝒛𝒊𝒅𝒏", "Pedagang", 88], ["muhamad agung", "Pedagang", 88], ["ayam bakar", "Pedagang", 88], ["s4answho", "Pedagang", 88], ["Nafis", "Menteri", 88], ["siapahayo", "Warga", 88], ["alid arslan", "Polisi", 88], ["Shinta Eka Febriana", "Warga", 88], ["Asmaulabdullah", "Warga", 88], ["Elfian", "Warga", 88], ["Naura Alexa", "Warga", 88], ["Tyo Muhammad", "Menteri", 88], ["hndo_prtma", "Warga", 88], ["cipoo", "Warga", 88], ["Indra Antanizal", "Pedagang", 88], ["Deni Setiawan", "Menteri", 88], ["RENJA NAKANA", "Warga", 88], ["ily♛", "Warga", 88], ["Atur Nauli", "Warga", 88], ["Ahmad Refai", "Menteri", 88], ["iiki", "Warga", 88], ["Koo", "Menteri", 88], ["HAFIDZ", "Menteri", 88], ["VincesVanGogh", "Warga", 88], ["S. Somantri", "Polisi", 88], ["nurtanto", "Warga", 88], ["Boy Prasetyo", "Warga", 88], ["alv", "Petani", 88], ["ANDALAN Intelligence Academy", "Warga", 88], ["Ryan Martha Hudi", "Warga", 88], ["xxYatzzzxx", "Warga", 88], ["S A N T I", "Warga", 88], ["Abu Ummah Ahmad Ertugrul", "Warga", 88], ["Novita Dian", "Guru", 88], ["Muhammad Aqif Al Fian", "Warga", 88], ["Amal saudu langgara", "Warga", 88], ["Belo Muhammad", "Warga", 88], ["Slamet Setiyadi", "Warga", 88], ["Entah", "Warga", 88], ["Dimas Mahendra Putra", "Warga", 88], ["Ai Risa", "Menteri", 88], ["F4HR1", "Warga", 88], ["Nurdiansyah", "Warga", 88], ["Ihsanan Muftie Labib", "Warga", 88], ["AL ✿", "Warga", 88], ["NPC IG", "Warga", 88], ["Barahama Putra", "Warga", 88], ["Raja tanpa mahkota", "Menteri", 88], ["Gita Firmansah", "Warga", 88], ["Tepusen Gumregah", "Arsitek", 88], ["Ridho Aidil Putra", "Warga", 88], ["barakah", "Guru", 88], ["aica", "Menteri", 88], ["Allirozali.ar", "Warga", 88], ["andri", "Warga", 88], ["Dedy Laila", "Warga", 88], ["sindysella", "Menteri", 88], ["Novi", "Warga", 88], ["4riss80", "Warga", 88], ["Nur Soleh", "Warga", 88], ["Andri Arjuna", "Warga", 88], ["Dwi Hassani", "Warga", 88], ["Nabilaayuuu", "Warga", 88], ["beni hermawan", "Warga", 88], ["mamang resah", "Warga", 88], ["STARTUP MEDIA KEKINIAN !!", "Warga", 88], ["Ryy", "Warga", 88], ["Rizki Draxter", "Warga", 88], ["Woleeesss_257", "Polisi", 88], ["chell", "Warga", 88], ["izam☘", "Guru", 88], ["delaaa", "Petani", 88], ["PISSY ARTSANA PRAMUDITYA", "Warga", 88], ["Isan", "Menteri", 88], ["Dessy Nuraeni", "Dokter", 88], ["Abu Azura", "Menteri", 88], ["Tahu walik", "Warga", 88], ["Arif Al", "Warga", 88], ["Candra Yuniarto", "Menteri", 88], ["SURYANDI", "Warga", 88], ["aGuS", "Warga", 88], ["sanjucahyaadittiarestiamo", "Warga", 88], ["ℌ", "Warga", 88], ["Muhammad Tiyas Arsana", "Warga", 88], ["‫طنيرا رتف انحي‬", "Warga", 88], ["Muhammad Yunus Bar", "Warga", 88], ["Fayakacon", "Warga", 88], ["kepin578", "Warga", 88], ["Dede Zaenudin", "Polisi", 88], ["Keysapaperbus", "Warga", 88], ["Moh.zabir januarsyah pakaya", "Warga", 88], ["PRINCEE MILO", "Warga", 88], ["Deaa Prtwii", "Pedagang", 88], ["Bunga Puspa", "Warga", 88], ["caaa", "Menteri", 88], ["oghaytarleub", "Warga", 88], ["yann", "Menteri", 88], ["lyga triatmaja", "Warga", 88], ["‫نيرأ‬", "Warga", 88], ["Sugiono Ono", "Tukang", 88], ["f4hm1", "Warga", 88], ["Gh I ⁴", "Dokter", 88], ["breif koitoli", "Warga", 88], ["SUPARDI", "Menteri", 88], ["Emir Maulana Gibran", "Warga", 88], ["Judhin Thayeib", "Tukang", 88], ["stevanly", "Warga", 88], ["di4nzz", "Warga", 88], ["Tika Handayani Rambe", "Dokter", 88], ["Fatakuna Raihan Karim", "Warga", 88], ["Hadi", "Warga", 88], ["polondra", "Warga", 88], ["EL", "Menteri", 88], ["Rizah", "Warga", 88], ["Gold Mountain Coffee", "Warga", 88], ["Ramdan Dani", "Menteri", 88], ["Oddi Akbar Asnawie", "Menteri", 88], ["adrina", "Warga", 88], ["Micho Syahputra", "Warga", 88], ["dapong16", "Warga", 88], ["miraa_ ♡", "Warga", 88], ["dmsprtma", "Pengusaha", 88], ["Titan", "Warga", 88], ["Ifansavina Ifan", "Warga", 88], ["Ahmad Sahril", "Warga", 88], ["Ba Pong", "Warga", 88], ["gembul_andii", "Warga", 88], ["LALU", "Pengusaha", 88], ["R Z", "Warga", 88], ["Aann", "Warga", 88], ["yeye", "Warga", 88], ["Martin Gerry", "Warga", 88], ["Abdul Hadi", "Warga", 88], ["secret", "Menteri", 88], ["Romi", "Warga", 88], ["Muhamad Zaini", "Warga", 88], ["Fatur Rohman", "Warga", 88], ["LeoSandy", "Warga", 88], ["Muhammad Fikri", "Warga", 88], ["WFN", "Warga", 88], ["Meetha Runisa", "Warga", 88], ["Nty Nas", "Warga", 88], ["Zaini Suprianto", "Warga", 88], ["koko eko", "Pedagang", 88], ["Sanjaya Priyanto", "Warga", 88], ["Kiki Frastika", "Warga", 88], ["Fadly AL Fauzy Pua", "Menteri", 88], ["genbby", "Warga", 88], ["asepwidayat", "Warga", 88], ["AMBA AKBAR", "Menteri", 88], ["rifky", "Penjahat", 88], ["Sudirgantara", "Menteri", 88], ["Muhammad Malik Amjad", "Menteri", 88], ["yogi", "Tukang", 88], ["MR_KECE_077™", "Warga", 88], ["MuhammadMoldy93", "Warga", 88], ["can", "Warga", 88], ["sobrunjamil_06", "Warga", 88], ["Gung Wah", "Warga", 88], ["sj perajen fc", "Polisi", 88], ["lepi", "Guru", 88], ["Whay??nt", "Tukang", 88], ["Abdul Qadir Ayd", "Guru", 88], ["bukan kejaksaan Agung", "Menteri", 88], ["Rafli Dwi sofyan", "Warga", 88], ["Safri Riansyah", "Warga", 88], ["Rayfan", "Warga", 88], ["desipah & galih", "Warga", 88], ["Ega Morgan", "Warga", 88], ["xyzabc", "Warga", 88], ["‫ىضترم‬", "Warga", 88], ["Wafa Ibnu Walidain", "Penjahat", 88], ["Rizqy Meola X", "Warga", 88], ["Kopi Liong", "Warga", 88], ["‫ناحرف دمحم‬", "Menteri", 88], ["Restu Syah", "Menteri", 88], ["Putra Puja", "Pengusaha", 88], ["Rino77", "Warga", 88], ["I Ketut Wedo Susilo", "Warga", 88], ["NioZio Brigit", "Warga", 88], ["ultramaenn", "Warga", 88], ["MUHAMMAD AKZAN PRATAMA", "Warga", 88], ["Ja'far El Biruni", "Dokter", 88], ["yanzasikx109", "Warga", 88], ["Ataya Dafa Maulana", "Menteri", 88], ["farhan", "Menteri", 88], ["Dieana Die", "Menteri", 88], ["Wahyu Chandra Wijaya", "Guru", 88], ["Muhammad Ziyad", "Warga", 88], ["Bambang Joko Santoso", "Warga", 88], ["fahrurrozi", "Menteri", 88], ["Muhammad Rajib", "Guru", 88], ["Adam Rapp'z", "Menteri", 88], ["Made Sukadana", "Pengusaha", 88], ["shaaa", "Dokter", 88], ["Kiki Irawan", "Warga", 88], ["Roniey Achrezza", "Pedagang", 88], ["Abdillah Aidil Adh'ha", "Menteri", 88], ["Iki", "Penjahat", 88], ["Afif Khoirul Abdi", "Warga", 88], ["ytta", "Dokter", 88], ["Rizki", "Menteri", 88], ["bg rull", "Warga", 88], ["Faiz Ihsan", "Warga", 88], ["WP", "Tukang", 88], ["saullllkimayyy", "Polisi", 88], ["Tami Geovani", "Warga", 88], ["fallstootal", "Warga", 88], ["hidup itu", "Warga", 88], ["Admiral Chabanenko", "Polisi", 88], ["Anjani", "Warga", 88], ["Juni Sy Jsy", "Pedagang", 88], ["Beny Azhar", "Polisi", 88], ["Hening", "Menteri", 88], ["Yoga Dwi Setiawan", "Warga", 88], ["Gerald Kabalessy", "Warga", 88], ["M.Faisal Raihan Thalib", "Menteri", 88], ["Hennn", "Warga", 88], ["apan anak baik!!", "Dokter", 88], ["R", "Warga", 88], ["royan", "Warga", 88], ["aura", "Warga", 88], ["Tyan", "Warga", 88], ["MAUNG33", "Menteri", 88], ["ririndwiputri panggabean", "Warga", 88], ["RUJAB UM", "Menteri", 88], ["akmal codet", "Warga", 88], ["sall", "Menteri", 88], ["napi", "Guru", 88], ["nadin chinta abelsa tambunan", "Warga", 88], ["frecklesrafael", "Warga", 88], ["abd.aziz", "Dokter", 88], ["NdyOxlly", "Warga", 88], ["Agantama", "Tukang", 88], ["Duwan Maea", "Polisi", 88], ["nabilmahesa", "Warga", 88], ["Dewi Rachel", "Dokter", 88], ["r3gar", "Warga", 88], ["Magriza", "Guru", 88], ["Putra Pradana", "Warga", 88], ["edikaherdiawan", "Menteri", 88], ["Adli Azis", "Warga", 88], ["sendiramadhan", "Guru", 88], ["daffayudiank", "Menteri", 88], ["rahmancukicaumania", "Warga", 88], ["har", "Warga", 88], ["Kevinn", "Warga", 88], ["A.m Yass Ah", "Warga", 88], ["Mas Fu'ad", "Warga", 88], ["muckin jack", "Warga", 88], ["djimmy_fernando", "Guru", 88], ["Caeѕar Nurwahyu", "Warga", 88], ["Dani Senna", "Penjahat", 88], ["Andaraa", "Penjahat", 88], ["dedy_virgoboys", "Menteri", 88], ["naaaa", "Dokter", 88], ["Danu Ramadhan", "Warga", 88], ["Salman Alfarizi", "Tukang", 88], ["Dwicky•J", "Tukang", 88], ["pramarap", "Warga", 88], ["Wanp Prtma", "Warga", 88], ["Anasera Arneyva", "Warga", 88], ["eko anak mak ita", "Warga", 88], ["raden jaibrot pangestu", "Pedagang", 88], ["febrid.p28", "Polisi", 88], ["Bang_den", "Polisi", 88], ["Harris Rizki", "Menteri", 88], ["Dekcik Kombih", "Warga", 88], ["Yudha Rahmaddianto", "Warga", 88], ["Novy Suci", "Warga", 88], ["Sekartaji.outdoor", "Warga", 88], ["Muhammad Raihan Fahrezi", "Polisi", 88], ["~~Tokoro~~", "Polisi", 88], ["Rosa Yoku", "Dokter", 88], ["Della Rizkyka", "Pedagang", 88], ["Leni setiani", "Warga", 88], ["Adnan Suzuki Pasangkayu", "Pengusaha", 88], ["Deca Permata Sari", "Dokter", 88], ["meri.y.p.y", "Dokter", 88], ["Dhea Dhea", "Dokter", 88], ["Kan", "Menteri", 88], ["Upa. Saccakumāro Bhustam Tan", "Menteri", 88], ["Ojik Gojan", "Warga", 88], ["LoneLynx", "Warga", 88], ["PSI DPC taman sari", "Warga", 88], ["=¥Dz4k1y4", "Pengusaha", 88], ["yanivelleo", "Warga", 88], ["lugowong", "Warga", 88], ["jo", "Menteri", 88], ["Aidilakbar", "Menteri", 88], ["Apikar", "Warga", 88], ["44yyiii", "Warga", 88], ["woy, caad", "Warga", 88], ["its.azizi", "Warga", 88], ["JstnGIW", "Warga", 88], ["Vxsual_o2", "Menteri", 88], ["siapa", "Warga", 88], ["_dirgatea", "Warga", 88], ["fr1d4snn", "Tukang", 88], ["__alief", "Warga", 88], ["Indonesian Football", "Warga", 88], ["4kyy", "Warga", 88], ["ᵖᵖᵕᵕᵕᵕ ᵕᵕᵖᵖᵕᵕ ᵖᵕᵕᵕᵕᵕᵕ", "Mandor", 88], ["!zah", "Warga", 88], ["Al Huda", "Warga", 88], ["UNTUNG ADA DODI", "Warga", 88], ["DRMN", "Warga", 88], ["pake q bukan pake k", "Pengusaha", 88], ["Jago Prompt", "Warga", 88], ["iyan", "Pengusaha", 88], ["swetiepie", "Warga", 88], ["R I V A L", "Menteri", 88], ["Fasta", "Warga", 88], ["n4zw4_kh0irusyf41702", "Menteri", 88], ["Muhammad Hanafi", "Warga", 88], ["‫ماهلإ يدنأ‬", "Warga", 88], ["Chaira Marhzend", "Warga", 88], ["Dicky Zanuar", "Petani", 88], ["A. Rahmat Al,Qadri M", "Warga", 88], ["Bangeza.s", "Tukang", 88], ["all_ihy'lmddn", "Pengusaha", 88], ["For Rest", "Warga", 88], ["akwil", "Menteri", 88], ["Rapita Said", "Warga", 88], ["dzakimars57", "Warga", 88], ["Senja Desyilla", "Menteri", 88], ["Bambang Arkaswara Wiradipha", "Menteri", 88], ["Casmariyanto", "Warga", 88], ["Mohfatt", "Warga", 88], ["Akram 38", "Warga", 88], ["masssssss", "Warga", 88], ["4l-here", "Warga", 88], ["siapa yah?", "Menteri", 88], ["Taufik Alam Tanta", "Pengusaha", 88], ["Rzqy Azz Yeager", "Warga", 88], ["ahmadsodikin", "Polisi", 88], ["Mr.D", "Guru", 88], ["Alfahrizi", "Warga", 88], ["falaah_amd", "Warga", 88], ["‫ديشرلا‬", "Warga", 88], ["Susiloweni Tenda Decoration", "Warga", 88], ["gwenndut", "Menteri", 88], ["Haris Nainggolan", "Warga", 88], ["Abdurahèém Jr", "Penjahat", 88], ["Bagas_TB56", "Tukang", 88], ["Sikayatul Mukarromah", "Menteri", 88], ["bix¥¥", "Tukang", 88], ["Indahrawasti Simamora", "Warga", 88], ["andre.sp", "Warga", 88], ["Reyhan", "Polisi", 88], ["Bayu Ahwan Muzaqi", "Tukang", 88], ["Dezoel Ox's", "Warga", 88], ["Waone pusam", "Pedagang", 88], ["CORONA-MAN", "Pengusaha", 88], ["Abiel Berton Harianja", "Warga", 88], ["Ahmadnurlutphi_Omeng#16", "Warga", 88], ["ipan paisal", "Warga", 88], ["Ahmad Munif Munfaridi", "Warga", 88], ["Luigi", "Menteri", 88], ["GARASI ROTOM MAINTENANCE", "Warga", 88], ["_COBRA", "Guru", 88], ["Wiliam Teguh", "Tukang", 88], ["Anggres Hanggara III", "Warga", 88], ["PARAKITA LOGISTIK", "Pengusaha", 88], ["Raqilla_12_PP", "Warga", 88], ["Joko Riadi", "Warga", 88], ["makan. Note", "Warga", 88], ["barat", "Polisi", 88], ["lonely blue", "Warga", 88], ["denzzbrengsekk", "Tukang", 88], ["Mamum Otonoites", "Tukang", 88], ["1408Wiii", "Warga", 88], ["Aleaictaesttt", "Warga", 88], ["Mhamd Fadli", "Menteri", 88], ["#serahkuhak", "Warga", 88], ["Adam Hermansyah", "Menteri", 88], ["BagusErvan Nurfa IzZy Shimbee", "Warga", 88], ["A R G A", "Warga", 88], ["Heri Subagja", "Pengusaha", 88], ["Bimo Satrio", "Warga", 88], ["MUHAMMAD AL FARIZ SITORUS", "Menteri", 88], ["Syauqi", "Dokter", 88], ["¹¹", "Polisi", 88], ["laberly", "Warga", 88], ["Wahyu Rifaldy", "Warga", 88], ["A.N. Gozali", "Polisi", 88], ["Samiyah alaydrus", "Pedagang", 88], ["ᴀɴᴅɪ ʏᴀʏᴀᴛ", "Menteri", 88], ["Imam", "Warga", 88], ["Pekii Ollshopp", "Warga", 88], ["Rahmad Sidik", "Warga", 88], ["om luter", "Warga", 88], ["Riyan Saputra", "Murid", 88], ["bg batu ndu", "Warga", 88], ["Randi", "Warga", 88], ["Anggi Setiawan", "Warga", 88], ["BARBER JAKARTA SEKITAR", "Warga", 88], ["asyam_zufarr", "Warga", 88], ["MUHAMMAD SYAHRONI BERUH", "Warga", 88], ["MAGIC", "Warga", 88], ["_001", "Warga", 88], ["‫م‬. ‫يمهاف لازير‬", "Menteri", 88], ["Arrany Wu Kamal", "Warga", 88], ["PonPes Jabal Rahmah", "Warga", 88], ["Taufik Hidayat", "Menteri", 88], ["Kang Den", "Menteri", 88], ["Asdian Kurniawan, a.k.a Iwan", "Warga", 88], ["Aiie Sugesty", "Warga", 88], ["Muhammad Ridho", "Warga", 88], ["Adam Malik Amin", "Warga", 88], ["CImam Ceo Seher Ambasador", "Warga", 88], ["Wendy Tanaka", "Warga", 88], ["rafsanjani", "Pengusaha", 88], ["Branzz", "Warga", 88], ["Erwin Saputra", "Warga", 88], ["fajri_elmandary", "Warga", 88], ["Rian Cahyadi Tanet", "Polisi", 88], ["dede", "Pedagang", 88], ["Vrenz", "Warga", 88], ["Fahmie Avicenna Auratu", "Warga", 88], ["Bagús Rúbén", "Warga", 88], ["LQ", "Menteri", 88], ["kym", "Warga", 88], ["anotherm4nn⚜", "Pedagang", 88], ["Rizal", "Warga", 88], ["ramdan?", "Pengusaha", 88], ["r i k o", "Warga", 88], ["DEBY ALYSHAAA", "Menteri", 88], ["Agus Budiarte", "Warga", 88], ["Abdul Ghoni Muzakki, C.PS., C.PSc", "Warga", 88], ["ғᴇʙʀʏᴀɴ", "Warga", 88], ["Asrun Si Tarzan", "Warga", 88], ["Fahmi khairi", "Menteri", 88], ["kuda___________lumping", "Polisi", 88], ["MAHLUK PELU KECAP !!", "Penjahat", 88], ["Pakdeh redzonerz", "Warga", 88], ["Atika Nuryanti", "Pedagang", 88], ["melann", "Warga", 88], ["Rahman", "Menteri", 88], ["IBNU 87", "Petani", 88], ["Zidan Hazbi", "Warga", 88], ["nyong___ Waipia", "Warga", 88], ["Rud Ex", "Warga", 88], ["Aslan", "Menteri", 88], ["callysta", "Menteri", 88], ["MRA", "Warga", 88], ["Muh Nur", "Warga", 88], ["Dela Puga", "Tukang", 88], ["Dhan_quotes", "Warga", 88], ["faa★", "Dokter", 88], ["mesak_m@rin", "Menteri", 88], ["ejott", "Pengusaha", 88], ["eduard", "Menteri", 88], ["Muhammad Sayyidul Amin", "Warga", 88], ["yogisaepulmalik", "Warga", 88], ["Mas Bud", "Petani", 88], ["ridho", "Warga", 88], ["Bib.z01", "Warga", 88], ["B4j1ngan Sewonderland", "Warga", 88], ["Ardiansyah", "Pengusaha", 88], ["Imron Rosadi", "Warga", 88], ["tedi", "Warga", 88], ["‫הטוד‬", "Menteri", 88], ["Muhammad Ihsan", "Warga", 88], ["Rangga Prayoga", "Guru", 88], ["a fizh", "Guru", 88], ["Riri", "Warga", 88], ["Reva", "Warga", 88], ["Aldiama Rakhmad Oktavian", "Guru", 88], ["M. Fahmi Kamal R", "Warga", 88], ["Zuki.Juki", "Warga", 88], ["erizaldi p", "Warga", 88], ["‫لصاو يزاغ يلع‬", "Pedagang", 88], ["i gede teddy setiadi . SE", "Warga", 88], ["Alvaro Dalcielo", "Warga", 88], ["dinda", "Warga", 88], ["Cau jadi bossa", "Warga", 88], ["Nhi Nhi", "Guru", 88], ["‫ناضمر جناليج دمحم‬", "Warga", 88], ["DHKHA", "Warga", 88], ["G 10", "Warga", 88], ["Rayz", "Polisi", 88], ["ANDRIYANSAH", "Tukang", 88], ["Sisi", "Warga", 88], ["ar_xdil", "Warga", 88], ["_bonkz™", "Polisi", 88], ["15.08", "Guru", 88], ["Arie Wijaya", "Warga", 88], ["illang", "Warga", 88], ["JEHEZKIEL PANSUS", "Polisi", 88], ["ALIKAZD", "Warga", 88], ["HERMAN PWT", "Warga", 88], ["Rij4ldhi", "Warga", 88], ["Mi", "Warga", 88], ["takorr", "Warga", 88], ["PENDEKAR NEON SIGN", "Tukang", 88], ["Diesa Ramadhana", "Warga", 88], ["Rafli Dafinsa Agwan", "Menteri", 88], ["unfol norak", "Warga", 88], ["Luis Figo Tarigan's", "Warga", 88], ["Alamsyah", "Menteri", 88], ["dilzz40", "Tukang", 88], ["ahmad", "Warga", 88], ["Gusman Ahmatyani", "Warga", 88], ["Pandu Wiratama", "Warga", 88], ["Adin Hajar", "Warga", 88], ["perancangsistemtidurkelas", "Menteri", 88], ["Okto Hadu", "Warga", 88], ["Eko Budi Andriyanto", "Dokter", 88], ["Gusti Arie Suhariansyah", "Warga", 88], ["Dijah", "Menteri", 88], ["suci delima", "Warga", 88], ["bay", "Warga", 88], ["jj", "Warga", 88], ["Syakirah Ian", "Menteri", 88], ["AVRILIO DEFIRSTO", "Warga", 88], ["RestuIbuu", "Warga", 88], ["FAHRI RR", "Warga", 88], ["Gerfil", "Warga", 88], ["Naklah Maulana", "Warga", 88], ["Ryo_Screampower", "Menteri", 88], ["Dani", "Warga", 88], ["Brendel", "Warga", 88], ["Mustakin", "Polisi", 88], ["ALDOY", "Menteri", 88], ["nopal_ cihuyyyy", "Warga", 88], ["Arizk", "Warga", 88], ["BANG PRA", "Petani", 88], ["Sandy Maliq", "Warga", 88], ["May", "Warga", 88], ["Muhammad Afandi", "Warga", 88], ["Nourva veve", "Warga", 88], ["rahmad", "Menteri", 88], ["Brian Geming", "Pedagang", 88], ["Alchemical Noir", "Warga", 88], ["dendy Al rahman", "Warga", 88], ["wina mulyani", "Menteri", 88], ["Taher", "Warga", 88], ["Bagoes Amin", "Menteri", 88], ["Alyana.in", "Warga", 88], ["Dinnda", "Warga", 88], ["S4N741", "Menteri", 88], ["putra", "Polisi", 88], ["Dwi Gunawan", "Warga", 88], ["ryzz_4you", "Warga", 88], ["Nuzul Muhammad Al Amin", "Polisi", 88], ["Nazarudin Ilyas", "Warga", 88], ["Muhammad Ghufron", "Menteri", 88], ["Ekoyuda Prastian", "Warga", 88], ["ADY", "Warga", 88], ["ikey tmrno", "Warga", 88], ["Kurnia Sari", "Warga", 88], ["Adakah Celibu", "Warga", 88], ["Moch Gufron Amin", "Warga", 88], ["Hafiz Fahrizuan", "Dokter", 88], ["kandangdomi", "Menteri", 88], ["POLOSJING", "Pedagang", 88], ["arsy Mohammad Yahya", "Guru", 88], ["bisun", "Polisi", 88], ["Oki Akbar Aprizal", "Tukang", 88], ["Muha kilan t", "Warga", 88], ["Ilma Hidayati", "Menteri", 88], ["Uki", "Warga", 88], ["joni marjo", "Warga", 88], ["ATHYZXX_09", "Menteri", 88], ["jasmani", "Warga", 88], ["Yati Wijaya", "Warga", 88], ["fendy mahendra", "Warga", 88], ["Bambang Herdiyansyah", "Warga", 88], ["Aska slenk", "Warga", 88], ["CANDRA", "Tukang", 88], ["Salman Faris Nugraha", "Menteri", 88], ["ayen garut", "Warga", 88], ["Mut Mutiiaa", "Warga", 88], ["Indika Juang Putra", "Guru", 88], ["Franz Wijaya Quebz", "Menteri", 88], ["togar", "Menteri", 88], ["hairilfurqan", "Warga", 88], ["Silitonga1984", "Warga", 88], ["BajugurDor", "Warga", 88], ["radenzainal", "Warga", 88], ["rahmat hardiansyah", "Warga", 88], ["yaa", "Menteri", 88], ["Pether Susanto", "Warga", 88], ["Deny Wahyudi", "Warga", 88], ["agungpratama", "Petani", 88], ["BiwzAnakbaik", "Arsitek", 88], ["Callme Alli", "Menteri", 88], ["Satria Jaya", "Menteri", 88], ["Ki Tambunan", "Menteri", 88], ["18mhmdfahrizi", "Warga", 88], ["Oci", "Guru", 88], ["Fitto", "Warga", 88], ["Re4nn", "Polisi", 88], ["fadlonn", "Warga", 88], ["Edy Hart", "Warga", 88], ["‫ما ِإ‬", "Warga", 88], ["zami", "Warga", 88], ["•°o.•", "Warga", 88], ["Dy vay", "Menteri", 88], ["Dim", "Warga", 88], ["M Padel", "Warga", 88], ["vanel molery", "Pedagang", 88], ["alers", "Warga", 88], ["At Timiki", "Tukang", 88], ["Adam Usman", "Penjahat", 88], ["Dani Ramdiansyah", "Warga", 88], ["Triyan Wahyudi", "Warga", 88], ["Riggi Chicken Lab Indonesia", "Warga", 88], ["Annisa Arianti", "Guru", 88], ["eh _ chika", "Warga", 88], ["azwan wf", "Dokter", 88], ["Sofia Luthfita", "Guru", 88], ["Khoirotu Alkahfi Qurun", "Warga", 88], ["Hapzul Umam Nasution", "Warga", 88], ["PT. Air Minum Bersujud (Perseroda)", "Warga", 88], ["ahid_irul", "Warga", 88], ["NDAA", "Pengusaha", 88], ["C.R Hidayat", "Warga", 88], ["Qi95", "Tukang", 88], ["Dika Mahesa", "Warga", 88], ["Rizwan Al-Banjari", "Warga", 88], ["MOCHAMMAD KHADAFI", "Warga", 88], ["gee", "Warga", 88], ["Junaidi Sulaiman", "Menteri", 88], ["sabraja", "Warga", 88], ["Jihad Farizqon Mubharok", "Menteri", 88], ["Abdus Salam", "Warga", 88], ["alvaro123", "Warga", 88], ["ky", "Warga", 88], ["Yan", "Menteri", 88], ["Zaky", "Warga", 88], ["Perdi Rahul", "Warga", 88], ["elfonda", "Warga", 88], ["D", "Dokter", 88], ["Alfanny", "Warga", 88], ["Rinthiz Dhewanta", "Warga", 88], ["Gundala Poetra Petir", "Polisi", 88], ["Rezki Eka Putra", "Menteri", 88], ["Muh. Fachrizal Sidiq", "Warga", 88], ["andra", "Warga", 88], ["muhammad fahrezi", "Warga", 88], ["Bayu Januar Finata", "Warga", 88], ["Rizal Zulfadhli Aqlan", "Warga", 88], ["khrulazam23", "Warga", 88], ["L Monim", "Warga", 88], ["Lex", "Warga", 88], ["Dimas kurniawan", "Warga", 88], ["Gonto", "Polisi", 88], ["Gak Eroh", "Warga", 88], ["Rijal Miftahuljanah", "Warga", 88], ["Khadafi Akbar", "Warga", 88], ["CairanHijauu115", "Warga", 88], ["Adi M. Munadi", "Warga", 88], ["dika180cm", "Warga", 88], ["Ahmad Fuady Hasibuan", "Warga", 88], ["Rudi Kentunk", "Warga", 88], ["gwm", "Warga", 88], ["Sofil Empi", "Warga", 88], ["Fachry Ilham", "Warga", 88], ["Lina Fitri Fiana", "Menteri", 88], ["ᵓᵓᵓᵓ ᵔᵔℍᵓᵔᵔᵓᵓ", "Warga", 88], ["aya_aja", "Warga", 88], ["Rahmat Fajar, S.Pd., Gr. , S.E.,M.E", "Guru", 88], ["Asmaul Husna", "Warga", 88], ["Arthurr Fahrezi", "Polisi", 88], ["Adaprilgus Adaprilgus", "Menteri", 88], ["Wit Manggo", "Warga", 88], ["Mu‫ح‬ammad Rap‫ اا‬", "Polisi", 88], ["Jody_pratama14", "Polisi", 88], ["Idha Kelink", "Warga", 88], ["A.W", "Pengusaha", 88], ["Rio Sampoernha Putra", "Warga", 88], ["MZNUU", "Warga", 88], ["Jordan Henderson", "Warga", 88], ["rohman_Betta", "Tukang", 88], ["M Iqbal Dwi Pangestu", "Warga", 88], ["MOHAMMAD TOHARI VIRDAUS", "Warga", 88], ["diodesssss", "Warga", 88], ["Syam Allzyab", "Warga", 88], ["Macchaaren,S.Pd", "Penjahat", 88], ["M Afan", "Warga", 88], ["Diyya Ticha Liansyah", "Guru", 88], ["Rangga Alfian", "Warga", 88], ["I Am", "Warga", 88], ["Qodrii", "Menteri", 88], ["tweng kyuh", "Menteri", 88], ["Ardian Awalansyah", "Warga", 88], ["rna_aliya12", "Guru", 88], ["Pratama Irfan", "Menteri", 88], ["PangeranPertama", "Pengusaha", 88], ["Muhamad Raditya Yusup", "Warga", 88], ["Yixī jié", "Menteri", 88], ["Hafidz Assyafi'i", "Warga", 88], ["Nadvansr", "Guru", 88], ["Adipati Jawa", "Warga", 88], ["ANDI REZKY", "Polisi", 88], ["Sudrajat_86", "Warga", 88], ["Irsyad0507000", "Dokter", 88], ["Simatupang", "Warga", 88], ["Sultan Alfathir", "Pengusaha", 88], ["Barlyan Kurdianto", "Warga", 88], ["Alfian Fahrurrozi As Sakho", "Warga", 88], ["Evelyn Angelica Floella", "Guru", 88], ["juan julian", "Warga", 88], ["anboyss", "Polisi", 88], ["Rusdiana Anna", "Warga", 88], ["husna loee", "Warga", 88], ["VIN", "Arsitek", 88], ["Firman Almahmudy", "Warga", 88], ["Muhammad Dony", "Warga", 88], ["_Musafirlokal", "Warga", 88], ["nurti hafidah★", "Warga", 88], ["ariesandjaya", "Warga", 35], ["Madilll", "Warga", 88], ["All Ghani", "Warga", 88], ["Nanda Manurung", "Penjahat", 88], ["UNCLE lebih BIKE", "Warga", 88], ["Wisnurhams", "Polisi", 88], ["Dicky S", "Warga", 35], ["Sri Azmi", "Warga", 88], ["[ ETALASE ] ALPUKAT KOCOK", "Pedagang", 88], ["Taufiiqulhakim", "Menteri", 88], ["Iksan Kendo Desu", "Warga", 88], ["AF", "Dokter", 88], ["M. Ridho Naufal", "Warga", 88], ["A L F I", "Warga", 35], ["Johannes", "Warga", 88], ["sinta mutiara", "Warga", 88], ["Mhd Ical", "Pedagang", 88], ["Hilmi Utiya", "Guru", 88], ["orangimyutttt", "Warga", 88], ["Andar Fuadi", "Warga", 88], ["Rizka Fadila Derwanda", "Warga", 88], ["lin_daa", "Dokter", 88], ["Linda Irvania", "Menteri", 88], ["Fanie Novianthi", "Polisi", 88], ["muhammad_arief", "Penjahat", 88], ["Arip Rachman Hakim", "Warga", 88], ["Muhammad Zihat Abimanyu", "Warga", 88], ["Lantif_Yulianto", "Menteri", 88], ["lifrzqllh", "Warga", 88], ["Anggy Putri", "Murid", 88], ["zeen", "Warga", 88], ["Rona Fermani Suci", "Warga", 88], ["Paidi", "Guru", 88], ["purr", "Penjahat", 88], ["Binar Aldiarto", "Menteri", 88], ["Yayoe Rahayu Talapiu", "Warga", 88], ["MIKO", "Warga", 88], ["Ujiww", "Arsitek", 88], ["1/2", "Warga", 88], ["saptr_22", "Warga", 88], ["Muhammad Farhan", "Warga", 88], ["arun.20", "Penjahat", 88], ["ramaa", "Menteri", 88], ["Indra Jaenudin", "Warga", 88], ["Radiva yusdry", "Polisi", 88], ["Ronaldo Tarigan", "Warga", 88], ["Rifki Ahram", "Warga", 88], ["Ripan AY", "Menteri", 88], ["Farkhan", "Warga", 88], ["ulllll", "Warga", 88], ["Akbarhasibuan", "Warga", 88], ["Gembong Satrio Utomo", "Warga", 88], ["NOVAL HAMZAH", "Penjahat", 88], ["Kopi Dusun Jrakah", "Penjahat", 88], ["Aldi Lan", "Pedagang", 88], ["C handika", "Pengusaha", 88], ["Eva Zuliani", "Dokter", 35], ["I Made Sedana Putra", "Warga", 88], ["Ilham Ricardo", "Warga", 88], ["ZAR", "Warga", 88], ["Sadri Andi Pelang", "Warga", 88], ["Imran", "Polisi", 88], ["Erganda Sejahtra Sitopu", "Warga", 88], ["Dede Yusuf", "Tukang", 88], ["Willi Tobing", "Warga", 88], ["Okta", "Warga", 88], ["shiren zanatulaifa", "Warga", 88], ["Indra Dharmanto", "Menteri", 88], ["lzs aboy ;)", "Polisi", 88], ["Nabi Tgs", "Dokter", 88], ["LnNZz", "Warga", 88], ["PRESIDEN NETIZEN", "Warga", 88], ["Fahrul Pasli Mustafa", "Warga", 88], ["FitraRamadhan", "Menteri", 88], ["Sandy Wijaya", "Menteri", 88], ["PANDU TRIANA", "Warga", 88], ["Krisna Damanik", "Polisi", 88], ["Ray Hans M", "Warga", 88], ["noodledoodlest", "Guru", 88], ["Harry Ramadhan Ozora", "Warga", 88], ["Mhmmd fajar", "Warga", 88], ["second Regi", "Warga", 88], ["Daniel S Manalu", "Menteri", 88], ["James D Angelo", "Warga", 88], ["Pandiangan vandy★†", "Menteri", 88], ["Apon.dapaa", "Warga", 88], ["BINJAI MANIS GEMSTONE", "Warga", 88], ["Surya Wanda Mardana", "Warga", 88], ["citcitcuit", "Warga", 88], ["adoya", "Warga", 88], ["aqilah dwi hardiani", "Menteri", 88], ["Pang Bloon", "Warga", 88], ["Franky Willy", "Warga", 88], ["Dwitya Surya", "Warga", 88], ["Kie Kie", "Menteri", 88], ["Cep Dizza", "Warga", 88], ["Jhspin Sbln", "Menteri", 88], ["yandihidayatullah", "Menteri", 88], ["Fathur Rochim", "Warga", 88], ["nrhfdah", "Warga", 88], ["Diky Mahrezeki", "Warga", 88], ["Steven Evan", "Menteri", 88], ["Ini rangga", "Warga", 88], ["SukaMatcha", "Warga", 88], ["saya akan lawan!", "Warga", 88], ["Dhoni Walker", "Menteri", 88], ["Loker Kalsel-Teng", "Menteri", 88], ["Alshamira.Scania", "Menteri", 88], ["mlnvnd", "Warga", 88], ["Bukhari Syed Albar Harahap", "Warga", 88], ["Yoas Marselhino Silalahi", "Warga", 88], ["JAKA", "Pengusaha", 88], ["ZIDAN EKA MAULANA", "Tukang", 88], ["helikopter1", "Polisi", 88], ["ferdinand", "Warga", 88], ["Muh Putra WayKanan", "Warga", 88], ["SIMON SIRAIT", "Warga", 88], ["eka safitra", "Polisi", 88], ["yuhu", "Warga", 88], ["ajezzskmbg", "Polisi", 88], ["AngelNovila", "Menteri", 88], ["Afinas Finas", "Warga", 88], ["Mr", "Polisi", 88], ["‫كيلاشت تادارإ يفاك‬", "Warga", 88], ["Yadi", "Warga", 88], ["Chairul Al-uluumi", "Warga", 88], ["Marvie climenzo danillo", "Warga", 88], ["Windy Mokoagow", "Menteri", 88], ["lisa amelia", "Murid", 88], ["Rusman Wampelano143", "Murid", 88], ["Lfaslsbla", "Warga", 88], ["i am princess alisya luxury", "Pengusaha", 88], ["Ghost", "Warga", 88], ["GRACE ⚕", "Warga", 88], ["Binsar Banjarnahor", "Warga", 88], ["Andika Ari Setiawan", "Polisi", 88], ["Riowilliam", "Warga", 88], ["Wulan Wahono", "Dokter", 88], ["Wahyu Hermawan", "Warga", 88], ["Salsabilla Vania Abigail", "Warga", 88], ["abian azhary", "Menteri", 88], ["Aufrichtiger Mensch", "Warga", 88], ["Riosatria22", "Menteri", 88], ["panggil aj lipo", "Warga", 88], ["raddiyah", "Warga", 88], ["ray tanggo", "Warga", 88], ["Aris Sitinjak", "Warga", 88], ["Nadine Patiung", "Menteri", 88], ["Anto prima atmaja", "Warga", 88], ["Astronova Soterra", "Menteri", 88], ["SEWA JAS PEKANBARU", "Warga", 88], ["Ridwan Nurhakim", "Menteri", 88], ["Rama", "Polisi", 88], ["Kang.Dan", "Dokter", 88], ["Hasanuddin", "Warga", 88], ["hamba", "Menteri", 88], ["naufal prabowo", "Warga", 88], ["Agus Christiant", "Warga", 88], ["hayo siapa?", "Menteri", 88], ["Rasti ap", "Warga", 88], ["Devzz", "Warga", 88], ["Niko Syahputra", "Penjahat", 88], ["ali akbar", "Warga", 88], ["ERGIN SY", "Menteri", 88], ["Cecep Maulana", "Menteri", 88], ["Indradi Burhan", "Warga", 88], ["Dedek Yuliandika,. MD", "Menteri", 88], ["Fauzan Azmi", "Warga", 88], ["Pardamean Syf", "Menteri", 88], ["kukuh", "Warga", 88], ["Muhammad Faried Iqbal", "Warga", 88], ["Catatan", "Warga", 88], ["Revina", "Warga", 88]]$seed$::jsonb) as hasil_isi_dunia;

-- 5.4  Pindahkan chat lama 7 hari terakhir sekali saja (nama tetap seperti dulu).
do $$
begin
  if to_regclass('public.chat_messages') is not null
     and not exists (select 1 from nz.meta where key = 'chat_lama_dipindah') then
    execute $q$
      insert into nz.chat_messages (user_id, name, text, created_at)
      select null, left(coalesce(username, 'warga'), 30), left(text, 200), created_at
      from public.chat_messages where created_at > now() - interval '7 days' order by created_at
    $q$;
    insert into nz.meta (key, value) values ('chat_lama_dipindah', to_jsonb(now()));
  end if;
exception when others then
  raise notice 'Chat lama tidak dipindahkan: %', sqlerrm;
end $$;

-- 5.4b Pindahkan donatur lama sekali saja (bila tabel public.donations ada di proyek ini).
do $$
begin
  if to_regclass('public.donations') is not null
     and not exists (select 1 from nz.meta where key = 'donasi_lama_dipindah') then
    execute $q$
      insert into nz.donations (donor_name, amount, message, donated_at)
      select left(coalesce(donator_name, 'Donatur'), 40), greatest(coalesce(amount, 0), 0)::bigint, left(message, 200), coalesce(created_at, now())
      from public.donations
    $q$;
    insert into nz.meta (key, value) values ('donasi_lama_dipindah', to_jsonb(now()));
  end if;
exception when others then
  raise notice 'Donatur lama tidak dipindahkan: %', sqlerrm;
end $$;

-- 5.5  pg_cron: tick tiap jam (menit 0) dan bersih-bersih harian 03:10 WIB (20:10 UTC).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      perform cron.unschedule(jobid) from cron.job where jobname in ('netizenia-hourly', 'netizenia-cleanup');
      perform cron.schedule('netizenia-hourly', '0 * * * *', 'select nz.tick_hourly()');
      perform cron.schedule('netizenia-cleanup', '10 20 * * *', 'select nz.cleanup_daily()');
    exception when others then
      raise notice 'Jadwal pg_cron gagal dibuat: %', sqlerrm;
    end;
  else
    raise notice 'pg_cron belum aktif. Aktifkan di Database > Extensions, lalu jalankan file ini lagi.';
  end if;
end $$;

-- 5.6  Pemeriksaan akhir (hanya membaca).
--      Hasil yang benar: SATU baris "OK | v2 terpasang ...".
--      Baris INFO boleh diabaikan. Baris lain = masalah yang harus dikirim ke pengembang.
with masalah as (
select case when pg_get_userbyid(c.relowner) = current_user then 'TABEL TANPA RLS'
            else 'INFO: tabel milik ' || pg_get_userbyid(c.relowner) || ' (biasanya ekstensi), tidak diubah' end as cek,
       n.nspname || '.' || c.relname as objek
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('public', 'nz') and c.relkind = 'r' and not c.relrowsecurity
union all
--      b) Tabel yang masih bisa ditulis anon/authenticated:
select 'TABEL BISA DITULIS WEB', table_schema || '.' || table_name || ' (' || grantee || ' ' || privilege_type || ')'
from information_schema.role_table_grants
where table_schema in ('public', 'nz') and grantee in ('anon', 'authenticated')
  and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
union all
--      c) Fungsi nz yang bisa dipanggil web:
select 'FUNGSI INTERNAL TERBUKA', p.oid::regprocedure::text
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'nz' and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))
union all
--      d) RPC lama berbahaya yang masih bisa dipanggil:
select 'RPC LAMA MASIH TERBUKA', p.oid::regprocedure::text
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('claim_resident', 'opt_out_resident', 'increment_proposal_vote', 'request_claim')
  and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))
)
select * from masalah
union all
select 'OK', 'v2 terpasang: ' || (select count(*) from nz.buildings) || ' bangunan, '
       || (select count(*) from nz.npcs) || ' warga NPC, pg_cron '
       || case when exists (select 1 from pg_extension where extname = 'pg_cron') then 'aktif' else 'BELUM aktif' end
where not exists (select 1 from masalah where cek not like 'INFO%');
