// Standard headers
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// Julia headers
#include "julia.h"
#include "uv.h"

#ifdef _MSC_VER
JL_DLLEXPORT char *dirname(char *);
#else
#include <libgen.h>
#endif

#ifdef NEW_DEFINE_FAST_TLS_SYNTAX
JULIA_DEFINE_FAST_TLS
#else
JULIA_DEFINE_FAST_TLS()
#endif

// TODO: Windows wmain handling as in repl.c

jl_value_t *checked_eval_string(const char *code) {
    jl_value_t *result = jl_eval_string(code);
    if (jl_exception_occurred()) {
        // none of these allocate, so a gc-root (JL_GC_PUSH) is not necessary
        jl_call2(jl_get_function(jl_base_module, "showerror"), jl_stderr_obj(),
                 jl_exception_occurred());
        jl_printf(jl_stderr_stream(), "\n");
        jl_atexit_hook(1);
        exit(1);
    }
    assert(result && "Missing return value but no exception occurred!");
    return result;
}

void set_depot_load_path(const char *root_dir) {
#ifdef _WIN32
    char *julia_share_subdir = "\\share\\julia";
#else
    char *julia_share_subdir = "/share/julia";
#endif
    char *share_dir =
        calloc(sizeof(char), strlen(root_dir) + strlen(julia_share_subdir) + 1);
    strcat(share_dir, root_dir);
    strcat(share_dir, julia_share_subdir);

#ifdef _WIN32
    _putenv_s("JULIA_DEPOT_PATH", share_dir);
    _putenv_s("JULIA_LOAD_PATH", share_dir);
#else
    setenv("JULIA_DEPOT_PATH", share_dir, 1);
    setenv("JULIA_LOAD_PATH", share_dir, 1);
#endif
}

// main function (windows UTF16 -> UTF8 argument conversion code copied from
// julia's ui/repl.c)
int main(int argc, char *argv[]) {
    argv = uv_setup_args(argc, argv); // no-op on Windows

    // Find where eventual julia arguments start
    int program_argc = argc;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--julia-args") == 0) {
            program_argc = i;
            break;
        }
    }
    int julia_argc = argc - program_argc;
    if (julia_argc > 0) {
        // Replace `--julia-args` with the program name
        argv[program_argc] = argv[0];
        char **julia_argv = &argv[program_argc];
        jl_parse_opts(&julia_argc, &julia_argv);
    }

    // Get the current exe path so we can compute a relative depot path
    char *exe_path = (char *)malloc(PATH_MAX);
    size_t path_size = PATH_MAX;
    if (!exe_path) {
        jl_errorf("fatal error: failed to allocate memory: %s",
                  strerror(errno));
        free(exe_path);
        return 1;
    }
    if (uv_exepath(exe_path, &path_size)) {
        jl_error("fatal error: unexpected error while retrieving exepath");
        free(exe_path);
        return 1;
    }

    // Set up LOAD_PATH and DEPOT_PATH
    char *root_dir = dirname(dirname(exe_path));
    set_depot_load_path(root_dir);

    jl_init();

    // Initialize Core.ARGS with the full argv.
    jl_set_ARGS(program_argc, argv);

    // Update ARGS and PROGRAM_FILE
    checked_eval_string("append!(empty!(Base.ARGS), Core.ARGS)");
    jl_value_t *firstarg = checked_eval_string("popfirst!(ARGS)");
    JL_GC_PUSH1(&firstarg);
    jl_set_global(jl_base_module, jl_symbol("PROGRAM_FILE"), firstarg);
    JL_GC_POP();

    // call the work function, and get back a value
    jl_value_t *jl_retcode = checked_eval_string(JULIA_MAIN "()");
    int32_t retcode = 0;
    if (!jl_typeis(jl_retcode, jl_int32_type)) {
        fprintf(stderr,
                "ERROR: expected a Cint return value from function " JULIA_MAIN
                "\n");
        retcode = 1;
    } else {
        retcode = jl_unbox_int32(jl_retcode);
    }

    // Cleanup and gracefully exit
    free(exe_path);
    jl_atexit_hook(retcode);
    return retcode;
}
