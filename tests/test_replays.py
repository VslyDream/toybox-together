import sys,tempfile,json,copy,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/'app'))
from replays import Replays
from storage import Store,atomic_json
class ReplayTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(dir=ROOT/'tests');self.root=Path(self.temp.name)
  self.replays=Replays(self.root,'build',Store(self.root,'build'))
  self.data=json.loads((ROOT/'tests/fixtures/camera.json').read_text())
 def tearDown(self):self.temp.cleanup()
 def test_invalid_coordinates_and_events(self):
  bad=copy.deepcopy(self.data);bad['tracks'][0]['frames'][0]['p']['X']=float('nan')
  with self.assertRaises(ValueError):self.replays.validate_data(bad)
  bad=copy.deepcopy(self.data);bad['tracks'][0]['events']=[{'t':0,'type':'press','input':99999}]
  with self.assertRaises(ValueError):self.replays.validate_data(bad)
  bad=copy.deepcopy(self.data);bad['tracks'][0]['frames'][1]['t']=-1
  with self.assertRaises(ValueError):self.replays.validate_data(bad)
 def test_hash_and_trash_block_preparation(self):
  m=self.replays.create('camera');source=self.root/'source.json';atomic_json(source,self.data);self.replays.register(m['id'],source)
  bridge=self.root/'bridge';bridge.mkdir();self.replays.prepare(m['id'],bridge)
  self.replays.patch(m['id'],{'deleted':True})
  with self.assertRaises(ValueError):self.replays.prepare(m['id'],bridge)
  self.replays.patch(m['id'],{'deleted':False});(self.replays.folder(m['id'])/'tracks.json').write_text('{}')
  with self.assertRaises(ValueError):self.replays.prepare(m['id'],bridge)
 def test_checkpoints_preserve_track_preferences(self):
  m=self.replays.create('camera');source=self.root/'source.json';atomic_json(source,self.data);self.replays.register(m['id'],source)
  self.replays.patch(m['id'],{'track':1,'enabled':False,'actions':False,'trackName':'My take'})
  after=self.replays.register(m['id'],source)
  self.assertFalse(after['tracks'][0]['enabled']);self.assertFalse(after['tracks'][0]['actions']);self.assertEqual(after['tracks'][0]['name'],'My take')
 def test_path_cannot_escape_gallery(self):
  with self.assertRaises(ValueError):self.replays.folder('../outside')
 def test_movement_modes_and_legacy_player_tracks(self):
  data=json.loads((ROOT/'tests/fixtures/players.json').read_text(encoding='utf-8'))
  self.replays.validate_data(data)
  for key,value in (('movementMode',True),('movementMode',99),('movementMode',1.5),('customMode',float('nan'))):
   bad=copy.deepcopy(data);bad['tracks'][0]['frames'][0][key]=value
   with self.assertRaises(ValueError):self.replays.validate_data(bad)
  for track in data['tracks']:
   for frame in track['frames']:frame.pop('movementMode',None);frame.pop('customMode',None)
  self.replays.validate_data(data)
if __name__=='__main__':unittest.main()
