# coolcom

A TempleOS-like operating system for arm64 — Apple M1 (booted by m1n1) and QEMU `virt` —
written in **Cool** (our HolyC) with a second, memory-safe language, **Warm** (a fork of
Austral with linear types and capabilities). Everything, including the compilers and the
kernel itself, can be edited and rebuilt from inside the OS.

- **coolvm**: our own Hypervisor.framework VM for Apple silicon Macs (virtio disk, network,
  framebuffer), used for development; QEMU `virt` works too.
- **Kernel**: SMP scheduler, FAT32, TCP/IP, a cell-grid terminal with Hangul and an IME,
  Tmux, Vim, Less, Top, Man, a shell whose command lines are compiled and run as Cool.
- **Cool compiler (`coolc`)**: self-hosting; the OS rebuilds its own compiler and kernel
  byte for byte (`make selfhost-test`, `make kernel-rebuild-test`).
- **Warm compiler (`warmc`)**: written in Cool, runs on the Mac and inside the OS; the
  network packet parser in the kernel is Warm.
- Also: Lua 5.4 translated to Cool through `tools/c2hc`, a Zed extension for both languages.

Start with the [user guide](docs/USER-GUIDE.md): `make run` on an Apple silicon Mac.

## Warm 시작하기

Warm 호스트 도구는 현재 Apple silicon macOS를 지원합니다. Apple Command Line
Tools (`xcode-select --install`), Python 3.12 이상, GNU coreutils (`gtimeout`)를
설치한 뒤 레포에서 다음을 실행하세요. OS 빌드나 VM은 필요하지 않습니다.

```sh
make -j -f tools/toolchain.mk warm-host
export PATH="$PWD/build:$PATH"
```

프로젝트 디렉터리에 `Hello.warm`을 만드세요:

```warm
module body Hello is
    function main(): ExitCode is
        printLn("Hello, Warm!");
        return ExitSuccess();
    end;
end module body.
```

```sh
warm run Hello.warm
warm build Hello.warm -o hello
./hello
warm check
warm fmt
```

`warm test tests/`는 `Test.warm` 또는 `*Test.warm` 테스트 프로그램을 실행합니다.

가져오는 모듈은 소스 디렉터리 아래와 표준 라이브러리에서 자동 탐색합니다.
추가 디렉터리는 `-I lib/`로 지정하며 `warm.toml`은 필요하지 않습니다.
`build` 결과는 레포 없이도 실행할 수 있는 macOS 실행 파일입니다.
명령·모듈 규칙·OS 경계와 Linux 후속 작업은 [toolchain 문서](docs/toolchain.md)를
참고하세요.

Licensed under MIT (`LICENSE`); third-party parts keep their own licenses (`THIRD_PARTY.md`).
