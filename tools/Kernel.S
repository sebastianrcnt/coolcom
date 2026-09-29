// Wraps the relocated kernel module so the linker can place it.
.section .kernel,"awx"
.incbin "build/kernel.raw"
