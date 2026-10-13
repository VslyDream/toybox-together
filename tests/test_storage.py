import sys,unittest,tempfile,io,zipfile,json
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'app'))
from storage import Store, atomic_json
from unittest.mock import patch
class SnapshotTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent); self.root=Path(self.temp.name);self.live=self.root/'live';self.live.mkdir();(self.live/'map.sav').write_bytes(b'GVAS original');self.store=Store(self.root/'data','build')
  self.meta=dict(world='L_ToyKingdom',mode=0,name='test',playthrough='test',source='current',position={'X':1,'Y':2,'Z':3},rotation={'Pitch':0,'Yaw':45,'Roll':0})
 def tearDown(self):self.temp.cleanup()
 def test_corruption_cannot_replace_current(self):
  m=self.store.capture(self.live,self.meta);(self.live/'map.sav').write_bytes(b'GVAS current');(self.store.folder(m['id'])/'saves'/'map.sav').write_bytes(b'corrupt')
  with self.assertRaises(ValueError):self.store.restore(m['id'],self.live)
  self.assertEqual((self.live/'map.sav').read_bytes(),b'GVAS current')
 def test_restore_retains_backup_and_roundtrip(self):
  m=self.store.capture(self.live,self.meta);(self.live/'map.sav').write_bytes(b'GVAS current');_,backup=self.store.restore(m['id'],self.live)
  self.assertEqual((Path(backup)/'map.sav').read_bytes(),b'GVAS current');self.assertEqual((self.live/'map.sav').read_bytes(),b'GVAS original')
  imported=self.store.import_zip(self.store.export(m['id']).read_bytes());self.assertNotEqual(imported['id'],m['id']);self.store.validate(self.store.folder(imported['id']))
 def test_trash_and_rename(self):
  m=self.store.capture(self.live,self.meta);self.store.patch(m['id'],deleted=True,name='new');self.assertFalse(self.store.list());self.assertEqual(self.store.list(True)[0]['name'],'new');self.store.patch(m['id'],deleted=False);self.assertEqual(len(self.store.list()),1)
 def test_zip_traversal_and_wrong_version(self):
  b=io.BytesIO()
  with zipfile.ZipFile(b,'w') as z:z.writestr('../outside.sav',b'GVAS x')
  with self.assertRaises(ValueError):self.store.import_zip(b.getvalue())
  m=self.store.capture(self.live,self.meta);self.store.version='different'
  with self.assertRaises(ValueError):self.store.restore(m['id'],self.live)
 def test_denied_replacement_keeps_previous_and_cleans_temp(self):
  p=self.root/'input.json';atomic_json(p,{'seq':1})
  with patch('storage.os.replace',side_effect=PermissionError('reader holds file')):
   with self.assertRaises(PermissionError):atomic_json(p,{'seq':2})
  self.assertEqual(json.loads(p.read_text()),{'seq':1})
  self.assertEqual(list(self.root.glob('input.json.*.tmp')),[])
if __name__=='__main__':unittest.main()

