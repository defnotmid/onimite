package onimite

import "core:mem"
import "core:sync"
import "core:thread"

// Caller-owned task pool, as in ../oasic (work/pool.odin): the application
// creates one `thread.Pool` and lends it to the operations it runs; nil runs
// the same task rows on the caller. Each operation tracks its own tasks, so
// two drivers can share the pool (the render loop's frame builders and the
// encoder thread's slice coding) without waiting for each other's tasks.
// Don't wait from a task already running on the pool. Tasks that use the
// temp allocator scope it themselves (`runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD`):
// a waiting caller may run them on its own thread.

pool_count :: proc(pool: ^thread.Pool) -> int {
	if pool == nil {
		return 1
	}
	sync.guard(&pool.mutex)
	return max(1, len(pool.threads))
}

@(private = "file")
Pool_Row :: struct {
	procedure: thread.Task_Proc,
	data:      rawptr,
	index:     int,
	// The call's unfinished rows.
	pending:   ^sync.Futex,
}

// Runs `procedure` once per row (`task.data` is the row, `task.user_index`
// its index) and returns when all are done; the caller helps, running any
// waiting task.
pool_run :: proc(pool: ^thread.Pool, rows: []$T, procedure: thread.Task_Proc, allocator: mem.Allocator) {
	if pool == nil || len(rows) <= 1 {
		for &row, i in rows {
			procedure({procedure = procedure, data = &row, user_index = i, allocator = allocator})
		}
		return
	}
	pending := sync.Futex(len(rows))
	tasks := make([]Pool_Row, len(rows), allocator)
	defer delete(tasks, allocator)
	for &row, i in rows {
		tasks[i] = {procedure, &row, i, &pending}
		thread.pool_add_task(pool, allocator, pool_row_task, &tasks[i], i)
	}
	for {
		left := sync.atomic_load(&pending)
		if left == 0 {
			break
		}
		if task, ok := thread.pool_pop_waiting(pool); ok {
			thread.pool_do_work(pool, task)
			continue
		}
		sync.futex_wait(&pending, u32(left))
	}
	pool_drain_done(pool)
}

@(private = "file")
pool_row_task :: proc(t: thread.Task) {
	row := (^Pool_Row)(t.data)
	pending := row.pending
	row.procedure({procedure = row.procedure, data = row.data, user_index = row.index, allocator = t.allocator})
	if sync.atomic_sub(pending, 1) == 1 {
		sync.futex_broadcast(pending)
	}
}

// Forgets finished tasks: `thread.Pool` keeps a record of each until popped,
// and popping them one by one moves the rest each time.
pool_drain_done :: proc(pool: ^thread.Pool) {
	if pool == nil {
		return
	}
	sync.guard(&pool.mutex)
	sync.atomic_sub(&pool.num_done, len(pool.tasks_done))
	clear(&pool.tasks_done)
}

// One task with its own completion, for pipelines: the owner spawns it,
// does other work, and joins it later. Set `procedure` once; the job must
// stay at its address while it runs.
Pool_Job :: struct {
	procedure: proc(job: ^Pool_Job),
	// 1 from spawn until the procedure returned.
	busy:      sync.Futex,
}

// Runs the job on the pool, or right here when `pool` is nil.
pool_spawn :: proc(pool: ^thread.Pool, job: ^Pool_Job, allocator: mem.Allocator) {
	assert(sync.atomic_load(&job.busy) == 0, "join a job before spawning it again")
	if pool == nil {
		job.procedure(job)
		return
	}
	sync.atomic_store(&job.busy, 1)
	thread.pool_add_task(pool, allocator, pool_job_task, job)
}

@(private = "file")
pool_job_task :: proc(t: thread.Task) {
	job := (^Pool_Job)(t.data)
	job.procedure(job)
	sync.atomic_store_explicit(&job.busy, 0, .Release)
	sync.futex_broadcast(&job.busy)
}

// Waits until the job's procedure returned. The owner doesn't help: it has
// its own work (and other tasks may be long).
pool_join :: proc(job: ^Pool_Job) {
	for sync.atomic_load_explicit(&job.busy, .Acquire) != 0 {
		sync.futex_wait(&job.busy, 1)
	}
}

// True while a spawned job hasn't finished (its owner would wait in
// `pool_join`).
pool_job_running :: proc(job: ^Pool_Job) -> bool {
	return sync.atomic_load_explicit(&job.busy, .Acquire) != 0
}
