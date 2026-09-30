# Venus: Vulkan for coolcom

Status: decisions accepted; the kernel MMIO transport and an opt-in command-flow stub
are implemented. The Vulkan layer and real host renderer remain later work.
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

**coolvm on the Mac.** coolvm links virglrenderer built with Venus, and virglrenderer uses
MoltenVK through the Vulkan loader.

- **virtio-gpu gains the 3D path** (`gpu.c`, or a new `gpu3d.c`, about 800 lines):
  - The capset queries and context commands, forwarded to virglrenderer
    (`virgl_renderer_context_create_with_flags`, `virgl_renderer_submit_cmd`,
    `virgl_renderer_resource_create_blob`, `virgl_renderer_resource_map`).
  - Fence callbacks (`write_context_fence`) that complete the queued requests.
  - The shared memory window: `virgl_renderer_resource_map` returns a host pointer to the
    blob's memory (MoltenVK maps an `MTLBuffer`), which coolvm maps into the guest-physical
    window with `hv_vm_map`. This is how libkrun/krunkit do it on macOS.
  - `SET_SCANOUT_BLOB`: the display reads the scanout blob's pixels for the window and for
    screenshots, as it reads a 2D resource now.
- **Build.** virglrenderer (MIT) with `-Dvenus=true`, MoltenVK (Apache-2.0), the Vulkan
  loader and headers (Apache-2.0), and venus-protocol (MIT, only for the generator). All
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
with `-device virtio-gpu-gl-pci,hostmem=...,blob=true,venus=true`. Only the PCI variant has
the host-memory region. So the kernel needs a virtio-pci transport on arm64 `-M virt` (PCIe
ECAM from the FDT), which is the same transport the x86-64 plan needs ([x86-64.md](x86-64.md)).

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
virglrenderer, MoltenVK and `hv_vm_map`, and the virglrenderer build on macOS. Both are
worth a spike before the generator: a C test program in coolvm that creates a Venus context
and maps one blob.

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
