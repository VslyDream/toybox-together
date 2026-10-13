"""Transactional snapshot storage. No game paths or personal files in the package."""
from pathlib import Path
import hashlib, json, os, shutil, tempfile, time, uuid, zipfile
import math

def atomic_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        temp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
        os.replace(temp, path)
    finally:
        # A game reader can briefly deny replacement on Windows. Do not leave
        # one temporary file behind for each skipped input frame.
        temp.unlink(missing_ok=True)

def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024), b''): h.update(chunk)
    return h.hexdigest()

class Store:
    def __init__(self, root, version, compatible_hashes=()):
        self.root=Path(root); self.version=version; self.compatible_hashes=frozenset(compatible_hashes)
        self.snapshots=self.root/'snapshots'; self.backups=self.root/'backups'
        self.snapshots.mkdir(parents=True, exist_ok=True)
        self.backups.mkdir(parents=True, exist_ok=True)

    def folder(self, sid):
        if not isinstance(sid,str) or len(sid)!=32 or any(x not in '0123456789abcdef' for x in sid):
            raise ValueError('Некорректный идентификатор снапшота.')
        return self.snapshots/sid

    def read(self, sid):
        p=self.folder(sid)
        data=json.loads((p/'snapshot.json').read_text(encoding='utf-8'))
        if data.get('id')!=sid: raise ValueError('Повреждённые данные снапшота.')
        return data

    def list(self, deleted=False):
        result=[]
        for p in self.snapshots.iterdir():
            if not p.is_dir() or p.name.startswith('.'): continue
            try:
                m=self.read(p.name)
                if not m.get('internal') and bool(m.get('deleted'))==deleted: result.append(m)
            except (OSError, ValueError): pass
        return sorted(result,key=lambda x:x['created'], reverse=True)

    def validate(self, folder):
        folder=Path(folder)
        m=json.loads((folder/'snapshot.json').read_text(encoding='utf-8'))
        if m.get('gameHash') not in {self.version,*self.compatible_hashes}: raise ValueError('Снапшот создан для другой версии игры.')
        if m.get('world') not in ('L_ToyKingdom','L_Shopping_mall','L_SkyKids_Store') or m.get('mode') not in (0,1,2):
            raise ValueError('В снапшоте нет поддерживаемой карты и режима.')
        for field, axes in [('position',('X','Y','Z')),('rotation',('Pitch','Yaw','Roll')),('actorRotation',('Pitch','Yaw','Roll'))]:
            if m.get(field) is not None:
                if not isinstance(m[field],dict) or any(not isinstance(m[field].get(k),(int,float)) or not math.isfinite(m[field][k]) for k in axes):
                    raise ValueError('Повреждённые координаты персонажа.')
        if 'heldDefinitions' in m and (not isinstance(m['heldDefinitions'],list) or len(m['heldDefinitions'])>10000 or any(not isinstance(x,str) or len(x)>1024 for x in m['heldDefinitions'])):
            raise ValueError('Повреждённые данные игрушек в руках.')
        files=m.get('files')
        if not isinstance(files,dict) or not files: raise ValueError('В снапшоте нет сохранений.')
        if m.get('slot') and m['slot'] not in files: raise ValueError('В снапшоте нет сохранения выбранной карты и режима.')
        for name, sha in files.items():
            if Path(name).name!=name or not name.endswith('.sav') or '/' in name or '\\' in name:
                raise ValueError('Недопустимый файл сохранения.')
            p=folder/'saves'/name
            if not p.is_file() or digest(p)!=sha: raise ValueError('Снапшот повреждён: '+name)
            with p.open('rb') as f:
                if f.read(4)!=b'GVAS': raise ValueError('Неверный формат сохранения: '+name)
        return m

    def capture(self, save_dir, metadata, image=None):
        sid=uuid.uuid4().hex
        staging=self.snapshots/('.'+sid)
        (staging/'saves').mkdir(parents=True)
        try:
            files={}
            for p in Path(save_dir).glob('*.sav'):
                if p.name=='ToxicSettingsShared.sav': continue
                # A torn save is never published as a usable snapshot.
                before=(p.stat().st_size,p.stat().st_mtime_ns)
                dest=staging/'saves'/p.name; shutil.copy2(p,dest)
                if before!=(p.stat().st_size,p.stat().st_mtime_ns): raise ValueError('Игра ещё записывает сохранение. Повторите снимок.')
                files[p.name]=digest(dest)
            metadata=dict(metadata,id=sid,created=time.time(),deleted=False,gameHash=self.version,files=files)
            if image: shutil.copy2(image,staging/'image.png'); metadata['image']=True
            else: metadata['image']=False
            atomic_json(staging/'snapshot.json',metadata)
            self.validate(staging)
            os.replace(staging,self.folder(sid))
            return metadata
        finally:
            if staging.exists(): shutil.rmtree(staging)

    def patch(self,sid,**changes):
        m=self.read(sid)
        if 'name' in changes: changes['name']=str(changes['name']).strip()[:120] or 'Снапшот'
        m.update(changes); atomic_json(self.folder(sid)/'snapshot.json',m); return m

    def backup(self, save_dir):
        p=self.backups/(time.strftime('%Y%m%d-%H%M%S')+'-'+uuid.uuid4().hex[:8])
        p.mkdir()
        for f in Path(save_dir).glob('*.sav'): shutil.copy2(f,p/f.name)
        return p

    def restore(self,sid,save_dir):
        # Validate all source data before touching live saves.
        source=self.folder(sid); m=self.validate(source)
        live=Path(save_dir); live.mkdir(parents=True, exist_ok=True)
        backup=self.backup(live)
        stage=Path(tempfile.mkdtemp(prefix='.toybox-',dir=live))
        affected=set(m['files'])
        try:
            for name in affected:
                shutil.copy2(source/'saves'/name,stage/name)
                if digest(stage/name)!=m['files'][name]: raise ValueError('Ошибка проверки копии сохранения.')
            for name in affected: os.replace(stage/name,live/name)
        except Exception:
            for name in affected:
                if (backup/name).exists(): shutil.copy2(backup/name,live/name)
                elif (live/name).exists(): (live/name).unlink()
            raise
        finally: shutil.rmtree(stage,ignore_errors=True)
        return m,str(backup)

    def export(self,sid):
        self.validate(self.folder(sid))
        dest=self.root/'exports'; dest.mkdir(exist_ok=True)
        p=dest/(sid+'.toybox.zip')
        with zipfile.ZipFile(p,'w',zipfile.ZIP_DEFLATED) as z:
            for f in self.folder(sid).rglob('*'):
                if f.is_file(): z.write(f,str(f.relative_to(self.folder(sid))))
        return p

    def import_zip(self, data):
        stage=Path(tempfile.mkdtemp(prefix='.import-',dir=self.snapshots))
        try:
            with zipfile.ZipFile(__import__('io').BytesIO(data)) as z:
                if sum(x.file_size for x in z.infolist())>1024**3: raise ValueError('Архив слишком большой.')
                names=set()
                for member in z.infolist():
                    n=member.filename
                    if n in names: raise ValueError('Повторяющийся файл в архиве.')
                    names.add(n)
                    if n not in ('snapshot.json','image.png') and not (n.startswith('saves/') and Path(n[6:]).name==n[6:] and n.endswith('.sav') and '\\' not in n):
                        raise ValueError('Недопустимое содержимое архива.')
                    if member.file_size>512*1024**2: raise ValueError('Файл слишком большой.')
                    if n=='snapshot.json' and member.file_size>1024**2: raise ValueError('Повреждённые метаданные.')
                    z.extract(member,stage)
            m=self.validate(stage); m['id']=uuid.uuid4().hex; m['deleted']=False
            atomic_json(stage/'snapshot.json',m)
            os.replace(stage,self.folder(m['id']))
            return m
        finally:
            if stage.exists(): shutil.rmtree(stage)
