/* -----------------------------------------------------------------------------
 *
 * (c) The GHC Team, 1998-2018
 *
 * Non-moving garbage collector and allocator: Mark phase
 *
 * ---------------------------------------------------------------------------*/

#pragma once

#include "Task.h"
#include "NonMoving.h"
#include "WSDeque.h"

#include "BeginPrivate.h"

enum EntryType {
    NULL_ENTRY = 0,
    MARK_CLOSURE = 1,
    MARK_ARRAY = 2
};

/* Note [Origin references in the nonmoving collector]
 * ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 *
 * To implement indirection short-cutting and the selector optimisation the
 * collector needs to know where it found references, so it can update the
 * reference if it later turns out that points to an indirection. For this
 * reason, each mark queue entry contains two things:
 *
 * - a pointer to the object to be marked (p), and
 *
 * - a pointer to the field where we found the reference (origin)
 *
 * Note that the origin pointer is an interior pointer: it points not to a
 * valid closure (with info table pointer) but rather to a field inside a closure.
 * Since such references can't be safely scavenged we establish the invariant
 * that the origin pointer may only point to a field of an object living in the
 * nonmoving heap, where no scavenging is needed.
 *
 */

typedef struct {
    // Which kind of mark queue entry we have is determined by the tag bits of
    // the first word (using the tags defined by the EntryType enum).
    union {
        // A null_entry indicates the end of the queue.
        struct {
            void *p;              // must be NULL
        } null_entry;
        struct {
            StgClosure *p;        // the object to be marked
            StgClosure **origin;  // field where this reference was found.
                                  // See Note [Origin references in the nonmoving collector]
        } mark_closure;
        struct {
            const StgMutArrPtrs *array;
            StgWord start_index;  // start index is shifted to the left by 16 bits
        } mark_array;
    };
} MarkQueueEnt;

INLINE_HEADER enum EntryType nonmovingMarkQueueEntryType(MarkQueueEnt *ent)
{
    uintptr_t tag = (uintptr_t) ent->null_entry.p & TAG_MASK;
    ASSERT(tag <= MARK_ARRAY);
    return tag;
}

/*
 * A block containing a dense array of MarkQueueEnts.
 */
typedef struct {
    // index of first *unused* queue entry
    uint32_t head;

    // MARK_QUEUE_BLOCK_ENTRIES in length.
    MarkQueueEnt entries[];
} MarkQueueBlock;

// Number of blocks to allocate for a mark queue
#define MARK_QUEUE_BLOCKS 16

// The length of MarkQueueBlock.entries
#define MARK_QUEUE_BLOCK_ENTRIES ((MARK_QUEUE_BLOCKS * BLOCK_SIZE - sizeof(MarkQueueBlock)) / sizeof(MarkQueueEnt))

INLINE_HEADER bool markQueueBlockIsFull(MarkQueueBlock *b)
{
    return b->head == MARK_QUEUE_BLOCK_ENTRIES;
}

INLINE_HEADER bool markQueueBlockIsEmpty(MarkQueueBlock *b)
{
    return b->head == 0;
}

INLINE_HEADER MarkQueueBlock *markQueueBlockFromBdescr(bdescr *bd)
{
    return (MarkQueueBlock *) bd->start;
}

INLINE_HEADER bdescr *markQueueBlockBdescr(MarkQueueBlock *b)
{
    return Bdescr((StgPtr) b);
}

// How far ahead in mark queue to prefetch?
#define MARK_PREFETCH_QUEUE_DEPTH 5

// How many blocks to keep on the deque?
#define MARK_QUEUE_DEQUE_SIZE 32

/* The mark queue is not capable of concurrent read or write.
 *
 * invariants:
 *
 *  a. top is a valid chain of MarkQueueBlocks (linked through bdescr.link)
 *     with at least one block.
 */
typedef struct MarkQueue_ {
    // A list of MarkQueueBlocks, linked together by bdescr.link (which points to the next bdescr).
    // e.g. the next MarkQueueBlock of MarkQueue q would be
    //
    //     Bdescr(q->top)->link->start
    MarkQueueBlock *top;

    // A WSDeque of MarkQueueBlock*s which mark threads can steal from. When
    // the deque overflows we link blocks onto Bdescr(top)->link.
    WSDeque *rest;

    int mark_thread_n;
    OSThreadId thread_id;

#if MARK_PREFETCH_QUEUE_DEPTH > 0
    // A ring-buffer of entries which we will mark next
    MarkQueueEnt prefetch_queue[MARK_PREFETCH_QUEUE_DEPTH];
    // The first free slot in prefetch_queue.
    uint8_t prefetch_head;
#endif
} MarkQueue;

struct MarkState {
    // protects active_mark_threads and n_mark_threads.
    Mutex lock;
    // signalled when all marking threads have finished a round of marking.
    Condition phase_done_cond;
    // signalled to wake up marking threads for a new round of marking
    // (or terminate if .n_mark_threads > thread.mark_thread_n).
    Condition new_work_cond;
    // how many threads are currently marking?
    uint32_t active_mark_threads;
    // how many threads have been created?
    // this is currently static throughout marking.
    uint32_t n_mark_threads;
    // an array of MarkQueue*s, one per mark thread
    MarkQueue **queues;
};

extern struct MarkState mark_state;

/* The update remembered set.
 *
 * invariants:
 *
 *  a. top is a valid MarkQueueBlock (but with no chained blocks).
 *
 */
typedef struct {
    MarkQueueBlock *block;
} UpdRemSet;

extern bdescr *nonmoving_large_objects, *nonmoving_marked_large_objects,
              *nonmoving_compact_objects, *nonmoving_marked_compact_objects;
extern memcount n_nonmoving_large_blocks, n_nonmoving_marked_large_blocks,
                n_nonmoving_compact_blocks, n_nonmoving_marked_compact_blocks;

extern StgTSO *nonmoving_old_threads;
extern StgWeak *nonmoving_old_weak_ptr_list;
extern StgTSO *nonmoving_threads;
extern StgWeak *nonmoving_weak_ptr_list;

#if defined(DEBUG)
extern StgIndStatic *debug_caf_list_snapshot;
#endif

extern MarkQueue *current_mark_queue;
extern bdescr *upd_rem_set_block_list;


struct MarkContext;

void nonmovingMarkInitUpdRemSet(void);

void init_upd_rem_set(UpdRemSet *rset);
void reset_upd_rem_set(UpdRemSet *rset);
void updateRemembSetPushClosure(UpdRemSet *rset, StgClosure *p);
void updateRemembSetPushThunk(Capability *cap, StgThunk *p);
void updateRemembSetPushTSO(Capability *cap, StgTSO *tso);
void updateRemembSetPushStack(Capability *cap, StgStack *stack);

#if defined(THREADED_RTS)
void nonmovingFlushCapUpdRemSetBlocks(Capability *cap);
void nonmovingBeginFlush(Task *task);
bool nonmovingWaitForFlush(void);
void nonmovingFinishFlush(Task *task);
#endif

void markQueueAddRoot(MarkQueue* q, StgClosure** root);

void startMarkThreads(int n_mark_threads);
void stopMarkThreads(void);
void nonmovingInitMarkState(void);
void nonmovingMarkLeader(void);

bool nonmovingTidyWeaks(struct MarkQueue_ *queue);
void nonmovingTidyThreads(void);
void nonmovingMarkDeadWeaks(struct MarkQueue_ *queue, StgWeak **dead_weak_ptr_list);
void nonmovingResurrectThreads(struct MarkQueue_ *queue, StgTSO **resurrected_threads);
bool nonmovingIsAlive(StgClosure *p);
void nonmovingMarkDeadWeak(struct MarkQueue_ *queue, StgWeak *w);
void nonmovingAddUpdRemSetBlocks(UpdRemSet *rset);

//void markQueuePush(MarkQueue *q, const MarkQueueEnt *ent);
void markQueuePushClosureGC(UpdRemSet *q, StgClosure *p);
void markQueuePushClosure(MarkQueue *q,
                          StgClosure *p,
                          StgClosure **origin);
void markQueuePushClosure_(MarkQueue *q, StgClosure *p);
void markQueuePushArray(MarkQueue *q, const StgMutArrPtrs *array, StgWord start_index);
void updateRemembSetPushThunkEager(Capability *cap,
                                  const StgThunkInfoTable *orig_info,
                                  StgThunk *thunk);

INLINE_HEADER bool markQueueIsEmpty(MarkQueue *q)
{
    return q->top->head == 0 && markQueueBlockBdescr(q->top)->link == NULL;
}

INLINE_HEADER bool updRemSetIsEmpty(UpdRemSet *q)
{
    ASSERT(markQueueBlockBdescr(q->block)->link == NULL);
    return q->block->head == 0;
}

#if defined(DEBUG)

void printMarkQueueEntry(MarkQueueEnt *ent);
void printMarkQueue(MarkQueue *q);

#endif

#include "EndPrivate.h"
