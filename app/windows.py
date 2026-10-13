"""Windows process and focus-scoped raw input helpers."""
import ctypes as C
from ctypes import wintypes as W
import json, os, threading, time, uuid
from pathlib import Path
from storage import atomic_json

user=C.windll.user32; kernel=C.windll.kernel32
LRESULT=C.c_ssize_t
WNDPROC=C.WINFUNCTYPE(LRESULT,W.HWND,W.UINT,W.WPARAM,W.LPARAM)
HOOKPROC=C.WINFUNCTYPE(LRESULT,C.c_int,W.WPARAM,W.LPARAM)
user.DefWindowProcW.restype=LRESULT
user.DefWindowProcW.argtypes=[W.HWND,W.UINT,W.WPARAM,W.LPARAM]
user.CallNextHookEx.restype=LRESULT
user.CallNextHookEx.argtypes=[W.HANDLE,C.c_int,W.WPARAM,W.LPARAM]
user.SetWindowsHookExW.restype=W.HANDLE
user.SetWindowsHookExW.argtypes=[C.c_int,HOOKPROC,W.HINSTANCE,W.DWORD]
user.CreateWindowExW.restype=W.HWND
user.CreateWindowExW.argtypes=[W.DWORD,W.LPCWSTR,W.LPCWSTR,W.DWORD,C.c_int,C.c_int,C.c_int,C.c_int,W.HWND,W.HMENU,W.HINSTANCE,C.c_void_p]
kernel.GetModuleHandleW.restype=W.HMODULE
kernel.OpenProcess.restype=W.HANDLE
kernel.OpenProcess.argtypes=[W.DWORD,W.BOOL,W.DWORD]
kernel.CloseHandle.argtypes=[W.HANDLE]
user.GetRawInputData.argtypes=[W.HANDLE,W.UINT,C.c_void_p,C.POINTER(W.UINT),W.UINT]
user.GetForegroundWindow.restype=W.HWND

class PROCESSENTRY32(C.Structure):
    _fields_=[('dwSize',W.DWORD),('cntUsage',W.DWORD),('th32ProcessID',W.DWORD),('th32DefaultHeapID',C.c_size_t),('th32ModuleID',W.DWORD),('cntThreads',W.DWORD),('th32ParentProcessID',W.DWORD),('pcPriClassBase',W.LONG),('dwFlags',W.DWORD),('szExeFile',W.WCHAR*260)]
kernel.CreateToolhelp32Snapshot.restype=W.HANDLE
kernel.Process32FirstW.argtypes=[W.HANDLE,C.POINTER(PROCESSENTRY32)]
kernel.Process32NextW.argtypes=[W.HANDLE,C.POINTER(PROCESSENTRY32)]
kernel.QueryFullProcessImageNameW.argtypes=[W.HANDLE,W.DWORD,W.LPWSTR,C.POINTER(W.DWORD)]
kernel.GetProcessTimes.argtypes=[W.HANDLE,C.POINTER(W.FILETIME),C.POINTER(W.FILETIME),C.POINTER(W.FILETIME),C.POINTER(W.FILETIME)]

def game_processes(exe):
    found=[]; snap=kernel.CreateToolhelp32Snapshot(2,0)
    if snap==C.c_void_p(-1).value: return found
    try:
        p=PROCESSENTRY32(); p.dwSize=C.sizeof(p)
        ok=kernel.Process32FirstW(snap,C.byref(p))
        while ok:
            if p.szExeFile.lower()==Path(exe).name.lower():
                handle=kernel.OpenProcess(0x1000,False,p.th32ProcessID)
                if handle:
                    try:
                        n=W.DWORD(32768); name=C.create_unicode_buffer(n.value)
                        if kernel.QueryFullProcessImageNameW(handle,0,name,C.byref(n)) and os.path.normcase(name.value)==os.path.normcase(str(exe)):
                            ft=[W.FILETIME() for _ in range(4)]
                            kernel.GetProcessTimes(handle,*[C.byref(x) for x in ft])
                            started=((ft[0].dwHighDateTime<<32)+ft[0].dwLowDateTime)/1e7-11644473600
                            found.append({'pid':p.th32ProcessID,'started':started})
                    finally: kernel.CloseHandle(handle)
            ok=kernel.Process32NextW(snap,C.byref(p))
    finally: kernel.CloseHandle(snap)
    return sorted(found,key=lambda x:x['started'])

def foreground_pid():
    pid=W.DWORD(); user.GetWindowThreadProcessId(user.GetForegroundWindow(),C.byref(pid)); return pid.value

def close_game(pid):
    @C.WINFUNCTYPE(W.BOOL,W.HWND,W.LPARAM)
    def callback(hwnd,lp):
        wp=W.DWORD(); user.GetWindowThreadProcessId(hwnd,C.byref(wp))
        if wp.value==pid and user.IsWindowVisible(hwnd): user.PostMessageW(hwnd,0x10,0,0)
        return True
    user.EnumWindows(callback,0)

class RAWINPUTDEVICE(C.Structure):
    _fields_=[('usagePage',W.USHORT),('usage',W.USHORT),('flags',W.DWORD),('target',W.HWND)]
class RAWINPUTHEADER(C.Structure):
    _fields_=[('type',W.DWORD),('size',W.DWORD),('device',W.HANDLE),('wparam',W.WPARAM)]
class WNDCLASS(C.Structure):
    _fields_=[('style',W.UINT),('wndproc',WNDPROC),('clsExtra',C.c_int),('wndExtra',C.c_int),('instance',W.HINSTANCE),('icon',W.HICON),('cursor',W.HANDLE),('background',W.HBRUSH),('menu',W.LPCWSTR),('name',W.LPCWSTR)]
class MSLLHOOKSTRUCT(C.Structure):
    _fields_=[('point',W.POINT),('mouseData',W.DWORD),('flags',W.DWORD),('time',W.DWORD),('extra',C.c_size_t)]
class KBDLLHOOKSTRUCT(C.Structure):
    _fields_=[('vk',W.DWORD),('scan',W.DWORD),('flags',W.DWORD),('time',W.DWORD),('extra',C.c_size_t)]

class Input:
    def __init__(self,bridge,state_fn,pid_fn):
        self.bridge=Path(bridge); self.state_fn=state_fn; self.pid_fn=pid_fn
        self.dx=self.dy=self.wheel=0; self.lock=threading.Lock(); self.seq=0
        self.error=None
        self.buttons={'lmb':False,'rmb':False}
        self.camera_toggle=0; self.session=uuid.uuid4().hex;self.hotkeys={0x69:["camera",0],0x30:["tool",0],0x60:["tool",0],0x75:["record",0],0x76:["play",0],0x77:["stop",0]};self.key_down=set()
        try:
            previous=json.loads((self.bridge/'input.json').read_text(encoding='utf-8'))
            self.dx=previous.get('dx',0);self.dy=previous.get('dy',0);self.wheel=previous.get('wheel',0)
            for key in self.hotkeys.values():key[1]=previous.get(key[0]+'Toggle',0)
        except (OSError,ValueError):pass
    def active(self):
        pid=self.pid_fn()
        return bool(pid and foreground_pid()==pid)
    def consume_wheel(self):
        state=self.state_fn(); return bool(state.get('freecam') or state.get('tool'))
    def start(self):
        threading.Thread(target=self.listen,daemon=True).start()
        threading.Thread(target=self.publish,daemon=True).start()
    def listen(self):
        @WNDPROC
        def wndproc(hwnd,msg,wp,lp):
            if msg==0xff and self.active():
                size=W.UINT()
                user.GetRawInputData(W.HANDLE(lp),0x10000003,None,C.byref(size),C.sizeof(RAWINPUTHEADER))
                buffer=C.create_string_buffer(size.value)
                if user.GetRawInputData(W.HANDLE(lp),0x10000003,buffer,C.byref(size),C.sizeof(RAWINPUTHEADER))!=0xffffffff:
                    header=RAWINPUTHEADER.from_buffer(buffer)
                    if header.type==0:
                        import struct
                        # RAWMOUSE is 24 bytes. Relative mouse deltas at +12/+16.
                        offset=C.sizeof(RAWINPUTHEADER)
                        flags=struct.unpack_from('<H',buffer,offset)[0]
                        if flags&1==0:
                            dx,dy=struct.unpack_from('<ii',buffer,offset+12)
                            with self.lock: self.dx+=dx; self.dy+=dy
                return 0
            return user.DefWindowProcW(hwnd,msg,wp,lp)
        @HOOKPROC
        def wheel_hook(code,wp,lp):
            if code>=0 and wp in (0x202,0x205):self.buttons['lmb' if wp==0x202 else 'rmb']=False
            if code>=0 and self.active():
                if wp in (0x201,0x202,0x204,0x205):
                    key='lmb' if wp in (0x201,0x202) else 'rmb'
                    self.buttons[key]=wp in (0x201,0x204)
                    if self.state_fn().get('tool'): return 1
                if wp==0x20a and self.consume_wheel():
                    event=C.cast(lp,C.POINTER(MSLLHOOKSTRUCT)).contents
                    delta=C.c_short(event.mouseData>>16).value/120
                    with self.lock: self.wheel+=delta
                    return 1
            return user.CallNextHookEx(None,code,wp,lp)
        @HOOKPROC
        def camera_hook(code,wp,lp):
            if code>=0:
                event=C.cast(lp,C.POINTER(KBDLLHOOKSTRUCT)).contents
                if event.vk in self.hotkeys:
                    if event.vk!=0x69 and self.state_fn().get('version') not in ('2.0.0','4.0.1'):return user.CallNextHookEx(None,code,wp,lp)
                    if wp in (0x101,0x105):
                        consumed=event.vk in self.key_down;self.key_down.discard(event.vk)
                        if consumed:return 1
                    elif wp in (0x100,0x104) and self.active() and self.state_fn().get('cameraReady'):
                        if event.vk not in self.key_down:
                            key=self.hotkeys[event.vk][0]
                            for item in self.hotkeys.values():
                                if item[0]==key:item[1]+=1
                        self.key_down.add(event.vk)
                        return 1
            return user.CallNextHookEx(None,code,wp,lp)
        instance=kernel.GetModuleHandleW(None)
        name='ToyboxInput-'+str(os.getpid())
        wc=WNDCLASS(); wc.wndproc=wndproc; wc.instance=instance; wc.name=name
        if not user.RegisterClassW(C.byref(wc)): self.error='Не удалось подключить ввод мыши.'; return
        hwnd=user.CreateWindowExW(0,name,name,0,0,0,0,0,W.HWND(-3),None,instance,None)
        device=RAWINPUTDEVICE(1,2,0x100,hwnd)
        if not user.RegisterRawInputDevices(C.byref(device),1,C.sizeof(device)): self.error='Недоступен Raw Input.'
        hook=user.SetWindowsHookExW(14,wheel_hook,instance,0)
        if not hook: self.error='Не удалось подключить колесо мыши.'
        keyboard_hook=user.SetWindowsHookExW(13,camera_hook,instance,0)
        if not keyboard_hook:self.error='Не удалось подключить Num9. Используйте Ctrl+P или галочку на сайте.'
        msg=W.MSG()
        while user.GetMessageW(C.byref(msg),None,0,0)>0:
            user.TranslateMessage(C.byref(msg)); user.DispatchMessageW(C.byref(msg))
    def publish(self):
        while True:
            active=self.active()
            with self.lock:
                dx,dy,wheel=self.dx,self.dy,self.wheel
            keys={key:bool(user.GetAsyncKeyState(vk)&0x8000) if active else False for key,vk in [('w',87),('a',65),('s',83),('d',68),('q',81),('e',69),('shift',16),('alt',18),('ctrl',17),('lmb',1),('rmb',2)]}
            if active and self.state_fn().get('tool'): keys.update(self.buttons)
            self.seq+=1
            try: atomic_json(self.bridge/'input.json',dict(seq=self.seq,focused=active,dx=dx,dy=dy,wheel=wheel,session=self.session,cameraToggle=self.hotkeys[0x69][1],toolToggle=self.hotkeys[0x30][1],recordToggle=self.hotkeys[0x75][1],playToggle=self.hotkeys[0x76][1],stopToggle=self.hotkeys[0x77][1],keys=keys,time=time.time()))
            except OSError: pass
            time.sleep(1/120)
