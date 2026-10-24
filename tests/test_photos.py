import sys,tempfile,unittest,json
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import artist_photos
from test_library import write_png

class PhotoTests(unittest.TestCase):
    def test_cached_photo_is_local_and_works_without_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);png=root/'test.png';write_png(png)
            info={'matched_artist':'The Strokes','image_url':'https://upload.wikimedia.org/example.png','source_url':'https://commons.wikimedia.org/wiki/File:Example.png','author':'Photographer','license':'CC BY-SA 3.0','license_url':'https://creativecommons.org/licenses/by-sa/3.0/'}
            with patch.object(artist_photos,'lookup',return_value=info) as lookup,patch.object(artist_photos,'download',return_value=png.read_bytes()) as download:
                photo=artist_photos.get_photo('The Strokes',root/'photos');self.assertIsNotNone(photo);self.assertTrue(photo.read_bytes().startswith(b'\xff\xd8'))
                self.assertEqual(artist_photos.get_photo('THE STROKES',root/'photos'),photo);self.assertEqual(lookup.call_count,1);self.assertEqual(download.call_count,1)
                self.assertEqual(artist_photos.credits(root/'photos')[0]['author'],'Photographer')
    def test_missing_photo_is_cached_and_unknown_hosts_rejected(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(artist_photos,'lookup',return_value=None) as lookup:
            self.assertIsNone(artist_photos.get_photo('Unmatched artist',tmp));self.assertIsNone(artist_photos.get_photo('Unmatched artist',tmp));self.assertEqual(lookup.call_count,1)
        with self.assertRaises(ValueError):artist_photos.download('https://example.com/photo.png')
    def test_lookup_requires_a_music_page_and_keeps_author_and_license(self):
        pages={'query':{'pages':{'1':{'title':'Example','thumbnail':{'source':'https://upload.wikimedia.org/test.jpg'},'pageimage':'Test.jpg','pageprops':{'wikibase-shortdesc':'English rock band','page_image_free':'Test.jpg'}}}}}
        commons={'query':{'pages':{'2':{'imageinfo':[{'extmetadata':{'Artist':{'value':'<a>Photo Author</a>'},'LicenseShortName':{'value':'CC BY-SA 4.0'},'LicenseUrl':{'value':'https://creativecommons.org/licenses/by-sa/4.0/'}}}]}}}}
        with patch.object(artist_photos,'fetch_json',side_effect=[pages,commons]):
            result=artist_photos.lookup('Example');self.assertEqual(result['author'],'Photo Author');self.assertEqual(result['license'],'CC BY-SA 4.0')
        pages['query']['pages']['1']['pageprops']['wikibase-shortdesc']='Geographic region'
        with patch.object(artist_photos,'fetch_json',return_value=pages) as fetch:self.assertIsNone(artist_photos.lookup('Example'));self.assertEqual(fetch.call_count,1)

class CustomPhotoTests(unittest.TestCase):
    def test_custom_cached_photo_is_never_overwritten_by_online_lookup(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);key=artist_photos.artist_id('The Strokes');photo=root/(key+'.jpg');photo.write_bytes(b'user selected photo')
            (root/(key+'.json')).write_text(json.dumps({'artist':'The Strokes','custom':True,'source_url':''}))
            with patch.object(artist_photos,'lookup') as lookup:
                self.assertEqual(artist_photos.get_photo('The Strokes',root),photo);lookup.assert_not_called()
                self.assertEqual(photo.read_bytes(),b'user selected photo')

if __name__=='__main__':unittest.main()
