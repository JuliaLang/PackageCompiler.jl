// This file is a part of Julia. License is MIT: http://julialang.org/license

// Standard headers
#include <string.h>
#include <stdint.h>
#include <stdio.h>

// Julia headers (for initialization and gc commands)
#include "uv.h"
#include "julia.h"

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

// Declare C prototype of a function defined in Julia
int julia_main(jl_array_t*);

// main function (windows UTF16 -> UTF8 argument conversion code copied from julia's ui/repl.c)
int main(int argc, char *argv[])
{
    uv_setup_args(argc, argv); // no-op on Windows

    // Find where eventual julia arguments start
    int program_argc = argc;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--julia-args") == 0) {
            program_argc = i;
            break;
        }
    }
    int julia_argc = argc - program_argc - 1;
    if (julia_argc > 0) {
        char ** julia_argv = &argv[program_argc];
        jl_parse_opts(&julia_argc, &julia_argv);
    }

    // Get the current exe path so we can compute a relative depot path
    char *exe_path = (char*)malloc(PATH_MAX);
    size_t path_size = PATH_MAX;
    if (!exe_path) {
        jl_errorf("fatal error: failed to allocate memory: %s", strerror(errno));
        free(exe_path);
        return 1;
    }
    if (uv_exepath(exe_path, &path_size)) {
        jl_error("fatal error: unexpected error while retrieving exepath");
        free(exe_path);
        return 1;
    }

    char* root_dir = dirname(dirname(exe_path));
    char* depot_str = "JULIA_DEPOT_PATH=";
    char* load_path_str = "JULIA_LOAD_PATH=";
#ifdef _WIN32
    char *julia_share_subdir = "\\share\\julia";
#else
    char *julia_share_subdir = "/share/julia";
#endif
    char *depot_path_env = calloc(sizeof(char), strlen(depot_str)    + strlen(root_dir) + strlen(julia_share_subdir) + 1);
    char *load_path_env  = calloc(sizeof(char), strlen(load_path_str)+ strlen(root_dir) + strlen(julia_share_subdir) + 1);

    strcat(depot_path_env, depot_str);
    strcat(depot_path_env, root_dir);
    strcat(depot_path_env, julia_share_subdir);

    strcat(load_path_env, load_path_str);
    strcat(load_path_env, root_dir);
    strcat(load_path_env, julia_share_subdir); 

    putenv(depot_path_env);
    putenv(load_path_env);
    // JULIAC_PROGRAM_LIBNAME defined on command-line for compilation
    jl_options.image_file = JULIAC_PROGRAM_LIBNAME;
    julia_init(JL_IMAGE_JULIA_HOME);

    // Initialize Core.ARGS with the full argv.
    jl_set_ARGS(program_argc, argv);

    // Set PROGRAM_FILE to argv[0].
    jl_set_global(jl_base_module,
        jl_symbol("PROGRAM_FILE"), (jl_value_t*)jl_cstr_to_string(argv[0]));

    // Set Base.ARGS to `String[ unsafe_string(argv[i]) for i = 1:argc ]`
    jl_array_t *ARGS = (jl_array_t*)jl_get_global(jl_base_module, jl_symbol("ARGS"));
    jl_array_grow_end(ARGS, program_argc - 1);
    for (int i = 1; i < program_argc; i++) {
        jl_value_t *s = (jl_value_t*)jl_cstr_to_string(argv[i]);
        jl_arrayset(ARGS, s, i - 1);
    }

    // call the work function, and get back a value
    int retcode = julia_main(ARGS);

    // Cleanup and gracefully exit

    free(depot_path_env);
    free(load_path_env);
    free(exe_path);
    jl_atexit_hook(retcode);
    return retcode;
}
