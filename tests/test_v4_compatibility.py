import sys,unittest,tempfile,json,copy
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/'app'))
from storage import Store,atomic_json,digest
from replays import Replays
class CompatibilityTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(dir=ROOT/'tests');self.root=Path(self.temp.name);self.live=self.root/'live';self.live.mkdir();(self.live/'map.sav').write_bytes(b'GVAS data')
 def tearDown(self):self.temp.cleanup()
 def test_old_snapshot_whitelist_keeps_original_hash_and_checks_files(self):
  old=Store(self.root/'data','old');meta=old.capture(self.live,dict(world='L_ToyKingdom',mode=2,slot='map.sav'))
  updated=Store(self.root/'data','new',['old']);self.assertEqual(updated.validate(old.folder(meta['id']))['gameHash'],'old')
  with self.assertRaises(ValueError):Store(self.root/'data','new').validate(old.folder(meta['id']))
  (old.folder(meta['id'])/'saves/map.sav').write_bytes(b'GVAS corrupt')
  with self.assertRaises(ValueError):updated.restore(meta['id'],self.live)
  self.assertEqual((self.live/'map.sav').read_bytes(),b'GVAS data')
 def test_skykids_roundtrip_and_old_replay_visibility(self):
  old=Store(self.root/'data','old');meta=old.capture(self.live,dict(world='L_SkyKids_Store',mode=0,slot='map.sav'))
  old_replays=Replays(self.root/'data','old',old);replay=old_replays.create('camera')
  updated=Store(self.root/'data','new',['old']);self.assertEqual(updated.validate(old.folder(meta['id']))['world'],'L_SkyKids_Store')
  new_replays=Replays(self.root/'data','new',updated);self.assertEqual(new_replays.list()[0]['id'],replay['id'])
  self.assertEqual(new_replays.read(replay['id'])['gameHash'],'old')
  bad=dict(replay,gameHash='unknown');atomic_json(new_replays.folder(replay['id'])/'replay.json',bad)
  with self.assertRaises(ValueError):new_replays.read(replay['id'])
 def test_skykids_tracks_supported_unknown_map_rejected(self):
  store=Store(self.root/'data','new');replays=Replays(self.root/'data','new',store)
  data=json.loads((ROOT/'tests/fixtures/camera.json').read_text());data['world']='L_SkyKids_Store';replays.validate_data(data)
  data['world']='../../unknown'
  with self.assertRaises(ValueError):replays.validate_data(data)
 def test_stable_toy_definition_validation(self):
  store=Store(self.root/'data','new');replays=Replays(self.root/'data','new',store)
  data=json.loads((ROOT/'tests/fixtures/players.json').read_text(encoding='utf-8'))
  target=next(e['targets'][0] for e in data['tracks'][0]['events']if e['type']=='bulkGrab')
  target['definition']='TS_ItemDefinition /Game/Items/PDA_Toy.PDA_Toy';replays.validate_data(data)
  target['definition']='/Script/Engine.Actor'
  with self.assertRaises(ValueError):replays.validate_data(data)
 def test_old_replay_remap_flag_only_in_prepared_copy(self):
  store=Store(self.root/'data','old');old=Replays(self.root/'data','old',store)
  data=json.loads((ROOT/'tests/fixtures/camera.json').read_text());source=self.root/'source.json';atomic_json(source,data)
  m=old.create('camera');old.register(m['id'],source);original=(old.folder(m['id'])/'tracks.json').read_bytes()
  new=Replays(self.root/'data','new',Store(self.root/'data','new',['old']));bridge=self.root/'bridge';bridge.mkdir();new.prepare(m['id'],bridge)
  self.assertTrue(json.loads((bridge/('replay-'+m['id']+'.json')).read_text(encoding='utf-8'))['legacyDefinitions'])
  self.assertEqual((old.folder(m['id'])/'tracks.json').read_bytes(),original)
if __name__=='__main__':unittest.main()
