#!/usr/bin/env python3
"""Apply our explicit platform patches, or verify they are already applied."""
from pathlib import Path
import subprocess
import sys
root=Path(__file__).resolve().parents[3]
source=Path(sys.argv[1])
for name in sys.argv[2:]:
    patch=root/'ports/nyxt/wpe/patches'/name
    common=['patch','--batch','-p1','-i',str(patch)]
    if subprocess.run(common+['--dry-run','--forward'],cwd=source,
                      stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:
        subprocess.run(common+['--forward'],cwd=source,check=True)
    else:
        subprocess.run(common+['--dry-run','--force','--reverse'],cwd=source,check=True)
