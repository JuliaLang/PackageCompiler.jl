// This file is a part of Julia. License is MIT: http://julialang.org/license


// Standard headers
#include <string.h>
#include <stdint.h>
#include <stdio.h>

// Julia headers (for initialization and gc commands)
#include "uv.h"
#include "julia.h"
#include "julia_init.h"

#ifdef NEW_DEFINE_FAST_TLS_SYNTAX
JULIA_DEFINE_FAST_TLS
#else
JULIA_DEFINE_FAST_TLS()
#endif

// TODO: Windows wmain handling as in repl.c

// Declare C prototype of a function defined in Julia
int julia_main(jl_array_t*);

void set_load_path();
void set_depot_path(char *);


int main(int argc, char *argv[])
{
    uv_setup_args(argc, argv);
    libsupport_init();

    // Initialize Core.ARGS with the full argv.
    jl_set_ARGS(argc, argv);

    // Get the current exe path so we can compute a relative depot path
    char *free_path = (char*)malloc(PATH_MAX);
    size_t path_size = PATH_MAX;
    if (!free_path)
       jl_errorf("fatal error: failed to allocate memory: %s", strerror(errno));
       return -1;
    if (uv_exepath(free_path, &path_size)) {
       jl_error("fatal error: unexpected error while retrieving exepath");
       return -1;
    }

    set_depot_path(free_path);
    free(free_path);
    set_load_path();
 
    jl_init_with_image(NULL, JULIAC_PROGRAM_LIBNAME);
    // Set PROGRAM_FILE to argv[0].
    jl_set_global(jl_base_module,
        jl_symbol("PROGRAM_FILE"), (jl_value_t*)jl_cstr_to_string(argv[0]));

    jl_eval_string("append!(empty!(ARGS), Core.ARGS);");

    jl_array_t *ARGS = (jl_array_t*)jl_get_global(jl_base_module, jl_symbol("ARGS"));
    int retcode = julia_main(ARGS);

    shutdown_julia(retcode);
    return retcode;
}
