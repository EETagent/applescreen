#!/usr/bin/env python3
"""Configure/check/build the app-owned GN entry with the synchronized toolchain."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from build_codecs import write_changed


def run(command, **kwargs):
    print('+', ' '.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--integration', type=Path, required=True, help='Prepared integration solution')
    parser.add_argument('--codecs', type=Path, required=True, help='Architecture/configuration codecs.json')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--install', type=Path, required=True)
    parser.add_argument('--av1-sender', action='store_true')
    parser.add_argument('--jobs', type=int, default=os.cpu_count() or 4)
    args = parser.parse_args()
    try:
        app = Path(__file__).resolve().parents[1]
        source = args.integration.resolve() / 'openscreen'
        state = json.loads((args.integration / '.applescreen-prepared.json').read_text())
        lock = json.loads((app / 'dependencies.lock.json').read_text())
        expected = {'mode': 'integration', 'repository': lock['openscreen']['repository'],
                    'revision': lock['openscreen']['revision'], 'patches': lock['integration']['patches'], 'app_root': str(app)}
        if state['input'] != expected:
            raise RuntimeError('Core build requires the prepared, currently locked integration')
        actual = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
        staged = subprocess.check_output(['git', '-C', str(source), 'diff', '--cached', '--binary'])
        unstaged = subprocess.check_output(['git', '-C', str(source), 'diff', '--name-only'], text=True)
        if actual != expected['revision'] or unstaged or hashlib.sha256(staged).hexdigest() != state['staged_sha256']:
            raise RuntimeError('Integration source changed after verified preparation')
        codecs = json.loads(args.codecs.read_text())
        if codecs.get('av1_sender') != args.av1_sender:
            raise RuntimeError('Codec manifest has a different AV1 sender configuration')
        if codecs['openscreen_revision'] != lock['openscreen']['revision']:
            raise RuntimeError('Codecs were built with another Open Screen toolchain')
        entry = source / 'applescreen'
        if not entry.is_symlink() or entry.resolve() != app:
            raise RuntimeError('Preparation must install the canonical applescreen GN entry symlink')
        prefixes = {name: Path(value['prefix']) for name, value in codecs['libraries'].items()}
        for value in codecs['libraries'].values():
            for library in value['libraries']:
                if not (Path(value['prefix']) / 'lib' / library).is_file():
                    raise RuntimeError(f'Required codec library is missing: {library}')
        floor = lock['build']['macos_deployment_target']
        gn_args = {
            'is_debug': codecs['configuration'] == 'Debug', 'is_component_build': False, 'target_os': 'mac',
            'target_cpu': 'x64' if codecs['architecture'] == 'x86_64' else 'arm64',
            'mac_deployment_target': floor, 'mac_min_system_version': floor,
            'use_system_xcode': True, 'have_ffmpeg': True, 'have_libopus': True,
            'have_libvpx': True, 'have_libaom': args.av1_sender,
            'ffmpeg_include_dirs': [str(prefixes['ffmpeg'] / 'include')],
            'ffmpeg_lib_dirs': [str(prefixes[name] / 'lib') for name in prefixes],
            # libaom decoding is retained even when its optional sender is disabled.
            'ffmpeg_libs': ['avformat', 'avcodec', 'swresample', 'swscale', 'avutil', 'aom', 'vpx', 'opus'],
            'libopus_include_dirs': [str(prefixes['opus'] / 'include')],
            'libopus_lib_dirs': [str(prefixes['opus'] / 'lib')],
            'libvpx_include_dirs': [str(prefixes['libvpx'] / 'include')],
            'libvpx_lib_dirs': [str(prefixes['libvpx'] / 'lib')],
        }
        if args.av1_sender:
            gn_args.update(libaom_include_dirs=[str(prefixes['libaom'] / 'include')],
                           libaom_lib_dirs=[str(prefixes['libaom'] / 'lib')])
        output = args.output.resolve()
        write_changed(output / 'args.gn', '\n'.join(f'{key} = {json.dumps(value)}' for key, value in gn_args.items()) + '\n')
        gn = source / 'buildtools/mac/gn'
        run([gn, 'gen', output, '--root-target=//applescreen:cast_core', '--check', '--fail-on-unused-args'], cwd=source)
        run([gn, 'check', output, '//applescreen:*', '--root-target=//applescreen:cast_core'], cwd=source)
        run([source / 'third_party/ninja/ninja', '-C', output, f'-j{args.jobs}', 'cast_library'], cwd=source)
        library = output / 'libapplescreen_cast.dylib'
        if not library.is_file():
            raise RuntimeError(f'GN did not produce its declared core library: {library}')
        args.install.mkdir(parents=True, exist_ok=True)
        destination = args.install / library.name
        # copyfile would change mtime and force an application relink on a no-op.
        if not destination.exists() or library.read_bytes() != destination.read_bytes():
            shutil.copy2(library, destination)
        run(['xcrun', 'lipo', destination, '-verify_arch', codecs['architecture']])
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Core build failed: {error}\n')


if __name__ == '__main__':
    main()
