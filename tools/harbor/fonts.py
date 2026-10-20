#!/usr/bin/env python3
"""Create static faces for the native rasterizer, which has no variable-font support.
Regenerate with: guix shell python python-fonttools -- python3 tools/harbor/fonts.py
Source and derived faces remain under assets/branding/fonts/Nunito-OFL.txt.
"""
from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

fonts = Path(__file__).resolve().parents[2] / 'assets' / 'branding' / 'fonts'
for name, weight in [('Regular', 400), ('SemiBold', 600), ('Bold', 700)]:
    font = TTFont(fonts / 'Nunito.ttf', recalcTimestamp=False)
    instance = instantiateVariableFont(font, {'wght': weight}, inplace=True,
                                       updateFontNames=True)
    instance.save(fonts / f'Nunito-{name}.ttf')
