"""Local PWA and game bridge. Python standard library only."""
from pathlib import Path
import argparse, json, logging, mimetypes, os, secrets, shutil, socket, subprocess, sys, threading, time, urllib.parse, uuid, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from storage import Store, atomic_json, digest
import windows
from replays import Replays

HERE=Path(__file__).resolve().parent
PACKAGE=HERE.parent
MANIFEST=json.loads((PACKAGE/'manifest.json').read_text(encoding='utf-8-sig'))
PORT=MANIFEST['port']

class App:
    def __init__(self,data):
        self.data=Path(data); self.data.mkdir(parents=True,exist_ok=True)
        self.bridge=self.data/'bridge'; self.bridge.mkdir(exist_ok=True)
        self.config_path=self.data/'config.json'
        self.config=json.loads(self.config_path.read_text(encoding='utf-8-sig'))
        self.game=Path(self.config['gameDir'])
        self.exe=self.game/MANIFEST['executable']
        self.store=Store(self.data,MANIFEST['sha256'],MANIFEST.get('compatibleSaveHashes',()))
        self.replays=Replays(self.data,MANIFEST['sha256'],self.store)
        self.lock=threading.Lock(); self.rpc_lock=threading.Lock(); self.op=None
        self.cached_state={}; self.cached_state_at=0; self.cached_processes=[]; self.last_proc=0
        self.input=windows.Input(self.bridge,self.state,self.pid)
        self.input.start()
        self.settings_seen=None
        threading.Thread(target=self.persist_settings,daemon=True).start()
        threading.Thread(target=self.monitor_replays,daemon=True).start()
    def processes(self):
        if time.monotonic()-self.last_proc>0.5:
            self.cached_processes=windows.game_processes(self.exe); self.last_proc=time.monotonic()
        return self.cached_processes
    def pid(self):
        ps=self.processes(); s=self.state()
        if s.get('started'):
            matching=[p for p in ps if p['started']<=s['started']+1]
            if matching: return matching[-1]['pid']
        return ps[-1]['pid'] if ps else None
    def state(self):
        path=self.bridge/'state.json'
        def current(s):
            return bool(s.get('started') and any(p['started']<=s['started']+1 for p in self.processes()))
        try:
            if time.time()-path.stat().st_mtime<2:
                s=json.loads(path.read_text(encoding='utf-8'))
                if current(s):self.cached_state=s;self.cached_state_at=time.monotonic();return s
        except (OSError,ValueError): pass
        if time.monotonic()-self.cached_state_at<2 and current(self.cached_state):return self.cached_state
        return {}
    def status(self):
        pid=self.pid();s=self.state() if pid else {}
        return dict(version=MANIFEST['version'],gameRunning=bool(pid),modConnected=bool(s),game=s,operation=self.op,inputError=self.input.error,test=bool(self.config.get('test')),service={'pid':os.getpid(),'parentPid':os.getppid(),'program':str(PACKAGE)})
    def persist_settings(self):
        while True:
            s=self.state()
            settings={k:s[k] for k in ('speed','fov','sensitivity','smoothing','rotationSmoothing','focusDistance','lensBlur','batch','hands','noCooldown') if k in s}
            if settings and settings!=self.settings_seen:
                self.settings_seen=settings; self.config['settings']=settings
                try: atomic_json(self.config_path,self.config)
                except OSError: logging.exception('settings')
            time.sleep(1)
    def rpc(self,action,timeout=12,**params):
        if 'id' in params:params['replayId']=params.pop('id')
        with self.rpc_lock:
            if not self.pid() or not self.state(): raise ValueError('Мод не подключён. Запустите игру после установки мода.')
            rid=uuid.uuid4().hex
            atomic_json(self.bridge/'request.json',dict(id=rid,action=action,**params))
            until=time.monotonic()+timeout
            while time.monotonic()<until:
                try:
                    r=json.loads((self.bridge/'response.json').read_text(encoding='utf-8'))
                    if r.get('id')==rid:
                        if not r.get('ok'): raise ValueError(r.get('error','Игра не выполнила действие.'))
                        return r.get('result') or {}
                except (OSError,json.JSONDecodeError): pass
                time.sleep(0.04)
            raise ValueError('Игра не ответила вовремя. Текущее сохранение не заменено этой командой.')
    def start(self):
        if self.pid(): return
        if digest(self.exe)!=MANIFEST['sha256']: raise ValueError('Версия игры изменилась. Установите совместимый пакет мода.')
        if self.config.get('test'):
            subprocess.Popen([str(self.exe),'MyToyStore','-ToxicApproved','-windowed','-ResX=1280','-ResY=720','-UserDir='+str(Path(self.config['testSavedDir']).parent)],cwd=self.game,creationflags=0x08000000)
        else: os.startfile('steam://rungameid/'+MANIFEST['appId'])
        self.wait(lambda:self.pid(),60,'Steam не запустил игру.')
    def wait(self,predicate,timeout,error):
        until=time.monotonic()+timeout
        while time.monotonic()<until:
            result=predicate()
            if result: return result
            time.sleep(0.15)
        raise ValueError(error)
    def save_dir(self,state=None):
        state=state or self.state()
        permitted=Path(self.config.get('testSavedDir') or self.config.get('gameSavedDir') or (Path(os.environ.get('LOCALAPPDATA',Path.home()/'AppData'/'Local'))/'MyToyStore'/'Saved')).resolve()
        raw=state.get('savedDir')
        if raw:
            path=Path(raw)
            if not path.is_absolute(): path=(self.exe.parent/path).resolve()
            if path.resolve()!=permitted: raise ValueError('Мод сообщил неожиданный путь сохранений. Восстановление остановлено.')
        return permitted/'SaveGames'
    def phase(self,text):
        self.op['message']=text
    def operate(self,kind,fn):
        if not self.lock.acquire(False): raise Busy('Уже выполняется другая операция.')
        self.op={'id':uuid.uuid4().hex,'kind':kind,'status':'running','message':'Подготовка…'}
        def run():
            try:
                result=fn(); self.op.update(status='done',message='Готово',result=result)
            except Exception as e:
                logging.exception('operation'); self.op.update(status='error',message=str(e))
            finally: self.lock.release()
        threading.Thread(target=run,daemon=True).start()
        return self.op
    def capture(self,body):
        try: return self.capture_frozen(body)
        finally:
            if self.state():
                try: self.rpc('finishSnapshot')
                except (ValueError,OSError): logging.exception('resume after snapshot')
    def capture_frozen(self,body):
        s=self.state(); save_dir=self.save_dir(s)
        screenshots=save_dir.parent/'Screenshots'/'Windows'
        before={str(p):p.stat().st_mtime_ns for p in screenshots.glob('*.png')}
        slot='EditorSave_'+s.get('world','')+'_'+['Classic','TimeAttack','FreePlay'][s.get('mode',0)]+'.sav'
        oldstamp=(save_dir/slot).stat().st_mtime_ns if (save_dir/slot).exists() else 0
        self.phase('Сохраняю текущее состояние игры и снимаю кадр…')
        meta=self.rpc('snapshot')
        save_dir=self.save_dir(meta)
        def saved():
            p=save_dir/slot
            return p.exists() and p.stat().st_mtime_ns!=oldstamp
        self.wait(saved,25,'Игра не записала новое сохранение. Снапшот не создан.')
        def image():
            candidates=[p for p in screenshots.glob('*.png') if before.get(str(p))!=p.stat().st_mtime_ns]
            return max(candidates,key=lambda p:p.stat().st_mtime_ns) if candidates else None
        shot=self.wait(image,15,'Движок не создал скриншот. Снапшот не опубликован.')
        stamp=(shot.stat().st_size,shot.stat().st_mtime_ns)
        time.sleep(0.4)
        if stamp!=(shot.stat().st_size,shot.stat().st_mtime_ns): time.sleep(0.6)
        self.phase('Проверяю и сохраняю снапшот…')
        meta.pop('savedDir',None)
        meta['internal']=bool(body.get('internal'))
        meta.update(name=body.get('name') or time.strftime('Снимок %d.%m %H:%M'),playthrough=body.get('playthrough') or 'Основное прохождение',source='current',slot=slot)
        return self.store.capture(save_dir,meta,shot)
    def disk_capture(self,body):
        if self.pid(): raise ValueError('Для снимка последнего сохранения на диске сначала закройте игру.')
        world=body.get('world'); mode=int(body.get('mode',0))
        if world not in ('L_ToyKingdom','L_Shopping_mall','L_SkyKids_Store') or mode not in range(3): raise ValueError('Выберите карту и режим.')
        slot='EditorSave_'+world+'_'+['Classic','TimeAttack','FreePlay'][mode]+'.sav'
        if not (self.save_dir()/slot).is_file():raise ValueError('Для выбранной карты и режима ещё нет сохранения на диске.')
        return self.store.capture(self.save_dir(),dict(name=body.get('name') or 'Сохранение на диске',playthrough=body.get('playthrough') or 'Основное прохождение',world=world,mode=mode,source='disk',position=None,rotation=None,slot=slot))
    def load(self,sid,restore_hands=True,restore_pose=True):
        m=self.store.validate(self.store.folder(sid)); save_dir=self.save_dir()
        # Backup before leaving the level as well as before replacement.
        backup=self.store.backup(save_dir)
        self.phase('Подготавливаю игру к загрузке…')
        s=self.state()
        if self.pid() and not s: raise ValueError('Игра работает без подключённого мода. Перезапустите её после установки.')
        if s.get('authority') is False and s.get('ready'): raise ValueError('Снапшоты загружаются у хоста.')
        if self.pid() and s.get('ready'):
            # EndPlay auto-save runs before returning to the menu. Replace only after it completes.
            self.rpc('menu')
            self.wait(lambda:self.state() and not self.state().get('ready') and 'Menu' in self.state().get('world',''),45,'Игра не вернулась в меню. Сохранения не заменены.')
        self.phase('Проверяю файлы и восстанавливаю сохранение…')
        _,replacement_backup=self.store.restore(sid,save_dir)
        try:
            self.phase('Запускаю выбранную карту…')
            self.start()
            self.wait(lambda:self.state(),60,'Мод не подключился после запуска игры.')
            pose=dict(world=m['world'],mode=m['mode'])
            held=m.get('heldDefinitions',[]) if restore_hands else []
            if restore_pose and m.get('position'): pose.update(position=m['position'],rotation=m['rotation'],actorRotation=m.get('actorRotation'),heldDefinitions=held)
            self.rpc('start',**pose)
            self.wait(lambda:self.state().get('ready') and self.state().get('world')==m['world'],90,'Карта не загрузилась вовремя. Резервная копия сохранена.')
            if restore_pose and m.get('position'):
                self.rpc('pose',position=m['position'],rotation=m['rotation'],actorRotation=m.get('actorRotation'),heldDefinitions=held)
                s=self.state(); self.wait(lambda:self.state().get('position') and sum((self.state()['position'][k]-m['position'][k])**2 for k in ('X','Y','Z'))<100,8,'Игра не подтвердила восстановление позиции.')
            return {'snapshot':sid,'backup':replacement_backup,'initialBackup':str(backup),'positionRestored':bool(restore_pose and m.get('position'))}
        except Exception:
            # Never overwrite saves while a live level might still be writing to them.
            if not self.state().get('ready'):
                for p in Path(replacement_backup).glob('*.sav'): shutil.copy2(p,save_dir/p.name)
            raise
    def monitor_replays(self):
        request_seen=finished_seen=checkpoint_seen=None
        missing_since=None
        while True:
            s=self.state()
            request=s.get('replayRequest') or {}
            finished=s.get('replayFinished') or {}
            checkpoint=s.get('replayCheckpoint') or {}
            checkpoint_token=(checkpoint.get('id'),checkpoint.get('time'))
            if checkpoint_token[0] and checkpoint_token!=checkpoint_seen:
                checkpoint_seen=checkpoint_token
                try:
                    self.replays.register(checkpoint_token[0],self.bridge/('replay-'+checkpoint_token[0]+'.json'))
                    if s.get('replay',{}).get('state') in ('recording','paused','overdubbing'):self.replays.status(checkpoint_token[0],'recording')
                except Exception:logging.exception('replay checkpoint')
            token=request.get('token')
            if token and token!=request_seen and not self.lock.locked():
                request_seen=token
                try:
                    if request.get('action')=='record':self.operate('record',lambda request=request:self.record_replay(request))
                    elif request.get('action')=='play' and request.get('id'):self.operate('replay',lambda request=request:self.hotkey_replay(request))
                except Exception:logging.exception('replay hotkey')
            done=(finished.get('id'),finished.get('time'))
            if done[0] and done!=finished_seen:
                finished_seen=done
                try:self.replays.register(done[0],self.bridge/('replay-'+done[0]+'.json'))
                except Exception:logging.exception('finish replay')
            if s:missing_since=None
            elif missing_since is None:missing_since=time.monotonic()
            elif time.monotonic()-missing_since>3:
                for m in self.replays.list():
                    if m.get('status')=='recording' and m.get('sha256'):self.replays.status(m['id'],'ready',recovered=True)
            time.sleep(.3)
    def record_replay(self,b):
        s=self.wait(self.state,8,'Игра занята. Дождитесь окончания текущих действий.')
        if s.get('version')!='4.0.1':raise ValueError('Для записей нужен перезапуск игры с модом v4.')
        if s.get('replay',{}).get('state')=='finished':
            self.rpc('replayStop');self.wait(lambda:self.state().get('replay',{}).get('state')=='idle',3,'Повтор ещё завершается.');s=self.state()
        if s.get('replay',{}).get('state') not in (None,'idle'):raise ValueError('Сначала завершите текущую запись или повтор.')
        kind=b.get('kind','camera')
        if kind not in ('camera','players'):raise ValueError('Неизвестный вид записи.')
        baseline=None
        if kind=='players':
            if not s.get('ready') or not s.get('authority'):raise ValueError('Игроки записываются у хоста после загрузки уровня.')
            baseline=self.capture(dict(name='Исходное состояние повтора',playthrough='Повторы',internal=True))['id']
        m=self.replays.create(kind,baseline,b.get('name'))
        try:
            self.rpc('replayRecord',id=m['id'],kind=kind)
            if kind=='camera':
                try:
                    screenshots=self.save_dir().parent/'Screenshots'/'Windows'
                    before={str(p):p.stat().st_mtime_ns for p in screenshots.glob('*.png')}
                    self.rpc('shot')
                    def image():
                        candidates=[p for p in screenshots.glob('*.png') if before.get(str(p))!=p.stat().st_mtime_ns]
                        return max(candidates,key=lambda p:p.stat().st_mtime_ns) if candidates else None
                    shot=self.wait(image,8,'Нет скриншота повтора.')
                    time.sleep(.3);self.replays.image(m['id'],shot)
                except (OSError,ValueError):logging.exception('replay thumbnail')
            return {'replay':m['id']}
        except Exception:
            self.replays.patch(m['id'],{'deleted':True});raise
    def load_replay(self,b):
        s=self.wait(self.state,8,'Игра занята. Дождитесь окончания текущих действий.')
        if s.get('version')!='4.0.1':raise ValueError('Для повторов нужен перезапуск игры с модом v4.')
        camera=None
        if b.get('keepCamera') and s.get('freecam') and s.get('cameraPosition') and s.get('cameraRotation'):
            camera=dict(p=s['cameraPosition'],r=s['cameraRotation'],fov=s['fov'],focusDistance=s['focusDistance'],lensBlur=s['lensBlur'])
        if s.get('replay',{}).get('state')!='idle':
            self.rpc('replayStop',timeout=30)
            active=s.get('replay',{})
            if active.get('id') and active.get('state') in ('recording','overdubbing','paused'):
                self.replays.register(active['id'],self.bridge/('replay-'+active['id']+'.json'))
        m=self.replays.prepare(b['id'],self.bridge)
        track=b.get('track')
        if track is not None and (m['kind']!='players' or not 1<=int(track)<=min(4,len(m['tracks'])+1)):raise ValueError('Выберите дорожку игрока.')
        if m['kind']=='players':self.load(m['baseline'],restore_hands=False,restore_pose=False)
        elif not s.get('cameraReady') or s.get('world')!=m['world']:raise ValueError('Откройте карту '+m['world']+' для повтора камеры.')
        self.phase('Подготавливаю игроков и объекты…' if m['kind']=='players' else 'Подготавливаю камеру…')
        self.rpc('replayLoad',id=m['id'],track=int(track) if track is not None else None,observer=b.get('observer',True),cameraPose=camera)
        return {'replay':m['id'],'track':track}
    def play_replay(self,b):
        s=self.wait(self.state,8,'Игра занята. Дождитесь окончания текущих действий.')
        if s.get('version')!='4.0.1':raise ValueError('Для повторов нужен перезапуск игры с модом v4.')
        r=s.get('replay',{})
        # Restart and overdub rebuild the baseline; starting a prepared take does not.
        if b.get('restart') or b.get('track') is not None or (r.get('state')=='finished' and r.get('id')==b.get('id')):
            self.load_replay(dict(b,keepCamera=True))
        elif r.get('id')!=b.get('id') or r.get('state') not in ('loaded','paused'):
            raise ValueError('Сначала загрузите этот повтор кнопкой «Загрузить».')
        self.phase('Перезаписываю игрока…' if b.get('track') else 'Начинаю повтор…')
        self.rpc('replayStart')
        return {'replay':b['id'],'track':b.get('track')}
    def hotkey_replay(self,b):
        r=self.state().get('replay',{})
        if r.get('id')!=b['id'] or r.get('state')=='idle':self.load_replay(dict(b,keepCamera=True))
        return self.play_replay(b)
    def shelves(self,b):
        token=uuid.uuid4().hex
        result=self.rpc('shelf',kind=b.get('kind'),count=b.get('count'),operationId=token)
        token=result['operation']
        deadline=time.monotonic()+max(60,min(900,result['total']/40+30))
        missing_since=None
        while time.monotonic()<deadline:
            state=self.state(); op=state.get('shelfOperation') or {}
            if not state:
                if missing_since is None:missing_since=time.monotonic()
                if not self.pid() or time.monotonic()-missing_since>30:raise ValueError('Связь с игрой потеряна. Операция с полками остановлена.')
            else:missing_since=None
            if op.get('id')==token:
                self.phase(op.get('message','Перемещаю игрушки…')+f" {op.get('completed',0)} / {op.get('total',0)}")
                if op.get('state')=='error':raise ValueError(op['message'])
                if op.get('state')=='done':return op
            time.sleep(.15)
        raise ValueError('Операция с полками ещё выполняется в игре. Дождитесь её завершения.')
    def action(self,path,b):
        if path=='/api/shelves':return self.operate('shelves',lambda:self.shelves(b))
        if path=='/api/replay/record':return self.operate('record',lambda:self.record_replay(b))
        if path=='/api/replay/load':return self.operate('loadReplay',lambda:self.load_replay(b))
        if path=='/api/replay/play':return self.operate('replay',lambda:self.play_replay(b))
        if path=='/api/replay/patch':
            if self.lock.locked():raise Busy('Дождитесь завершения операции.')
            m=self.replays.patch(b['id'],b)
            if 'track' in b and self.state().get('replay',{}).get('id')==b['id']:
                self.rpc('replayTrack',id=b['id'],track=int(b['track']),enabled=b.get('enabled'),actions=b.get('actions'))
            return m
        if path=='/api/snapshot': return self.operate('snapshot',lambda:self.capture(b))
        if path=='/api/disk-snapshot': return self.operate('snapshot',lambda:self.disk_capture(b))
        if path=='/api/load': return self.operate('load',lambda:self.load(b['id']))
        if path=='/api/start': return self.operate('start',lambda:self.start())
        if path=='/api/close':
            def close():
                pid=self.pid()
                if not pid: return {}
                if self.state(): self.rpc('quit')
                else: windows.close_game(pid)
                self.wait(lambda:not self.pid(),40,'Игра ещё закрывается. Дождитесь завершения.')
                return {}
            return self.operate('close',close)
        if self.lock.locked(): raise Busy('Дождитесь завершения операции.')
        if path=='/api/game': return self.rpc(timeout=30 if b.get('action')=='replayStop' else 12,**b)
        if path=='/api/rename': return self.store.patch(b['id'],name=b['name'])
        if path=='/api/delete': return self.store.patch(b['id'],deleted=True)
        if path=='/api/undelete': return self.store.patch(b['id'],deleted=False)
        if path=='/api/export': return {'url':'/exports/'+self.store.export(b['id']).name}
        raise ValueError('Неизвестное действие.')

class Busy(ValueError): pass

class LocalServer(ThreadingHTTPServer):
    allow_reuse_address=False
    def server_bind(self):
        self.socket.setsockopt(socket.SOL_SOCKET,socket.SO_EXCLUSIVEADDRUSE,1)
        super().server_bind()
def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--data',default=str(Path(os.environ.get('LOCALAPPDATA',Path.home()/'AppData'/'Local'))/'ToyboxTogether')); parser.add_argument('--open',action='store_true'); args=parser.parse_args()
    data=Path(args.data); data.mkdir(parents=True,exist_ok=True)
    logging.basicConfig(filename=data/'backend.log',level=logging.INFO,format='%(asctime)s %(message)s')
    # Binding first gives a process-independent single-instance guard without stale lock files.
    try: server=LocalServer(('127.0.0.1',PORT),Handler)
    except OSError:
        if args.open: webbrowser.open('http://127.0.0.1:'+str(PORT))
        return
    server.app=App(data)
    if args.open: webbrowser.open('http://127.0.0.1:'+str(PORT))
    server.serve_forever()

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    @property
    def app(self): return self.server.app
    def host_ok(self):
        return self.headers.get('Host') in ('127.0.0.1:'+str(PORT),'localhost:'+str(PORT))
    def send_data(self,data,ctype='application/json',status=200):
        if not isinstance(data,bytes): data=json.dumps(data,ensure_ascii=False).encode('utf-8')
        self.send_response(status); self.send_header('Content-Type',ctype); self.send_header('Content-Length',str(len(data)))
        self.send_header('X-Content-Type-Options','nosniff'); self.send_header('Cache-Control','no-store')
        self.send_header('Content-Security-Policy',"default-src 'self'; img-src 'self' blob:; style-src 'self'; script-src 'self'; connect-src 'self'; object-src 'none'; frame-ancestors 'none'")
        self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if not self.host_ok(): return self.send_data({'error':'Недопустимый адрес.'},status=403)
        path=urllib.parse.urlsplit(self.path).path
        try:
            if path=='/api/status': return self.send_data(self.app.status())
            if path=='/api/replays':return self.send_data({'items':self.app.replays.list()})
            if path.startswith('/replays/'):
                parts=path.split('/')
                if len(parts)!=4 or parts[3]!='image.png':raise ValueError('Нет файла.')
                return self.send_data((self.app.replays.folder(parts[2])/'image.png').read_bytes(),'image/png')
            if path=='/api/snapshots': return self.send_data({'items':self.app.store.list(), 'trash':self.app.store.list(True)})
            if path.startswith('/snapshots/'):
                parts=path.split('/'); folder=self.app.store.folder(parts[2]); name=parts[3] if len(parts)==4 else ''
                if name!='image.png': raise ValueError('Нет файла.')
                return self.send_data((folder/name).read_bytes(),'image/png')
            if path.startswith('/exports/'):
                name=path.removeprefix('/exports/')
                if len(name)!=43 or not name.endswith('.toybox.zip'): raise ValueError('Нет файла.')
                self.app.store.folder(name[:32])
                return self.send_data((self.app.data/'exports'/name).read_bytes(),'application/zip')
            if path=='/': path='/index.html'
            file=(HERE/'web'/path.lstrip('/')).resolve()
            if not file.is_relative_to((HERE/'web').resolve()): raise ValueError('Нет файла.')
            return self.send_data(file.read_bytes(),mimetypes.guess_type(file)[0] or 'application/octet-stream')
        except (OSError,ValueError,KeyError): self.send_data({'error':'Не найдено.'},status=404)
    def do_POST(self):
        origin=self.headers.get('Origin')
        if not self.host_ok() or origin not in (None,'http://127.0.0.1:'+str(PORT),'http://localhost:'+str(PORT)):
            return self.send_data({'error':'Запрос разрешён только с локального сайта.'},status=403)
        path=urllib.parse.urlsplit(self.path).path
        try:
            length=int(self.headers.get('Content-Length','0'))
            if length<0 or length>128*1024**2: raise ValueError('Файл слишком большой.')
            raw=self.rfile.read(length)
            if path=='/api/shutdown':
                if self.app.lock.locked():raise Busy('Дождитесь завершения операции.')
                self.send_data({'stopping':True})
                threading.Thread(target=self.server.shutdown,daemon=True).start()
                return
            if path=='/api/import':
                if self.headers.get('Content-Type')!='application/octet-stream': raise ValueError('Неверный формат импорта.')
                if self.app.lock.locked(): raise Busy('Дождитесь завершения операции.')
                result=self.app.store.import_zip(raw)
            else:
                if self.headers.get('Content-Type')!='application/json' or length>1024**2: raise ValueError('Неверный формат запроса.')
                b=json.loads(raw); result=self.app.action(path,b)
            self.send_data(result)
        except Busy as e: self.send_data({'error':str(e)},status=409)
        except (ValueError,KeyError,OSError) as e: self.send_data({'error':str(e)},status=400)
        except Exception:
            logging.exception('request'); self.send_data({'error':'Ошибка сервиса. Подробности записаны в журнал.'},status=500)

if __name__=='__main__': main()
