// Wraps the relocated kernel module so the linker can place it.
// Assembled with -I <build dir>.
.section .kernel,"awx"
.incbin "kernel.raw"
