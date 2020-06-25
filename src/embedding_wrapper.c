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

JULIA_DEFINE_FAST_TLS()

// TODO: Windows wmain handling as in repl.c

// Declare C prototype of a function defined in Julia
int julia_main(jl_array_t*);

// main function (windows UTF16 -> UTF8 argument conversion code copied from julia's ui/repl.c)
int main(int argc, char *argv[])
{
    uv_setup_args(argc, argv); // no-op on Windows

    // initialization
    libsupport_init();

    // Get the current exe path so we can compute a relative depot path
    char *free_path = (char*)malloc(PATH_MAX);
    size_t path_size = PATH_MAX;
    if (!free_path)
       jl_errorf("fatal error: failed to allocate memory: %s", strerror(errno));
    if (uv_exepath(free_path, &path_size)) {
       jl_error("fatal error: unexpected error while retrieving exepath");
    }

    char buf[PATH_MAX];
    snprintf(buf, sizeof(buf), "JULIA_DEPOT_PATH=%s/", dirname(dirname(free_path)));
    putenv(buf);
    putenv("JULIA_LOAD_PATH=@");

    // JULIAC_PROGRAM_LIBNAME defined on command-line for compilation
    jl_options.image_file = JULIAC_PROGRAM_LIBNAME;
    julia_init(JL_IMAGE_JULIA_HOME);

    // Initialize Core.ARGS with the full argv.
    jl_set_ARGS(argc, argv);

    // Set PROGRAM_FILE to argv[0].
    jl_set_global(jl_base_module,
        jl_symbol("PROGRAM_FILE"), (jl_value_t*)jl_cstr_to_string(argv[0]));

    // Set Base.ARGS to `String[ unsafe_string(argv[i]) for i = 1:argc ]`
    jl_array_t *ARGS = (jl_array_t*)jl_get_global(jl_base_module, jl_symbol("ARGS"));
    jl_array_grow_end(ARGS, argc - 1);
    for (int i = 1; i < argc; i++) {
        jl_value_t *s = (jl_value_t*)jl_cstr_to_string(argv[i]);
        jl_arrayset(ARGS, s, i - 1);
    }

    // call the work function, and get back a value
    int retcode = julia_main(ARGS);

    // Cleanup and gracefully exit
    jl_atexit_hook(retcode);
    return retcode;
}
