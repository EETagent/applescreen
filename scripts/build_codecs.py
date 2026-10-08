#!/usr/bin/env python3
"""Build the locked codec libraries with Open Screen's DEPS-pinned compiler.

Sources are immutable; each dependency, architecture and input fingerprint has a
separate build/install directory. A completed invocation verifies its outputs and
returns without configuring or rebuilding. No sibling source tree is modified.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess


def run(command, **kwargs):
    print('+', ' '.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True, **kwargs)


def capture(command):
    return subprocess.check_output(list(map(str, command)), text=True).strip()


def write_changed(path, contents):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_text() != contents:
        path.write_text(contents)


@contextmanager
def exclusive(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def checkout(root, name, pin):
    # Universal builds share only immutable source repositories. Serialize each
    # first fetch so two architecture targets cannot race Git's index/ref locks.
    with exclusive(root / 'sources' / name / '.checkout.lock'):
        return checkout_locked(root, name, pin)


def checkout_locked(root, name, pin):
    source = root / 'sources' / name / pin['revision']
    if not (source / '.git').exists():
        source.mkdir(parents=True, exist_ok=True)
        if any(source.iterdir()):
            raise RuntimeError(f'Refusing nonempty source directory: {source}')
        run(['git', 'init', source])
        run(['git', '-C', source, 'remote', 'add', 'origin', pin['repository']])
    if capture(['git', '-C', source, 'remote', 'get-url', 'origin']) != pin['repository']:
        raise RuntimeError(f'Unexpected source origin: {source}')
    head = subprocess.run(['git', '-C', str(source), 'rev-parse', '--verify', 'HEAD'],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    if head.returncode:
        if capture(['git', '-C', source, 'status', '--porcelain']):
            raise RuntimeError(f'Refusing files in an incomplete checkout: {source}')
        run(['git', '-C', source, '-c', 'http.version=HTTP/1.1', 'fetch', '--depth=1',
             'origin', pin['revision']])
        run(['git', '-C', source, 'checkout', '--detach', pin['revision']])
    actual = capture(['git', '-C', source, 'rev-parse', 'HEAD'])
    if actual != pin['revision'] or capture(['git', '-C', source, 'diff', 'HEAD', '--name-only']):
        raise RuntimeError(f'Unexpected source revision or changes: {source}')
    return source


def build(args):
    app = Path(__file__).resolve().parents[1]
    lock = json.loads((app / 'dependencies.lock.json').read_text())
    floor = lock['build']['macos_deployment_target']
    if capture(['git', '-C', args.openscreen, 'rev-parse', 'HEAD']) != lock['openscreen']['revision']:
        raise RuntimeError('The selected Open Screen checkout does not match the dependency lock')
    llvm = args.openscreen / 'third_party/llvm-build/Release+Asserts/bin'
    cc, cxx = llvm / 'clang', llvm / 'clang++'
    if not cc.exists():
        raise RuntimeError('Open Screen DEPS compiler is missing; run preparation and hooks first')
    sdk = capture(['xcrun', '--sdk', 'macosx', '--show-sdk-path'])
    sdk_version = capture(['xcrun', '--sdk', 'macosx', '--show-sdk-version'])
    arch = args.arch
    flags = f'-arch {arch} -isysroot {sdk} -mmacosx-version-min={floor} -fPIC'
    env = os.environ.copy()
    env.update(CC=str(cc), CXX=str(cxx), AR=str(llvm / 'llvm-ar'),
               CFLAGS=flags, CXXFLAGS=flags, LDFLAGS=flags,
               MACOSX_DEPLOYMENT_TARGET=floor)
    configuration = args.configuration
    base = args.workspace / arch / configuration
    result = {'architecture': arch, 'configuration': configuration, 'deployment_target': floor,
              'openscreen_revision': lock['openscreen']['revision'], 'av1_sender': args.av1_sender,
              'upstream_encoder_tests': args.upstream_encoder_tests, 'libraries': {}}
    common = {'script_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'compiler': capture([cc, '--version']), 'sdk': sdk, 'sdk_version': sdk_version,
              'arch': arch, 'configuration': configuration, 'deployment_target': floor, 'av1_sender': args.av1_sender}
    for name in ('opus', 'libvpx', 'libaom', 'ffmpeg'):
        pin = lock['libraries'][name]
        source = checkout(args.workspace, name, pin)
        inputs = dict(common, library=pin, dependencies=result['libraries'])
        if name == 'ffmpeg': inputs['upstream_encoder_tests'] = args.upstream_encoder_tests
        fingerprint = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()[:16]
        directory = base / name / fingerprint
        prefix, work = directory / 'install', directory / 'build'
        outputs = ['libavcodec.a', 'libavformat.a', 'libavutil.a', 'libswresample.a', 'libswscale.a'] \
            if name == 'ffmpeg' else [{'opus': 'libopus.a', 'libvpx': 'libvpx.a', 'libaom': 'libaom.a'}[name]]
        stamp = directory / 'completed.json'
        if stamp.exists():
            if json.loads(stamp.read_text()) != inputs or any(not (prefix / 'lib' / x).is_file() for x in outputs):
                raise RuntimeError(f'Completed codec install was changed or is incomplete: {directory}')
            print(f'Already built: {name} ({arch}, {configuration})', flush=True)
        else:
            work.mkdir(parents=True, exist_ok=True)
            if name in ('opus', 'libaom'):
                command = ['cmake', '-S', source, '-B', work, '-G', 'Ninja',
                           f'-DCMAKE_INSTALL_PREFIX={prefix}', f'-DCMAKE_C_COMPILER={cc}',
                           f'-DCMAKE_CXX_COMPILER={cxx}', f'-DCMAKE_AR={llvm / "llvm-ar"}',
                           f'-DCMAKE_OSX_ARCHITECTURES={arch}', f'-DCMAKE_OSX_SYSROOT={sdk}',
                           f'-DCMAKE_OSX_DEPLOYMENT_TARGET={floor}',
                           f'-DCMAKE_BUILD_TYPE={configuration}', '-DBUILD_SHARED_LIBS=OFF',
                           '-DCMAKE_POSITION_INDEPENDENT_CODE=ON', '-DCMAKE_INSTALL_LIBDIR=lib']
                command += ['-DOPUS_BUILD_TESTING=OFF', '-DOPUS_BUILD_PROGRAMS=OFF'] if name == 'opus' else [
                    '-DENABLE_DOCS=OFF', '-DENABLE_EXAMPLES=OFF', '-DENABLE_TESTS=OFF',
                    '-DENABLE_TOOLS=OFF', f'-DCONFIG_AV1_ENCODER={int(args.av1_sender)}',
                    f'-DAOM_TARGET_CPU={"arm64" if arch == "arm64" else "x86_64"}']
                run(command, env=env)
                run(['cmake', '--build', work, '--parallel', args.jobs], env=env)
                run(['cmake', '--install', work], env=env)
            elif name == 'libvpx':
                run([source / 'configure', f'--prefix={prefix}',
                     f'--target={arch}-darwin20-gcc', '--disable-examples', '--disable-tools',
                     '--disable-docs', '--disable-unit-tests', '--disable-shared', '--enable-pic',
                     '--enable-vp9-highbitdepth', f'--extra-cflags={flags}',
                     f'--extra-cxxflags={flags}',
                     '--enable-debug' if configuration == 'Debug' else '--disable-debug'], cwd=work, env=env)
                run(['make', f'-j{args.jobs}'], cwd=work, env=env)
                run(['make', 'install'], cwd=work, env=env)
            elif name == 'ffmpeg':
                prefixes = [Path(value['prefix']) for value in result['libraries'].values()]
                ffenv = env.copy()
                ffenv['PKG_CONFIG_LIBDIR'] = os.pathsep.join(str(p / 'lib/pkgconfig') for p in prefixes)
                ffenv.pop('PKG_CONFIG_PATH', None)
                # Optional validation profile supplies factories required by
                # untouched upstream encoder tests. It adds no app codec option.
                validation_encoders = ['--enable-encoder=h264_videotoolbox',
                                       '--enable-encoder=hevc_videotoolbox'] if args.upstream_encoder_tests else []
                includes = ' '.join(f'-I{p}/include' for p in prefixes)
                libraries = ' '.join(f'-L{p}/lib' for p in prefixes)
                run([source / 'configure', f'--prefix={prefix}', '--target-os=darwin',
                     f'--arch={"aarch64" if arch == "arm64" else arch}', f'--cc={cc}', f'--cxx={cxx}',
                     f'--ar={llvm / "llvm-ar"}', '--enable-cross-compile', '--enable-static', '--disable-shared',
                     '--disable-autodetect', '--disable-doc', '--disable-programs', '--disable-network',
                     '--disable-avdevice', '--disable-avfilter', '--disable-encoders', '--disable-securetransport',
                     '--disable-sdl2', '--disable-xlib', '--enable-videotoolbox', '--enable-audiotoolbox',
                     '--enable-libopus', '--enable-libvpx', '--enable-libaom', '--pkg-config-flags=--static',
                     f'--extra-cflags={flags} {includes}', f'--extra-ldflags={flags} {libraries}',
                     '--enable-debug' if configuration == 'Debug' else '--disable-debug', *validation_encoders], cwd=work, env=ffenv)
                run(['make', f'-j{args.jobs}'], cwd=work, env=ffenv)
                run(['make', 'install'], cwd=work, env=ffenv)
            if any(not (prefix / 'lib' / x).is_file() for x in outputs):
                raise RuntimeError(f'Required {name} installation output is missing')
            stamp.write_text(json.dumps(inputs, indent=2, sort_keys=True) + '\n')
        current = base / 'current' / name
        current.parent.mkdir(parents=True, exist_ok=True)
        if current.is_symlink():
            if current.resolve() != prefix:
                current.unlink()
        elif current.exists():
            raise RuntimeError(f'Refusing non-symlink install alias: {current}')
        if not current.exists():
            current.symlink_to(prefix, target_is_directory=True)
        result['libraries'][name] = {'revision': pin['revision'], 'prefix': str(prefix), 'libraries': outputs}
    manifest = base / 'codecs.json'
    write_changed(manifest, json.dumps(result, indent=2) + '\n')
    print(manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=lambda p: Path(p).resolve(), required=True)
    parser.add_argument('--openscreen', type=lambda p: Path(p).resolve(), required=True)
    parser.add_argument('--arch', choices=('arm64', 'x86_64'), default=platform.machine())
    parser.add_argument('--configuration', choices=('Debug', 'Release'), default='Debug')
    parser.add_argument('--av1-sender', action='store_true')
    parser.add_argument('--upstream-encoder-tests', action='store_true',
                        help='Validation-only FFmpeg H.264/HEVC VideoToolbox encoder factories')
    parser.add_argument('--jobs', type=int, default=os.cpu_count() or 4)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    try:
        with exclusive(args.workspace / args.arch / args.configuration / '.build.lock'):
            build(args)
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Codec build failed: {error}\n')


if __name__ == '__main__':
    main()
