// This file is a part of Julia. License is MIT: http://julialang.org/license

// Standard headers
#include <string.h>
#include <stdint.h>

// Julia headers (for initialization and gc commands)
#include "uv.h"
#include "julia.h"

#ifdef JULIA_DEFINE_FAST_TLS // only available in Julia 0.7+
JULIA_DEFINE_FAST_TLS()
#endif

// Declare C prototype of a function defined in Julia
extern int julia_main(jl_array_t*);

// main function (windows UTF16 -> UTF8 argument conversion code copied from julia's ui/repl.c)
#ifndef _OS_WINDOWS_
int main(int argc, char *argv[])
{
    int retcode;
    int i;
    uv_setup_args(argc, argv); // no-op on Windows
#else
int wmain(int argc, wchar_t *wargv[], wchar_t *envp[])
{
    int retcode;
    int i;
    char **argv;
    for (i = 0; i < argc; i++) { // convert the command line to UTF8
        wchar_t *warg = argv[i];
        size_t len = WideCharToMultiByte(CP_UTF8, 0, warg, -1, NULL, 0, NULL, NULL);
        if (!len) return 1;
        char *arg = (char*)alloca(len);
        if (!WideCharToMultiByte(CP_UTF8, 0, warg, -1, arg, len, NULL, NULL)) return 1;
        argv[i] = arg;
    }
#endif

    // initialization
    libsupport_init();
    // jl_options.compile_enabled = JL_OPTIONS_COMPILE_OFF;
    // JULIAC_PROGRAM_LIBNAME defined on command-line for compilation.
    jl_options.image_file = JULIAC_PROGRAM_LIBNAME;
    julia_init(JL_IMAGE_JULIA_HOME);

    // build arguments array: `String[ unsafe_string(argv[i]) for i in 1:argc ]`
    jl_array_t *ARGS = jl_alloc_array_1d(jl_apply_array_type(jl_string_type, 1), 0);
    JL_GC_PUSH1(&ARGS);
    jl_array_grow_end(ARGS, argc - 1);
    for (i = 1; i < argc; i++) {
        jl_value_t *s = (jl_value_t*)jl_cstr_to_string(argv[i]);
        jl_arrayset(ARGS, s, i - 1);
    }
    // call the work function, and get back a value
    retcode = julia_main(ARGS);
    JL_GC_POP();

    // Cleanup and gracefully exit
    jl_atexit_hook(retcode);
    return retcode;
}
