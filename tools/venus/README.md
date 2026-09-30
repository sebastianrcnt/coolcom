# Guest Vulkan generator

`make venus-gen` fetches the immutable inputs and writes `build/venus/Vulkan.cool`
and `manifest.json`. `make venus-gen-test` compiles the complete generated library
with `build/coolc`, runs its encoders/decoders on the host, and compares 16 packets
with the **unmodified upstream Venus C encoders**, generated from their own
registry/templates. It also runs as part of `make -j test`. No GPU or renderer is
needed. Downloads go into ignored `vendor/`; all generated/test artifacts go into
ignored `build/`.

Inputs are Vulkan-Headers **v1.4.357** and venus-protocol **1.1.3**, locked by full
Git revision in `vendor.py`; the independently downloaded Khronos `vk.xml` has a
SHA-256 check. Existing modified inputs are rejected. The generator uses Python's
standard library and the pinned upstream parser/encoding backend, loaded without
its Mako template frontend. Only the C test oracle needs Mako **1.3.10** and
MarkupSafe **3.0.3**, installed by `tools/vendor-venus.sh --test` into an isolated
`vendor/venus-python` virtual environment. Cached downloads need no network.

`subset.txt` lists commands and extra structs (one name per line, `#` comments).
Commands pull in parameter/member types transitively. `pNext` nodes are included
only when reached by a command or explicitly listed; unsupported nodes are skipped
on encode, as in Venus. The initial 80 commands cover the triangle milestone,
including dynamic rendering, descriptors, compute, resource copies and the Venus
ring/reply-stream commands. `vkMapMemory` is a guest blob operation and is not
serialized. Adding a command requires a subset line and a host oracle test.

The generated library uses Vulkan field names and enum/flag constants. Scalar
aliases are resolved to Cool storage types, handles to `U64i` guest object ids.
Cool has no binary32 type: Vulkan `float` fields/arrays use `U32i` **IEEE-754 bits**,
including union alternatives (e.g. `1.0f` is `0x3f800000`). This preserves exact
wire bytes; assigning an ordinary Cool floating value would perform an integer
conversion. `size_t` and pointer/count wire markers are 64-bit. Scalar arrays are
padded to four bytes. The supported guest/host architectures are little endian.

A caller initializes a `VenusWire` with `data`, `capacity`, `pos=0`, `error=0`.
Call `vn_encode_vkCmdDraw(&stream, 0, commandBufferId, 3, 1, 0, 0)`, for example.
Every encoder takes command flags explicitly; commands with outputs automatically
include `VK_COMMAND_GENERATE_REPLY_BIT_EXT`. Creation output pointers must contain
preallocated guest object ids, as in Mesa. Allocation callbacks must be null.
The caller owns the ring, object allocation, transport and reply buffers.

For replies, call `vn_decode_vkNAME_reply` with a reply stream and the original
command parameters. Supply initialized output structs, arrays with adequate
capacity, and matching `sType`/`pNext` nodes; decoders do not allocate. Enumeration
counts cannot exceed the supplied input capacity. Check the sticky `stream.error`
after every operation, in addition to any returned `VkResult`. Bounds, wrong reply
ids, mismatched array counts and missing reply chain nodes set this flag. Discard
failed streams; a partial encoded command must never be submitted.

The host checks include a literal `vkDeviceWaitIdle` packet, creation ids, strings,
conditional queue-family arrays, SPIR-V words, dynamic rendering and its pipeline
`pNext`, tagged clear unions, submit/fence arrays, binary32 viewports, and ring
creation/notify/wait/execute/reply streams. Reply checks cover results, handles,
enumerations and memory requirements, plus selected chains, truncation, destination
capacity and overflow. The C oracle packets are saved as
`build/venus/oracle-packets.json` for inspection.

This milestone supplies generation and host verification. Transport, capability
negotiation, blob mapping, `os/Vulkan` helpers, kernel and coolvm changes remain
separate work described in `docs/venus.md`.
