package main

// The leak tracker, named and proven — CORE-REPLAN §13's second owed item.
//
// The one-arena-per-match shape (the plan for the daemon, when matches multiply
// inside one process) frees a whole match by freeing its arena — no per-
// allocation bookkeeping. That shape needs a CHECK, not a hope: after a match,
// whatever was allocated for it must be back at zero. Odin's core:mem ships the
// tracker, and this program proves it in the dev-2026-09 build the rest of the
// spike compiles against:
//
//   mem.Tracking_Allocator — total_allocation_count / total_free_count,
//   total_memory_allocated / total_memory_freed, current_memory_allocated,
//   and a per-allocation map whose entries carry each call's source-code
//   location, so a leak names its own line.
//
// Three proofs, in order:
//   1. a balanced context: allocate, free, the counts agree.
//   2. a leak, seen: allocate and "forget" — the imbalance is visible.
//   3. the arena shape itself: a match's arena whose buffer comes from the
//      tracked context, a thousand per-match allocations that are never
//      individually freed, the match ends, the arena and the buffer are
//      freed, and the counts balance at zero bytes live.

import "core:fmt"
import "core:mem"
import "core:os"

main :: proc() {
	heap := context.allocator

	// --- proof 1: the tracked context balances.
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, heap)
	context.allocator = mem.tracking_allocator(&tracker)
	a := make([]byte, 100)
	delete(a)
	context.allocator = heap
	if tracker.total_allocation_count != tracker.total_free_count {
		fmt.printf("MEM TRACK RED: a balanced context shows %d allocs, %d frees\n",
			tracker.total_allocation_count, tracker.total_free_count)
		os.exit(1)
	}
	fmt.printf("proof 1 ok: %d allocations, %d frees, %d bytes live\n",
		tracker.total_allocation_count, tracker.total_free_count, tracker.current_memory_allocated)

	// --- proof 2: a leak is visible, and the entry names its line.
	context.allocator = mem.tracking_allocator(&tracker)
	leaked := make([]byte, 128)
	context.allocator = heap
	if tracker.total_allocation_count == tracker.total_free_count {
		fmt.println("MEM TRACK RED: a leaked allocation is invisible to the tracker")
		os.exit(1)
	}
	entry, ok := tracker.allocation_map[&leaked[0]]
	_ = entry
	if !ok {
		fmt.println("MEM TRACK RED: the leaked allocation has no tracked entry")
		os.exit(1)
	}
	fmt.printf("proof 2 ok: leak seen — %d allocs, %d frees, %d bytes live (the entry names its own line)\n",
		tracker.total_allocation_count, tracker.total_free_count, tracker.current_memory_allocated)
	context.allocator = mem.tracking_allocator(&tracker)
	delete(leaked)
	context.allocator = heap

	// --- proof 3: the one-arena-per-match shape.
	// The arena's buffer is the match's memory, allocated from the tracked
	// context; the thousand per-match allocations bump the arena and are never
	// individually freed — that is the point of the shape. The match ends with
	// one arena free and one buffer free, and the tracked context must balance.
	context.allocator = mem.tracking_allocator(&tracker)
	buf := make([]byte, 1 << 20)
	arena: mem.Arena
	mem.arena_init(&arena, buf)
	context.allocator = mem.arena_allocator(&arena)
	for i in 0 ..< 1000 {
		_ = make([]byte, 64)
	}
	context.allocator = mem.tracking_allocator(&tracker)
	// the match ends: the arena's bump pointer resets, the buffer returns
	mem.arena_free_all(&arena)
	delete(buf)
	if tracker.total_allocation_count != tracker.total_free_count || tracker.current_memory_allocated != 0 {
		fmt.printf("MEM TRACK RED: the arena shape leaves %d bytes live (%d allocs, %d frees)\n",
			tracker.current_memory_allocated, tracker.total_allocation_count, tracker.total_free_count)
		os.exit(1)
	}
	fmt.printf("proof 3 ok: the arena shape balances — %d allocations, %d frees, 0 bytes live\n",
		tracker.total_allocation_count, tracker.total_free_count)

	mem.tracking_allocator_destroy(&tracker)
	fmt.println("MEM TRACK GREEN — mem.Tracking_Allocator, named and proven")
}
