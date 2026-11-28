#!/usr/bin/env python3
"""Validate bundled pinned sources; no checkout can silently change a build."""
import hashlib,json,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
checks=[('parano1d-sdk','sdk-integrity.json')]
if '--with-mobile' in sys.argv: checks.append(('paramo1d','mobile-integrity.json'))
for folder,manifest in checks:
    expected=json.loads((root/'Vendor'/manifest).read_text())
    ignored={'target','node_modules','dist','.git','__pycache__'}
    actual={str(p.relative_to(root/'Vendor'/folder)) for p in (root/'Vendor'/folder).rglob('*') if p.is_file() and not any(part in ignored for part in p.relative_to(root/'Vendor'/folder).parts)}
    if actual != set(expected): raise SystemExit('Unexpected or missing bundled source files: '+folder+' '+str(actual ^ set(expected)))
    for name,digest in expected.items():
        path=root/'Vendor'/folder/name
        if not path.is_file() or path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest()!=digest:
            raise SystemExit('Bundled source integrity failed: '+folder+'/'+name)
    print(folder+': pinned source integrity verified')
