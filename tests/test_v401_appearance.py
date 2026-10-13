import sys,unittest,tempfile,json,copy
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/'app'))
from replays import Replays
from storage import Store
class AppearanceTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(dir=ROOT/'tests');self.root=Path(self.temp.name)
  self.replays=Replays(self.root,'build',Store(self.root,'build'))
  self.data=json.loads((ROOT/'tests/fixtures/appearance.json').read_text(encoding='utf-8'))
 def tearDown(self):self.temp.cleanup()
 def test_current_appearance_and_legacy_format_accepted(self):
  self.replays.validate_data(self.data)
  data=copy.deepcopy(self.data);data['tracks'][0]['appearance']={'PresetIndex':0,'SkinColorIndex':1,'SlotMeshIndices':[0,1],'SlotColorIndices':[1,2]}
  self.replays.validate_data(data)
 def test_asset_types_and_paths_rejected_before_game_load(self):
  for field,value in [('Body','TS_CharacterBodyDefinition /Game/../bad'),('Body','Class /Script/Engine.Actor'),('Parts',[{'Part':'TS_ItemDefinition /Game/Toy','ColorIndex':0}]),('Parts',[{'Part':None,'ColorIndex':1.5}]),('SkinColorIndex',False)]:
   data=copy.deepcopy(self.data);data['tracks'][0]['appearance'][field]=value
   with self.subTest(field=field,value=value):
    with self.assertRaises(ValueError):self.replays.validate_data(data)
if __name__=='__main__':unittest.main()
