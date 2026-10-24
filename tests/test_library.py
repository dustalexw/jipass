import unittest,tempfile,sqlite3,os,sys,wave,zlib,struct,subprocess
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import app

def write_png(path,color=b'\xe9\x5e\x35'):
    def chunk(kind,data):return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data)&0xffffffff)
    path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!2I5B',16,16,8,2,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+color*16)*16))+chunk(b'IEND',b''))

def write_wav(path):
    path.parent.mkdir(parents=True,exist_ok=True)
    with wave.open(str(path),'wb') as w:w.setnchannels(1);w.setsampwidth(2);w.setframerate(8000);w.writeframes(b'\0\0'*32000)

class LibraryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name).resolve()
        self.patches=[patch.object(app,'DB',self.root/'db.sqlite3'),patch.object(app,'DATA',self.root/'data'),patch.dict(os.environ,{k:v for k,v in os.environ.items() if k not in ['NEEDLE_MUSIC_DIR','NEEDLE_MUSIC_DIRS']},clear=True)]
        for p in self.patches:p.start()
        app.DATA.mkdir();app.init()
        self.meta=dict(title='Song',artist='Artist',album='Album',genre='Rock',duration=10)
    def tearDown(self):
        for p in reversed(self.patches):p.stop()
        self.temp.cleanup()
    def test_multiple_folders_incremental_overlap_and_remove(self):
        a=self.root/'A';b=self.root/'B';child=a/'Nested';child.mkdir(parents=True);b.mkdir()
        (a/'one.mp3').write_bytes(b'one');(child/'two.mp3').write_bytes(b'two');(b/'three.mp3').write_bytes(b'three')
        with patch.object(app,'probe',return_value=self.meta) as probe:
            app.scan_paths([str(a),str(b),str(child)])
            self.assertEqual(probe.call_count,3)
            with app.conn() as c:self.assertEqual(c.execute('SELECT count(*) FROM tracks').fetchone()[0],3)
            self.assertEqual(len(app.config_paths()),3)
            app.scan_paths(app.config_paths());self.assertEqual(probe.call_count,3)
            self.assertEqual(app.SCAN['processed'],0)
            app.remove_folder(str(a))
            with app.conn() as c:self.assertEqual(c.execute('SELECT count(*) FROM tracks').fetchone()[0],2)
            self.assertTrue((a/'one.mp3').exists())
            app.remove_folder(str(child))
            with app.conn() as c:self.assertEqual(c.execute('SELECT count(*) FROM tracks').fetchone()[0],1)
            self.assertEqual(app.config_paths(),[str(b)])
    def test_offline_folder_keeps_index_and_other_folders_continue(self):
        a=self.root/'A';b=self.root/'B';a.mkdir();b.mkdir();(a/'one.mp3').write_bytes(b'1');(b/'two.mp3').write_bytes(b'2')
        with patch.object(app,'probe',return_value=self.meta):app.scan_paths([str(a),str(b)])
        a.rename(self.root/'offline')
        with patch.object(app,'probe',return_value=self.meta):app.scan_paths([str(a),str(b)])
        with app.conn() as c:self.assertEqual(c.execute('SELECT count(*) FROM tracks').fetchone()[0],2)
        self.assertFalse(app.SCAN['running']);self.assertFalse(app.SCAN['folders'][0]['ok']);self.assertTrue(app.SCAN['folders'][1]['ok'])
    def test_legacy_path_migration_preserves_tracks(self):
        folder=self.root/'old';folder.mkdir();song=folder/'song.mp3';song.write_bytes(b'1')
        with app.conn() as c:
            c.execute("DELETE FROM settings WHERE key='multi_path_migrated'")
            c.execute("INSERT INTO settings VALUES('nas',?)",(str(folder),))
            c.execute("INSERT INTO tracks(path,source) VALUES(?,'nas')",(str(song),))
        app.init();self.assertEqual(app.config_paths(),[str(folder)]);self.assertEqual(app.folder_info()[0]['count'],1)
        app.remove_folder(str(folder));app.init();self.assertEqual(app.config_paths(),[])
    def test_new_overlapping_folder_inherits_existing_track_memberships(self):
        parent=self.root/'parent';child=parent/'child';child.mkdir(parents=True);(child/'song.mp3').write_bytes(b'1')
        with patch.object(app,'probe',return_value=self.meta):app.index_folder(str(parent))
        app.add_folder(str(child));app.remove_folder(str(parent))
        self.assertEqual(app.folder_info()[0]['count'],1)
    def test_environment_paths_json_and_validation(self):
        with patch.dict(os.environ,{'NEEDLE_MUSIC_DIRS':'["/music/A", "/music/B", "/music/A"]'}):self.assertEqual(app.config_paths(),['/music/A','/music/B'])
        with self.assertRaises(ValueError):app.add_folder('relative/folder')
        with patch.dict(os.environ,{'NEEDLE_MUSIC_DIRS':'"not an array"'}):
            with self.assertRaises(ValueError):app.config_paths()
    def test_sidecar_artwork_and_missing_fallback(self):
        song=self.root/'song.wav';write_wav(song)
        self.assertIsNone(app.extract_artwork(str(song)))
        write_png(self.root/'Cover.PNG')
        result=app.extract_artwork(str(song));self.assertIsNotNone(result);self.assertTrue(result.read_bytes().startswith(b'\xff\xd8'))
        self.assertEqual(app.extract_artwork(str(song)),result)
    def test_embedded_artwork(self):
        song=self.root/'song.wav';write_wav(song);cover=self.root/'picture.png';write_png(cover);out=self.root/'embedded.flac'
        subprocess.run(['ffmpeg','-v','error','-i',str(song),'-i',str(cover),'-map','0:a','-map','1:v','-c:a','flac','-c:v','copy','-disposition:v:0','attached_pic','-y',str(out)],capture_output=True,check=True)
        cover.unlink();result=app.extract_artwork(str(out));self.assertIsNotNone(result);self.assertTrue(result.read_bytes().startswith(b'\xff\xd8'))

if __name__=='__main__':unittest.main()
