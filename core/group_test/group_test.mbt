// SPDX-License-Identifier: Apache-2.0
// The rules under test are the ones that decide who reads what, and
// who is allowed to say how far they got. A wrong answer here either
// duplicates work (two owners of one partition) or loses it (a commit
// for a partition the member no longer holds).

///|
fn member(id : String, at : Int64) -> @group.GroupMember {
  @group.GroupMember::{ id, address: "127.0.0.1:1", last_seen_ms: at, }
}

///|
fn part(topic : String, index : Int) -> @cluster.PartitionId {
  @cluster.PartitionId::{ topic, index, }
}

///|
test "range assignment is deterministic and balanced" {
  let members = [member("b", 0L), member("a", 0L), member("c", 0L)]
  let partitions = [
    part("events", 0),
    part("events", 1),
    part("events", 2),
    part("events", 3),
    part("events", 4),
  ]
  let shares = @group.assign(members, partitions)
  // members come out in id order whatever order they reported in
  assert_eq(shares.map(fn(share) { share.member }), ["a", "b", "c"])
  // 5 partitions over 3 members: the remainder goes to the earliest
  assert_eq(shares[0].partitions.length(), 2)
  assert_eq(shares[1].partitions.length(), 2)
  assert_eq(shares[2].partitions.length(), 1)
  // the shares are contiguous runs of the sorted partitions, and
  // together they are the whole topic exactly once
  let covered : Array[@cluster.PartitionId] = []
  for share in shares {
    for p in share.partitions {
      covered.push(p)
    }
  }
  covered.sort_by(fn(a, b) { a.index - b.index })
  assert_eq(covered, partitions)
  // the same call in any other order agrees: assignment is a function
  // of the member *set*, not of report ordering
  let shuffled = [member("c", 0L), member("a", 0L), member("b", 0L)]
  assert_eq(@group.assign(shuffled, partitions), shares)
  // more members than partitions: the extra ones hold nothing rather
  // than stealing a share
  let idle = @group.assign(
    [member("a", 0L), member("b", 0L), member("zz", 0L)],
    [part("events", 0)],
  )
  assert_eq(idle[2].partitions.length(), 0)
}

///|
test "membership changes move the epoch; silence removes a member once" {
  let state = @group.new_group("analytics")
  assert_eq(state.epoch, 0L)
  assert_true(@group.observe_member(state, member("a", 100L)))
  assert_eq(state.epoch, 1L)
  // a repeat report is not a membership change
  assert_true(!@group.observe_member(state, member("a", 150L)))
  assert_eq(state.epoch, 1L)
  // b reports later than a, so a timeout that removes a leaves b alone
  assert_true(@group.observe_member(state, member("b", 1500L)))
  assert_eq(state.epoch, 2L)
  // declaring a topic also moves the epoch: the assignment is about to
  // cover something new
  assert_true(@group.declare_topics(state, ["events"]))
  assert_eq(state.epoch, 3L)
  assert_true(!@group.declare_topics(state, ["events"]))
  // a silent member leaves, and the departure is reported once
  assert_eq(@group.sweep(state, 2000L, 1000L), ["a"])
  assert_eq(state.epoch, 4L)
  assert_eq(@group.sweep(state, 3000L, 1000L), ["b"])
  assert_eq(@group.sweep(state, 9000L, 1000L), [])
  assert_eq(state.members.length(), 0)
}

///|
test "a commit is fenced by the epoch and may only move forward" {
  let state = @group.new_group("analytics")
  let _ = @group.observe_member(state, member("a", 100L))
  let _ = @group.observe_member(state, member("b", 100L))
  let _ = @group.declare_topics(state, ["events"])
  let partitions = [part("events", 0), part("events", 1)]
  let epoch = state.epoch
  let mine = @group.assignment_of(state, "a", partitions)
  assert_eq(mine.length(), 1)
  let my_partition = mine[0]
  // the member that holds it may commit
  assert_true(@group.commit(state, "a", epoch, my_partition, 5L, mine) is Ok(_))
  assert_eq(@group.resume_offset(state, my_partition), 5L)
  // idempotent: the same offset again is fine (a retry is not an error)
  assert_true(@group.commit(state, "a", epoch, my_partition, 5L, mine) is Ok(_))
  // regression is refused: it would re-deliver records
  assert_true(
    @group.commit(state, "a", epoch, my_partition, 4L, mine)
    is Err(Regression(_)),
  )
  // a partition this member does not hold cannot be committed
  let theirs = @group.assignment_of(state, "b", partitions)
  assert_true(
    @group.commit(state, "a", epoch, theirs[0], 1L, mine) is Err(NotAssigned(_)),
  )
  // and a stranger cannot commit at all
  assert_true(
    @group.commit(state, "c", epoch, my_partition, 9L, mine)
    is Err(UnknownMember(_)),
  )
  // the fence: once membership moves, the old epoch is finished
  let _ = @group.observe_member(state, member("c", 200L))
  let stale = @group.commit(state, "a", epoch, my_partition, 6L, mine)
  assert_true(stale is Err(StaleEpoch(_)))
  // the member that now holds it (recompute at the new epoch) may
  let now = @group.assignment_of(state, "a", partitions)
  assert_true(@group.commit(state, "a", state.epoch, now[0], 6L, now) is Ok(_))
}

///|
test "the retention floor is the slower of the replicas and the group" {
  let state = @group.new_group("analytics")
  let p = part("events", 0)
  // no progress: the group holds nothing back (offset 0 means "no
  // floor", so the replicas' watermark is the only bound)
  assert_eq(@group.retention_floor(state, p, 100L), 100L)
  assert_eq(@group.retention_floor(state, p, 0L), 0L)
  let _ = @group.observe_member(state, member("a", 0L))
  let _ = @group.declare_topics(state, ["events"])
  let mine = @group.assignment_of(state, "a", [p])
  assert_true(@group.commit(state, "a", state.epoch, p, 30L, mine) is Ok(_))
  // the group is behind the watermark: it decides the floor
  assert_eq(@group.retention_floor(state, p, 100L), 30L)
  // a group ahead of the watermark is not a licence to keep less
  assert_eq(@group.retention_floor(state, p, 10L), 10L)
  // lag is derived, not stored
  assert_eq(@group.lag(state, p, 100L), 70L)
  assert_eq(@group.lag(state, p, 30L), 0L)
}
