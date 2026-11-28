#!/usr/bin/env python3
"""Package source only, including exact dependency pins and validation records."""
from pathlib import Path
from zipfile import ZipFile,ZIP_DEFLATED
import hashlib
root=Path(__file__).resolve().parents[1]
output=root.parent/'Parano1d-AppStore-Source.zip'
exclude={'target','node_modules','dist','.git','__pycache__','Headers','TestResults','NodeParameters','DerivedData'}
with ZipFile(output,'w',ZIP_DEFLATED,compresslevel=9) as archive:
    for path in sorted(root.rglob('*')):
        relative=path.relative_to(root)
        if any(p in exclude or p.endswith(('.xcframework','.xcodeproj')) for p in relative.parts): continue
        if path.is_symlink(): raise SystemExit('Refusing symlink: '+str(relative))
        if not path.is_file(): continue
        if path.name.startswith('.env') or path.suffix in {'.p12','.mobileprovision'}: raise SystemExit('Refusing credential file: '+str(relative))
        archive.write(path,Path(root.name)/relative)
with ZipFile(output) as archive:
    assert archive.testzip() is None
    names=set(archive.namelist())
    for required in ['README.md','PUBLIC-EDITION.md','Scripts/validate-public.sh','Scripts/archive-public.sh','App/WalletVault.swift','WatchApp/ParanoidWatchApp.swift','Native/Cargo.lock','Node/Cargo.lock','project-public.yml']:
        assert root.name+'/'+required in names
print(output)
print('bytes:',output.stat().st_size)
print('sha256:',hashlib.sha256(output.read_bytes()).hexdigest())
