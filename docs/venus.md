# Venus: Vulkan for coolcom

Status: decisions accepted. Kernel transport, the guest subset generator and the
optional real host renderer are implemented. Milestone 1 passes with real guest
memory coherence, Vulkan triangle rendering and blob scanout pixel validation.
See [generator usage](../tools/venus/README.md) and the host validation log below.
The goal is one general GPU API, Vulkan,
used for everything (the terminal, images, 3D, compute). It reaches the host through
virtio-gpu **Venus**: under coolvm on the Mac through virglrenderer and MoltenVK to Metal,
and under QEMU on Linux hosts through virglrenderer to the host's Vulkan driver. Logos
([logos.md](logos.md)) stays as it is until the terminal runs on Vulkan; then its custom
channel retires. The original choices are listed with options and a recommendation
(**Rec.**), and collected at the end.

How Venus works, in short. Venus is a Vulkan driver in Mesa (`src/virtio/vulkan`). It does
not run Vulkan in the guest: it serializes every Vulkan call into a command stream, which
the host's virglrenderer (its `vkr` renderer) decodes and replays on a real Vulkan driver.
The wire format is generated from `vk.xml` by the venus-protocol project. Commands travel
through a shared-memory ring, and replies through a reply buffer. Memory that both sides
touch (mapped buffers, the ring) is virtio-gpu *blob* memory mapped into the guest.
Swapchains are not part of the protocol: the guest shows images through ordinary virtio-gpu
scanout.

## 1. The guest Vulkan layer, without porting Mesa

Mesa's Venus driver is C that expects Linux (DRM, dma-buf, the Vulkan loader). We write only
the part that matters for us, and generate most of it.

- **The generator** (`tools/venus/gen.py`) reads `vk.xml` (Khronos) and the venus-protocol
  definitions (the Venus-specific commands and the encoding rules). It emits Cool:
  - a class per Vulkan struct, with Vulkan's field names;
  - enums and flags as `#define`s;
  - for each command, an encoder that appends the Venus wire form to a command stream
    (the command id, flags, then the arguments: handles as 64-bit object ids, counts before
    arrays, `pNext` chains, optional pointers as a presence word);
  - decoders for replies.

  Object handles are ids the guest allocates, as in Mesa's Venus. A command that returns
  something (`vkCreate*` results, `vkWaitForFences`, queries) is encoded with the "reply"
  flag and decoded from the reply stream.
- **Only a listed subset is generated.** `tools/venus/subset.txt` names the commands; the
  generator pulls in the types they reach. Adding a command is a line in that file plus a
  test. The first list:
  - Instance and device: `vkCreateInstance`, `vkEnumeratePhysicalDevices`,
    `vkGetPhysicalDevice{Properties2,Features2,MemoryProperties,QueueFamilyProperties}`,
    `vkCreateDevice`, `vkGetDeviceQueue`, and the matching destroy calls.
  - Memory: `vkAllocateMemory` (host-visible memory is a blob, see 2), `vkMapMemory` as a
    guest-side operation on the blob mapping, `vkFlush/InvalidateMappedMemoryRanges`,
    `vkGetBuffer/ImageMemoryRequirements`, `vkBindBuffer/ImageMemory`.
  - Resources: buffers, images, image views, samplers.
  - Shaders and pipelines: shader modules, descriptor set layouts, descriptor pools and
    sets and their updates, pipeline layouts, graphics and compute pipelines.
  - Rendering: `VK_KHR_dynamic_rendering`, so no render passes or framebuffers
    (MoltenVK supports it).
  - Commands: command pools and buffers, `vkBegin/EndCommandBuffer`, and `vkCmd*` for
    begin/end rendering, bind pipeline, descriptor sets, vertex and index buffers, draw,
    dispatch, copy buffer to/from image, pipeline barrier, push constants, viewport and
    scissor.
  - Submission and sync: `vkQueueSubmit`, fences (create, wait, reset), semaphores, and
    `vkDeviceWaitIdle`.
  - Venus's own commands: create and notify the ring, set the reply stream, execute
    command streams, and wait for a ring sequence number.

  The list then grows by use: query pools and timestamps for profiling, timeline
  semaphores, larger compute features.
- **Hand-written parts** (`os/Vulkan/`, about 1,000 lines): the ring (write position,
  wraparound, notify), the reply buffer, object-id allocation, a small allocator that
  places host-visible allocations inside blob mappings, and error handling. A lost device
  or a failed reply becomes a `VkResult`, never a fault.

## 2. virtio-gpu 3D in the kernel

What `Gpu.cool` gains, per the virtio-gpu spec:

- **Features:** `VIRTIO_GPU_F_VIRGL` (3D commands), `F_CONTEXT_INIT`, `F_RESOURCE_BLOB`, and
  the device's **shared memory region**. That region is virtio-mmio's `SHMSel`/`SHMLen`/
  `SHMBase` registers, or a BAR on virtio-pci. It is a window of guest-physical address space
  where the host maps blob memory.
- **Capsets:** `GET_CAPSET_INFO` and `GET_CAPSET` for capset 4 (Venus). The capset carries
  the protocol version and the renderer's supported extensions, which the generated layer
  checks.
- **Contexts:** `CTX_CREATE` with `context_init` naming the Venus capset. Fence timelines are
  selected by the request header's `ring_idx`; the wire create command has no ring-count field. Also `CTX_ATTACH_RESOURCE`, `CTX_DETACH_RESOURCE` and
  `CTX_DESTROY`.
- **Blob resources:** `RESOURCE_CREATE_BLOB`, with `BLOB_MEM_GUEST` (guest pages, for the
  ring and reply buffers) or `BLOB_MEM_HOST3D` (host Vulkan memory, for mapped buffers and
  images). `RESOURCE_MAP_BLOB` / `UNMAP_BLOB` place a host blob at an offset in the shared
  memory window, and the guest reads and writes it there directly. The kernel manages that
  window like a heap. Mappings are aligned to 16 KiB, the M1 page size.
- **`SUBMIT_3D`** carries a Venus command stream: small ones directly, large ones through the
  ring, with `SUBMIT_3D` used only to create or notify it.
- **Fences:** each request can ask for a fence on a ring index (`FLAG_FENCE` plus the ring
  index flag). The kernel waits for the response, or later uses the fence IRQ. Vulkan fences
  and semaphores themselves stay inside the protocol (`vkWaitForFences` is a call with a
  reply); the virtio fence only says "the host has consumed this submission".
- **Presentation:** Venus has no swapchain. A frame is rendered into a `VkImage`, copied with
  `vkCmdCopyImageToBuffer` into a host-visible buffer whose memory is a HOST3D blob, and shown
  with `SET_SCANOUT_BLOB` (0x10d) on that blob (offset, stride, format). The kernel then
  flushes the scanout. Two such buffers give double buffering. Options: (a) this copy;
  (b) zero copy, where the image itself is scanned out (an IOSurface-backed Metal texture
  shared with the window on the Mac). **Rec.: (a) first**. The copy costs about 1 ms at
  3200×2000 on the GPU, and (b) needs host-specific memory export that virglrenderer does
  not offer for MoltenVK today.

This is a transport of roughly 600 lines in `Gpu.cool` (or a `GpuVenus.cool` beside it),
which stays in the kernel.

### Implemented kernel transport (2026-09-30)

`os/Kernel/Gpu.cool` negotiates VIRGL, CONTEXT_INIT and RESOURCE_BLOB together when
all three are offered, independently of Logos. `GpuVenus.cool` provides a lazy,
single Venus context; boot and the 2D/Logos console do not query capsets or depend on it.
A missing feature or Venus capset returns false without logging or changing the console.
This stage uses the existing modern virtio-MMIO transport; PCI is still milestone 2.

- `GpuVenusInit()` enumerates `num_capsets`, selects capset 4, fetches its maximum
  supported version, and creates context 1. `venus.cap + 24` holds the opaque capability
  bytes, with `venus.cap_size` and `venus.cap_version`; the future Vulkan layer interprets
  them. Discovery is bounded to 256 capsets and 64 KiB of capability data.
- `GpuBlobCreate(size, GPU_BLOB_GUEST/GPU_BLOB_HOST3D, blob_id, flags)` returns a
  `CGpuBlob` or null. Guest backing is owned by the transport and accessible through
  `blob->guest`. HOST3D uses the protocol's host allocation `blob_id`. There are at most
  64 live blobs, each at most 256 MiB. Attach/detach with `GpuContextResource(id, attach)`.
- `GpuBlobMap(blob)` selects first-fit 16 KiB aligned offsets in shared region 1,
  including freed holes. It installs identity-mapped, non-executable guest pages using
  the returned cache policy; existing RAM/MMIO mappings are never overwritten.
  Missing/invalid shared regions or unavailable offsets return null. `GpuBlobUnmap`
  waits for the host and removes guest PTEs; `GpuBlobDestroy` unmaps, fences unref and
  frees guest backing. Empty page tables are retained for reuse.
- `GpuSubmit3D(stream, bytes, ring)` accepts aligned inline streams up to 1504 bytes,
  on timelines 0..63. It waits synchronously for the matching virtio fence and context.
  A larger stream belongs in a Venus shared ring; ring encoding and notifications are
  the next layer's responsibility. Fence completion means consumption, not Vulkan
  execution completion. Hosts may omit the ring flag/index from response headers, as
  [QEMU does](https://github.com/qemu/qemu/blob/master/hw/display/virtio-gpu.c).
- `GpuScanoutBlob(blob, width, height, stride, offset, format)` sends SET_SCANOUT_BLOB
  for a single-plane, four-byte pixel buffer on scanout 0, then RESOURCE_FLUSH. It
  invalidates the 2D scanout cache so a following console frame can restore its resource.
- `GpuVenusDestroy()` refuses live blobs and destroys the context after cleanup.
  Callers serialize use and destruction of a blob/context; the transport protects the
  queue and shared-window allocator with IRQ-safe locks. Device errors, bad responses
  and invalid arguments return false/null. A two-second queue timeout resets the GPU
  before backing can be freed and marks it inactive, preserving the driver's existing
  timeout behavior. Asynchronous fence IRQ handling is deferred.

Wire definitions follow the [Linux virtio-gpu UAPI](https://github.com/torvalds/linux/blob/master/include/uapi/linux/virtio_gpu.h)
and [virtio-MMIO registers](https://github.com/torvalds/linux/blob/master/include/uapi/linux/virtio_mmio.h).

`make venus-transport-test` boots the real kernel under coolvm with
`--gpu-3d-stub`, then with ordinary 2D, Logos and no GPU. The opt-in stub offers one
opaque fake capset, creates contexts/blobs, supplies a 16 MiB host-visible window and
completes submissions immediately. It does **not** decode Venus or render Vulkan.
The test verifies capsets, device errors and response lengths, resource lifecycle,
map/remap and hole reuse, forty submissions across two timelines (queue wrap), fence
IDs, scanout/flush and silent fallback. It is included in `make -j test`; `qemu-test`
continues to check the ordinary QEMU transport without Venus dependencies.

## 3. The host side

**coolvm on the Mac.** coolvm optionally links virglrenderer built with Venus. The pinned krunkit fork
links MoltenVK directly; a Vulkan loader belongs to the generic upstream route.

- **virtio-gpu gains the 3D path** (`gpu.c`, or a new `gpu3d.c`, about 800 lines):
  - The capset queries and context commands, forwarded to virglrenderer
    (`virgl_renderer_context_create_with_flags`, `virgl_renderer_submit_cmd`,
    `virgl_renderer_resource_create_blob`, `virgl_renderer_resource_get_map_ptr`).
  - Fence callbacks (`write_context_fence`) that complete the queued requests.
  - The shared memory window: `virgl_renderer_resource_get_map_ptr` in the pinned krunkit fork returns a
    host pointer to the blob's memory (`vkMapMemory` on MoltenVK), which coolvm maps into the guest-physical
    window with `hv_vm_map`. This is how libkrun/krunkit do it on macOS.
  - `SET_SCANOUT_BLOB`: the display reads the scanout blob's pixels for the window and for
    screenshots, as it reads a 2D resource now.
- **Build.** virglrenderer (MIT) with `-Dvenus=true`, MoltenVK (Apache-2.0), the Vulkan
  loader and headers (Apache-2.0), and venus-protocol (MIT, for generation and the host spike). All
  are compatible with the repository. Options for getting them:
  - (a) `tools/vendor-venus.sh`, like `vendor-m1n1.sh`: fetch pinned releases into
    `vendor/`, build virglrenderer with meson and ninja, and take MoltenVK from Homebrew
    (`molten-vk`, `vulkan-loader`) or its release package;
  - (b) the Homebrew tap that krunkit uses (a macOS build of virglrenderer with Venus):
    quickest, but a third-party tap and its patches;
  - (c) committed prebuilt dylibs: no build, but binaries in git.

  **Rec.: (a)**, pinned to the versions and patches krunkit ships, since they are known to
  run Venus on MoltenVK. coolvm keeps building without them: the 3D path is compiled only
  when the libraries are found (`COOLVM_VENUS=1`), and virtio-gpu then offers the 3D
  features. `make run` works either way.
- **Limits to expect.** MoltenVK is Vulkan 1.2/1.3 on Metal with gaps: no geometry
  shaders, and some formats and features are missing. Venus needs external-memory
  support from the host driver, which krunkit has shown works on MoltenVK. The feature
  list the guest sees is whatever MoltenVK reports, so apps check features as on any
  Vulkan driver.

**QEMU on Linux hosts.** QEMU (9.2 or later, with virglrenderer 1.0 or later) offers Venus
with `-device virtio-gpu-gl-pci,hostmem=...,blob=true,venus=true`. The documented
PCI route uses a host-memory region. A virtio-pci transport on arm64 `-M virt`
(PCIe ECAM from the FDT) would also serve the x86-64 plan ([x86-64.md](x86-64.md)).

Can this be tested from this Mac?
- QEMU on macOS with Venus: not with stock builds, and it would test MoltenVK again rather
  than a Linux driver.
- A Linux VM on this Mac (Apple Virtualization, `tools/vzrun`), running QEMU with the
  software Vulkan driver lavapipe on the Linux side: this works without a GPU, just slowly.
  An arm64 Linux VM runs QEMU's arm64 guest under KVM if nested virtualization is available
  (M3 or later), otherwise under TCG.
- CI on a Linux runner (x86-64 or arm64) with lavapipe and QEMU TCG: the check that does not
  depend on this machine.

**Rec.:** a `venus-qemu-test` script that runs on any Linux host with QEMU and lavapipe, used
from a Linux VM here and from CI. It checks correctness, not speed.

## 4. Shaders

Vulkan takes SPIR-V. Options:

- (a) GLSL sources compiled on the host at build time with glslang or shaderc (Homebrew
  `glslang`); the `.spv` files go on the disk next to the sources.
- (b) The same, but with the SPIR-V committed, so a build needs no shader compiler.
- (c) A SPIR-V assembler in Cool: `.spvasm` text in, SPIR-V out, about 600 lines,
  table-driven from the SPIR-V grammar JSON the way the Vulkan layer is generated. Shaders
  become editable and compilable in the OS, in assembly.
- (d) A small shading language (a GLSL subset, or HolyC-like) compiled to SPIR-V in the OS:
  the full "everything editable" answer, and a project the size of a compiler back end.

**Rec.: (a) now, (c) next, (d) only if shader work grows.** The terminal's shaders are
small (one fullscreen triangle, one fragment shader), so an assembler version of them is
practical, and (c) keeps the rule that everything in the OS can be rebuilt in the OS.
`glslang -V --target-env vulkan1.2` can emit readable `.spvasm` as the starting point.

## 5. The API apps use, and the terminal

- **Two layers.**
  - The generated layer is raw Vulkan in Cool: Vulkan's names, structs and `VkResult`s. It
    is complete for the subset, and anything written for Vulkan maps onto it.
  - On top of it, a thin helper `Gfx.cool` (about 500 lines) does the setup every app
    repeats: pick the device and queue, allocate and upload memory, make a pipeline from
    SPIR-V, record and submit, present to the screen or to a window.

  Options: raw only; thin helper only; or both. **Rec.: both**. Apps start with `Gfx`
  and drop to raw Vulkan when they need to. Warm bindings follow the same split later, with
  a Vulkan device as a capability.
- **Where the code lives.** The transport (2) is in the kernel. The generated layer for the
  whole subset will be large (estimated 15,000-30,000 lines of Cool), too big to put in every
  kernel image. Options: (a) all in the kernel; (b) the transport plus the few commands the
  console needs in the kernel, with the full layer as a library on disk (`C:/Vulkan`,
  compiled with `Cmp` and loaded by apps); (c) everything on disk, with the console using the
  CPU renderer until the library is loaded. **Rec.: (b)**: the console works at boot, and
  apps load the rest.
- **The terminal as a Vulkan app** (replacing `LogosFrame`, same frame structure):
  - The cells live in a host-visible storage buffer, a blob mapped into the guest, so the
    guest writes changed rows straight into GPU-visible memory; no ROWS command is needed.
  - The glyph atlas is a `VkImage`, uploaded through a staging buffer as glyphs appear.
    It stays one fixed size with no eviction, as in Logos.
  - The fragment shader is Logos's (`logos.m`), ported from MSL to GLSL or `.spvasm`:
    the cell ring, colors, reverse, bold, underline, wide cells, the cursor, and the pixel
    layer, which becomes a second image that `FbFillRect` and image drawing write into.
  - A frame: write the dirty rows, update the push constants (first row, cursor), submit a
    pre-recorded command buffer (a fullscreen triangle, then a copy into the scanout
    buffer), and flip `SET_SCANOUT_BLOB`.
  - The CPU renderer stays as the fallback when there is no Venus (a real M1, QEMU without
    it), as it does for Logos now.

## 6. Milestones

| # | Milestone | Main work | Check | Rough size |
|---|---|---|---|---|
| 1 | Triangle on coolvm | coolvm 3D path, virglrenderer and MoltenVK vendoring, kernel transport, generator and first subset, `Gfx`, a triangle app | `make venus-test`: headless coolvm draws a triangle, the screenshot matches expected pixels; the generator's round-trip unit tests | coolvm 800, kernel 600, generator 1,500 Python, hand-written Vulkan 1,000, `Gfx` 500 |
| 2 | Triangle on QEMU/Linux | virtio-pci transport on arm64 `virt`, Venus through `virtio-gpu-gl-pci` | `venus-qemu-test` in a Linux VM and in CI: the same triangle, within a tolerance (lavapipe rasterizes differently) | virtio-pci 400, scripts 200 |
| 3 | Terminal on Vulkan | the cell renderer as a Vulkan app, shaders, the pixel layer as an image | `make venus-term-test`: the Logos screens (colors, Vim, Tmux, resize) compared with the CPU renderer, as `logos-test` does; scroll-bench numbers recorded | renderer 500, shaders 200 |
| 4 | Logos retired | remove the Logos commands, `logos.m` and `Logos.cool`; the terminal uses Vulkan when Venus is there, else the CPU renderer | `make -j test`, `qemu-test`, `venus-test`, `venus-term-test` | about -700 lines |

Milestone 1 is the big one. The riskiest parts are the shared-memory mapping between
virglrenderer, MoltenVK and `hv_vm_map`, and the virglrenderer build on macOS. Both were
tested first in the host spike recorded below, then through actual guest Vulkan
buffer copies and triangle rendering. Milestone 1 is complete; its exact tested
scope and remaining limitations are recorded at the end.

## Decisions for you

1. Where the guest Vulkan layer lives: in the kernel; **the transport and the console's
   subset in the kernel, the full layer as a disk library**; or all on disk.
2. virglrenderer and MoltenVK: **a vendoring script with pinned versions**; the krunkit
   Homebrew tap; or committed prebuilt libraries.
3. Shaders: **host glslang now, an in-OS SPIR-V assembler next**; host only; or a shading
   language in the OS.
4. Presentation: **copy into a scanout blob**; or work toward zero copy right away.
5. The API: **generated raw Vulkan plus a thin `Gfx` helper**; raw only; or helper only.
6. Linux testing: **a Linux-host script, run from a Linux VM here and in CI**; or a Linux VM
   only; or skip QEMU until someone has a Linux machine.
7. Logos: **keep it until milestone 3 passes, then delete it**; or keep it as a fallback for
   hosts without Vulkan.

**Decided (user, 2026-09-30):** all seven follow the recommendations; downloading the
pinned dependencies (virglrenderer, MoltenVK, Vulkan headers/registry, venus-protocol, a
Linux VM image for testing) is approved.

## Host validation log (2026-09-30)

### Step 1: pinned source builds

`tools/vendor-venus.sh --host` builds into the gitignored `vendor/venus/install` prefix.
`tools/venus-deps.json` records every source URL and SHA-256. Run the script with
Xcode installed; build tools are `meson`, `ninja`, `pkgconf`, `cmake`, and Python 3
(`brew install meson ninja pkgconf cmake` if missing). No runtime Homebrew packages
or binary bottles are used. Build logs and upstream license notices are retained in
`vendor/venus/logs` and `vendor/venus/licenses`.

- virglrenderer: **0.10.4e-krunkit**, the macOS fork still used by the
  [current krun formula](https://github.com/libkrun/homebrew-krun/blob/main/Formula/virglrenderer-krun.rb).
  This is not upstream virglrenderer 1.0: it carries its own Venus/macOS patches.
  Built with Venus enabled, render server/DRM/EGL/GLX disabled. The only local
  source adjustment removes a hardcoded Homebrew header path; headers come from
  the vendored prefix. Its bundled renderer protocol was generated at d6bf073e;
  that matching venus-protocol source is downloaded too.
- MoltenVK: **1.4.2**, built from source with the seven exact dependency revisions
  in its `ExternalRevisions` (also checksummed in our manifest). This is a locally
  verified pairing, not a claim that krunkit pins this MoltenVK version.
- libepoxy: **1.5.10**, required even though the GL renderer is not used.
- Licenses inspected: virglrenderer, venus-protocol and libepoxy MIT (epoxy also
  retains Khronos notices); MoltenVK, SPIRV-Cross and SPIRV-Tools Apache-2.0;
  SPIRV-Headers MIT/Khronos notices; Vulkan-Headers Apache-2.0 OR MIT,
  Vulkan-Tools Apache-2.0; Volk MIT; cereal BSD-3-Clause. Preserve the upstream
  notices when redistributing. Apple frameworks/SDK remain system dependencies.
- Unlike the proposed generic Linux path, this krunkit fork links **directly to
  MoltenVK**, so no Vulkan loader/ICD is needed for this host build. The pinned
  Vulkan-Headers includes registry XML.

Verified on Apple M6, macOS 27 / Xcode 27: all libraries built successfully;
`otool -L` shows runtime dependencies only in our prefix and system libraries.
MoltenVK's packaging script removes its intermediate directory unless
`KEEP_CACHE=Y`; the vendoring script sets this to avoid deleting Xcode's active
build database. The script supports rerunning from its cached sources.

### Step 2: guestless C mapping spike

Run `make venus-host-test` after vendoring (Mako 1.3.10 and MarkupSafe 3.0.3
are also checksummed source downloads, used without installation for the upstream
C wire generator).
The test builds/codesigns `build/venus-spike/spike`, creates an HV VM with **no
vCPU or guest**, and performs real Venus calls using generated upstream codecs:

1. Initialize the renderer with VENUS, NO_VIRGL, THREAD_SYNC and ASYNC_FENCE_CB;
   create context 1 with capset 4 (156 bytes, capset version 0).
2. Create a mappable HOST3D blob with blob_id 0 (renderer-owned shared memory);
   get its pointer and map/unmap 16 KiB at IPA `0xa00000000`.
3. Use that blob as the Venus reply stream; create a Vulkan 1.1 instance,
   enumerate a physical device, read memory properties, create a device, and
   allocate 16 KiB from an actual HOST_VISIBLE memory type **through Venus**.
4. Create a second HOST3D blob with blob_id 4 (the VkDeviceMemory object id),
   map/unmap its pointer at IPA `0xa00004000`, then release resources in order.

**Result: PASS** on the host above. Both pointers were 16 KiB aligned and both
`hv_vm_map` and `hv_vm_unmap` returned HV_SUCCESS. Host writes to the mappings
also completed. This proves acceptance by Hypervisor.framework; guest reads,
cache coherence, GPU read/write visibility and pixel rendering still need tests.
This is not milestone 1's triangle test.

**Correction to the design:** standard `virgl_renderer_resource_map` returned
`-EINVAL` (-22) on both macOS opaque-handle resources. The krunkit fork provides
`virgl_renderer_resource_get_map_ptr`; its Vulkan blob path calls `vkMapMemory`
and retains that pointer. Blob id 0 uses anonymous mmap instead of Vulkan memory.
The pointer's lifetime belongs to the renderer: unmap the IPA before resource
unref/context destruction/freeing the corresponding VkDeviceMemory.

**krunkit source check:** libkrun
[`e66cad1cefb775a56fcf5fe9f524d8422e31cf0c`](https://github.com/containers/libkrun/tree/e66cad1cefb775a56fcf5fe9f524d8422e31cf0c)
uses rutabaga to get a blob pointer in
[`resource_map_blob`](https://github.com/containers/libkrun/blob/e66cad1cefb775a56fcf5fe9f524d8422e31cf0c/src/devices/src/virtio/gpu/virtio_gpu.rs),
passes it via `GpuAddMapping`, and its
[`HVF map_memory`](https://github.com/containers/libkrun/blob/e66cad1cefb775a56fcf5fe9f524d8422e31cf0c/src/hvf/src/lib.rs)
calls `hv_vm_map`. That supports the design's general mapping claim, with the
API correction above. It does **not** establish the proposed scanout path: its
GPU worker currently leaves `SetScanoutBlob` unimplemented.

**QEMU version check (source/docs, not runtime-tested here):**
[QEMU 9.2 release notes](https://www.qemu.org/2024/12/11/qemu-9-2-0/) confirm
Venus introduction; [official virtio-gpu docs](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html)
require a Venus-enabled virglrenderer >=1.0.0 and show
`virtio-gpu-gl-pci,hostmem=8G,blob=true,venus=true`. The docs also list
`virtio-gpu-gl-device`, so the earlier claim that only PCI can expose host memory
is not established and must not be treated as a requirement. The generic Linux
external-memory requirements do not describe the krunkit macOS pointer patch.
No QEMU/Linux/lavapipe runtime result is claimed by this host spike.

### Step 3: optional coolvm virtio-gpu transport

Build with `COOLVM_VENUS=1 make coolvm`, or preserve the default executable with
`COOLVM_VENUS=1 tools/coolvm/build.sh build/coolvm-venus`. Default `make coolvm`
links no vendored libraries, even when the sources are present. Vendoring is never
triggered by `make test`. Missing libraries produce an explicit error only when
the optional build is requested; renderer initialization failure falls back to 2D.

`gpu3d.c` now implements:

- Negotiated VIRGL / RESOURCE_BLOB / CONTEXT_INIT features, Venus capset 4
  discovery and capset contents, context create/destroy, blob attach/detach.
  **Correction:** the virtio `context_init` field names the capset (4); it does
  not encode a number of rings.
- Bounded SUBMIT_3D (up to 65,504 payload bytes), forwarded in dwords. A flagged
  submission waits for `write_context_fence` on the requested timeline before
  returning its fence; CPU timeline 0 is exercised. Missing timelines and failed
  submissions return an error without claiming fence completion. Waiting is
  synchronous under the device lock, with a five-second limit; deferred virtqueue
  completion and GPU timeline stress testing remain future work.
- Mappable GUEST blobs from checked DRAM scatter lists and HOST3D blobs using
  the macOS pointer API. HOST3D maps/unmaps into shared-memory region **1** (`VIRTIO_GPU_SHM_ID_HOST_VISIBLE`),
  advertised by MMIO SHMSel/SHMLen/SHMBase, at `0x400000000`, size **256 MiB**.
  This does not overlap coolvm's DRAM or framebuffer.
- 16 KiB allocation/mapping alignment, aperture range and overlap checks, a
  256 MiB blob budget, 64 blob slots and 16 contexts, and a shared resource-id
  namespace with the existing 2D path. Only blob_mem GUEST/HOST3D and the
  MAPPABLE flag are accepted for now; shareable/cross-device and HOST3D_GUEST
  resources are rejected. HOST3D resources stay attached to their owner; context
  destruction requires releasing owned blobs first.
- Unmapping before resource unref, GPU reset and VM destruction; renderer
  teardown stops context/ring work before freeing guest iovec storage. The
  guest must also unmap/unref a Vulkan blob before `vkFreeMemory`.

`make venus-host-test` now additionally drives actual MMIO split queues through
`gpu.c` and the real renderer, with no vCPU: capsets, context lifecycle, a fenced
Venus reply (`vkEnumerateInstanceVersion`), blob creation/attachment/mapping,
invalid headers/ids, unshareable attachment, wrapping/out-of-range/overlapping
mappings, repeated unmap, and reset cleanup. **PASS**. The guestless Vulkan
allocation spike also remains **PASS**. Mako (MIT) and MarkupSafe (BSD-3-Clause)
are now pinned/checksummed source dependencies for generating these test codecs.

Validation: **`make -j test` exited 0**, and the optional `build/coolvm-venus`
passed `tools/coolvm/test/run.sh` (existing assembly guests, devices, GPU 2D
queues and scanout). A default executable builds and `otool -L` confirms it has
no virglrenderer/MoltenVK dependency.

At the end of the initial host-only work, guest coherence and triangle scanout
were still pending. The integration results below complete these parts. The
existing 2D/Logos path stays available; shared command rings and GPU timeline
concurrency remain future work.

The transport layout was checked against the [Linux v6.12 virtio-gpu ABI](https://github.com/torvalds/linux/blob/v6.12/include/uapi/linux/virtio_gpu.h)
and [MMIO register definitions](https://github.com/torvalds/linux/blob/v6.12/include/uapi/linux/virtio_mmio.h):
the header's `ring_idx` byte is at offset 20, and the host-visible region selector
is 1 (0 is undefined). These values are exercised by the host transport tests.

## Integration with main (2026-09-30)

Merged the kernel Venus transport and guest generator from main. The vendor
entrypoint now dispatches `--generator [--test]` (the default) or `--host`.
`vendor-venus` explicitly builds the host section; `venus-vendor` explicitly
fetches generator/oracle inputs. Default `make -j test` has no download prerequisite.
The opt-in stub takes precedence over the real renderer even in a Venus build,
with separate resources and shared-memory register routing. Recipes for host,
transport and generator tests are attached to their individual Makefile rules.

Offline merge validation: `make -j test` passed, including the four transport
configurations and generator offline regression tests. Full generator wire-oracle
tests reported SKIP because their separate pinned inputs had not yet been fetched.


### Actual guest memory and coherence (2026-09-30)

`make venus-memory-test` uses the generated Cool Vulkan layer, kernel virtio
transport, real virglrenderer and MoltenVK. It requires the explicit host and
generator vendor steps; it never downloads. The full pinned generator oracle
suite also passed after fetching its inputs.

The guest creates an instance/device, discovers graphics queues and memory
properties, allocates two HOST_VISIBLE | HOST_COHERENT Vulkan buffers, exposes
each allocation as a HOST3D blob and accesses them through guest page tables.
For three rounds it writes 32 KiB of changing data, performs Vulkan GPU buffer
copies with HOST/TRANSFER barriers, polls a Vulkan completion fence and checks
every destination byte. Unmap/remap and resource/context teardown also pass.
**PASS** on Apple M6, macOS 27, pinned MoltenVK/krunkit renderer. This establishes
coherent memory for this device; noncoherent flush/invalidate is not tested.

Integration corrected the shared window to **16 GiB**: HV accepted 40 GiB in
the guestless spike, but Boot.S already installs guest stage-1 mappings for the
32–48 GiB DRAM aperture. The kernel refuses to overwrite these entries. The
unused 16 GiB window permits the actual guest stage-1 + HV stage-2 mapping.
GUEST blob creation now accepts the kernel's owning context and attaches it.

Venus deliberately rejects `vkGetDeviceQueue` and `vkQueueWaitIdle`; this is a
renderer contract rather than a wire generator failure. The client uses
`vkGetDeviceQueue2` with `VkDeviceQueueTimelineInfoMESA` (ring 1) and polls
`vkGetFenceStatus` after `vkQueueSubmit`. Inline command decoding/replies are
completed on CPU timeline 0; shared command rings and concurrent timelines
remain future work. Kernel request capacity grows to 16 KiB for shaders/pipelines.


## Milestone 1 complete (2026-09-30)

Build prerequisites (explicit downloads, outside `make test`):

```sh
tools/vendor-venus.sh --host
tools/vendor-venus.sh --generator --test
brew install glslang mtools  # if absent
make venus-test
```

`venus-test` builds a separate `build/coolvm-venus` executable, generates the
Cool Vulkan subset and compiles the checked-in vertex/fragment GLSL with host
`glslang -V --target-env vulkan1.2` (tested glslang 16.6.0). It creates an isolated
FAT disk containing the library and SPIR-V; all output stays in ignored `build/`.
The default coolvm and `make -j test` still need no renderer or network.

The actual Cool guest (`tools/venus/triangle-test.cool`) uses `Gfx` to create a
Vulkan 1.3 device, an optimal-tiled BGRA8 image, shader modules and a dynamic
rendering graphics pipeline. It draws three vertices, transitions the image to
TRANSFER_SRC and copies it into a HOST_VISIBLE | HOST_COHERENT buffer. A Vulkan
completion fence and HOST_READ barrier precede guest pixel reads. The guest
checks coverage, center and background, then sends **SET_SCANOUT_BLOB followed
by RESOURCE_FLUSH**, pointing to that same readback allocation. No host-side
triangle drawing or software triangle rasterizer supplies the displayed pixels.

coolvm's real 3D path now snapshots a checked linear BGRA/BGRX HOST3D plane for
both the window and screenshots. It validates scanout 0, format, dimensions,
crop, stride, offset, backing size and unused planes before changing scanout.
Zero resource id disables it; selecting 2D or unref/reset clears it. The host
MMIO test additionally checks cropped/padded rows, invalid stride/offset/crop,
unknown resources, flush bounds and lifecycle transitions. **PASS**.

The guest holds `fb.render_lock` during final presentation/power-off so periodic
console rendering cannot replace the blob scanout. Render objects are explicitly
destroyed; the displayed buffer/device remain alive until coolvm captures the
screenshot, then host teardown unmaps blobs and destroys the renderer. The
separate memory test exercises full guest resource/context cleanup.

**`make venus-test`: PASS**, screenshot
`build/venus-test/triangle.png` is 256×256 with **18,432 triangle pixels**.
The host checks **63,004 pixels** against analytically expected triangle and
background colors (±1 channel tolerance), excluding a narrow rasterization edge.
This catches blank images, wrong orientation/stride/channel order and missing
blob presentation. The same run first repeats the three-round coherence test.
Guest logs are `build/venus-test/triangle.log`; `make venus-memory-test` runs
memory verification separately. `make venus-gen-test` passes all **17** upstream
C byte-oracle packets, including the newly required queue timeline pNext.

Limits: one synchronous guest context/queue, bounded inline SUBMIT_3D, one
linear four-byte scanout plane, offscreen image-to-buffer presentation. No Vulkan
WSI, zero-copy Metal image export, shared command-ring execution, noncoherent
memory, Linux/QEMU runtime or GPU concurrency result is claimed. These do not
block the tested milestone-1 triangle path.


Final validation: **`make -j test` exited 0 without downloads**, including
transport stub/2D/Logos/no-GPU, generator, kernel and existing display tests.
`make venus-host-test`, `make venus-memory-test`, `make venus-test` and the
expanded generator suite pass. The real renderer executable also passes the
40-submission/two-timeline `--gpu-3d-stub` guest, confirming stub precedence.
`otool -L build/coolvm` confirms the default binary has no vendored dependency.
Detailed local logs: `build/venus-final-test.log`, `build/venus-final-host-test.log`,
`build/venus-final-gen-test.log`, `build/venus-real-build-stub.log`.

## Milestone 3 work (2026-09-30)

Merged current main (`bbe3b78`, fast-forward) before terminal work.
Baseline `make -j test` passed without downloads.


### Milestone 3: resident Vulkan terminal

`make venus-terminal` builds the generated disk library and the host-glslang
terminal shaders (SPIR-V Vulkan 1.2). `make venus-disk` installs them on the
regular disk; `make venus-run` starts the optional Venus coolvm with that disk.
No vendoring or downloads are implicit in these targets. The kernel starts a
resident compiler task before `Init.cool` when both Venus and the disk library
are available. That task owns the compiled app across primary-shell restarts;
its framebuffer hooks are serialized by `fb.render_lock`. It parks after setup.
Missing Venus or shader inputs retain Logos, then the CPU renderer; initialization
exceptions release the lock and partial blob/context resources before fallback.

`os/Vulkan/Terminal.cool` ports the Logos layout directly:

- The 16-byte cells live in a mapped HOST_VISIBLE | HOST_COHERENT storage buffer.
  The guest writes changed rows directly, without a custom ROWS command or a
  staging copy of the cell grid. Counters in `fb` measure actual cell bytes/rows.
- The same Unifont coverage occupies a 4096×2048 **R8 Vulkan atlas image**, with
  16×16 slots for narrow/wide glyphs, 32,768 slots, no eviction and `?` fallback.
  New glyphs dirty atlas rows; only those rows are copied from the mapped upload
  buffer. Unicode slot lookup remains in the guest.
- Full-screen scroll advances the physical-row ring. The shader indexes cells
  and overlay rows with that ring; only newly exposed/changed rows are written.
- The GLSL fragment shader ports Logos's foreground/background, reverse, bold,
  wide-right-half, underline flag and inverted block cursor. One fullscreen
  triangle draws the entire grid in one rendering pass; partial-cell margins
  stay black, with overlay pixels supported there too.
- `FbFillRect` (including Warm's `OS.CoolOS.Framebuffer`) writes a mapped upload
  buffer for a **second BGRA Vulkan image**. Changed physical pixel rows upload;
  the cell shader composites the image and clears row overlays as Logos did.
- Resize replaces size-dependent cells, overlay, target, readback and pipeline
  after the last GPU fence, updates descriptors, preserves the atlas and redraws
  the new terminal grid. No frame races resource destruction.

As in milestone 1, the rendered target is copied to a coherent HOST3D scanout
buffer. Vulkan barriers and a polled completion fence precede blob presentation.
A Venus blob scanout takes display priority over the bootstrap Logos grid.
`Gfx.no_sleep` polls without scheduling while the existing framebuffer/IRQ lock
is held; no shaders/files are loaded during frames. This is synchronous and
bounded, with frame latency to improve before a production compositor.

**`make venus-term-test`: PASS.** The five original `logos-test` screens compare
against the same CPU renderer at the original 0.1% threshold: colors 31 pixels
(0.0039%), margins 31 (0.0039%), Vim 0, Tmux 0, resize 0. Filled-rectangle probes
pass exactly. A separate per-screen probe also checks that one changed line
writes at most two rows, exactly `rows × cols × 16` bytes, and produces one Vulkan
frame. `make venus-test` and `make venus-memory-test` continue to pass.
Screenshots/logs live in `build/venus-term-test/<screen>/`.

### Milestone 3 scroll measurements

Apple M6, macOS 27; headless, 3,000 forced-frame lines then 3,000 timer-batched
lines, averages of three runs at each resolution. CPU, Logos and Venus were run
sequentially with the same FAT disk/prompt, input and final scroll/fill screen.
All final scroll/fill screenshots match the CPU **exactly**. These are new
measurements, separate from the historical M1 figures in `docs/logos.md`.

| Resolution | Backend | Forced render µs/line | 3,000 forced lines ms | Batched lines ms | Whole-run host CPU s |
|---|---|---:|---:|---:|---:|
| 1024×768 | CPU (virtio 2D) | 106.7 | 710.5 | 451.1 | 1.67 |
| 1024×768 | Logos | 45.4 | 530.2 | 417.5 | 1.43 |
| 1024×768 | Venus | 428.3 | 1673.9 | 434.3 | 3.47 |
| 3200×2000 | CPU (virtio 2D) | 263.2 | 1232.2 | 640.3 | 2.53 |
| 3200×2000 | Logos | 135.1 | 852.7 | 500.6 | 1.94 |
| 3200×2000 | Venus | 1440.7 | 4773.6 | 579.3 | 7.80 |

The forced-frame Venus result includes actual GPU drawing, image-to-buffer copy
and completion polling for every frame. Headless Logos only updates its cells
on PRESENT and draws when the screenshot is requested. Thus this is a comparison
of current end-to-end behavior, not equivalent shader execution timings. Venus
is slower for forced frames; batching reduces the difference. Future work is
cached command buffers, asynchronous GPU fences/double buffering and direct
presentation instead of the full readback copy; these measurements do not claim
a performance win.

Reproduction before Logos retirement: `tools/scroll-bench.py` labels
`venus-m3-cpu`, `venus-m3-logos`, `venus-m3-vulkan`, `--repeat 3 --lines 3000
--size 1024x768 --size 3200x2000 --disk build/venus-test/terminal.img`. CPU adds
`--extra=--no-logos`; Venus uses `--vm build/coolvm-venus --expect-venus 1`;
Logos uses the default executable. Use `--compare venus-m3-cpu` for both GPU
runs. Results are in `build/scroll-bench/venus-m3-*.json`; the prepared test disk
can also be made with `tools/venus/install.sh` on a formatted FAT32 image.
