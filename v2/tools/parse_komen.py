# Mengurai teks PDF komentar → daftar (nama, profesi, alasan). Isi komentar TIDAK disimpan.
# Pemakaian: pdftotext -layout komentar.pdf k.txt
# python3 parse_komen.py k.txt seed_lama.json baru.json tinjauan.csv
# Hanya nama dan profesi yang diambil; isi komentar tidak disimpan.
import re, json, sys, unicodedata, collections
src, seedf, out_json, out_csv = sys.argv[1:5]
lines = open(src, encoding='utf-8').read().split('\n')
GARBLE = re.compile('[ἀ-῿�​-‏⁠️]')   # emoji rusak dari font PDF
def clean(s): return re.sub(r'\s+', ' ', GARBLE.sub('', s)).strip()
start = next(k for k, l in enumerate(lines) if 'teks di PDF dari counter' in l and l.startswith('Hari 1'))
comments, cur, section = [], None, ''
NAME = re.compile(r'^[\x0c\s]*([^:]{0,60}?)\s*:(?:\s(.*)|$)')
for raw in lines[start:]:
    l = raw.rstrip()
    if 'teks di PDF dari counter' in l: section = l.split(' — ')[0]; cur = None; continue
    if re.fullmatch(r'[\x0c\s]*—?\s*Df[\w-]{6,}\s*', l) or not l.strip(): continue
    m = NAME.match(l)
    # nama asli maksimal 7 kata; lebih dari itu berarti potongan kalimat yang kebetulan berisi ':'
    if m and len(m.group(1).split()) <= 7 and not m.group(1).strip().startswith('@'):
        cur = {'name': clean(m.group(1)), 'text': m.group(2) or '', 'sec': section}; comments.append(cur)
    elif cur is not None:
        cur['text'] += ' ' + l.strip()
OWN = {'republik netizenia', 'republiknetizenia'}
RULES = [  # urutan = prioritas
  ('Penjahat', r'penjahat|maling|preman|rampok|rampog|copet|begal|koruptor|mafia'),
  ('Dokter',   r'dokter|perawat|bidan|apoteker|suster|nakes'),
  ('Polisi',   r'polisi|polri|kapolri|satpam|keamanan|tentara|\btni\b|jend(e)?ral|damkar|pemadam|paspampres|ajudan|pengawal|intel'),
  ('Guru',     r'\bguru\b|ngajar|mengajar|dosen|kepsek|kepala sekolah|pengajar'),
  ('Murid',    r'\bmurid\b|siswa|pelajar|mahasiswa|anak sekolah'),
  ('Mandor',   r'mandor'),
  ('Tukang',   r'tukang|kuli|buruh bangunan'),
  ('Arsitek',  r'arsitek|insinyur|desainer|perancang'),
  ('Petani',   r'petani|\btani\b|kebun|sawah|ternak|peternak|nelayan|tambak'),
  ('Pengusaha',r'pengusaha|perusahaan|bisnis|investor|\bceo\b|konglomerat|supermarket|pabrik'),
  ('Pedagang', r'dagang|jualan|penjual|jual |warung|kedai|\bpkl\b|toko|kopi|barber|cukur|kuliner'),
  ('Menteri',  r'menteri|mentri|wapres|wakil presiden|\bdpr\b|dprd|gubernur|walikota|wali kota|bupati|kades|kepala desa|camat|kementrian|kementerian|kepala bpn|danantara|wantimpres|pejabat|ketua'),
]
SPAM = re.compile(r'deposit|bonus|slot|gacor|togel|judi|maxwin|\bjp\b|wd\s*\d|link\s*alt', re.I)
def tidy(n):
    n = re.split(r'\s+[|—]\s+', n)[0]              # buang tagline setelah | atau —
    n = re.sub(r'[\s.,_-]+$', '', n).strip()
    return n[:40]
by = collections.OrderedDict(); dropped = collections.Counter()
for c in comments:
    n = tidy(c['name'])
    if not n or n.lower() in OWN: continue
    if not any(ch.isalnum() for ch in n): dropped['tanpa huruf'] += 1; continue
    if SPAM.search(n): dropped['spam'] += 1; continue
    by.setdefault(n.lower(), {'name': n, 'texts': []})['texts'].append(c['text'].lower())
seed = json.load(open(seedf, encoding='utf-8')); seed_keys = {s[0].strip().lower(): s[1] for s in seed}
rows = []; stat = collections.Counter(); dup_seed = 0
for k, v in by.items():
    if k in seed_keys: dup_seed += 1; continue
    prof, why = 'Warga', ''
    for t in v['texts']:
        for p, rx in RULES:
            mm = re.search(r'\b(jadi|jd|jdi|jadiin|jadikan|daftar|lamar|ngelamar|melamar|rekrut|angkat|pekerjakan|sebagai|aku|saya|sy|gw|gue|gua)\b\W+(?:[\w.,]+\W+){0,5}?(' + rx + ')', t)
            if mm: prof, why = p, mm.group(2); break
        if why: break
    health = 35 if any(re.search(r'pasien|berobat|lagi sakit|sedang sakit', t) for t in v['texts']) else 88
    rows.append([v['name'][:60], prof, health, why]); stat[prof] += 1
json.dump([r[:3] for r in rows], open(out_json, 'w', encoding='utf-8'), ensure_ascii=False)
import csv
with open(out_csv, 'w', encoding='utf-8', newline='') as f:
    w = csv.writer(f); w.writerow(['nama', 'profesi', 'kesehatan', 'kata_kunci']); w.writerows(rows)
print('komentar terurai:', len(comments), '| tanpa nama:', sum(1 for c in comments if not c['name']), '| akun sendiri:', sum(1 for c in comments if c['name'].lower() in OWN))
print('nama unik:', len(by), '| sudah ada di benih lama:', dup_seed, '| nama baru:', len(rows))
print('profesi nama baru:', dict(stat.most_common())); print('dibuang:', dict(dropped))
