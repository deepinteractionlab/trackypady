#!/usr/bin/env python3
"""Build a separate local Mac app. No installation, ledger, or distribution signing."""
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
subprocess.run(['swift', 'build', '--package-path', str(root)], check=True)
bin_path = Path(subprocess.check_output(['swift', 'build', '--package-path', str(root), '--show-bin-path'], text=True).strip())
app = root / '.build/Local/Trackypady Bridge Local.app'
if app.exists():
    shutil.rmtree(app)
(app/'Contents/MacOS').mkdir(parents=True)
(app/'Contents/Resources').mkdir()
shutil.copy2(bin_path/'TrackypadyBridge', app/'Contents/MacOS/TrackypadyBridge')
shutil.copy2(root/'MacSupport/Branding/Trackypady.icns', app/'Contents/Resources/Trackypady.icns')
shutil.copy2(root/'MacSupport/Info.plist', app/'Contents/Info.plist')
# Preserve required license/attribution material in the local package too.
for name in ('LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md', 'ASSETS.md'):
    source = root/name
    if source.is_file():
        shutil.copy2(source, app/'Contents/Resources'/name)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
print(f'Local ad hoc-signed app: {app}')
print('Not installed or notarized. See docs/building.md before running alongside the official bridge.')
