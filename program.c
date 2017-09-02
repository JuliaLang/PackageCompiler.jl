// This file is a part of Julia. License is MIT: http://julialang.org/license

// Standard headers
#include <string.h>
#include <stdint.h>

// Julia headers (for initialization and gc commands)
#include "uv.h"
#include "julia.h"

// Declare C prototype of a function defined in Julia
//extern intptr_t (*julia_hello)(char*, intptr_t);
extern void julia_main();

int main(int argc, char *argv[])
{
  intptr_t v;
  
  // Initialize Julia
  uv_setup_args(argc, argv); // no-op on Windows
  libsupport_init();
  // jl_options.compile_enabled = JL_OPTIONS_COMPILE_OFF;
  jl_options.image_file = "libhello";
  julia_init(JL_IMAGE_CWD);

  // Do some work
  //v = julia_hello(argv[argc - 1], 42);
  julia_main();

  // Cleanup and graceful exit
  jl_atexit_hook(0);
  return 0;
}
