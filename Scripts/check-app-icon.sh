#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
icon=App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
expected=7432c4305642cfcb2898fb81766882c59c1049cc159a35c190ff18360e67b404
actual="$(shasum -a 256 "$icon" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || {
  echo 'Wrong AppIcon.png: expected the approved clean-background Parano1d World circled-1 icon. Stop before archiving.' >&2
  exit 1
}
brand=App/Assets.xcassets/Brand.imageset/Brand.png
brand_expected=5f32e921d2ad44da2fe92ff9e884ce7c0e6d3c21dc85ad15b1ee7a657ac869bf
brand_actual="$(shasum -a 256 "$brand" | awk '{print $1}')"
[[ "$brand_actual" == "$brand_expected" ]] || {
  echo 'Wrong in-app Brand.png: expected the new Parano1d World circled-1 artwork.' >&2
  exit 1
}
wordmark=App/Assets.xcassets/BrandWordmark.imageset/BrandWordmark.png
wordmark_expected=64bb1af6d1f51b94c70945753197e9b55706e48b05f6ebca3c587b5dab1ee77d
[[ "$(shasum -a 256 "$wordmark" | awk '{print $1}')" == "$wordmark_expected" ]] || {
  echo 'Wrong full Parano1d World wordmark.' >&2
  exit 1
}
wordmark_light=App/Assets.xcassets/BrandWordmark.imageset/BrandWordmark-Light.png
wordmark_light_expected=4255a85490e5892ccc1729cba4544513e263c020688ea56a92e72b7acc53cba6
[[ "$(shasum -a 256 "$wordmark_light" | awk '{print $1}')" == "$wordmark_light_expected" ]] || {
  echo 'Wrong light-mode Parano1d World wordmark.' >&2
  exit 1
}
coin=App/Assets.xcassets/NOIDCoin.imageset/NOIDCoin.png
coin_expected=1a2dbbbcbc70aa5ae98da32d3275dc7bbd553cf9357461c94816df9d48e58796
[[ "$(shasum -a 256 "$coin" | awk '{print $1}')" == "$coin_expected" ]] || {
  echo 'The NOID asset icon must remain separate from the app brand.' >&2
  exit 1
}
python3 - <<'PY'
import json
from pathlib import Path
item=json.loads(Path('App/Assets.xcassets/AppIcon.appiconset/Contents.json').read_text())['images']
assert any(i.get('filename')=='AppIcon.png' and i.get('size')=='1024x1024' for i in item), 'AppIcon asset catalog does not select the full-size PNG'
project=Path('project-public.yml').read_text()
assert 'ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon' in project, 'Project does not select AppIcon'
print('Logo verified: Parano1d World app branding and separate NOID coin icon.')
PY
