package onimite_app

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import om "../onimite"
import enc "../encode"
import script "../script"

// The clips a script's audio_add deferred (`audio_add(name, function)`),
// built as rows on the app's pool. A slot per clip is the promise: a job
// claims the next slot (an atomic cursor, slots in the order they are
// needed), builds the clip into it and publishes it `Done`; the owner
// drains finished slots on its own loop into its media and places the
// tracks again, so sound arrives as it is made and nobody waits for all of
// it. A job runs Lua, so it loads the script into a state of its own (with
// its own media, for the fonts a script measures with at load) and builds
// slot after slot in it.

// Jobs (script states) building at once: a few run every core a score
// keeps busy, each costs a load of the script.
CLIP_JOBS :: 4

Clip_Slot_State :: enum u32 {
	Waiting,
	Done,
	Failed,
}

Clip_Slot :: struct {
	name:    string,
	// Published by the job (release) after `clip` / `failure` are written.
	state:   Clip_Slot_State,
	clip:    om.Audio_Clip,
	// Why it failed (owned): the build's, or the job's load's.
	failure: script.Failure,
	// The owner has drained it.
	drained: bool,
}

Clip_Builds :: struct {
	slots:       []Clip_Slot,
	// The next slot a job claims (atomic).
	next:        int,
	// Jobs still running (atomic); the owner frees the builds at 0.
	running:     int,
	cancel:      bool,
	jobs:        []Clip_Job,
	// What a job loads.
	script_path: string,
	media_dir:   string,
	args, props: []string,
	video:       ^enc.Video_Decoders,
	// Called by a job after each slot it fills (the preview wakes its worker).
	wake:        proc(data: rawptr),
	wake_data:   rawptr,
}

Clip_Job :: struct {
	builds: ^Clip_Builds,
}

// Builds for `names` (in the order they are needed), with up to `jobs`
// rows; nothing runs until clip_builds_start or clip_builds_wait.
clip_builds_make :: proc(names: []string, jobs: int, script_path, media_dir: string, args, props: []string, video: ^enc.Video_Decoders) -> ^Clip_Builds {
	b := new(Clip_Builds)
	b.slots = make([]Clip_Slot, len(names))
	for n, i in names {
		b.slots[i].name = strings.clone(n)
	}
	b.jobs = make([]Clip_Job, clamp(jobs, 1, max(len(names), 1)))
	for &j in b.jobs {
		j.builds = b
	}
	b.script_path = strings.clone(script_path)
	b.media_dir = strings.clone(media_dir)
	b.args = clone_strings(args)
	b.props = clone_strings(props)
	b.video = video
	return b
}

// Hands the jobs to `pool` and returns (the owner drains slots as they land).
clip_builds_start :: proc(b: ^Clip_Builds, pool: ^thread.Pool) {
	sync.atomic_store(&b.running, len(b.jobs))
	for &j, i in b.jobs {
		thread.pool_add_task(pool, context.allocator, clip_job_task, &j, i)
	}
}

// Runs the jobs on `pool` (the caller helps) and returns when every slot is
// filled.
clip_builds_wait :: proc(b: ^Clip_Builds, pool: ^thread.Pool) {
	sync.atomic_store(&b.running, len(b.jobs))
	om.pool_run(pool, b.jobs, clip_job_task, context.allocator)
}

// Whether no job of `b` runs any more (its memory may go).
clip_builds_idle :: proc(b: ^Clip_Builds) -> bool {
	return sync.atomic_load(&b.running) == 0
}

// Moves the clips finished since the last drain into `m`, marking them
// built in `s` (so it never runs their functions). Returns how many landed
// and the first failure not seen before (borrowed from `b`).
clip_builds_drain :: proc(b: ^Clip_Builds, m: ^om.Media, s: ^script.Script) -> (landed: int, failure: script.Failure) {
	for &slot in b.slots {
		if slot.drained {
			continue
		}
		switch sync.atomic_load_explicit(&slot.state, .Acquire) {
		case .Waiting:
			continue
		case .Done:
			if slot.clip.samples != nil {
				if om.media_add_clip(m, slot.name, slot.clip) {
					landed += 1
				}
				script.audio_mark_built(s, slot.name)
			}
			slot.clip = {}
		case .Failed:
			if failure.code == .None {
				failure = slot.failure
			}
		}
		slot.drained = true
	}
	return
}

// Whether every slot is drained.
clip_builds_finished :: proc(b: ^Clip_Builds) -> bool {
	for slot in b.slots {
		if !slot.drained {
			return false
		}
	}
	return true
}

// Frees `b` once clip_builds_idle; undrained clips go with it.
clip_builds_destroy :: proc(b: ^Clip_Builds) {
	for &slot in b.slots {
		delete(slot.name)
		script.failure_destroy(&slot.failure)
		if !slot.drained {
			om.audio_clip_destroy(&slot.clip)
		}
	}
	delete(b.slots)
	delete(b.jobs)
	delete(b.script_path)
	delete(b.media_dir)
	delete_strings(b.args)
	delete_strings(b.props)
	free(b)
}

// One job: a script state of its own, then slot after slot until none is
// left (or the owner cancels).
@(private = "file")
clip_job_task :: proc(t: thread.Task) {
	// A waiting caller may run this on its own thread: temp memory is scoped.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	b := (^Clip_Job)(t.data).builds
	// The last wake comes after the count drops (the owner frees idle
	// builds then), so it can't read `b`.
	wake, wake_data := b.wake, b.wake_data
	defer if wake != nil {
		wake(wake_data)
	}
	defer sync.atomic_sub(&b.running, 1)
	media: om.Media
	media_open(&media, om.IMAGE_BUDGET_DEFAULT, b.video)
	defer om.media_destroy(&media)
	if os.is_dir(b.media_dir) {
		om.media_load_dir(&media, b.media_dir)
	}
	s := new(script.Script)
	defer free(s)
	defer script.unload(s)
	loaded := script.load(s, b.script_path, b.args, &media, nil, b.props) == nil
	for !sync.atomic_load(&b.cancel) {
		i := sync.atomic_add(&b.next, 1)
		if i >= len(b.slots) {
			break
		}
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		slot := &b.slots[i]
		if !loaded {
			slot.failure = script.failure_clone(s.failure)
			sync.atomic_store_explicit(&slot.state, .Failed, .Release)
		} else if clip, ok, failure := script.audio_build_clip(s, slot.name); failure.code != .None {
			slot.failure = script.failure_clone(failure)
			sync.atomic_store_explicit(&slot.state, .Failed, .Release)
		} else {
			// No clip: the script no longer defers it (nothing to add).
			slot.clip = clip if ok else {}
			sync.atomic_store_explicit(&slot.state, .Done, .Release)
		}
		if b.wake != nil {
			b.wake(b.wake_data)
		}
	}
}

@(private = "file")
clone_strings :: proc(list: []string) -> []string {
	out := make([]string, len(list))
	for s, i in list {
		out[i] = strings.clone(s)
	}
	return out
}

@(private = "file")
delete_strings :: proc(list: []string) {
	for s in list {
		delete(s)
	}
	delete(list)
}
