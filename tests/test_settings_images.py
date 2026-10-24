import sys,json,threading,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
from urllib.request import Request,urlopen
from urllib.error import HTTPError
from urllib.parse import urlencode
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import app
from test_library import write_png

class SettingsImageTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name).resolve();self.patches=[patch.object(app,'DB',self.root/'db.sqlite'),patch.object(app,'DATA',self.root)]
        for p in self.patches:p.start()
        app.init()
        with app.conn() as c:c.execute("INSERT INTO tracks(path,source,artist,genre) VALUES('/fake/song.mp3','nas','The Strokes','Rock')")
        self.png=self.root/'image.png';write_png(self.png)
    def tearDown(self):
        for p in reversed(self.patches):p.stop()
        self.temp.cleanup()
    def enable(self):
        with app.conn() as c:c.execute("INSERT OR REPLACE INTO settings VALUES('debug_mode','true')")
    def test_upload_guard_validation_and_version_changes(self):
        self.assertEqual(app.app_settings(),{'demo_mode':False,'debug_mode':False})
        with self.assertRaises(PermissionError):app.store_category_image('artist','nas','The Strokes',self.png.read_bytes())
        self.enable();first=app.store_category_image('artist','nas','The Strokes',self.png.read_bytes());write_png(self.png,b'\x30\x70\xe0');second=app.store_category_image('artist','nas','The Strokes',self.png.read_bytes())
        self.assertNotEqual(first['url'],second['url']);self.assertEqual(first['key'],second['key'])
        with self.assertRaises(ValueError):app.store_category_image('artist','nas','Not indexed',self.png.read_bytes())
        with self.assertRaises(ValueError):app.store_category_image('genre','nas','Rock',b'not an image')
        with app.conn() as c:self.assertEqual(c.execute('SELECT count(*) FROM category_images').fetchone()[0],1)
    def test_artist_and_genre_images_persist_and_override_defaults(self):
        self.enable();a=app.store_category_image('artist','nas','The Strokes',self.png.read_bytes());g=app.store_category_image('genre','nas','Rock',self.png.read_bytes());app.init()
        genres=[{'source':'nas','genre':'Rock'}];artists=app.artist_categories([{'source':'nas','artist':'The Strokes'}]);app.decorate_category_images(genres,artists)
        self.assertEqual(genres[0]['image_url'],g['url']);self.assertEqual(artists[0]['image_url'],a['url']);self.assertTrue(artists[0]['image_custom'])
        with app.conn() as c:c.execute("UPDATE settings SET value='false' WHERE key='debug_mode'")
        app.decorate_category_images(genres,artists);self.assertEqual(artists[0]['image_url'],a['url'])
    def test_automatic_artist_url_changes_when_cached_file_is_replaced(self):
        import artist_photos
        folder=self.root/'artist-photos';folder.mkdir();photo=folder/(artist_photos.artist_id('The Strokes')+'.jpg');photo.write_bytes(b'first')
        artists=app.artist_categories([{'source':'nas','artist':'The Strokes'}]);app.decorate_category_images([],artists);first=artists[0]['image_url']
        import os
        os.utime(photo,ns=(photo.stat().st_atime_ns,photo.stat().st_mtime_ns+1000000));app.decorate_category_images([],artists)
        self.assertNotEqual(first,artists[0]['image_url']);self.assertIn('?v=',artists[0]['image_url'])
    def test_http_upload_and_reset_are_rejected_when_debug_off(self):
        server=app.ThreadingHTTPServer(('127.0.0.1',0),app.Handler)
        with patch.object(app,'PORT',server.server_port):
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start();base=f'http://127.0.0.1:{server.server_port}'
            def post(endpoint,data):
                with urlopen(Request(base+'/api/'+endpoint,json.dumps(data).encode(),{'Content-Type':'application/json'})) as r:return json.load(r)
            def upload():return urlopen(Request(base+'/api/category-image?'+urlencode({'kind':'genre','source':'nas','name':'Rock'}),self.png.read_bytes(),{'Content-Type':'image/png'}))
            try:
                with self.assertRaises(HTTPError) as denied:upload()
                self.assertEqual(denied.exception.code,403)
                saved=post('settings',{'debug_mode':True,'demo_mode':True});self.assertTrue(saved['settings']['debug_mode']);self.assertTrue(saved['settings']['demo_mode'])
                with upload() as r:saved_image=json.load(r)
                with urlopen(base+saved_image['url']) as r:self.assertEqual(r.headers['Cache-Control'],'private, no-cache');self.assertTrue(r.read().startswith(b'\xff\xd8'))
                post('settings',{'debug_mode':False})
                with self.assertRaises(HTTPError) as denied:upload()
                self.assertEqual(denied.exception.code,403)
                with self.assertRaises(HTTPError):post('category-image/remove',{'kind':'genre','source':'nas','name':'Rock'})
                post('settings',{'debug_mode':True});post('category-image/remove',{'kind':'genre','source':'nas','name':'Rock'})
                with self.assertRaises(HTTPError):urlopen(base+saved_image['url'])
            finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':unittest.main()
