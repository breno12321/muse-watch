#!/usr/bin/env python3
"""Prepare pinned, English-only model inputs for MusePhone. No test app is created."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / 'scripts/speech'
LOCAL = ROOT / '.local/speech-conversion'
CORE_REVISION = '484907db6a8347a6afb6e7b86850ea2878c6a3fb'
MODEL_REVISION = 'f3ff3571791e39611d31c381e3a41a3af07b4987'
ENV = dict(os.environ, HF_HUB_DISABLE_IMPLICIT_TOKEN='1', HF_HOME=str(LOCAL / 'hf'),
           UV_CACHE_DIR=str(LOCAL / 'uv-cache'))
ENV.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')


def run(*args, cwd=ROOT):
    subprocess.run([str(x) for x in args], cwd=cwd, env=ENV, check=True)


def sources():
    core = LOCAL / 'coreml'
    marker = core / '.source-revision'
    if core.exists():
        if not marker.exists() or marker.read_text().strip() != CORE_REVISION:
            raise RuntimeError('Unexpected conversion source; preserve it before preparing pinned sources.')
    else:
        LOCAL.mkdir(parents=True, exist_ok=True)
        url = 'https://codeload.github.com/laishere/kokoro-coreml/tar.gz/' + CORE_REVISION
        with urllib.request.urlopen(url, timeout=60) as response:
            archive = response.read()
        prefix = 'kokoro-coreml-' + CORE_REVISION + '/'
        with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as source:
            for member in source.getmembers():
                if not member.isfile() or not member.name.startswith(prefix):
                    continue
                relative = Path(member.name[len(prefix):])
                if relative.is_absolute() or '..' in relative.parts:
                    raise RuntimeError('Unexpected conversion archive path.')
                target = core / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.extractfile(member).read())
        marker.write_text(CORE_REVISION + '\n')
    shutil.copy2(CONFIG / 'conversion.uv.lock', core / 'uv.lock')
    shutil.copy2(CONFIG / 'conversion.pyproject.toml', core / 'pyproject.toml')
    run('uv', 'sync', '--frozen', '--python', '3.11.17', cwd=core)


def convert():
    core = LOCAL / 'coreml'
    python = core / '.venv/bin/python'
    # Public immutable model inputs only; never send implicit Hugging Face credentials.
    script = f'''
from huggingface_hub import hf_hub_download
import torch, json, pathlib, hashlib
root = pathlib.Path({str(LOCAL)!r})
assets = root / 'assets'; assets.mkdir(exist_ok=True)
files = ['config.json', 'kokoro-v1_0.pth', 'voices/af_heart.pt']
paths = {{name: hf_hub_download('hexgrad/Kokoro-82M', name, revision={MODEL_REVISION!r}, token=False) for name in files}}
checksums = {{name: hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest() for name, path in paths.items()}}
expected = json.loads(pathlib.Path({str(CONFIG / 'download-checksums.json')!r}).read_text())
assert checksums == expected, 'Pinned model/voice checksum mismatch'
(root / 'download-paths.json').write_text(json.dumps(paths))
(assets / 'vocab.json').write_text(json.dumps(json.loads(pathlib.Path(paths['config.json']).read_text())['vocab']))
tensor = torch.load(paths['voices/af_heart.pt'], map_location='cpu', weights_only=True)
assert tuple(tensor.shape) == (510, 1, 256)
tensor.float().numpy().astype('<f4').tofile(assets / 'af_heart.bin')
'''
    run(python, '-c', script)
    paths = json.loads((LOCAL / 'download-paths.json').read_text())
    original = (core / 'convert.py').read_text()
    start = original.index('    CU_LIST = ')
    end = original.index('\n\n    def bench', start)
    changed = original[:start] + "    CU_LIST = [('CPU_AND_NE', ct.ComputeUnit.CPU_AND_NE)]" + original[end:]
    changed = changed.replace('compute_units=ct.ComputeUnit.ALL', 'compute_units=ct.ComputeUnit.CPU_AND_NE')
    changed = changed.replace('model = KModel()', f"model = KModel(config={paths['config.json']!r}, model={paths['kokoro-v1_0.pth']!r})")
    changed = changed.replace("    from kokoro.pipeline import KPipeline\n    pipe = KPipeline(lang_code='a', model=model)\n    voice_pack = pipe.load_voice('af_heart')", f"    voice_pack = torch.load({paths['voices/af_heart.pt']!r}, map_location='cpu', weights_only=True)")
    (core / 'convert-local.py').write_text(changed)
    # Preserve upstream validation failures. Explicit collect-models is available
    # only after inspecting a conversion that wrote all seven packages before failing.
    run(python, 'convert-local.py', cwd=core)
    collect_models()


def collect_models():
    packages = sorted((LOCAL / 'coreml/output').glob('*.mlpackage'))
    if len(packages) != 7:
        raise RuntimeError('Expected seven model packages; inspect the conversion output.')
    destination = LOCAL / 'models'
    destination.mkdir(exist_ok=True)
    for package in packages:
        shutil.copytree(package, destination / package.name, dirs_exist_ok=True)
    for name in ['af_heart.bin', 'vocab.json']:
        if not (LOCAL / 'assets' / name).is_file():
            raise RuntimeError('English voice and vocabulary must be prepared first.')
    entries = {str(p.relative_to(LOCAL)): hashlib.sha256(p.read_bytes()).hexdigest()
               for folder in ['models', 'assets'] for p in sorted((LOCAL / folder).rglob('*')) if p.is_file()}
    (LOCAL / 'asset-manifest.json').write_text(json.dumps(entries, indent=2, sort_keys=True) + '\n')
    print('Sealed seven model packages and English voice/vocabulary. Run scripts/prepare_speech.py.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['sources', 'convert', 'collect-models'])
    args = parser.parse_args()
    {'sources': sources, 'convert': convert, 'collect-models': collect_models}[args.phase]()
