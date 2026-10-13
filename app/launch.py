"""Start the local panel as an independent user application, outside Steam's game tree."""
import ctypes as C
from ctypes import wintypes as W
from pathlib import Path
import os, subprocess, sys, time

class STARTUPINFO(C.Structure):
    _fields_=[('cb',W.DWORD),('reserved',W.LPWSTR),('desktop',W.LPWSTR),('title',W.LPWSTR),('x',W.DWORD),('y',W.DWORD),('xsize',W.DWORD),('ysize',W.DWORD),('xchars',W.DWORD),('ychars',W.DWORD),('fill',W.DWORD),('flags',W.DWORD),('show',W.WORD),('reserved2size',W.WORD),('reserved2',C.c_void_p),('stdin',W.HANDLE),('stdout',W.HANDLE),('stderr',W.HANDLE)]
class STARTUPINFOEX(C.Structure):
    _fields_=[('startup',STARTUPINFO),('attributes',C.c_void_p)]
class PROCESSINFO(C.Structure):
    _fields_=[('process',W.HANDLE),('thread',W.HANDLE),('pid',W.DWORD),('tid',W.DWORD)]

def launch():
    root=Path(sys.executable).resolve().parent.parent; data=root.parent
    kernel=C.WinDLL('kernel32',use_last_error=True);user=C.WinDLL('user32',use_last_error=True)
    user.GetShellWindow.restype=W.HWND
    user.GetWindowThreadProcessId.argtypes=[W.HWND,C.POINTER(W.DWORD)]
    kernel.OpenProcess.restype=W.HANDLE;kernel.OpenProcess.argtypes=[W.DWORD,W.BOOL,W.DWORD]
    kernel.CloseHandle.argtypes=[W.HANDLE]
    kernel.InitializeProcThreadAttributeList.argtypes=[C.c_void_p,W.DWORD,W.DWORD,C.POINTER(C.c_size_t)]
    kernel.UpdateProcThreadAttribute.argtypes=[C.c_void_p,W.DWORD,C.c_size_t,C.c_void_p,C.c_size_t,C.c_void_p,C.c_void_p]
    kernel.DeleteProcThreadAttributeList.argtypes=[C.c_void_p]
    kernel.CreateProcessW.argtypes=[W.LPCWSTR,W.LPWSTR,C.c_void_p,C.c_void_p,W.BOOL,W.DWORD,C.c_void_p,W.LPCWSTR,C.POINTER(STARTUPINFOEX),C.POINTER(PROCESSINFO)]
    pid=W.DWORD();user.GetWindowThreadProcessId(user.GetShellWindow(),C.byref(pid))
    if not pid.value:raise RuntimeError('Windows desktop is unavailable')
    parent=kernel.OpenProcess(0x80,False,pid.value)
    if not parent:raise C.WinError(C.get_last_error())
    initialized=False
    try:
        size=C.c_size_t();kernel.InitializeProcThreadAttributeList(None,1,0,C.byref(size))
        attributes=C.create_string_buffer(size.value)
        if not kernel.InitializeProcThreadAttributeList(attributes,1,0,C.byref(size)):raise C.WinError(C.get_last_error())
        initialized=True; parent_value=W.HANDLE(parent)
        if not kernel.UpdateProcThreadAttribute(attributes,0,0x20000,C.byref(parent_value),C.sizeof(parent_value),None,None):raise C.WinError(C.get_last_error())
        startup=STARTUPINFOEX();startup.startup.cb=C.sizeof(startup);startup.startup.flags=1;startup.startup.show=0;startup.attributes=C.cast(attributes,C.c_void_p)
        args=[str(root/'runtime'/'pythonw.exe'),str(root/'app'/'server.py'),'--data',str(data)]
        if '--open' in sys.argv:args.append('--open')
        command=C.create_unicode_buffer(subprocess.list2cmdline(args));process=PROCESSINFO()
        env={k:v for k,v in os.environ.items() if not k.lower().startswith('steam')}
        environment=C.create_unicode_buffer('\0'.join(k+'='+v for k,v in sorted(env.items()))+'\0\0')
        if not kernel.CreateProcessW(args[0],command,None,None,False,0x80000|0x400|0x8000000,environment,str(root),C.byref(startup),C.byref(process)):raise C.WinError(C.get_last_error())
        kernel.CloseHandle(process.thread);kernel.CloseHandle(process.process)
    finally:
        if initialized:kernel.DeleteProcThreadAttributeList(attributes)
        kernel.CloseHandle(parent)

if __name__=='__main__':
    try:launch()
    except Exception as e:
        data=Path(__file__).resolve().parents[2]
        with (data/'startup.log').open('a',encoding='utf-8') as f:f.write(time.strftime('%Y-%m-%d %H:%M:%S')+' '+str(e)+'\n')
        if '--open' in sys.argv:C.windll.user32.MessageBoxW(None,'Не удалось открыть панель. Подробности в startup.log.','Toybox Together',0x10)
