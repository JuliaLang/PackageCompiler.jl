// This file is a part of Julia. License is MIT: http://julialang.org/license

#include <string.h>
#include <stdint.h>

#include "uv.h"
#include "julia.h"

extern intptr_t (*julia_hello)(char*, intptr_t);

int main(int argc, char *argv[])
{
    uv_setup_args(argc, argv); // no-op on Windows
    libsupport_init();
    jl_options.compile_enabled = JL_OPTIONS_COMPILE_OFF;
    jl_options.image_file = "sys-plus.dylib";
    julia_init(JL_IMAGE_CWD);

    julia_hello(argv[argc - 1], 42);

    jl_atexit_hook(0);
    return 0;
}

