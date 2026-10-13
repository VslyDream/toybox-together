"""Replay gallery with validated coordinate/action tracks and snapshot baselines."""
from pathlib import Path
import json,math,time,uuid,shutil,os
from storage import atomic_json,digest

class Replays:
    def __init__(self,root,game_hash,snapshots):
        self.root=Path(root)/'replays';self.root.mkdir(exist_ok=True)
        self.game_hash=game_hash;self.snapshots=snapshots
    def folder(self,rid):
        if not isinstance(rid,str) or len(rid)!=32 or any(c not in '0123456789abcdef' for c in rid):raise ValueError('Некорректный идентификатор повтора.')
        return self.root/rid
    def read(self,rid):
        m=json.loads((self.folder(rid)/'replay.json').read_text(encoding='utf-8'))
        if m.get('id')!=rid or m.get('gameHash') not in {self.game_hash,*self.snapshots.compatible_hashes}:raise ValueError('Повтор создан для другой версии игры или повреждён.')
        return m
    def list(self):
        out=[]
        for p in self.root.iterdir():
            if p.is_dir() and not p.name.startswith('.'):
                try:out.append(self.read(p.name))
                except (OSError,ValueError):pass
        return sorted(out,key=lambda x:x['created'],reverse=True)
    def create(self,kind,baseline=None,name=None):
        if kind not in ('camera','players'):raise ValueError('Неизвестный вид записи.')
        rid=uuid.uuid4().hex;p=self.folder(rid);p.mkdir()
        m=dict(id=rid,kind=kind,name=(name or ('Полёт камеры' if kind=='camera' else 'Движения игроков'))[:120],gameHash=self.game_hash,created=time.time(),duration=0,tracks=[],baseline=baseline,status='recording')
        if baseline:
            snap=self.snapshots.read(baseline);m.update(world=snap['world'],mode=snap['mode'],image=snap.get('image',False))
            if snap.get('image'):shutil.copy2(self.snapshots.folder(baseline)/'image.png',p/'image.png')
        atomic_json(p/'replay.json',m);return m
    def validate_data(self,data):
        def num(x,lo,hi):return isinstance(x,(int,float)) and not isinstance(x,bool) and math.isfinite(x) and lo<=x<=hi
        def vector(x,axes):return isinstance(x,dict) and all(num(x.get(k),-1e8,1e8) for k in axes)
        if not isinstance(data,dict) or data.get('schema')!=2 or data.get('kind') not in ('camera','players') or data.get('world') not in ('L_ToyKingdom','L_Shopping_mall','L_SkyKids_Store') or data.get('mode') not in (0,1,2):raise ValueError('Повреждённые данные повтора.')
        duration=data.get('duration')
        if not num(duration,0,1801):raise ValueError('Недопустимая длительность записи.')
        if not num(data.get('timeScale',1),.01,20):raise ValueError('Недопустимая скорость времени в записи.')
        tracks=data.get('tracks')
        if not isinstance(tracks,list) or not 1<=len(tracks)<=4 or (data['kind']=='camera' and len(tracks)!=1):raise ValueError('Недопустимое число дорожек.')
        for track in tracks:
            if not isinstance(track,dict) or not isinstance(track.get('id'),str) or len(track['id'])>64:raise ValueError('Повреждённая дорожка.')
            frames=track.get('frames');events=track.get('events')
            if not isinstance(frames,list) or not 1<=len(frames)<=200000 or not isinstance(events,list) or len(events)>200000:raise ValueError('Недопустимый размер дорожки.')
            last=-1
            for f in frames:
                if not isinstance(f,dict) or not num(f.get('t'),last,duration+.5) or not vector(f.get('p'),('X','Y','Z')) or not vector(f.get('r'),('Pitch','Yaw','Roll')):raise ValueError('Повреждённые координаты повтора.')
                last=f['t']
                if data['kind']=='camera':
                    if not num(f.get('fov'),20,150) or not num(f.get('focusDistance',5),.1,1000) or not num(f.get('lensBlur',0),0,10):raise ValueError('Повреждённые параметры камеры.')
                elif not vector(f.get('look'),('Pitch','Yaw','Roll')) or not vector(f.get('velocity'),('X','Y','Z')):raise ValueError('Повреждённые движения игрока.')
                elif f.get('view') is not None and not vector(f['view'],('X','Y','Z')):raise ValueError('Повреждённая позиция взгляда игрока.')
                elif f.get('cameraMode',1) not in (0,1,2,3):raise ValueError('Повреждённый режим камеры игрока.')
                elif not num(f.get('movementMode',1),0,6) or int(f.get('movementMode',1))!=f.get('movementMode',1) or not num(f.get('customMode',0),0,255) or int(f.get('customMode',0))!=f.get('customMode',0):raise ValueError('Повреждённый режим движения игрока.')
            last=-1
            for e in events:
                if not isinstance(e,dict) or not num(e.get('t'),last,duration+.5) or e.get('type') not in ('press','release','throw','toolThrow','scroll','bulkGrab'):raise ValueError('Повреждённые действия игрока.')
                last=e['t']
                if e['type'] in ('press','release') and e.get('input') not in (*range(11),1000,1001,1002,1003):raise ValueError('Недопустимая способность в записи.')
                if e['type'] in ('throw','toolThrow') and not num(e.get('charge'),0,30):raise ValueError('Повреждённый бросок.')
                if e['type']=='scroll' and e.get('direction') not in (-1,1):raise ValueError('Повреждённая смена игрушки.')
                if e['type']=='bulkGrab':
                    targets=e.get('targets')
                    if not isinstance(targets,list) or not 1<=len(targets)<=200 or any(not isinstance(x,dict) or not isinstance(x.get('def'),int) or not 0<=x['def']<=65535 or not vector(x.get('p'),('X','Y','Z')) or 'definition' in x and (not isinstance(x['definition'],str) or len(x['definition'])>1024 or not x['definition'].startswith('TS_ItemDefinition ')) for x in targets):raise ValueError('Повреждённый массовый подбор.')
            initial=track.get('initialHeld',[])
            if not isinstance(initial,list) or len(initial)>10000 or any(not isinstance(x,str) or len(x)>1024 or not x.startswith('TS_ItemDefinition ') for x in initial):raise ValueError('Повреждённые игрушки в руках.')
            appearance=track.get('appearance')
            if appearance:
                if not isinstance(appearance,dict) or type(appearance.get('SkinColorIndex')) is not int or not -1<=appearance['SkinColorIndex']<=10000:raise ValueError('Повреждённая внешность игрока.')
                if 'Parts' in appearance:
                    def asset(value,prefix):
                        return value is None or isinstance(value,str) and len(value)<=1024 and value.startswith(prefix+' /Game/') and '..' not in value
                    parts=appearance['Parts']
                    if not asset(appearance.get('Body'),'TS_CharacterBodyDefinition') or not isinstance(parts,list) or len(parts)>128:raise ValueError('Повреждённая внешность игрока.')
                    for part in parts:
                        if not isinstance(part,dict) or not asset(part.get('Part'),'TS_CharacterPartDefinition') or type(part.get('ColorIndex')) is not int or not -1<=part['ColorIndex']<=10000:raise ValueError('Повреждённая внешность игрока.')
                else:
                    if type(appearance.get('PresetIndex')) is not int or not -1<=appearance['PresetIndex']<=10000:raise ValueError('Повреждённая внешность игрока.')
                    for k in ('SlotMeshIndices','SlotColorIndices'):
                        a=appearance.get(k)
                        if not isinstance(a,list) or len(a)>128 or any(not isinstance(x,int) or not -1<=x<=10000 for x in a):raise ValueError('Повреждённая внешность игрока.')
        return data
    def register(self,rid,source):
        m=self.read(rid);source=Path(source)
        if source.stat().st_size>256*1024**2:raise ValueError('Запись превышает 256 МБ.')
        data=self.validate_data(json.loads(source.read_text(encoding='utf-8')))
        if data['kind']!=m['kind']:raise ValueError('Вид записи не совпадает.')
        if m['kind']=='players':
            snap=self.snapshots.validate(self.snapshots.folder(m['baseline']))
            if (snap['world'],snap['mode'])!=(data['world'],data['mode']):raise ValueError('Исходное состояние не совпадает с записью.')
        target=self.folder(rid)/'tracks.json';temp=target.with_suffix('.tmp');shutil.copyfile(source,temp);os.replace(temp,target)
        old={x['id']:x for x in m.get('tracks',[])}
        tracks=[dict(id=t['id'],name=old.get(t['id'],{}).get('name') or t.get('name','Игрок'),enabled=old.get(t['id'],{}).get('enabled',True),actions=old.get(t['id'],{}).get('actions',True),frames=len(t['frames']),events=len(t['events'])) for t in data['tracks']]
        m.update(status='ready',duration=data['duration'],world=data['world'],mode=data['mode'],tracks=tracks,sha256=digest(target),updated=time.time())
        atomic_json(self.folder(rid)/'replay.json',m);return m
    def image(self,rid,path):
        m=self.read(rid);shutil.copy2(path,self.folder(rid)/'image.png');m['image']=True
        atomic_json(self.folder(rid)/'replay.json',m)
    def status(self,rid,status,**values):
        m=self.read(rid);m.update(status=status,**values);atomic_json(self.folder(rid)/'replay.json',m)
    def patch(self,rid,body):
        m=self.read(rid)
        if 'name' in body:m['name']=str(body['name']).strip()[:120] or 'Повтор'
        if 'track' in body:
            index=int(body['track'])-1
            if not 0<=index<len(m['tracks']):raise ValueError('Дорожка не найдена.')
            for k in ('enabled','actions'):
                if k in body:m['tracks'][index][k]=bool(body[k])
            if 'trackName' in body:m['tracks'][index]['name']=str(body['trackName']).strip()[:80] or 'Игрок'
        if 'deleted' in body:m['deleted']=bool(body['deleted'])
        atomic_json(self.folder(rid)/'replay.json',m);return m
    def prepare(self,rid,bridge):
        m=self.read(rid);p=self.folder(rid)/'tracks.json'
        if m.get('deleted'):raise ValueError('Повтор находится в корзине.')
        if m.get('status')!='ready' or digest(p)!=m.get('sha256'):raise ValueError('Запись ещё не завершена или повреждена.')
        data=self.validate_data(json.loads(p.read_text(encoding='utf-8')))
        data['legacyDefinitions']=m['gameHash']!=self.game_hash
        for t,settings in zip(data['tracks'],m['tracks']):t.update(enabled=settings['enabled'],actions=settings['actions'],name=settings['name'])
        atomic_json(Path(bridge)/('replay-'+rid+'.json'),data);return m
