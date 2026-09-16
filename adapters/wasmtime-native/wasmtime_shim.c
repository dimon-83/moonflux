// wasmtime C API shim for the operator host (P2).
//
// Session-struct design: one mf_session_t holds engine/store/instance/
// memory plus the resolved ABI exports, so the MoonBit side deals in a
// single opaque handle (Int64) and plain i32/int64 scalars.
//
// libwasmtime is dlopen'ed at runtime (no link-time dependency): this
// sidesteps moon's native link config entirely (cc-link-flags on a
// library package mis-triggers an executable link expecting `main`)
// and makes the library path configurable via MOONFLUX_WASMTIME_LIB.
// The wasmtime.h header is NOT included (its include path would need
// link config, which mis-builds for library packages); minimal layout
// mirrors below are pinned against wasmtime 48.0.2 headers. Every call
// goes through dlsym-resolved function pointers.

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

/* ---- minimal type mirrors (pinned to wasmtime 48.0.2 layouts) ---- */
typedef struct wasm_engine_t mf_engine_o;
typedef struct wasmtime_store_t mf_store_o;
typedef struct wasmtime_module_t mf_module_o;
typedef struct wasmtime_context_t mf_context_o;
typedef struct wasmtime_error_t mf_error_o;
typedef struct wasm_trap_t mf_trap_o;

typedef struct {
  uint8_t kind; /* WASMTIME_I32 = 0 */
  uint8_t pad0[7];
  union {
    int32_t i32;
    int64_t i64;
    float f32;
    double f64;
    /* the real valunion is larger (funcref/v128 + tail padding):
     * sizeof(wasmtime_val_t) == 32 with of.i32 at offset 8 — verified
     * by the T15 probe; undersized mirrors corrupt the stack */
    uint8_t blob[24];
  } of;
} mf_val_t; /* 32 bytes, of.i32 at offset 8 */

typedef struct {
  uint64_t store_id;
  void *__private;
} mf_func_t; /* 16 bytes */

typedef struct {
  uint64_t store_id;
  uint32_t __private1;
  uint32_t __private2;
} mf_memory_t; /* 16 bytes */

typedef struct {
  uint64_t store_id;
  size_t __private;
} mf_instance_t; /* 16 bytes */

typedef struct {
  uint8_t kind; /* WASMTIME_EXTERN_FUNC = 0, _MEMORY = 3 */
  uint8_t pad0[7];
  union {
    mf_func_t func;
    mf_memory_t memory;
    uint8_t raw[24];
  } of;
} mf_extern_t; /* 32 bytes */

typedef struct {
  const char *data;
  size_t size;
} mf_name_t; /* 16 bytes */


/* Function-pointer typedefs mirroring the wasmtime C API. */
typedef struct wasm_engine_t *(*mf_engine_new_t)(void);
typedef void (*mf_engine_delete_t)(struct wasm_engine_t *);
typedef struct wasm_config_t mf_config_o; /* base config (wasm C API) */
typedef struct wasmtime_error_t *(*mf_module_new_t)(
    mf_engine_o *, const uint8_t *, size_t, mf_module_o **);
typedef void (*mf_module_delete_t)(mf_module_o *);
typedef struct wasmtime_store_t *(*mf_store_new_t)(mf_engine_o *, void *,
                                                   void *);
typedef void (*mf_store_delete_t)(mf_store_o *);
typedef struct wasmtime_context_t *(*mf_store_context_t)(mf_store_o *);
typedef struct wasmtime_error_t *(*mf_instance_new_t)(
    mf_context_o *, const mf_module_o *, const mf_extern_t *, size_t,
    mf_instance_t *, mf_trap_o **);
typedef bool (*mf_instance_export_get_t)(mf_context_o *,
                                         const mf_instance_t *, const char *,
                                         size_t, mf_extern_t *);
typedef struct wasmtime_error_t *(*mf_func_call_t)(
    mf_context_o *, const mf_func_t *, const mf_val_t *, size_t, mf_val_t *,
    size_t, mf_trap_o **);
typedef uint8_t *(*mf_memory_data_t)(mf_context_o *, const mf_memory_t *);
typedef size_t (*mf_memory_data_size_t)(mf_context_o *, const mf_memory_t *);
typedef void (*mf_error_message_t)(mf_error_o *, mf_name_t *);
typedef void (*mf_error_delete_t)(mf_error_o *);
typedef mf_config_o *(*mf_config_new_t)(void);
typedef void (*mf_config_parallel_set_t)(mf_config_o *, bool);
typedef void (*mf_config_delete_t)(mf_config_o *);
typedef void (*mf_gc_support_set_t)(mf_config_o *, bool);
typedef mf_engine_o *(*mf_engine_new_with_config_t)(mf_config_o *); /* wasm_ prefix: wasm_engine_new_with_config */
typedef void (*mf_trap_message_t)(mf_trap_o *, mf_name_t *);
typedef void (*mf_trap_delete_t)(mf_trap_o *);

/* Resolves a symbol lazily; every export helper carries its own err
 * buffer, so unresolved symbols surface as structured errors. */
#define MF_SYM(var, name, type)                          \
  static type var = NULL;                                \
  if (var == NULL) {                                     \
    void *sym = mf_sym(name);                            \
    if (sym == NULL) {                                   \
      snprintf(err, err_len,                             \
               "cannot resolve %s from libwasmtime "     \
               "(set MOONFLUX_WASMTIME_LIB)",            \
               name);                                    \
      return -1;                                         \
    }                                                    \
    var = (type)sym;                                     \
  }

void mf_we_session_free(void *session);

#define WASMTIME_I32 0
#define MF_EXTERN_FUNC 0
#define MF_EXTERN_MEMORY 3

typedef struct mf_session {
  mf_engine_o *engine;
  mf_store_o *store;
  mf_module_o *module;
  mf_instance_t instance;
  mf_memory_t memory;
  mf_func_t f_abi_version;
  mf_func_t f_alloc_input;
  mf_func_t f_init;
  mf_func_t f_process;
  mf_func_t f_output_len;
  mf_func_t f_last_status;
  mf_func_t f_last_error;
  mf_func_t f_start;
} mf_session_t;

static void mf_write_error(struct wasmtime_error_t *error, char *err,
                           int err_len) {
  mf_error_message_t msg_fn =
      (mf_error_message_t)mf_sym("wasmtime_error_message");
  mf_error_delete_t del_fn =
      (mf_error_delete_t)mf_sym("wasmtime_error_delete");
  if (msg_fn == NULL || del_fn == NULL) {
    snprintf(err, err_len, "libwasmtime not loaded");
    return;
  }
  mf_name_t msg;
  msg_fn(error, &msg);
  int n = (int)msg.size;
  if (n > err_len - 1) n = err_len - 1;
  memcpy(err, msg.data, n);
  err[n] = 0;
  del_fn(error);
}

static void mf_write_trap(struct wasm_trap_t *trap, char *err, int err_len) {
  mf_trap_message_t msg_fn = (mf_trap_message_t)mf_sym("wasm_trap_message");
  mf_trap_delete_t del_fn = (mf_trap_delete_t)mf_sym("wasm_trap_delete");
  if (msg_fn == NULL || del_fn == NULL) {
    snprintf(err, err_len, "libwasmtime not loaded");
    return;
  }
  mf_name_t msg;
  msg_fn(trap, &msg);
  int n = (int)msg.size;
  if (n > err_len - 1) n = err_len - 1;
  memcpy(err, msg.data, n);
  err[n] = 0;
  del_fn(trap);
}

static void *mf_store_context(mf_store_o *store) {
  mf_store_context_t fn = (mf_store_context_t)mf_sym("wasmtime_store_context");
  if (!fn) return NULL;
  return fn(store);
}

static int mf_lookup_func(mf_context_o *ctx, mf_instance_t *inst,
                          const char *name, mf_func_t *out, char *err,
                          int err_len) {
  MF_SYM(export_get, "wasmtime_instance_export_get", mf_instance_export_get_t)
  mf_extern_t item;
  if (!export_get(ctx, inst, name, strlen(name), &item)) {
    snprintf(err, err_len, "missing export %s", name);
    return -1;
  }
  if (item.kind != MF_EXTERN_FUNC) {
    snprintf(err, err_len, "export %s is not a function", name);
    return -1;
  }
  *out = item.of.func;
  return 0;
}

void *mf_we_session_new(const uint8_t *wasm, int wasm_len, char *err,
                        int err_len) {
  mf_engine_new_t engine_new = (mf_engine_new_t)mf_sym("wasm_engine_new");
  mf_module_new_t module_new = (mf_module_new_t)mf_sym("wasmtime_module_new");
  mf_store_new_t store_new = (mf_store_new_t)mf_sym("wasmtime_store_new");
  mf_instance_new_t instance_new =
      (mf_instance_new_t)mf_sym("wasmtime_instance_new");
  mf_store_delete_t store_delete =
      (mf_store_delete_t)mf_sym("wasmtime_store_delete");
  mf_module_delete_t module_delete =
      (mf_module_delete_t)mf_sym("wasmtime_module_delete");
  mf_engine_delete_t engine_delete =
      (mf_engine_delete_t)mf_sym("wasm_engine_delete");
  if (!engine_new || !module_new || !store_new || !instance_new ||
      !store_delete || !module_delete || !engine_delete) {
    snprintf(err, err_len,
             "cannot resolve wasmtime symbols (set MOONFLUX_WASMTIME_LIB)");
    return NULL;
  }
  /* Parallel-compilation worker threads panic on MoonBit-generated
   * modules (wasmtime 48, vmoffsets num_defined_memories assert) while
   * single-threaded compilation of the same module is fine — so the
   * engine is built with parallel compilation disabled. */
  mf_config_new_t config_new = (mf_config_new_t)mf_sym("wasm_config_new");
  mf_config_parallel_set_t parallel_set =
      (mf_config_parallel_set_t)mf_sym("wasmtime_config_parallel_compilation_set");
  mf_config_delete_t config_delete =
      (mf_config_delete_t)mf_sym("wasm_config_delete");
  mf_gc_support_set_t gc_support_set =
      (mf_gc_support_set_t)mf_sym("wasmtime_config_gc_support_set");
  mf_engine_new_with_config_t engine_new_with_config =
      (mf_engine_new_with_config_t)mf_sym("wasm_engine_new_with_config");
  if (!config_new || !parallel_set || !config_delete || !engine_new_with_config || !gc_support_set) {
    snprintf(err, err_len,
             "cannot resolve wasmtime config symbols (set MOONFLUX_WASMTIME_LIB)");
    return NULL;
  }
  mf_config_o *config = config_new();
  if (!config) {
    snprintf(err, err_len, "config_new failed");
    return NULL;
  }
  parallel_set(config, false);
  /* classic wasm target: no GC proposal needed; dropping GC support
   * also removes the compilation path that asserts on MoonBit modules */
  gc_support_set(config, false);
  mf_session_t *s = (mf_session_t *)malloc(sizeof(mf_session_t));
  if (!s) {
    config_delete(config);
    snprintf(err, err_len, "oom");
    return NULL;
  }
  memset(s, 0, sizeof(*s));
  /* wasmtime_engine_new_with_config TAKES OWNERSHIP of the config —
   * do not delete it here. */
  s->engine = engine_new_with_config(config);
  if (!s->engine) {
    snprintf(err, err_len, "engine_new failed");
    free(s);
    return NULL;
  }
  mf_error_o *e = module_new(s->engine, wasm, (size_t)wasm_len,
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
  mf_context_o *ctx = (mf_context_o *)mf_store_context(s->store);
  mf_trap_o *trap = NULL;
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
  /* the linear memory export */
  mf_instance_export_get_t export_get =
      (mf_instance_export_get_t)mf_sym("wasmtime_instance_export_get");
  if (!export_get) {
    snprintf(err, err_len,
             "cannot resolve wasmtime symbols (set MOONFLUX_WASMTIME_LIB)");
    mf_we_session_free(s);
    return NULL;
  }
  mf_extern_t mem_item;
  if (!export_get(ctx, &s->instance, "memory", 6, &mem_item)) {
    snprintf(err, err_len, "missing export memory");
    mf_we_session_free(s);
    return NULL;
  }
  if (mem_item.kind != MF_EXTERN_MEMORY) {
    snprintf(err, err_len, "export memory is not a memory");
    mf_we_session_free(s);
    return NULL;
  }
  s->memory = mem_item.of.memory;
  /* Run the WASI _start once so the guest runtime initializes before
   * any ABI call (MoonBit wasm modules rely on it). A _start that
   * "exits" via WASI would surface as a trap here — rejected. */
  if (mf_lookup_func(ctx, &s->instance, "_start", &s->f_start, err, err_len) != 0) {
    mf_we_session_free(s);
    return NULL;
  }
  fprintf(stderr, "[shim] _start call begin\n");
  mf_func_call_t func_call = (mf_func_call_t)mf_sym("wasmtime_func_call");
  if (!func_call) {
    snprintf(err, err_len,
             "cannot resolve wasmtime symbols (set MOONFLUX_WASMTIME_LIB)");
    mf_we_session_free(s);
    return NULL;
  }
  mf_trap_o *start_trap = NULL;
  mf_error_o *se = func_call(ctx, &s->f_start, NULL, 0, NULL, 0, &start_trap);
  fprintf(stderr, "[shim] _start call done\n");
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

static int mf_call_1_1(mf_session_t *s, mf_func_t *fn, int32_t arg,
                       int32_t *out, char *err, int err_len) {
  MF_SYM(func_call, "wasmtime_func_call", mf_func_call_t)
  mf_context_o *ctx = (mf_context_o *)mf_store_context(s->store);
  mf_val_t args[1];
  args[0].kind = WASMTIME_I32;
  args[0].of.i32 = arg;
  mf_val_t results[1];
  mf_trap_o *trap = NULL;
  mf_error_o *e = func_call(ctx, fn, args, 1, results, 1, &trap);
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

static int mf_call_0_1(mf_session_t *s, mf_func_t *fn, int32_t *out,
                       char *err, int err_len) {
  MF_SYM(func_call, "wasmtime_func_call", mf_func_call_t)
  mf_context_o *ctx = (mf_context_o *)mf_store_context(s->store);
  mf_val_t results[1];
  mf_trap_o *trap = NULL;
  mf_error_o *e = func_call(ctx, fn, NULL, 0, results, 1, &trap);
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

/* Calls mf_op_init; the guest's status (-1 = rejected config) comes
 * back through `out`, shim failures through the negative return. */
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

int mf_we_output_len(void *session, int32_t *out, char *err, int err_len) {
  mf_session_t *s = (mf_session_t *)session;
  return mf_call_0_1(s, &s->f_output_len, out, err, err_len);
}

int mf_we_last_status(void *session, int32_t *out, char *err, int err_len) {
  mf_session_t *s = (mf_session_t *)session;
  return mf_call_0_1(s, &s->f_last_status, out, err, err_len);
}

/* Returns the data pointer of the guest's last-error byte object.
 * (The guest resolves the corresponding export; the shim stores no
 * func for it because f_last_error is looked up only when needed.) */
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
  mf_context_o *ctx = (mf_context_o *)mf_store_context(s->store);
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
