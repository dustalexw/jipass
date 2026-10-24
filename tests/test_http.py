"""Exercise real HTTP requests, SQLite persistence, and FFmpeg clip delivery."""
import unittest, tempfile, threading, json, wave, sys
from pathlib import Path
from unittest.mock import patch
from urllib.request import urlopen, Request
from urllib.error import HTTPError
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import app
from test_library import write_png

class HTTPTests(unittest.TestCase):
    def test_round_lifecycle(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();clips=root/'clips';clips.mkdir()
            with patch.object(app,'DB',root/'test.db'),patch.object(app,'CLIPS',clips):
                app.init();write_png(root/'cover.png')
                for i in range(6):
                    path=root/f'{i}.wav'
                    with wave.open(str(path),'wb') as w:w.setnchannels(1);w.setsampwidth(2);w.setframerate(8000);w.writeframes(b'\0\0'*32000)
                    with app.conn() as c:c.execute('INSERT INTO tracks(path,source,title,artist,album,genre,duration) VALUES(?,?,?,?,?,?,?)',(str(path),'nas',f'Title {i}',f'Artist {i}','Album','Rock',4))
                server=app.ThreadingHTTPServer(('127.0.0.1',0),app.Handler)
                with patch.object(app,'PORT',server.server_port):
                    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
                    base=f'http://127.0.0.1:{server.server_port}'
                    def post(endpoint,data):
                        with urlopen(Request(base+'/api/'+endpoint,json.dumps(data).encode(),{'Content-Type':'application/json'})) as r:return json.load(r)
                    try:
                        player=post('profile',{'name':'QA'})
                        r=post('round',{'profile':player['id'],'source':'nas','kind':'artist','length':5,'seconds':5})
                        rid=r['id'];q=r['question'];tokens=set();correct=0
                        for i in range(5):
                            self.assertNotIn('answer',q);self.assertNotIn('track',q);self.assertNotIn('artwork',q);
                            with self.assertRaises(HTTPError):urlopen(base+'/artwork/'+q['token'])
                            self.assertNotIn(q['token'],tokens);tokens.add(q['token'])
                            with urlopen(base+'/audio/'+q['token']) as clip:self.assertTrue(clip.read().startswith(b'RIFF'))
                            with self.assertRaises(HTTPError):post('answer',{'id':rid,'token':q['token'],'option':q['options'][0]['id']})
                            ready=post('ready',{'id':rid,'token':q['token']});again=post('ready',{'id':rid,'token':q['token']});self.assertLessEqual(again['remaining'],ready['remaining'])
                            early=post('answer',{'id':rid,'token':q['token']});self.assertIn('remaining',early);self.assertNotIn('answer',early)
                            state=app.get_round(rid)
                            if i==4:
                                state['q']['started']-=10;app.save_round(state)
                            answer=post('answer',{'id':rid,'token':q['token'],'option':state['q']['answer']})
                            with urlopen(base+answer['feedback']['artwork']) as image:self.assertTrue(image.read().startswith(b'\xff\xd8'))
                            repeat=post('answer',{'id':rid,'token':q['token'],'option':q['options'][0]['id']});self.assertEqual(answer,repeat)
                            if i<4:
                                self.assertTrue(answer['feedback']['correct']);correct+=answer['feedback']['points'];q=post('next',{'id':rid})['question']
                            else:
                                self.assertTrue(answer['feedback']['timeout']);self.assertEqual(answer['feedback']['points'],0)
                                self.assertEqual(answer['summary']['count'],5);self.assertEqual(answer['summary']['accuracy'],80);self.assertEqual(answer['summary']['score'],correct)
                        with urlopen(base+'/api/library') as response:library=json.load(response)
                        self.assertEqual(len(library['history']),1);self.assertEqual(library['history'][0]['score'],correct)
                        self.assertEqual(len(app.get_round(rid)['results']),5)
                        mixed=post('round',{'profile':player['id'],'source':'nas','kind':'mixed','genre':'Rock','length':5,'seconds':5})
                        first=mixed['question']['kind'];self.assertIn(first,['artist','title']);self.assertEqual(mixed['notice'],'')
                        mq=mixed['question'];post('ready',{'id':mixed['id'],'token':mq['token']});post('answer',{'id':mixed['id'],'token':mq['token'],'option':mq['options'][0]['id']})
                        second=post('next',{'id':mixed['id']})['question']['kind'];self.assertNotEqual(first,second)
                        post('folders/add',{'path':str(root)})
                        with urlopen(base+'/api/library') as response:folders=json.load(response)['folders']
                        self.assertEqual(folders[0]['count'],6)
                        post('folders/remove',{'path':str(root)})
                        # Reinsert fixture metadata for the artist filtering check.
                        for i in range(6):
                            with app.conn() as c:c.execute('INSERT INTO tracks(id,path,source,title,artist,album,genre,duration) VALUES(?,?,?,?,?,?,?,?)',(i+1,str(root/f'{i}.wav'),'nas',f'Title {i}',f'Artist {i}','Album','Rock',4))
                        # An artist category must choose only that artist's songs.
                        with app.conn() as c:c.execute("UPDATE tracks SET artist='Featured Artist' WHERE id<=5")
                        with urlopen(base+'/api/library') as response:artists=json.load(response)['artist_categories']
                        self.assertEqual(next(a['count'] for a in artists if a['artist']=='Featured Artist'),5)
                        selected=post('round',{'profile':player['id'],'source':'nas','artist':'featured artist','kind':'title','length':5,'seconds':5})
                        artist_round=app.get_round(selected['id'])
                        self.assertEqual(artist_round['q']['track']['artist'],'Featured Artist')
                        self.assertTrue(all(t['artist']=='Featured Artist' for t in artist_round['pending']))
                        with self.assertRaises(HTTPError):post('round',{'profile':player['id'],'source':'nas','artist':'Featured Artist','kind':'artist','length':5,'seconds':5})
                        fallback=post('round',{'profile':player['id'],'source':'nas','kind':'mixed','length':5,'seconds':5})
                        self.assertEqual(fallback['question']['kind'],'title');self.assertIn('four distinct artists',fallback['notice'])
                        with self.assertRaises(HTTPError):
                            urlopen(Request(base+'/api/profile',b'{"name":"Bad origin"}',{'Origin':'https://example.com','Content-Type':'application/json'}))
                    finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':unittest.main()
