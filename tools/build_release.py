"""Build a complete installer using pinned, verified upstream dependencies."""
from pathlib import Path
import hashlib,json,urllib.request,zipfile,shutil
ROOT=Path(__file__).resolve().parents[1]
CACHE=ROOT/'.build-cache';DIST=ROOT/'dist'
CACHE.mkdir(exist_ok=True);DIST.mkdir(exist_ok=True)
version=json.loads((ROOT/'manifest.json').read_text(encoding='utf-8-sig'))['version']
prefix='Toybox-Together-v'+version;stage=DIST/prefix
assert stage.parent.resolve()==DIST.resolve()
if stage.exists():shutil.rmtree(stage)
stage.mkdir()
for name in ('app','payload','runtime','manifest.json','Install.cmd','Install.ps1','Remove.cmd','Rollback.cmd','Start.vbs','README.md','VERIFICATION.md','THIRD_PARTY.md'):
 source=ROOT/name;dest=stage/name
 if source.is_dir():shutil.copytree(source,dest,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
 else:shutil.copy2(source,dest)
def dependency(name,url,digest):
 path=CACHE/name
 if not path.exists():
  temp=path.with_suffix('.download');urllib.request.urlretrieve(url,temp)
  if hashlib.sha256(temp.read_bytes()).hexdigest()!=digest:temp.unlink();raise ValueError('Checksum failed: '+name)
  temp.replace(path)
 if hashlib.sha256(path.read_bytes()).hexdigest()!=digest:raise ValueError('Checksum failed: '+name)
 return zipfile.ZipFile(path)
with dependency('ue4ss.zip','https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental/UE4SS_v3.0.1-1161-g6eb3d9bc.zip','938dc9901e6452cad3120280681c93a00ae12df2b259668815a150e221a35563')as z:
 for member in ('dwmapi.dll','ue4ss/UE4SS.dll','ue4ss/Mods/shared/UEHelpers/UEHelpers.lua'):
  out=stage/'payload/loader'/member;out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(z.read(member))
with dependency('python-embed.zip','https://www.python.org/ftp/python/3.13.9/python-3.13.9-embed-amd64.zip','91d828c2da3a029b41699e918674a0cb379c02cf20dab9c501306885f837402a')as z:
 for member in z.namelist():
  if Path(member).name!=member:raise ValueError('Unexpected archive path')
  if member=='python313._pth':continue
  (stage/'runtime'/member).write_bytes(z.read(member))
archive=DIST/(prefix+'.zip')
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=6)as z:
 for p in sorted(stage.rglob('*')):
  if p.is_file():z.write(p,prefix+'/'+p.relative_to(stage).as_posix())
with zipfile.ZipFile(archive)as z:
 if z.testzip()is not None:raise ValueError('Archive failed CRC check')
 if any(n.endswith(('.sav','.dmp','.log','.pyc'))or'ToyboxRoot.lua'in n for n in z.namelist()):raise ValueError('Unexpected local data')
digest=hashlib.sha256(archive.read_bytes()).hexdigest()
(DIST/(archive.name+'.sha256')).write_text(digest+'  '+archive.name+'\n',encoding='ascii')
print(archive);print('SHA256',digest)
