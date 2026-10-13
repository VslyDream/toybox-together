# Included components

## UE4SS

Version: UE4SS_v3.0.1-1161-g6eb3d9bc, experimental release.

Project and corresponding source: https://github.com/UE4SS-RE/RE-UE4SS/tree/6eb3d9bc

Release archive: https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental/UE4SS_v3.0.1-1161-g6eb3d9bc.zip

MIT license: `payload/loader/ue4ss/LICENSE`.

The package includes the loader, UEHelpers and settings. Lua hot reload and debug windows are disabled. The loader is supplied as its upstream binary.

## Python

Version: CPython 3.13.9, Windows x64 embeddable distribution.

Official distribution: https://www.python.org/ftp/python/3.13.9/python-3.13.9-embed-amd64.zip

Corresponding source: https://github.com/python/cpython/tree/v3.13.9

Python and bundled library license notices: `runtime/LICENSE.txt`.

Only `python313._pth` has been changed to add the relative application directory. The backend uses the standard library.

## json.lua

Project and source: https://github.com/rxi/json.lua

MIT license and copyright notice are included at the beginning of `payload/json.lua`.

No game executables, assets or save data are included.
