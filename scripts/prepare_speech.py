#!/usr/bin/env python3
"""Stage verified English-only Kokoro resources. No native phonemizer is linked."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request
import io

ROOT = Path(__file__).resolve().parent.parent
INPUTS = ROOT / '.local/speech-conversion'
DEST = ROOT / '.local/speech'
MISAKI_REVISION = '20bf04c506e913ff129d7d2229398180ba24c690'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def entries():
    return {str(p.relative_to(DEST)): digest(p) for folder in ('models', 'resources', 'Misaki')
            for p in sorted((DEST / folder).rglob('*')) if p.is_file()
            and not any(part in ('.build', '.swiftpm') for part in p.relative_to(DEST).parts)}


def verify():
    expected = json.loads((DEST / 'manifest.json').read_text())
    if expected != entries():
        raise RuntimeError('Speech assets changed. Run scripts/prepare_speech.py after reviewing the pinned inputs.')
    if len(list((DEST / 'models').glob('*.mlpackage'))) != 7:
        raise RuntimeError('All seven Kokoro models are required.')


def prepare(replace=False):
    if (DEST / 'manifest.json').exists() and not replace:
        verify()
        copy_notices()
        (DEST / 'manifest.json').write_text(json.dumps(entries(), indent=2, sort_keys=True) + '\n')
        print('Existing production speech assets verified.')
        return
    # Reuse sealed production conversion inputs; no experiment checkout is needed.
    manifest = json.loads((INPUTS / 'asset-manifest.json').read_text())
    selected = {name: value for name, value in manifest.items()
                if name.startswith('models/') or name in ('assets/af_heart.bin', 'assets/vocab.json')}
    if not selected or any(digest(INPUTS / name) != value for name, value in selected.items()):
        raise RuntimeError('Conversion inputs are missing or changed; follow scripts/speech/README.md.')
    DEST.mkdir(parents=True, exist_ok=True)
    archive = DEST / 'misaki-source.tar.gz'
    if not archive.exists():
        with urllib.request.urlopen('https://codeload.github.com/mweinbach/kokoro-swift/tar.gz/' + MISAKI_REVISION, timeout=60) as response:
            archive.write_bytes(response.read())
    for name in selected:
        target = DEST / name.replace('assets/', 'resources/', 1)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(INPUTS / name, target)
    # Extract only regular package/license files from the immutable revision archive.
    with tarfile.open(fileobj=io.BytesIO(archive.read_bytes()), mode='r:gz') as source:
        prefix = 'kokoro-swift-' + MISAKI_REVISION + '/'
        for member in source.getmembers():
            if not member.isfile() or not member.name.startswith(prefix):
                continue
            relative = member.name[len(prefix):]
            if relative == 'LICENSE':
                target = DEST / 'resources/LICENSE-Misaki.txt'
            elif relative.startswith('Packages/Misaki/') and '..' not in Path(relative).parts:
                target = DEST / relative.removeprefix('Packages/')
            else:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.extractfile(member).read())
    copy_notices()
    (DEST / 'manifest.json').write_text(json.dumps(entries(), indent=2, sort_keys=True) + '\n')
    verify()
    print('Verified seven models, one English voice, vocabulary and pinned Swift pronunciation package.')


def copy_notices():
    shutil.copy2(ROOT / 'LocalSpeech/LICENSE-CoreML', DEST / 'resources/LICENSE-CoreML.txt')
    shutil.copy2(ROOT / 'LocalSpeech/NOTICE.md', DEST / 'resources/Speech-NOTICE.txt')


def compile_mac():
    verify()
    destination = DEST / 'mac'
    destination.mkdir(exist_ok=True)
    for package in sorted((DEST / 'models').glob('*.mlpackage')):
        subprocess.run(['xcrun', 'coremlcompiler', 'compile', str(package), str(destination)], check=True)
    for name in ['af_heart.bin', 'vocab.json']:
        shutil.copy2(DEST / 'resources' / name, destination / name)
    print('Mac synthesis test assets prepared in .local/speech/mac.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--verify', action='store_true')
    mode.add_argument('--replace', action='store_true', help='Restage reviewed conversion inputs.')
    mode.add_argument('--compile-mac', action='store_true', help='Compile prepared models for local synthesis tests.')
    args = parser.parse_args()
    if args.verify: verify()
    elif args.compile_mac: compile_mac()
    else: prepare(replace=args.replace)
