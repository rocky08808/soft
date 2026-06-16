# -*- mode: python ; coding: utf-8 -*-
# Build: python -m PyInstaller --clean --noconfirm term_agent.spec
# Output: dist/ReST/ (onedir, avoids onefile temp extraction that triggers Defender)

block_cipher = None

a = Analysis(
    ['term_agent.py'],
    pathex=[],
    binaries=[],
    datas=[('../agent/agent.config.json', '.')],
    hiddenimports=['websockets', 'websockets.legacy.client'],
    hookspath=[],
    runtime_hooks=[],
    excludes=[
        'tkinter',
        'matplotlib',
        'numpy',
        'cv2',
        'scipy',
        'pandas',
        'PIL',
        'IPython',
        'notebook',
        'pytest',
        'setuptools',
        'distutils',
        'pydoc',
        'doctest',
        'unittest',
        'lib2to3',
        'curses',
        'xmlrpc',
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='ReST',
    debug=False,
    bootloader_ignore_signals=False,
    strip=True,
    upx=True,
    console=False,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=True,
    upx=True,
    name='ReST',
)
