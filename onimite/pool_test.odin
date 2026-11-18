package onimite

import "core:sync"
import "core:testing"
import "core:thread"

// A finished task another borrower queued stays in the pool's done list
// while onimite's work runs and drains: o3d's software renderer waits for its
// own records there, and the encoder thread forgetting them hung
// render --software to a .webm (or --codec av1) on a scene with 3D motion blur.
@(test)
test_pool_drain_keeps_other_borrowers_done :: proc(t: ^testing.T) {
	pool: thread.Pool
	thread.pool_init(&pool, context.allocator, 3)
	thread.pool_start(&pool)
	defer {
		thread.pool_finish(&pool)
		thread.pool_destroy(&pool)
	}
	theirs :: proc(_: thread.Task) {}
	mark: int
	thread.pool_add_task(&pool, context.allocator, theirs, &mark)
	for thread.pool_num_done(&pool) < 1 {
		thread.yield()
	}
	Ranges :: [64]int
	count_range :: proc(data: rawptr, first, end: int) {
		ranges := (^Ranges)(data)
		for i in first ..< end {
			ranges[i] += 1
		}
	}
	ranges: Ranges
	work: Pool_Work
	pool_work_init(&work, &pool)
	work.work_pool.run(&work.work_pool, len(ranges), count_range, &ranges)
	pool_work_destroy(&work)
	pool_drain_done(&pool)
	for n, i in ranges {
		testing.expectf(t, n == 1, "range %d ran %d times", i, n)
	}
	sync.guard(&pool.mutex)
	kept := 0
	for d in pool.tasks_done {
		if d.procedure == theirs && d.data == &mark {
			kept += 1
		}
	}
	testing.expect_value(t, kept, 1)
	testing.expect_value(t, pool.num_done, len(pool.tasks_done))
}
