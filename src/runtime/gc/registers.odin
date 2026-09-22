package gc

/*
The per-platform stub of the stack scan (requirements 6): a reference the mutator keeps only in a
callee-saved register lies in no stack word.

The template only declares those registers clobbered, so LLVM saves them all in the prologue of
collect, and the scan, which runs in a procedure collect calls, reads them from collect's frame.
This is __builtin_unwind_init, which bdwgc runs before its scan. The template cannot copy the
registers out itself: Odin refuses one that reads a register it did not write.

The call to the scan must not be collect's last one: at -o:speed LLVM makes it a tail call, which
restores the registers before the scan runs.

amd64 names the registers Windows x64 preserves, a superset of System V's, where rdi and rsi are
scratch and naming them costs nothing. Vector registers are left out, as Oilpan leaves them: a
reference never lives there.
*/

#assert(ODIN_ARCH == .amd64 || ODIN_ARCH == .arm64, "the collector knows amd64 and arm64")

when ODIN_ARCH == .amd64 {
	@(private)
	spill_registers :: asm() [
		#clobber %rbx,
		#clobber %rbp,
		#clobber %rdi,
		#clobber %rsi,
		#clobber %r12,
		#clobber %r13,
		#clobber %r14,
		#clobber %r15,
		#volatile,
	] {}
} else when ODIN_ARCH == .arm64 {
	@(private)
	spill_registers :: asm() [
		#clobber %x19,
		#clobber %x20,
		#clobber %x21,
		#clobber %x22,
		#clobber %x23,
		#clobber %x24,
		#clobber %x25,
		#clobber %x26,
		#clobber %x27,
		#clobber %x28,
		#clobber %x29,
		#volatile,
	] {}
}
