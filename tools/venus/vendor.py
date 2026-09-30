#!/usr/bin/env python3
"""Fetch immutable generator inputs into gitignored vendor/."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
VK_REV = '354fab82dbd91d2526a41ee4dbfff1012a623798'  # Vulkan-Headers v1.4.357
VK_SHA256 = '264d0d7350e37d70c82407fb430d085040fc01a9a961d43dec8c2d6ed1dfd183'
VN_REV = 'ca19b6358d7cc491bc3e4de76f04c6700876a8fa'  # venus-protocol 1.1.3
VN_URL = 'https://gitlab.freedesktop.org/virgl/venus-protocol.git'

def check():
    vk = ROOT / 'vendor/vk.xml'
    vn = ROOT / 'vendor/venus-protocol'
    if not vk.exists() or hashlib.sha256(vk.read_bytes()).hexdigest() != VK_SHA256:
        raise SystemExit('vk.xml missing or modified; run tools/vendor-venus.sh')
    if subprocess.check_output(['git', '-C', str(vn), 'rev-parse', 'HEAD'], text=True).strip() != VN_REV:
        raise SystemExit('venus-protocol revision mismatch')
    if subprocess.check_output(['git', '-C', str(vn), 'status', '--porcelain', '--untracked-files=no'], text=True).strip():
        raise SystemExit('venus-protocol has modified tracked inputs')
    return vk, vn

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--test', action='store_true', help='also fetch pinned C oracle template dependencies')
    args = parser.parse_args()
    (ROOT / 'vendor').mkdir(exist_ok=True)
    vk = ROOT / 'vendor/vk.xml'
    if not vk.exists():
        data = urllib.request.urlopen(
            f'https://raw.githubusercontent.com/KhronosGroup/Vulkan-Headers/{VK_REV}/registry/vk.xml', timeout=60).read()
        if hashlib.sha256(data).hexdigest() != VK_SHA256:
            raise SystemExit('vk.xml download checksum mismatch')
        tmp = vk.with_suffix('.tmp')
        tmp.write_bytes(data)
        tmp.replace(vk)
    vn = ROOT / 'vendor/venus-protocol'
    if not vn.exists():
        subprocess.run(['git', 'clone', '--no-checkout', VN_URL, str(vn)], check=True)
        subprocess.run(['git', '-C', str(vn), 'checkout', '--detach', VN_REV], check=True)
    check()
    if args.test:
        env = ROOT / 'vendor/venus-python'
        if not env.exists():
            subprocess.run(['python3', '-m', 'venv', str(env)], check=True)
        python = env / 'bin/python'
        versions = subprocess.run([str(python), '-c', 'import mako, markupsafe; from importlib.metadata import version; assert version("Mako")=="1.3.10" and version("MarkupSafe")=="3.0.3"'], capture_output=True)
        if versions.returncode:
            subprocess.run([str(python), '-m', 'pip', 'install', 'Mako==1.3.10', 'MarkupSafe==3.0.3'], check=True)
    print(f'Venus 1.1.3 ({VN_REV}); Vulkan-Headers v1.4.357 ({VK_REV})')

if __name__ == '__main__':
    main()
