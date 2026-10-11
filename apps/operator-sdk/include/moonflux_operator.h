/* SPDX-License-Identifier: Apache-2.0
 *
 * moonflux operator ABI — the C surface a guest module must export.
 *
 * This header is the author-facing statement of the contract the host
 * enforces. It is not documentation that can rot: every operator build
 * runs tools/probe_operator_exports.py, which checks these declarations
 * against the probe's own expectations and this file's ABI version
 * against the kernel's constant (P30/T112).
 *
 * A guest is a wasm module with NO imports — no WASI, no clock, no random
 * source, no IO. That is a structural fact, not a convention: the probe
 * refuses a module with an import section, because the host's "pure
 * function" assumption rests on it. Any language that can emit such a
 * module may author a guest; apps/operator-sdk is the MoonBit one, and
 * docs/operator-authoring-guide.md is the walkthrough.
 *
 * Pointers are i32 offsets into the module's linear memory, which is why
 * this header uses int32_t rather than a pointer type: a wasm guest has
 * no addresses the host can hand it.
 *
 * Buffered-call protocol (ABI v1, guest-owned allocation):
 *   1. host:  len = expected payload size
 *             ptr = mf_op_alloc_input(len)
 *   2. host:  writes `len` payload bytes at [ptr, ptr+len) in the guest's
 *             exported memory
 *   3. host:  status = mf_op_process(ptr)
 *   4. host:  the answer is at the returned value; its length comes from
 *             mf_op_output_len()
 *   5. host:  on failure, mf_op_last_status() / mf_op_last_error() carry
 *             the structured reason (the text is bounded by the host)
 */
#ifndef MOONFLUX_OPERATOR_H
#define MOONFLUX_OPERATOR_H

#include <stdint.h>

/* The ABI this header describes. A guest reports the ABI it targets from
 * mf_op_abi_version(); a mismatch is refused before any record flows. */
#define MOONFLUX_OPERATOR_ABI_VERSION 1

/* ABI v1 — the batch call. Every export below is REQUIRED.
 *
 * The payload is one batch frame: a count-prefixed sequence of records
 * (key, value, timestamp, headers). The answer is one batch frame of the
 * same shape, which is what makes 1->0 (a shorter batch) and 1->N (a
 * longer one) expressible instead of being special cases.
 */
int32_t mf_op_abi_version(void);

/* Reserves `len` bytes for the host to write the next payload into and
 * returns their offset. */
int32_t mf_op_alloc_input(int32_t len);

/* Called once per module instance with the spec's `config` object
 * verbatim (JSON text). Returns 0 on success; anything else refuses the
 * transform. The host never interprets the config: its meaning belongs to
 * the operator, and an unknown key should be refused here rather than
 * silently ignored. */
int32_t mf_op_init(int32_t config_ptr);

/* Transforms one batch. Returns the offset of the answer. */
int32_t mf_op_process(int32_t input_ptr);

/* Length in bytes of the answer produced by the last call. */
int32_t mf_op_output_len(void);

/* 0 when the last call succeeded; the structured failure code otherwise.
 * A failure is fail-closed: no partial batch reaches a sink. */
int32_t mf_op_last_status(void);

/* Offset of the bounded error text for the last failure. */
int32_t mf_op_last_error(void);

/* ABI v2 — the scalar call. OPTIONAL and SYMMETRIC: a module that exports
 * one of these two must export both, and a v1-only module exports
 * neither (the probe enforces both halves).
 *
 * The scalar surface evaluates one value at a time under a node
 * registry, for functions that are configured rather than mounted as a
 * transform. It reuses the v1 return split: the answer pointer comes back
 * from mf_op_eval, its length from mf_op_output_len, and failures from
 * mf_op_last_status / mf_op_last_error. Do not invent a third buffering
 * protocol.
 */
int32_t mf_op_scalar_abi_version(void);
int32_t mf_op_eval(int32_t input_ptr);

/* ABI v3 — the stateful call (P30/T114). OPTIONAL and SYMMETRIC, on the
 * same terms as v2: a module that keeps keyed state exports both of these,
 * a stateless module neither.
 *
 * State arrives and leaves as DATA, which is why a stateful guest still
 * has no imports. The v3 payload is a self-describing state prefix (uleb
 * entry count, then per entry: uleb key length + key, uleb value length +
 * value) followed by the v1 batch frame; the answer uses the same layout.
 * Only a module exporting this pair is ever called through
 * mf_op_state_apply, so the v1/v2 payload shapes are untouched.
 *
 * Values are opaque bytes: the host moves them and never interprets them.
 * See docs/operator-abi-v3-state.md for the host-side view and the
 * durability story (the state lives in a compacted keyed topic).
 */
int32_t mf_op_state_abi_version(void);
int32_t mf_op_state_apply(int32_t input_ptr);

#endif /* MOONFLUX_OPERATOR_H */
