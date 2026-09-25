// wasmtime C API shim for the operator host (P2).
//
// Session-struct design: one mf_session_t holds engine/store/instance/
// memory plus the resolved ABI exports, so the MoonBit side deals in a
// single opaque handle (Int64) and plain i32/int64 scalars.
//
// libwasmtime is dlopen'ed at runtime (no link-time dependency —
// cc-flags on a library package mis-triggers moon's executable link).
// The real wasmtime.h header provides the types; every CALL goes
// through dlsym-resolved function pointers. The stub compiler is
// pinned to clang (tcc mishandles the wasmtime header).
//
// Forensics note (T15): wasmtime_val_t is 32 bytes and
// wasmtime_memory_t is 24 bytes on arm64 — undersized hand mirrors of
// these caused the original stack corruption.

#include <wasmtime.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static void *mf_lib = NULL;

static void *mf_sym(const char *name) {
  if (mf_lib == NULL) {
    const char *path = getenv("MOONFLUX_WASMTIME_LIB");
    if (path == NULL || path[0] == 0) {
      path = "/opt/homebrew/lib/libwasmtime.dylib";
    }
    mf_lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (mf_lib == NULL) {
      return NULL;
    }
  }
  return dlsym(mf_lib, name);
}

/* Function-pointer typedefs mirroring the wasmtime C API. */
typedef wasmtime_error_t *(*mf_module_new_t)(wasm_engine_t *, const uint8_t *,
                                             size_t, wasmtime_module_t **);
typedef void (*mf_module_delete_t)(wasmtime_module_t *);
typedef wasmtime_store_t *(*mf_store_new_t)(wasm_engine_t *, void *, void *);
typedef void (*mf_store_delete_t)(wasmtime_store_t *);
typedef wasmtime_context_t *(*mf_store_context_t)(wasmtime_store_t *);
typedef wasmtime_error_t *(*mf_instance_new_t)(
    wasmtime_context_t *, const wasmtime_module_t *, const wasmtime_extern_t *,
    size_t, wasmtime_instance_t *, wasm_trap_t **);
typedef bool (*mf_instance_export_get_t)(wasmtime_context_t *,
                                         const wasmtime_instance_t *,
                                         const char *, size_t,
                                         wasmtime_extern_t *);
typedef wasmtime_error_t *(*mf_func_call_t)(wasmtime_context_t *,
                                            const wasmtime_func_t *,
                                            const wasmtime_val_t *, size_t,
                                            wasmtime_val_t *, size_t,
                                            wasm_trap_t **);
typedef uint8_t *(*mf_memory_data_t)(wasmtime_context_t *,
                                     const wasmtime_memory_t *);
typedef size_t (*mf_memory_data_size_t)(wasmtime_context_t *,
                                        const wasmtime_memory_t *);
typedef void (*mf_error_message_t)(wasmtime_error_t *, wasm_name_t *);
typedef void (*mf_error_delete_t)(wasmtime_error_t *);
typedef void (*mf_trap_message_t)(wasm_trap_t *, wasm_name_t *);
typedef void (*mf_trap_delete_t)(wasm_trap_t *);
typedef wasm_config_t *(*mf_config_new_t)(void);
typedef void (*mf_config_parallel_set_t)(wasm_config_t *, bool);
typedef void (*mf_config_delete_t)(wasm_config_t *);
typedef wasm_engine_t *(*mf_engine_new_with_config_t)(wasm_config_t *);
typedef void (*mf_engine_delete_t)(wasm_engine_t *);
// Fuel API: declared here rather than taken from the headers because
// wasmtime_config_consume_fuel_set is only documented (not declared) in
// the installed 48.0.2 headers, and every call is dlsym'ed anyway.
typedef void (*mf_config_consume_fuel_set_t)(wasm_config_t *, bool);
typedef wasmtime_error_t *(*mf_ctx_set_fuel_t)(wasmtime_context_t *,
                                               uint64_t);
typedef wasmtime_error_t *(*mf_ctx_get_fuel_t)(const wasmtime_context_t *,
                                               uint64_t *);

// Fuel granted for guest start-up (_start + abi_version + init). The
// per-call budget is installed by mf_we_set_fuel before each process.
#define MF_STARTUP_FUEL 10000000ULL

void mf_we_session_free(void *session);

typedef struct mf_session {
  wasm_engine_t *engine;
  wasmtime_store_t *store;
  wasmtime_module_t *module;
  wasmtime_instance_t instance;
  wasmtime_memory_t memory;
  wasmtime_func_t f_abi_version;
  wasmtime_func_t f_alloc_input;
  wasmtime_func_t f_init;
  wasmtime_func_t f_process;
  wasmtime_func_t f_output_len;
  wasmtime_func_t f_last_status;
  wasmtime_func_t f_last_error;
  wasmtime_func_t f_start;
  /* ABI v2 scalar exports (P26): OPTIONAL — a v1-only module has
     has_scalar = 0 and keeps working exactly as before. */
  int has_scalar;
  wasmtime_func_t f_scalar_version;
  wasmtime_func_t f_scalar_eval;
} mf_session_t;

static wasmtime_context_t *mf_store_context(wasmtime_store_t *store) {
  mf_store_context_t fn = (mf_store_context_t)mf_sym("wasmtime_store_context");
  if (!fn) return NULL;
  return fn(store);
}

/* Installs `fuel` as the remaining budget for this store. Returns 0 on
 * success, -1 with a message otherwise (fuel must be enabled on the
 * engine, which mf_engine_new guarantees). */
static int mf_ctx_set_fuel(wasmtime_context_t *ctx, uint64_t fuel, char *err,
                           int err_len);

static int mf_get_extern(wasmtime_context_t *ctx, wasmtime_instance_t *inst,
                         const char *name, wasmtime_extern_t *item) {
  mf_instance_export_get_t fn =
      (mf_instance_export_get_t)mf_sym("wasmtime_instance_export_get");
  if (!fn) return 0;
  return fn(ctx, inst, name, strlen(name), item);
}

static void mf_write_error(wasmtime_error_t *error, char *err, int err_len) {
  mf_error_message_t msg_fn =
      (mf_error_message_t)mf_sym("wasmtime_error_message");
  mf_error_delete_t del_fn =
      (mf_error_delete_t)mf_sym("wasmtime_error_delete");
  if (msg_fn == NULL || del_fn == NULL) {
    snprintf(err, err_len, "libwasmtime not loaded");
    return;
  }
  wasm_name_t msg;
  msg_fn(error, &msg);
  int n = (int)msg.size;
  if (n > err_len - 1) n = err_len - 1;
  memcpy(err, msg.data, n);
  err[n] = 0;
  del_fn(error);
}

static void mf_write_trap(wasm_trap_t *trap, char *err, int err_len) {
  mf_trap_message_t msg_fn = (mf_trap_message_t)mf_sym("wasm_trap_message");
  mf_trap_delete_t del_fn = (mf_trap_delete_t)mf_sym("wasm_trap_delete");
  if (msg_fn == NULL || del_fn == NULL) {
    snprintf(err, err_len, "libwasmtime not loaded");
    return;
  }
  wasm_name_t msg;
  msg_fn(trap, &msg);
  int n = (int)msg.size;
  if (n > err_len - 1) n = err_len - 1;
  memcpy(err, msg.data, n);
  err[n] = 0;
  del_fn(trap);
}

static int mf_ctx_set_fuel(wasmtime_context_t *ctx, uint64_t fuel, char *err,
                           int err_len) {
  mf_ctx_set_fuel_t fn = (mf_ctx_set_fuel_t)mf_sym("wasmtime_context_set_fuel");
  if (!fn) {
    snprintf(err, err_len, "cannot resolve wasmtime_context_set_fuel");
    return -1;
  }
  wasmtime_error_t *e = fn(ctx, fuel);
  if (e != NULL) {
    mf_write_error(e, err, err_len);
    return -1;
  }
  return 0;
}

static int mf_lookup_func(wasmtime_context_t *ctx, wasmtime_instance_t *inst,
                          const char *name, wasmtime_func_t *out, char *err,
                          int err_len) {
  mf_instance_export_get_t export_get =
      (mf_instance_export_get_t)mf_sym("wasmtime_instance_export_get");
  if (!export_get) {
    snprintf(err, err_len,
             "cannot resolve wasmtime symbols (set MOONFLUX_WASMTIME_LIB)");
    return -1;
  }
  wasmtime_extern_t item;
  if (!export_get(ctx, inst, name, strlen(name), &item)) {
    snprintf(err, err_len, "missing export %s", name);
    return -1;
  }
  if (item.kind != WASMTIME_EXTERN_FUNC) {
    snprintf(err, err_len, "export %s is not a function", name);
    return -1;
  }
  *out = item.of.func;
  return 0;
}

/* Parallel-compilation worker threads panic on MoonBit-generated
 * modules (wasmtime 48, vmoffsets num_defined_memories assert) while
 * single-threaded compilation of the same module is fine — so the
 * engine is built with parallel compilation disabled. */
static wasm_engine_t *mf_engine_new(char *err, int err_len) {
  mf_config_new_t config_new = (mf_config_new_t)mf_sym("wasm_config_new");
  mf_config_parallel_set_t parallel_set =
      (mf_config_parallel_set_t)mf_sym("wasmtime_config_parallel_compilation_set");
  mf_config_consume_fuel_set_t fuel_set =
      (mf_config_consume_fuel_set_t)mf_sym("wasmtime_config_consume_fuel_set");
  mf_config_delete_t config_delete =
      (mf_config_delete_t)mf_sym("wasm_config_delete");
  mf_engine_new_with_config_t engine_new_with_config =
      (mf_engine_new_with_config_t)mf_sym("wasm_engine_new_with_config");
  if (!config_new || !parallel_set || !config_delete || !engine_new_with_config) {
    snprintf(err, err_len,
             "cannot resolve wasmtime config symbols (set MOONFLUX_WASMTIME_LIB)");
    return NULL;
  }
  if (!fuel_set) {
    // Without fuel the tier budget cannot be enforced: refuse rather
    // than run unbounded guest code.
    snprintf(err, err_len, "cannot resolve wasmtime_config_consume_fuel_set");
    return NULL;
  }
  wasm_config_t *config = config_new();
  if (!config) {
    snprintf(err, err_len, "config_new failed");
    return NULL;
  }
  parallel_set(config, false);
  fuel_set(config, true);
  /* wasmtime_engine_new_with_config TAKES OWNERSHIP of the config —
   * do not delete it here. */
  wasm_engine_t *engine = engine_new_with_config(config);
  if (!engine) {
    snprintf(err, err_len, "engine_new_with_config failed");
  }
  return engine;
}

void *mf_we_session_new(const uint8_t *wasm, int wasm_len, char *err,
                        int err_len) {
  mf_module_new_t module_new = (mf_module_new_t)mf_sym("wasmtime_module_new");
  mf_store_new_t store_new = (mf_store_new_t)mf_sym("wasmtime_store_new");
  mf_store_delete_t store_delete =
      (mf_store_delete_t)mf_sym("wasmtime_store_delete");
  mf_module_delete_t module_delete =
      (mf_module_delete_t)mf_sym("wasmtime_module_delete");
  mf_engine_delete_t engine_delete =
      (mf_engine_delete_t)mf_sym("wasm_engine_delete");
  mf_instance_new_t instance_new =
      (mf_instance_new_t)mf_sym("wasmtime_instance_new");
  if (!module_new || !store_new || !store_delete || !module_delete ||
      !engine_delete || !instance_new) {
    snprintf(err, err_len,
             "cannot resolve wasmtime symbols (set MOONFLUX_WASMTIME_LIB)");
    return NULL;
  }
  mf_session_t *s = (mf_session_t *)malloc(sizeof(mf_session_t));
  if (!s) {
    snprintf(err, err_len, "oom");
    return NULL;
  }
  memset(s, 0, sizeof(*s));
  s->engine = mf_engine_new(err, err_len);
  if (!s->engine) {
    free(s);
    return NULL;
  }
  wasmtime_error_t *e = module_new(s->engine, wasm, (size_t)wasm_len,
                                   &s->module);
  if (e != NULL) {
    mf_write_error(e, err, err_len);
    engine_delete(s->engine);
    free(s);
    return NULL;
  }
  s->store = store_new(s->engine, NULL, NULL);
  if (!s->store) {
    snprintf(err, err_len, "store_new failed");
    module_delete(s->module);
    engine_delete(s->engine);
    free(s);
    return NULL;
  }
  wasmtime_context_t *ctx = mf_store_context(s->store);
  /* fuel is enabled engine-wide, so the store starts at zero and every
   * guest call would trap; grant the start-up allowance first. */
  if (mf_ctx_set_fuel(ctx, MF_STARTUP_FUEL, err, err_len) != 0) {
    store_delete(s->store);
    module_delete(s->module);
    engine_delete(s->engine);
    free(s);
    return NULL;
  }
  wasm_trap_t *trap = NULL;
  e = instance_new(ctx, s->module, NULL, 0, &s->instance, &trap);
  if (e != NULL) {
    mf_write_error(e, err, err_len);
    store_delete(s->store);
    module_delete(s->module);
    engine_delete(s->engine);
    free(s);
    return NULL;
  }
  if (trap != NULL) {
    mf_write_trap(trap, err, err_len);
    store_delete(s->store);
    module_delete(s->module);
    engine_delete(s->engine);
    free(s);
    return NULL;
  }
  if (mf_lookup_func(ctx, &s->instance, "mf_op_abi_version",
                     &s->f_abi_version, err, err_len) != 0 ||
      mf_lookup_func(ctx, &s->instance, "mf_op_alloc_input",
                     &s->f_alloc_input, err, err_len) != 0 ||
      mf_lookup_func(ctx, &s->instance, "mf_op_init", &s->f_init, err,
                     err_len) != 0 ||
      mf_lookup_func(ctx, &s->instance, "mf_op_process", &s->f_process, err,
                     err_len) != 0 ||
      mf_lookup_func(ctx, &s->instance, "mf_op_output_len",
                     &s->f_output_len, err, err_len) != 0 ||
      mf_lookup_func(ctx, &s->instance, "mf_op_last_status",
                     &s->f_last_status, err, err_len) != 0 ||
      mf_lookup_func(ctx, &s->instance, "mf_op_last_error",
                     &s->f_last_error, err, err_len) != 0) {
    mf_we_session_free(s);
    return NULL;
  }
  wasmtime_extern_t ver_item;
  wasmtime_extern_t eval_item;
  /* ABI v2 scalar exports: optional by design. A missing export
     leaves has_scalar = 0 (a v1-only module); a PRESENT export must
     be a function. */
  s->has_scalar = 0;
  if (mf_get_extern(ctx, &s->instance, "mf_op_scalar_abi_version",
                    &ver_item) &&
      mf_get_extern(ctx, &s->instance, "mf_op_eval", &eval_item)) {
    if (ver_item.kind != WASMTIME_EXTERN_FUNC ||
        eval_item.kind != WASMTIME_EXTERN_FUNC) {
      snprintf(err, err_len, "scalar exports are present but not functions");
      mf_we_session_free(s);
      return NULL;
    }
    s->f_scalar_version = ver_item.of.func;
    s->f_scalar_eval = eval_item.of.func;
    s->has_scalar = 1;
  }
  /* the linear memory export */
  wasmtime_extern_t mem_item;
  if (!mf_get_extern(ctx, &s->instance, "memory", &mem_item)) {
    snprintf(err, err_len, "missing export memory");
    mf_we_session_free(s);
    return NULL;
  }
  if (mem_item.kind != WASMTIME_EXTERN_MEMORY) {
    snprintf(err, err_len, "export memory is not a memory");
    mf_we_session_free(s);
    return NULL;
  }
  s->memory = mem_item.of.memory;
  /* Run the WASI _start once so the guest runtime initializes before
   * any ABI call (MoonBit wasm modules rely on it). */
  if (mf_lookup_func(ctx, &s->instance, "_start", &s->f_start, err,
                     err_len) != 0) {
    mf_we_session_free(s);
    return NULL;
  }
  mf_func_call_t func_call = (mf_func_call_t)mf_sym("wasmtime_func_call");
  if (!func_call) {
    snprintf(err, err_len,
             "cannot resolve wasmtime symbols (set MOONFLUX_WASMTIME_LIB)");
    mf_we_session_free(s);
    return NULL;
  }
  wasm_trap_t *start_trap = NULL;
  wasmtime_error_t *se =
      func_call(ctx, &s->f_start, NULL, 0, NULL, 0, &start_trap);
  if (se != NULL) {
    mf_write_error(se, err, err_len);
    mf_we_session_free(s);
    return NULL;
  }
  if (start_trap != NULL) {
    mf_write_trap(start_trap, err, err_len);
    mf_we_session_free(s);
    return NULL;
  }
  return s;
}

void mf_we_session_free(void *session) {
  mf_session_t *s = (mf_session_t *)session;
  if (!s) return;
  mf_store_delete_t store_delete =
      (mf_store_delete_t)mf_sym("wasmtime_store_delete");
  mf_module_delete_t module_delete =
      (mf_module_delete_t)mf_sym("wasmtime_module_delete");
  mf_engine_delete_t engine_delete =
      (mf_engine_delete_t)mf_sym("wasm_engine_delete");
  if (s->store && store_delete) store_delete(s->store);
  if (s->module && module_delete) module_delete(s->module);
  if (s->engine && engine_delete) engine_delete(s->engine);
  free(s);
}

static int mf_call_1_1(mf_session_t *s, wasmtime_func_t *fn, int32_t arg,
                       int32_t *out, char *err, int err_len) {
  mf_func_call_t func_call = (mf_func_call_t)mf_sym("wasmtime_func_call");
  if (!func_call) {
    snprintf(err, err_len,
             "cannot resolve wasmtime symbols (set MOONFLUX_WASMTIME_LIB)");
    return -1;
  }
  wasmtime_context_t *ctx = mf_store_context(s->store);
  wasmtime_val_t args[1];
  args[0].kind = WASMTIME_I32;
  args[0].of.i32 = arg;
  wasmtime_val_t results[1];
  wasm_trap_t *trap = NULL;
  wasmtime_error_t *e = func_call(ctx, fn, args, 1, results, 1, &trap);
  if (e != NULL) {
    mf_write_error(e, err, err_len);
    return -1;
  }
  if (trap != NULL) {
    mf_write_trap(trap, err, err_len);
    return -2;
  }
  *out = results[0].of.i32;
  return 0;
}

static int mf_call_0_1(mf_session_t *s, wasmtime_func_t *fn, int32_t *out,
                       char *err, int err_len) {
  mf_func_call_t func_call = (mf_func_call_t)mf_sym("wasmtime_func_call");
  if (!func_call) {
    snprintf(err, err_len,
             "cannot resolve wasmtime symbols (set MOONFLUX_WASMTIME_LIB)");
    return -1;
  }
  wasmtime_context_t *ctx = mf_store_context(s->store);
  wasmtime_val_t results[1];
  wasm_trap_t *trap = NULL;
  wasmtime_error_t *e = func_call(ctx, fn, NULL, 0, results, 1, &trap);
  if (e != NULL) {
    mf_write_error(e, err, err_len);
    return -1;
  }
  if (trap != NULL) {
    mf_write_trap(trap, err, err_len);
    return -2;
  }
  *out = results[0].of.i32;
  return 0;
}

int mf_we_abi_version(void *session, int32_t *out, char *err, int err_len) {
  mf_session_t *s = (mf_session_t *)session;
  return mf_call_0_1(s, &s->f_abi_version, out, err, err_len);
}

int mf_we_alloc_input(void *session, int len, int32_t *out_ptr, char *err,
                      int err_len) {
  mf_session_t *s = (mf_session_t *)session;
  int32_t boxed = 0;
  if (mf_call_1_1(s, &s->f_alloc_input, (int32_t)len, &boxed, err, err_len) !=
      0) {
    return -1;
  }
  *out_ptr = boxed;
  return 0;
}

int mf_we_init(void *session, int32_t config_ptr, int32_t *out, char *err,
               int err_len) {
  mf_session_t *s = (mf_session_t *)session;
  return mf_call_1_1(s, &s->f_init, config_ptr, out, err, err_len);
}

int mf_we_process(void *session, int32_t input_ptr, int32_t *out_ptr,
                  char *err, int err_len) {
  mf_session_t *s = (mf_session_t *)session;
  return mf_call_1_1(s, &s->f_process, input_ptr, out_ptr, err, err_len);
}

/* Installs the per-call fuel budget. Returns 0 on success, -1 on error. */
int mf_we_set_fuel(void *session, int64_t fuel, char *err, int err_len) {
  mf_session_t *s = (mf_session_t *)session;
  if (!s || !s->store) {
    snprintf(err, err_len, "invalid session");
    return -1;
  }
  if (fuel <= 0) {
    snprintf(err, err_len, "fuel must be positive");
    return -1;
  }
  return mf_ctx_set_fuel(mf_store_context(s->store), (uint64_t)fuel, err,
                         err_len);
}

/* Reports the fuel left in the store; 0 on success, -1 on error. */
int mf_we_fuel_left(void *session, int64_t *out, char *err, int err_len) {
  mf_session_t *s = (mf_session_t *)session;
  mf_ctx_get_fuel_t fn =
      (mf_ctx_get_fuel_t)mf_sym("wasmtime_context_get_fuel");
  if (!fn) {
    snprintf(err, err_len, "cannot resolve wasmtime_context_get_fuel");
    return -1;
  }
  uint64_t left = 0;
  wasmtime_error_t *e = fn(mf_store_context(s->store), &left);
  if (e != NULL) {
    mf_write_error(e, err, err_len);
    return -1;
  }
  *out = (int64_t)left;
  return 0;
}

int mf_we_output_len(void *session, int32_t *out, char *err, int err_len) {
  mf_session_t *s = (mf_session_t *)session;
  return mf_call_0_1(s, &s->f_output_len, out, err, err_len);
}

/* ABI v2 (P26): the guest's scalar ABI version, or 0 when the module
   offers no scalar exports (out is untouched). */
int mf_we_scalar_version(void *session, int32_t *out, char *err,
                         int err_len) {
  mf_session_t *s = (mf_session_t *)session;
  if (!s->has_scalar) {
    return 1; /* no scalar exports: not an error, a fact */
  }
  return mf_call_0_1(s, &s->f_scalar_version, out, err, err_len);
}

/* ABI v2 (P26): one scalar evaluation. The caller installs fuel
   first; the guest returns the ANSWER BUFFER's pointer (a guest Bytes,
   lowered to i32 exactly like mf_op_process's return), the length
   rides the existing mf_op_output_len, and failures ride
   mf_op_last_status/last_error. Returns -3 when the module has no
   scalar exports (a caller bug, not a guest failure). */
int mf_we_scalar_eval(void *session, int32_t ptr, int32_t len,
                      int32_t *out, char *err, int err_len) {
  mf_session_t *s = (mf_session_t *)session;
  if (!s->has_scalar) {
    snprintf(err, err_len, "module has no scalar exports");
    return -3;
  }
  mf_func_call_t func_call = (mf_func_call_t)mf_sym("wasmtime_func_call");
  if (!func_call) {
    snprintf(err, err_len,
             "cannot resolve wasmtime symbols (set MOONFLUX_WASMTIME_LIB)");
    return -1;
  }
  wasmtime_context_t *ctx = mf_store_context(s->store);
  wasmtime_val_t args[2];
  args[0].kind = WASMTIME_I32;
  args[0].of.i32 = ptr;
  args[1].kind = WASMTIME_I32;
  args[1].of.i32 = len;
  wasmtime_val_t results[1];
  wasm_trap_t *trap = NULL;
  wasmtime_error_t *e = func_call(ctx, &s->f_scalar_eval, args, 2, results,
                                  1, &trap);
  if (e != NULL) {
    mf_write_error(e, err, err_len);
    return -1;
  }
  if (trap != NULL) {
    mf_write_trap(trap, err, err_len);
    return -2;
  }
  *out = results[0].of.i32;
  return 0;
}

int mf_we_last_status(void *session, int32_t *out, char *err, int err_len) {
  mf_session_t *s = (mf_session_t *)session;
  return mf_call_0_1(s, &s->f_last_status, out, err, err_len);
}

/* Returns the data pointer of the guest's last-error byte object. */
int mf_we_last_error(void *session, int32_t *out, char *err, int err_len) {
  mf_session_t *s = (mf_session_t *)session;
  return mf_call_0_1(s, &s->f_last_error, out, err, err_len);
}

static uint8_t *mf_mem_slice(mf_session_t *s, int32_t ptr, int len, char *err,
                             int err_len) {
  mf_memory_data_t memory_data =
      (mf_memory_data_t)mf_sym("wasmtime_memory_data");
  mf_memory_data_size_t memory_data_size =
      (mf_memory_data_size_t)mf_sym("wasmtime_memory_data_size");
  if (!memory_data || !memory_data_size) {
    snprintf(err, err_len,
             "cannot resolve wasmtime symbols (set MOONFLUX_WASMTIME_LIB)");
    return NULL;
  }
  wasmtime_context_t *ctx = mf_store_context(s->store);
  size_t size = memory_data_size(ctx, &s->memory);
  if (ptr < 8 || len < 0 || (size_t)ptr + (size_t)len > size) {
    snprintf(err, err_len,
             "memory access out of bounds (ptr=%d len=%d mem=%zu)", ptr, len,
             size);
    return NULL;
  }
  return memory_data(ctx, &s->memory) + ptr;
}

int mf_we_mem_write(void *session, int32_t ptr, const uint8_t *data, int len,
                    char *err, int err_len) {
  uint8_t *base = mf_mem_slice((mf_session_t *)session, ptr, len, err, err_len);
  if (!base) return -1;
  memcpy(base, data, len);
  return 0;
}

int mf_we_mem_read(void *session, int32_t ptr, uint8_t *out, int len,
                   char *err, int err_len) {
  uint8_t *base = mf_mem_slice((mf_session_t *)session, ptr, len, err, err_len);
  if (!base) return -1;
  memcpy(out, base, len);
  return 0;
}

/* Reads the length header of a guest boxed byte object (data pointer
 * given): length = load32(ptr - 4) & 0x0FFFFFFF. */
int mf_we_boxed_len(void *session, int32_t ptr, int32_t *out, char *err,
                    int err_len) {
  uint8_t *base =
      mf_mem_slice((mf_session_t *)session, ptr - 4, 4, err, err_len);
  if (!base) return -1;
  uint32_t header;
  memcpy(&header, base, 4);
  *out = (int32_t)(header & 0x0FFFFFFFu);
  return 0;
}
