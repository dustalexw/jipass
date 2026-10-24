#!/usr/bin/env python3
"""jipass — a local music quiz. Python 3.9+, FFmpeg, no Python dependencies."""
import os, json, sqlite3, subprocess, random, secrets, time, threading, math, wave, struct, shutil, hashlib, tempfile
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import artist_photos

ROOT = Path(__file__).resolve().parent
DATA = Path(os.environ.get('NEEDLE_DATA', ROOT / 'data')).resolve()
DATA.mkdir(parents=True, exist_ok=True)
CLIPS = DATA / 'clips'; CLIPS.mkdir(exist_ok=True)
DB = DATA / 'needle.sqlite3'
LOCK = threading.RLock()
ART_LOCK = threading.Lock()
SCAN = {'running': False, 'message': 'Ready to scan', 'processed': 0, 'skipped': 0, 'errors': []}
FORMATS = {'.mp3','.flac','.m4a','.aac','.ogg','.opus','.wav','.aiff','.aif','.wma','.alac','.ape','.mp4'}

def conn():
    c = sqlite3.connect(DB); c.row_factory = sqlite3.Row
    return c

def init():
    with conn() as c:
        c.executescript('''CREATE TABLE IF NOT EXISTS tracks(id INTEGER PRIMARY KEY, path TEXT UNIQUE, source TEXT, size INTEGER, mtime INTEGER, title TEXT, artist TEXT, album TEXT, genre TEXT, duration REAL);
        CREATE TABLE IF NOT EXISTS profiles(id TEXT PRIMARY KEY, name TEXT);
        CREATE TABLE IF NOT EXISTS rounds(id TEXT PRIMARY KEY, profile TEXT, state TEXT, finished REAL);
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS library_roots(path TEXT PRIMARY KEY, status TEXT DEFAULT 'Not scanned', last_scan REAL);
        CREATE TABLE IF NOT EXISTS track_roots(path TEXT, root TEXT, PRIMARY KEY(path,root));
        CREATE TABLE IF NOT EXISTS artwork_refs(token TEXT PRIMARY KEY, path TEXT, created REAL);
        CREATE TABLE IF NOT EXISTS category_images(key TEXT PRIMARY KEY, kind TEXT, source TEXT, name TEXT, file TEXT, version TEXT);''')

        # One-time migration preserves the existing path and indexed music.
        if not c.execute("SELECT 1 FROM settings WHERE key='multi_path_migrated'").fetchone():
            old=c.execute("SELECT value FROM settings WHERE key='nas'").fetchone()
            if old and old[0]:
                folder=str(Path(old[0]).expanduser().resolve())
                c.execute('INSERT OR IGNORE INTO library_roots(path) VALUES(?)',(folder,))
                for row in c.execute("SELECT path FROM tracks WHERE source='nas'").fetchall():
                    if Path(row['path']).is_relative_to(Path(folder)):
                        c.execute('INSERT OR IGNORE INTO track_roots VALUES(?,?)',(row['path'],folder))
            c.execute("INSERT INTO settings VALUES('multi_path_migrated','1')")

def app_settings():
    with conn() as c: values={r['key']:r['value'] for r in c.execute("SELECT key,value FROM settings WHERE key IN ('debug_mode','demo_mode')")}
    return {key:values.get(key)=='true' for key in ['debug_mode','demo_mode']}

def category_image_key(kind,source,name):
    return hashlib.sha256((kind+'\0'+source+'\0'+normalize(name)).encode()).hexdigest()

def require_category(kind,source,name):
    if kind not in ['artist','genre'] or source not in ['nas','demo'] or not isinstance(name,str):raise ValueError('Invalid image category')
    with conn() as c:known=[r[0] for r in c.execute('SELECT DISTINCT '+kind+' FROM tracks WHERE source=?',(source,))]
    if not any(normalize(n)==normalize(name) for n in known):raise ValueError('This category is not in your library')

def category_image_url(row):return '/category-image/'+row['key']+'?v='+row['version']

def decorate_category_images(genres,artists):
    with conn() as c: images={r['key']:dict(r) for r in c.execute('SELECT * FROM category_images')}
    for kind,groups in [('genre',genres),('artist',artists)]:
        for group in groups:
            custom=images.get(category_image_key(kind,group['source'],group[kind]))
            group['image_custom']=bool(custom)
            if custom:group['image_url']=category_image_url(custom)
            elif kind=='artist' and group.get('photo_id'):
                cached=DATA/'artist-photos'/(group['photo_id']+'.jpg')
                version=str(cached.stat().st_mtime_ns) if cached.exists() else '0'
                group['image_url']='/artist-photo/'+group['photo_id']+'?v='+version

def store_category_image(kind,source,name,raw):
    if not app_settings()['debug_mode']:raise PermissionError("Enable BIG CHIEF'M (Debug) mode in Settings to upload images")
    require_category(kind,source,name)
    if not raw or len(raw)>8*1024*1024:raise ValueError('Choose an image smaller than 8 MB')
    if not (raw.startswith(b'\xff\xd8\xff') or raw.startswith(b'\x89PNG\r\n\x1a\n') or (raw[:4]==b'RIFF' and raw[8:12]==b'WEBP')):raise ValueError('Choose a JPEG, PNG, or WebP image')
    folder=DATA/'category-images';folder.mkdir(parents=True,exist_ok=True)
    key=category_image_key(kind,source,name)
    with tempfile.TemporaryDirectory(dir=folder) as tmp:
        image=Path(tmp)/'upload';image.write_bytes(raw)
        p=subprocess.run(['ffprobe','-v','error','-select_streams','v:0','-show_entries','stream=width,height','-of','json',str(image)],capture_output=True,timeout=15)
        streams=json.loads(p.stdout or b'{}').get('streams',[])
        if p.returncode or not streams:raise ValueError('This image could not be read')
        width,height=streams[0].get('width',0),streams[0].get('height',0)
        if width<=0 or height<=0 or width*height>40000000:raise ValueError('Choose an image below 40 megapixels')
        output=Path(tmp)/'image.jpg'
        p=subprocess.run(['ffmpeg','-nostdin','-v','error','-i',str(image),'-frames:v','1','-vf','scale=1200:1200:force_original_aspect_ratio=decrease','-map_metadata','-1','-q:v','2','-y',str(output)],capture_output=True,timeout=20)
        if p.returncode or not output.exists():raise ValueError('This image could not be decoded')
        version=hashlib.sha256(output.read_bytes()).hexdigest()[:20];filename=key+'-'+version+'.jpg';output.replace(folder/filename)
    with conn() as c:c.execute('INSERT OR REPLACE INTO category_images VALUES(?,?,?,?,?,?)',(key,kind,source,name,filename,version))
    return {'key':key,'version':version,'url':'/category-image/'+key+'?v='+version}

def normalize_folder(folder):
    if not isinstance(folder,str) or not folder.strip(): raise ValueError('Enter a mounted music folder path')
    path=Path(folder.strip()).expanduser()
    if not path.is_absolute(): raise ValueError('Use an absolute mounted folder path, for example /Volumes/Music')
    return str(path.resolve())

def environment_paths():
    raw=os.environ.get('NEEDLE_MUSIC_DIRS')
    if raw is not None:
        paths=json.loads(raw)
        if not isinstance(paths,list) or not all(isinstance(p,str) for p in paths): raise ValueError('NEEDLE_MUSIC_DIRS must be a JSON array of folder paths')
        return list(dict.fromkeys(normalize_folder(p) for p in paths))
    single=os.environ.get('NEEDLE_MUSIC_DIR')
    return [normalize_folder(single)] if single else None

def config_paths():
    override=environment_paths()
    if override is not None: return override
    with conn() as c: return [r[0] for r in c.execute('SELECT path FROM library_roots ORDER BY rowid')]

def config():
    paths=config_paths()
    return paths[0] if paths else ''

def add_folder(folder):
    path=normalize_folder(folder)
    with conn() as c:
        if c.execute('SELECT count(*) FROM library_roots').fetchone()[0]>=50 and not c.execute('SELECT 1 FROM library_roots WHERE path=?',(path,)).fetchone(): raise ValueError('A maximum of 50 music folders is supported')
        c.execute('INSERT OR IGNORE INTO library_roots(path) VALUES(?)',(path,))
        for row in c.execute("SELECT path FROM tracks WHERE source='nas'").fetchall():
            if Path(row['path']).is_relative_to(Path(path)):
                c.execute('INSERT OR IGNORE INTO track_roots VALUES(?,?)',(row['path'],path))
    return path

def remove_folder(folder):
    path=normalize_folder(folder)
    with conn() as c:
        c.execute('DELETE FROM library_roots WHERE path=?',(path,))
        c.execute('DELETE FROM track_roots WHERE root=?',(path,))
        c.execute("DELETE FROM tracks WHERE source='nas' AND NOT EXISTS(SELECT 1 FROM track_roots WHERE track_roots.path=tracks.path)")

def folder_info():
    result=[]
    with conn() as c:
        for path in config_paths():
            row=c.execute('SELECT status,last_scan FROM library_roots WHERE path=?',(path,)).fetchone()
            count=c.execute('SELECT count(*) FROM track_roots JOIN tracks USING(path) WHERE root=?',(path,)).fetchone()[0]
            result.append({'path':path,'count':count,'status':row['status'] if row else 'Not scanned','last_scan':row['last_scan'] if row else None})
    return result

def probe(path):
    p = subprocess.run(['ffprobe','-v','error','-show_format','-show_streams','-of','json',str(path)], capture_output=True, timeout=25)
    if p.returncode: raise ValueError('Cannot decode audio metadata')
    d=json.loads(p.stdout); f=d.get('format',{}); streams=[s for s in d.get('streams',[]) if s.get('codec_type')=='audio']
    if not streams: raise ValueError('No audio stream')
    tags={k.lower():str(v).strip() for block in [streams[0].get('tags',{}),f.get('tags',{})] for k,v in block.items()}
    duration=float(f.get('duration') or streams[0].get('duration') or 0)
    if duration < 3 or not math.isfinite(duration): raise ValueError('Track is too short or has unknown duration')
    return dict(title=tags.get('title') or path.stem, artist=tags.get('artist') or tags.get('album_artist') or 'Unknown artist', album=tags.get('album') or 'Unknown album', genre=tags.get('genre') or 'Uncategorized', duration=duration)

def scan_one(folder, source='nas'):
    base=Path(folder).expanduser().resolve(); root=str(base)
    updated=unchanged=0; failures=[]; complete=False
    try:
        if not base.is_dir(): raise ValueError('Folder unavailable. Mount the NAS and check this path.')
        if source=='nas': add_folder(root)
        seen=set()
        def walk_error(e): raise e
        for directory, _, files in os.walk(base, onerror=walk_error):
            for name in files:
                path=Path(directory)/name
                if path.suffix.lower() not in FORMATS: continue
                canonical=path.resolve()
                if not canonical.is_relative_to(base): continue
                key=str(canonical); seen.add(key)
                try:
                    st=canonical.stat()
                    with conn() as c: old=c.execute('SELECT size,mtime FROM tracks WHERE path=?',(key,)).fetchone()
                    if old and old['size']==st.st_size and old['mtime']==st.st_mtime_ns:
                        unchanged+=1; SCAN['skipped']+=1
                    else:
                        meta=probe(canonical)
                        with conn() as c:
                            c.execute('INSERT OR REPLACE INTO tracks(path,source,size,mtime,title,artist,album,genre,duration) VALUES(?,?,?,?,?,?,?,?,?)',(key,source,st.st_size,st.st_mtime_ns,*[meta[k] for k in ['title','artist','album','genre','duration']]))
                        updated+=1; SCAN['processed']+=1
                    if source=='nas':
                        with conn() as c: c.execute('INSERT OR IGNORE INTO track_roots VALUES(?,?)',(key,root))
                except OSError as e:
                    # A disappearing mount/file is not evidence that metadata is corrupt.
                    if len(failures)<30: failures.append(f'{name}: {e}')
                except Exception as e:
                    with conn() as c:
                        c.execute('DELETE FROM tracks WHERE path=?',(key,));c.execute('DELETE FROM track_roots WHERE path=?',(key,))
                    if len(failures)<30: failures.append(f'{name}: {e}')
        with conn() as c:
            # Remove only this root's stale memberships after a complete walk.
            if source=='nas':
                for row in c.execute('SELECT path FROM track_roots WHERE root=?',(root,)).fetchall():
                    if row['path'] not in seen:
                        c.execute('DELETE FROM track_roots WHERE path=? AND root=?',(row['path'],root))
                        c.execute("DELETE FROM tracks WHERE path=? AND source='nas' AND NOT EXISTS(SELECT 1 FROM track_roots WHERE path=?)",(row['path'],row['path']))
        complete=True
        message=f'{updated} updated · {unchanged} unchanged'+(f' · {len(failures)} file issues' if failures else '')
    except Exception as e: message=str(e)
    if source=='nas':
        with conn() as c:
            c.execute('INSERT OR IGNORE INTO library_roots(path) VALUES(?)',(root,))
            c.execute('UPDATE library_roots SET status=?,last_scan=? WHERE path=?',(message,time.time(),root))
    SCAN['errors'].extend((root+' / '+e) for e in failures[:max(0,30-len(SCAN['errors']))])
    return {'path':root,'ok':complete,'message':message}

def scan_paths(folders, source='nas'):
    SCAN.update(running=True,message='Reading music folders…',processed=0,skipped=0,errors=[],folders=[])
    try:
        for i,folder in enumerate(folders):
            SCAN['message']=f'Scanning folder {i+1} of {len(folders)}: {folder}'
            SCAN['folders'].append(scan_one(folder,source))
        unavailable=sum(not f['ok'] for f in SCAN['folders'])
        SCAN['message']=f"Scan complete · {SCAN['processed']} updated · {SCAN['skipped']} unchanged"+(f' · {unavailable} unavailable folder(s)' if unavailable else '')
    finally: SCAN['running']=False

def index_folder(folder, source='nas'):
    scan_paths([folder],source)

def normalize(s): return ' '.join(s.casefold().split())

def artist_categories(tracks):
    groups={}
    for t in tracks:
        name=(t['artist'] or '').strip(); key=normalize(name)
        if not key or key=='unknown artist': continue
        group=groups.setdefault((t['source'],key),{'source':t['source'],'artist':name,'count':0})
        group['count']+=1
    result=sorted(groups.values(),key=lambda x:normalize(x['artist']))
    for group in result:
        if group['source']=='nas':group['photo_id']=artist_photos.artist_id(group['artist'])
    return result

def round_pool(library, genre='', artist='', kind='title'):
    if artist and genre: raise ValueError('Choose either an artist or a genre')
    if artist and kind!='title': raise ValueError('Artist categories use song-title questions; the artist is already known.')
    return [t for t in library if (not genre or t['genre']==genre) and (not artist or normalize(t['artist'])==normalize(artist))]

def choices(track, library, kind, rng=random):
    correct=track[kind]
    if not correct or (kind=='artist' and correct=='Unknown artist'): raise ValueError('Missing answer metadata')
    used={normalize(correct)}; same_artist=[]; same=[]; other=[]
    for t in library:
        value=t[kind]; key=normalize(value)
        if not value or key in used or (kind=='artist' and value=='Unknown artist'): continue
        # A title shared by a different artist is still the same answer label, deduped above.
        used.add(key)
        bucket=same_artist if kind=='title' and normalize(track['artist'])!='unknown artist' and normalize(t['artist'])==normalize(track['artist']) else same if normalize(t['genre'])==normalize(track['genre']) else other
        bucket.append(value)
    rng.shuffle(same_artist); rng.shuffle(same); rng.shuffle(other)
    wrong=(same_artist+same+other)[:3]
    if len(wrong)<3: raise ValueError('Need at least four distinct '+('artists' if kind=='artist' else 'song titles')+' in the library')
    options=[{'id':secrets.token_urlsafe(9),'label':v} for v in [correct]+wrong]
    answer=options[0]['id']; rng.shuffle(options)
    return options,answer

def question_kinds(track,library,mode):
    valid=[]
    for kind in (['title','artist'] if mode=='mixed' else [mode]):
        try:choices(track,library,kind);valid.append(kind)
        except ValueError:pass
    return valid

def choose_question_kind(round_state,track):
    valid=question_kinds(track,round_state['library'],round_state['kind'])
    if not valid:raise ValueError('No unambiguous answers available')
    if round_state['kind']!='mixed':return valid[0]
    first=round_state.get('mixed_first','title')
    desired=first if len(round_state['results'])%2==0 else ('artist' if first=='title' else 'title')
    return desired if desired in valid else valid[0]

def score(correct, elapsed, limit):
    return 0 if not correct or elapsed>=limit else 500+round(500*max(0,1-max(0,elapsed)/limit))

def clip_start(duration, seconds, rng=random):
    # Keep clear of intros/outros when there is room, otherwise use the entire safe range.
    margin= min(10, max(0,(duration-seconds)/4))
    return rng.uniform(margin,max(margin,duration-seconds-margin))

def demo():
    folder=DATA/'demo'; folder.mkdir(exist_ok=True)
    titles=['Velvet Satellite','Afterglow Avenue','Paper Moons','Electric Orchard','Slow Horizon','Midnight Current','Amber Circuit','Sunday Static','Blue Carousel','Copper Rain','Soft Geometry','Neon Letters','Golden Hour','Distant Rooms','City of Ferns','Plum Weather','Small Hours','Parallel Gardens']
    artists=['Luna Relay','The Daybreaks','Moss & Mercury','Glass District','June Atlas','Night Assembly']
    for i,title in enumerate(titles):
        path=folder/(title+'.wav')
        if not path.exists():
            # Original generated melodic sketches. No external audio or metadata.
            rate=16000; length=24; notes=[0,3,7,10,7,3,5,2]; buf=bytearray()
            for n in range(rate*length):
                t=n/rate; beat=t*(2+i%3*.25); phase=beat%1; note=notes[(int(beat)+i)%len(notes)]
                freq=130.81*2**((note+i%5)/12)
                env=min(1,phase*25)*math.exp(-phase*3)
                value=.24*env*(math.sin(2*math.pi*freq*t)+.3*math.sin(4*math.pi*freq*t))+.08*math.sin(2*math.pi*65.4*t)*math.exp(-(beat%1)*10)
                buf.extend(struct.pack('<h',int(max(-1,min(1,value))*32767)))
            with wave.open(str(path),'wb') as w: w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(buf)
        st=path.stat()
        with conn() as c:
            c.execute('INSERT OR IGNORE INTO tracks(path,source,size,mtime,title,artist,album,genre,duration) VALUES(?,?,?,?,?,?,?,?,?)',(str(path),'demo',st.st_size,st.st_mtime_ns,title,artists[i%6],'jipass · Original sketches',['Electronic','Indie','Jazz'][i%3],24))

def get_round(rid):
    with conn() as c: row=c.execute('SELECT state FROM rounds WHERE id=?',(rid,)).fetchone()
    if not row: raise ValueError('Round not found')
    return json.loads(row[0])

def save_round(r):
    with conn() as c: c.execute('UPDATE rounds SET state=?,finished=? WHERE id=?',(json.dumps(r),time.time() if r.get('done') else None,r['id']))

def public_question(q):
    return {k:q[k] for k in ['number','options','kind','token','duration']}

def prepare(r):
    # Bound temporary storage during long-running listening sessions.
    for old in CLIPS.glob('*.wav'):
        try:
            if time.time()-old.stat().st_mtime > 86400: old.unlink()
        except OSError: pass
    while r['pending']:
        t=r['pending'].pop(0)
        try:
            kind=choose_question_kind(r,t)
            options,answer=choices(t,r['library'],kind)
            token=secrets.token_urlsafe(24); dest=CLIPS/(token+'.wav'); seconds=min(r['seconds'],t['duration'])
            p=subprocess.run(['ffmpeg','-v','error','-ss',str(clip_start(t['duration'],seconds)),'-i',t['path'],'-t',str(seconds),'-vn','-map_metadata','-1','-ac','1','-ar','22050','-c:a','pcm_s16le','-y',str(dest)],capture_output=True,timeout=40)
            if p.returncode or not dest.exists() or dest.stat().st_size<100: raise ValueError('Track cannot be decoded')
            r['q']={'number':len(r['results'])+1,'options':options,'answer':answer,'kind':kind,'token':token,'duration':seconds,'track':{k:t[k] for k in ['title','artist','album','genre']},'track_path':t['path'],'started':None,'created':time.time(),'resolved':False}
            save_round(r); return public_question(r['q'])
        except Exception: r['unplayable']+=1
    raise ValueError('No more playable tracks. Rescan the library or choose a different category.')

def resolve(r, option, now=None):
    q=r['q']; now=time.time() if now is None else now
    if q['resolved']: return q['feedback']
    if q['started'] is None: raise ValueError('Play the clip before answering')
    elapsed=max(0,now-q['started']); timed=elapsed>=q['duration']; correct=not timed and option==q['answer']
    if option is not None and option not in [o['id'] for o in q['options']]: raise ValueError('Invalid answer')
    feedback={'correct':correct,'timeout':timed,'points':score(correct,elapsed,q['duration']),'elapsed':min(elapsed,q['duration']),'answer':q['answer'],'track':q['track'],'kind':q.get('kind')}
    if q.get('track_path'): feedback['artwork']=artwork_reference(q['track_path'])
    q.update(resolved=True,feedback=feedback); r['results'].append(feedback)
    if len(r['results'])>=r['length'] or not r['pending']: r['done']=True
    save_round(r); return feedback

def summary(r):
    results=r['results']; total=sum(x['points'] for x in results)
    with conn() as c: previous=c.execute('SELECT state FROM rounds WHERE profile=? AND finished IS NOT NULL',(r['profile'],)).fetchall()
    # Personal best is comparable: same source, question type, round length, and clip duration.
    best=total
    for row in previous:
        old=json.loads(row[0])
        if all(old.get(k)==r.get(k) for k in ['source','kind','length','seconds']): best=max(best,sum(x['points'] for x in old['results']))
    return {'score':total,'accuracy':round(100*sum(x['correct'] for x in results)/max(1,len(results))),'average':round(sum(x['elapsed'] for x in results)/max(1,len(results)),2),'best':best,'count':len(results),'skipped':r['unplayable'],'results':results}

def artwork_reference(path):
    token=secrets.token_urlsafe(24)
    with conn() as c: c.execute('INSERT INTO artwork_refs VALUES(?,?,?)',(token,path,time.time()))
    return '/artwork/'+token

def extract_artwork(path):
    """Read only embedded art or a conventional image in the same album directory."""
    audio=Path(path)
    if not audio.is_file(): return None
    cover=None
    try:
        images={p.name.casefold():p for p in audio.parent.iterdir() if p.is_file() and p.suffix.lower() in {'.jpg','.jpeg','.png','.webp'}}
        for stem in ['cover','folder','front','album','artwork']:
            for ext in ['.jpg','.jpeg','.png','.webp']:
                candidate=images.get(stem+ext)
                if candidate and candidate.resolve().parent==audio.resolve().parent and candidate.stat().st_size<=20*1024*1024:
                    cover=candidate;break
            if cover:break
        stat=audio.stat(); signature=f'{audio}:{stat.st_size}:{stat.st_mtime_ns}'
        if cover:
            cs=cover.stat();signature+=f':{cover}:{cs.st_size}:{cs.st_mtime_ns}'
        cache=DATA/'artwork';cache.mkdir(exist_ok=True)
        dest=cache/(hashlib.sha256(signature.encode()).hexdigest()+'.jpg')
        with ART_LOCK:
            if dest.exists():return dest
            # Ask for attached-picture streams so video frames never masquerade as cover art.
            probe_result=subprocess.run(['ffprobe','-v','error','-select_streams','v','-show_entries','stream=index:stream_disposition=attached_pic','-of','json',str(audio)],capture_output=True,timeout=15)
            streams=json.loads(probe_result.stdout or b'{}').get('streams',[])
            attached=next((v for v in streams if v.get('disposition',{}).get('attached_pic')),None)
            inputs=[(audio,str(attached['index']))] if attached else []
            if cover: inputs.append((cover,'0:v:0'))
            for image,index in inputs:
                mapping='0:'+index if image==audio else index
                p=subprocess.run(['ffmpeg','-v','error','-i',str(image),'-map',mapping,'-frames:v','1','-vf','scale=600:600:force_original_aspect_ratio=decrease','-map_metadata','-1','-q:v','3','-y',str(dest)],capture_output=True,timeout=20)
                if p.returncode==0 and dest.exists() and dest.stat().st_size>0:return dest
                dest.unlink(missing_ok=True)
    except Exception: return None
    return None

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def send_json(self,data,status=200):
        b=json.dumps(data).encode(); self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Cache-Control','no-store'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.headers.get('Host','') not in [f'127.0.0.1:{PORT}',f'localhost:{PORT}']:
            return self.send_json({'error':'Local requests only'},403)
        path=urlparse(self.path).path
        try:
            if path=='/api/library':
                with conn() as c:
                    tracks=[dict(r) for r in c.execute('SELECT source,genre,count(*) AS count,count(DISTINCT title) AS titles,count(DISTINCT CASE WHEN artist != \'Unknown artist\' THEN artist END) AS artists FROM tracks GROUP BY source,genre')]
                    artists=artist_categories([dict(r) for r in c.execute('SELECT source,artist FROM tracks')])
                    profiles=[dict(r) for r in c.execute('SELECT * FROM profiles')]
                    history=[]
                    for row in c.execute('SELECT id,profile,state FROM rounds WHERE finished IS NOT NULL ORDER BY finished DESC LIMIT 20'):
                        r=json.loads(row['state']); history.append({'profile':row['profile'],'source':r['source'],'score':sum(x['points'] for x in r['results']),'count':len(r['results']),'accuracy':round(sum(x['correct'] for x in r['results'])*100/max(1,len(r['results'])))})
                decorate_category_images(tracks,artists)
                return self.send_json({'api_version':5,'categories':tracks,'artist_categories':artists,'profiles':profiles,'history':history,'nas':config(),'folders':folder_info(),'folders_locked':environment_paths() is not None,'scan':SCAN,'settings':app_settings()})
            if path.startswith('/category-image/'):
                key=path.split('/')[-1]
                with conn() as c:row=c.execute('SELECT file FROM category_images WHERE key=?',(key,)).fetchone()
                f=DATA/'category-images'/row['file'] if row else None
                if not f or not f.is_file():return self.send_json({'error':'Image not found'},404)
                b=f.read_bytes();self.send_response(200);self.send_header('Content-Type','image/jpeg');self.send_header('Content-Length',str(len(b)));self.send_header('Cache-Control','private, no-cache');self.send_header('X-Content-Type-Options','nosniff');self.end_headers();self.wfile.write(b);return
            if path=='/api/photo-credits':return self.send_json({'credits':artist_photos.credits(DATA/'artist-photos')})
            if path.startswith('/artist-photo/'):
                key=path.split('/')[-1]
                if len(key)!=64 or any(ch not in '0123456789abcdef' for ch in key):return self.send_json({'error':'Not found'},404)
                with conn() as c:names=[r[0] for r in c.execute("SELECT DISTINCT artist FROM tracks WHERE source='nas'")]
                name=next((n for n in names if artist_photos.artist_id(n)==key),None)
                f=artist_photos.get_photo(name,DATA/'artist-photos') if name else None
                if not f:return self.send_json({'error':'Artist photo unavailable'},404)
                b=f.read_bytes();self.send_response(200);self.send_header('Content-Type','image/jpeg');self.send_header('Content-Length',str(len(b)));self.send_header('Cache-Control','private, no-cache');self.send_header('X-Content-Type-Options','nosniff');self.end_headers();self.wfile.write(b);return
            if path.startswith('/artwork/'):

                token=path.split('/')[-1]
                with conn() as c: ref=c.execute('SELECT path FROM artwork_refs WHERE token=?',(token,)).fetchone()
                f=extract_artwork(ref['path']) if ref else None
                if not f:return self.send_json({'error':'No local album artwork'},404)
                b=f.read_bytes();self.send_response(200);self.send_header('Content-Type','image/jpeg');self.send_header('Content-Length',str(len(b)));self.send_header('Cache-Control','private, max-age=86400');self.send_header('X-Content-Type-Options','nosniff');self.end_headers();self.wfile.write(b);return
            if path.startswith('/audio/'):

                token=path.split('/')[-1]
                if not token or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in token): return self.send_json({'error':'Not found'},404)
                f=CLIPS/(token+'.wav')
            else: f=ROOT/'static'/({'/':'index.html'}.get(path,path.lstrip('/')))
            if not f.resolve().is_relative_to((CLIPS if path.startswith('/audio/') else ROOT/'static').resolve()) or not f.is_file(): return self.send_json({'error':'Not found'},404)
            b=f.read_bytes(); self.send_response(200); self.send_header('Content-Type', {'.html':'text/html','.js':'text/javascript','.css':'text/css','.wav':'audio/wav'}.get(f.suffix,'application/octet-stream')); self.send_header('Content-Length',str(len(b))); self.send_header('Cache-Control','no-store'); self.send_header('X-Content-Type-Options','nosniff'); self.end_headers(); self.wfile.write(b)
        except Exception as e: self.send_json({'error':str(e)},400)
    def do_POST(self):
        # Loopback-only service, reject cross-origin writes (including DNS rebinding).
        host=self.headers.get('Host','')
        if host not in [f'127.0.0.1:{PORT}',f'localhost:{PORT}'] or self.headers.get('Origin',f'http://{host}')!=f'http://{host}': return self.send_json({'error':'Local requests only'},403)
        try:
            size=int(self.headers.get('Content-Length',0))
            if urlparse(self.path).path=='/api/category-image':
                with LOCK:
                    if not app_settings()['debug_mode']:return self.send_json({'error':"Enable BIG CHIEF'M (Debug) mode in Settings to upload images"},403)
                    if size<=0 or size>8*1024*1024:return self.send_json({'error':'Choose an image smaller than 8 MB'},413)
                    if self.headers.get('Content-Type','').split(';')[0] not in ['image/jpeg','image/png','image/webp']:return self.send_json({'error':'Choose a JPEG, PNG, or WebP image'},415)
                    args=parse_qs(urlparse(self.path).query)
                    result=store_category_image(args.get('kind',[''])[0],args.get('source',[''])[0],args.get('name',[''])[0],self.rfile.read(size))
                    return self.send_json(result)
            if size>16384: raise ValueError('Request too large')
            d=json.loads(self.rfile.read(size) or b'{}'); path=urlparse(self.path).path
            with LOCK:
                if path=='/api/settings':
                    if not isinstance(d,dict) or not d or any(k not in ['debug_mode','demo_mode'] or not isinstance(v,bool) for k,v in d.items()):raise ValueError('Invalid settings')
                    with conn() as c:
                        for k,v in d.items():c.execute('INSERT OR REPLACE INTO settings VALUES(?,?)',(k,'true' if v else 'false'))
                    return self.send_json({'settings':app_settings()})
                if path=='/api/category-image/remove':
                    if not app_settings()['debug_mode']:return self.send_json({'error':"Enable BIG CHIEF'M (Debug) mode first"},403)
                    require_category(d.get('kind'),d.get('source'),d.get('name'))
                    key=category_image_key(d['kind'],d['source'],d['name'])
                    with conn() as c:c.execute('DELETE FROM category_images WHERE key=?',(key,))
                    return self.send_json({'ok':True})
                if path=='/api/profile':
                    name=str(d.get('name','')).strip()[:30]
                    if not name: raise ValueError('Enter a player name')
                    pid=secrets.token_urlsafe(12)
                    with conn() as c: c.execute('INSERT INTO profiles VALUES(?,?)',(pid,name))
                    return self.send_json({'id':pid,'name':name})
                if path in ['/api/folders/add','/api/folders/remove']:
                    if SCAN['running']:raise ValueError('Wait for the current scan to finish before changing folders')
                    if environment_paths() is not None:raise ValueError('Folders are configured through environment variables; update them and restart')
                    folder=d.get('path','')
                    if path.endswith('/add'):add_folder(folder)
                    else:remove_folder(folder)
                    return self.send_json({'folders':folder_info()})
                if path=='/api/scan':
                    if SCAN['running']: raise ValueError('A scan is already running')
                    requested=d.get('path')
                    folders=config_paths()
                    if requested:
                        requested=normalize_folder(requested)
                        if environment_paths() is not None and requested not in folders:raise ValueError('This folder is not in the environment configuration')
                        if requested not in folders:add_folder(requested)
                        folders=[requested]
                    if not folders: raise ValueError('Add at least one mounted music folder')
                    SCAN['running']=True; threading.Thread(target=scan_paths,args=(folders,),daemon=True).start()
                    return self.send_json({'ok':True})
                if path=='/api/round':
                    source=d.get('source','demo'); kind=d.get('kind','title'); length=int(d.get('length',10)); seconds=int(d.get('seconds',10)); genre=d.get('genre',''); artist=d.get('artist','')
                    if source not in ['demo','nas'] or kind not in ['title','artist','mixed'] or length not in [5,10,15] or seconds not in [5,10,15]: raise ValueError('Invalid round settings')
                    with conn() as c:
                        if not c.execute('SELECT id FROM profiles WHERE id=?',(d.get('profile'),)).fetchone(): raise ValueError('Choose a player first')
                        library=[dict(x) for x in c.execute('SELECT * FROM tracks WHERE source=?',(source,))]
                    pool=round_pool(library,genre,artist,kind)
                    eligible=[]
                    for t in pool:
                        if question_kinds(t,library,kind):eligible.append(t)
                    if len(eligible)<length: raise ValueError(f'This selection has {len(eligible)} eligible tracks; choose a shorter round or Mixed library. Four distinct answer labels are required across the library.')
                    mixed_types=set(k for t in eligible for k in question_kinds(t,library,kind)) if kind=='mixed' else set()
                    notice=('Mixed mode: only song-title questions are available. Add at least four distinct artists to enable artist questions.' if mixed_types=={'title'} else 'Mixed mode: only artist questions are available. Add at least four distinct song titles to enable song questions.' if mixed_types=={'artist'} else '')
                    random.shuffle(eligible); rid=secrets.token_urlsafe(24)
                    r={'id':rid,'source':source,'profile':d['profile'],'kind':kind,'length':length,'seconds':seconds,'genre':genre,'artist':artist,'library':library,'pending':eligible,'results':[],'done':False,'unplayable':0,'mixed_first':random.choice(['title','artist']),'notice':notice}
                    with conn() as c: c.execute('INSERT INTO rounds VALUES(?,?,?,NULL)',(rid,d['profile'],json.dumps(r)))
                    return self.send_json({'id':rid,'question':prepare(r),'notice':notice})
                r=get_round(d.get('id','')); q=r['q']
                if path=='/api/ready':
                    if d.get('token')!=q['token'] or q['resolved']: raise ValueError('Question no longer active')
                    if q['started'] is None: q['started']=time.time(); save_round(r)
                    remaining=max(0,q['duration']-(time.time()-q['started']))
                    return self.send_json({'remaining':remaining})
                if path=='/api/answer':
                    if d.get('token')!=q['token']: raise ValueError('Question no longer active')
                    if d.get('option') is None and q['started'] is not None and time.time()<q['started']+q['duration']: return self.send_json({'remaining':q['started']+q['duration']-time.time()})
                    result=resolve(r,d.get('option'))
                    return self.send_json({'feedback':result,'done':r['done'],'summary':summary(r) if r['done'] else None})
                if path=='/api/next':
                    if not q['resolved'] or r['done']: raise ValueError('Finish the current question first')
                    try: question=prepare(r)
                    except ValueError:
                        r['done']=True; save_round(r)
                        return self.send_json({'summary':summary(r)})
                    return self.send_json({'question':question})
                raise ValueError('Unknown request')
        except Exception as e: self.send_json({'error':str(e)},400)

PORT=int(os.environ.get('NEEDLE_PORT','8765'))
if __name__=='__main__':
    if not shutil.which('ffmpeg') or not shutil.which('ffprobe'): raise SystemExit('Install FFmpeg (including ffprobe) first. See README.md.')
    init(); print('Preparing local demo library…',flush=True); demo()
    # Remove transient clips from prior runs; interrupted rounds are retained but not resumed.
    for f in CLIPS.glob('*.wav'): f.unlink()
    server=ThreadingHTTPServer(('127.0.0.1',PORT),Handler)
    print(f'jipass is ready at http://127.0.0.1:{PORT}',flush=True)
    server.serve_forever()
