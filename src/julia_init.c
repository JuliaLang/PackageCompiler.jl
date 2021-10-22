#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

#ifdef _MSC_VER
JL_DLLEXPORT char *dirname(char *);
#else
#include <libgen.h>
#endif

// Julia headers (for initialization and gc commands)
#include "julia.h"
#include "julia_init.h"
#include "uv.h"

void setup_args(int argc, char **argv) {
    uv_setup_args(argc, argv);
    jl_parse_opts(&argc, &argv);
}

const char *get_sysimage_path(const char *libname) {
    if (libname == NULL) {
        jl_error("julia: Specify `libname` when requesting the sysimage path");
        exit(1);
    }

    void *handle = jl_load_dynamic_library(libname, JL_RTLD_DEFAULT, 0);
    if (handle == NULL) {
        jl_errorf("julia: Failed to load library at %s", libname);
        exit(1);
    }

    const char *libpath = jl_pathname_for_handle(handle);
    if (libpath == NULL) {
        jl_errorf("julia: Failed to retrieve path name for library at %s",
                  libname);
        exit(1);
    }

    return libpath;
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
    free(share_dir);
}

void init_julia(int argc, char **argv) {
    setup_args(argc, argv);

    const char *sysimage_path = get_sysimage_path(JULIAC_PROGRAM_LIBNAME);
    char *_sysimage_path = strdup(sysimage_path);
    char *root_dir = dirname(dirname(_sysimage_path));
    set_depot_load_path(root_dir);
    free(_sysimage_path);

    jl_options.image_file = sysimage_path;
    julia_init(JL_IMAGE_CWD);
}

void shutdown_julia(int retcode) { jl_atexit_hook(retcode); }
