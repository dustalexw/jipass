import unittest, tempfile, sys, json, random, wave
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import app

class GameTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.root=Path(self.temp.name)
        self.dbpatch=patch.object(app,'DB',self.root/'test.sqlite3');self.dbpatch.start();app.init()
    def tearDown(self): self.dbpatch.stop();self.temp.cleanup()
    def library(self):
        return [dict(id=i,title=title,artist=artist,genre=genre) for i,(title,artist,genre) in enumerate([('One','A','Rock'),('Two','B','Rock'),('Three','C','Rock'),('Four','D','Rock'),('Five','E','Jazz'),(' one ','A','Jazz')])]
    def test_answers_are_distinct_local_and_same_genre(self):
        tracks=self.library(); opts,answer=app.choices(tracks[0],tracks,'title',random.Random(4))
        self.assertEqual(len(opts),4);self.assertEqual(len({app.normalize(o['label']) for o in opts}),4)
        self.assertEqual({o['label'] for o in opts},{'One','Two','Three','Four'})
        self.assertEqual(next(o['label'] for o in opts if o['id']==answer),'One')
    def test_artist_dedup_and_insufficient_answers(self):
        with self.assertRaises(ValueError):app.choices(self.library()[0],self.library()[:3],'artist')
        opts,_=app.choices(self.library()[0],self.library(),'artist');self.assertEqual(len({o['label'] for o in opts}),4)
    def test_missing_artist_not_an_answer(self):
        t=self.library();t[0]['artist']='Unknown artist'
        with self.assertRaises(ValueError): app.choices(t[0],t,'artist')
    def test_artist_categories_merge_case_and_exclude_missing(self):
        tracks=[{'source':'nas','artist':'Tame Impala'},{'source':'nas','artist':' tame  impala '},{'source':'demo','artist':'Tame Impala'},{'source':'nas','artist':'Unknown artist'}]
        groups=app.artist_categories(tracks)
        self.assertEqual(len(groups),2)
        self.assertEqual(next(g['count'] for g in groups if g['source']=='nas'),2)
    def test_artist_round_filters_tracks_and_requires_titles(self):
        tracks=self.library();pool=app.round_pool(tracks,artist=' a ',kind='title')
        self.assertEqual(len(pool),2);self.assertTrue(all(t['artist']=='A' for t in pool))
        with self.assertRaises(ValueError):app.round_pool(tracks,artist='A',kind='artist')
        with self.assertRaises(ValueError):app.round_pool(tracks,genre='Rock',artist='A')
    def test_artist_round_distractors_prefer_same_artist(self):
        tracks=self.library()
        for t in tracks[:4]:t['artist']='A'
        options,_=app.choices(tracks[0],tracks,'title',random.Random(3))
        self.assertEqual({o['label'] for o in options},{'One','Two','Three','Four'})
    def test_mixed_questions_alternate_and_fallback_without_inventing_artists(self):
        library=self.library();track=library[0]
        self.assertEqual(app.question_kinds(track,library,'mixed'),['title','artist'])
        r={'library':library,'kind':'mixed','mixed_first':'artist','results':[]}
        self.assertEqual(app.choose_question_kind(r,track),'artist')
        r['results'].append({});self.assertEqual(app.choose_question_kind(r,track),'title')
        for i,t in enumerate(library):t['artist']='Artist '+str(i%3)
        self.assertEqual(app.question_kinds(track,library,'mixed'),['title'])
        r['results']=[];self.assertEqual(app.choose_question_kind(r,track),'title')
        with self.assertRaises(ValueError):app.round_pool(library,artist='Artist 0',kind='mixed')
    def test_scoring(self):
        self.assertEqual(app.score(True,0,10),1000);self.assertEqual(app.score(True,5,10),750)
        self.assertEqual(app.score(False,1,10),0);self.assertEqual(app.score(True,10,10),0)
        self.assertEqual(app.score(True,11,10),0)
    def make_round(self,started=None):
        r={'id':'r','profile':'p','q':{'started':started,'duration':10,'resolved':False,'options':[{'id':'a'},{'id':'b'}],'answer':'a','track':{}},'results':[],'length':1,'pending':[]}
        with app.conn() as c:c.execute('INSERT INTO rounds VALUES(?,?,?,NULL)',('r','p',json.dumps(r)))
        return r
    def test_timer_cannot_answer_until_playback_ready(self):
        r=self.make_round()
        with self.assertRaises(ValueError): app.resolve(r,'a',now=100)
        self.assertEqual(r['results'],[])
    def test_timeout_and_duplicate_submission(self):
        r=self.make_round(100);f=app.resolve(r,'a',110)
        self.assertTrue(f['timeout']);self.assertEqual(f['points'],0)
        self.assertEqual(app.resolve(r,'b',111),f);self.assertEqual(len(r['results']),1)
    def test_speed_uses_server_time(self):
        r=self.make_round(100);self.assertEqual(app.resolve(r,'a',102)['points'],900)
    def test_public_question_has_no_answer_or_metadata(self):
        q={'number':1,'options':[],'kind':'title','token':'random','duration':10,'answer':'secret','track':{'title':'secret'},'started':None}
        self.assertEqual(set(app.public_question(q)),{'number','options','kind','token','duration'})
    def test_random_start_stays_inside_track(self):
        for duration in [3,10,20,180]:
            seconds=min(duration,15)
            for _ in range(100):
                start=app.clip_start(duration,seconds);self.assertGreaterEqual(start,0);self.assertLessEqual(start+seconds,duration+.0001)
    def test_incremental_index_and_unavailable_root(self):
        song=self.root/'song.wav';song.write_bytes(b'test')
        meta=dict(title='Song',artist='Artist',album='Album',genre='Rock',duration=20)
        with patch.object(app,'probe',return_value=meta) as probe:
            app.index_folder(str(self.root));self.assertEqual(probe.call_count,1)
            app.index_folder(str(self.root));self.assertEqual(probe.call_count,1);self.assertEqual(app.SCAN['skipped'],1)
            song.write_bytes(b'updated');app.index_folder(str(self.root));self.assertEqual(probe.call_count,2)
            app.index_folder(str(self.root/'offline'))
            with app.conn() as c:self.assertEqual(c.execute('SELECT count(*) FROM tracks').fetchone()[0],1)
            song.unlink();app.index_folder(str(self.root))
            with app.conn() as c:self.assertEqual(c.execute('SELECT count(*) FROM tracks').fetchone()[0],0)
    def test_corrupt_track_and_metadata_fallback(self):
        bad=self.root/'bad.flac';bad.write_bytes(b'not audio');app.index_folder(str(self.root))
        self.assertEqual(len(app.SCAN['errors']),1)
        song=self.root/'untagged.wav'
        with wave.open(str(song),'wb') as w:w.setnchannels(1);w.setsampwidth(2);w.setframerate(8000);w.writeframes(b'\0\0'*32000)
        m=app.probe(song);self.assertEqual(m['title'],'untagged');self.assertEqual(m['artist'],'Unknown artist');self.assertEqual(m['genre'],'Uncategorized')

if __name__=='__main__':unittest.main()
