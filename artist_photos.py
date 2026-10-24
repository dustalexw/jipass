"""Optional artist-name-only Wikipedia lookup; all displayed images are local JPEGs."""
import hashlib,html,json,re,time,subprocess,tempfile,threading
from pathlib import Path
from urllib.parse import urlencode,urlparse,quote
from urllib.request import urlopen,Request

PHOTO_LOCK=threading.Lock()
AGENT='jipass/1.0 (personal local music trivia; artist photo cache)'
HOSTS={'en.wikipedia.org','commons.wikimedia.org','upload.wikimedia.org','thumb.wikimedia.org'}

def artist_id(name):return hashlib.sha256(' '.join(name.casefold().split()).encode()).hexdigest()
def plain(value):return html.unescape(re.sub('<[^>]+>','',str(value))).strip()
def download(url,limit=5*1024*1024):
    if urlparse(url).scheme!='https' or urlparse(url).hostname not in HOSTS:raise ValueError('Unsupported photo host')
    with urlopen(Request(url,headers={'User-Agent':AGENT}),timeout=12) as response:
        if urlparse(response.url).hostname not in HOSTS:raise ValueError('Unsupported photo redirect')
        data=response.read(limit+1)
        if len(data)>limit:raise ValueError('Photo response too large')
        return data

def fetch_json(host,params):return json.loads(download('https://'+host+'/w/api.php?'+urlencode(params),2*1024*1024))

def lookup(name):
    # Exact artist pages first; disambiguate bands and musicians without a broad fuzzy search.
    candidates=[name,name+' (band)',name+' (musician)']
    if ',' in name:candidates.append(name.split(',')[0].strip())
    data=fetch_json('en.wikipedia.org',{'action':'query','format':'json','prop':'pageimages|pageprops','titles':'|'.join(candidates),'piprop':'thumbnail|name','pithumbsize':640,'redirects':1})
    pages=list(data.get('query',{}).get('pages',{}).values())
    for wanted in candidates:
        for page in pages:
            if page.get('title','').casefold()!=wanted.casefold():continue
            props=page.get('pageprops',{});description=props.get('wikibase-shortdesc','').casefold()
            if 'disambiguation' in props or not re.search(r'music|band|singer|rapper|rock|pop|artist|composer|\bdj\b',description):continue
            image=page.get('pageimage');thumb=page.get('thumbnail',{}).get('source')
            if not image or not thumb or not props.get('page_image_free'):continue
            commons=fetch_json('commons.wikimedia.org',{'action':'query','format':'json','prop':'imageinfo','titles':'File:'+image,'iiprop':'extmetadata'})
            entry=next(iter(commons.get('query',{}).get('pages',{}).values()),{})
            meta=(entry.get('imageinfo') or [{}])[0].get('extmetadata',{})
            def value(k):return plain(meta.get(k,{}).get('value',''))
            if not value('LicenseShortName'):continue
            return {'matched_artist':page['title'],'image_url':thumb,'source_url':'https://commons.wikimedia.org/wiki/File:'+quote(image),'author':value('Artist'),'license':value('LicenseShortName'),'license_url':value('LicenseUrl'),'file_title':image}
    return None

def get_photo(name,directory):
    folder=Path(directory);folder.mkdir(parents=True,exist_ok=True)
    key=artist_id(name);image=folder/(key+'.jpg');record=folder/(key+'.json')
    with PHOTO_LOCK:
        if record.exists():
            try:
                saved=json.loads(record.read_text())
                if image.exists() and (saved.get('custom') or saved.get('source_url')):return image
                if time.time()-saved.get('checked',0)<86400:return None
            except (ValueError,OSError):pass
        try:
            result=lookup(name)
            if not result:
                record.write_text(json.dumps({'artist':name,'checked':time.time()}));return None
            raw=download(result.pop('image_url'))
            with tempfile.TemporaryDirectory(dir=folder) as tmp:
                source=Path(tmp)/'source';source.write_bytes(raw);dest=Path(tmp)/'photo.jpg'
                p=subprocess.run(['ffmpeg','-v','error','-i',str(source),'-frames:v','1','-vf','scale=640:640:force_original_aspect_ratio=decrease','-map_metadata','-1','-q:v','3','-y',str(dest)],capture_output=True,timeout=15)
                if p.returncode or not dest.exists():raise ValueError('Photo could not be decoded')
                dest.replace(image)
            result.update(artist=name,checked=time.time());record.write_text(json.dumps(result));return image
        except Exception:
            # Short retry delay for network failures; missing images remain usable monograms.
            record.write_text(json.dumps({'artist':name,'checked':time.time()-86400+300}));return None

def credits(directory):
    result=[]
    for record in Path(directory).glob('*.json'):
        try:
            row=json.loads(record.read_text())
            if row.get('source_url') and record.with_suffix('.jpg').exists():result.append(row)
        except (OSError,ValueError):pass
    return sorted(result,key=lambda r:r['artist'].casefold())
