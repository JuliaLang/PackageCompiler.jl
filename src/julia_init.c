#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

#ifdef _MSC_VER
JL_DLLEXPORT char *dirname(char *);
#else
#include <libgen.h>
#endif

#ifdef _OS_WINDOWS_
#define DLLEXPORT __declspec(dllexport)
#else
#define DLLEXPORT
#endif


// Julia headers (for initialization and gc commands)
#include "julia.h"
#include "julia_init.h"
#include "uv.h"

static void setup_args(int argc, char **argv) {
    uv_setup_args(argc, argv);
    jl_parse_opts(&argc, &argv);
}

static const char *get_sysimage_path(const char *libname) {
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

static void set_depot_load_path(const char *root_dir) {
#ifdef _WIN32
    char *path_sep = ";";
    char *julia_share_subdir = "\\share\\julia";
#else
    char *path_sep = ":";
    char *julia_share_subdir = "/share/julia";
#endif
    int share_path_len = strlen(root_dir) + strlen(julia_share_subdir) + 1;

    char *curr_depot_path = getenv("JULIA_DEPOT_PATH");
    int curr_depot_path_len = curr_depot_path == NULL ? 0 : strlen(curr_depot_path);
    int new_depot_path_len = curr_depot_path_len + 1 + share_path_len;
    char *new_depot_path = calloc(sizeof (char), new_depot_path_len);
    if (curr_depot_path_len > 0) {
        strcat(new_depot_path, curr_depot_path);
        strcat(new_depot_path, path_sep);
    }
    strcat(new_depot_path, root_dir);
    strcat(new_depot_path, julia_share_subdir);

    char *curr_load_path = getenv("JULIA_LOAD_PATH");
    int curr_load_path_len = curr_load_path == NULL ? 0 : strlen(curr_load_path);
    int new_load_path_len = curr_load_path_len + 1 + share_path_len;
    char *new_load_path = calloc(sizeof (char), new_load_path_len);
    if (curr_load_path_len > 0) {
        strcat(new_load_path, curr_load_path);
        strcat(new_load_path, path_sep);
    }
    strcat(new_load_path, root_dir);
    strcat(new_load_path, julia_share_subdir);

#ifdef _WIN32
    _putenv_s("JULIA_DEPOT_PATH", new_depot_path);
    _putenv_s("JULIA_LOAD_PATH", new_load_path);
#else
    setenv("JULIA_DEPOT_PATH", new_depot_path, 1);
    setenv("JULIA_LOAD_PATH", new_load_path, 1);
#endif
    free(new_load_path);
    free(new_depot_path);
}

DLLEXPORT void init_julia(int argc, char **argv) {
    setup_args(argc, argv);

    const char *sysimage_path = get_sysimage_path(JULIAC_PROGRAM_LIBNAME);
    // Convert to absolute path since jl_init_with_image_file (Julia 1.12+)
    // resolves relative paths against bindir, which would be incorrect.
#ifdef _WIN32
    char *abs_sysimage_path = _fullpath(NULL, sysimage_path, 0);
#else
    char *abs_sysimage_path = realpath(sysimage_path, NULL);
#endif
    char *_sysimage_path = strdup(abs_sysimage_path);
    char *root_dir = dirname(dirname(_sysimage_path));
    set_depot_load_path(root_dir);
#if JULIA_VERSION_MAJOR == 1 && JULIA_VERSION_MINOR <= 11
    jl_options.image_file = abs_sysimage_path;
    julia_init(JL_IMAGE_CWD);
#else
    // Julia 1.12+: Pass explicit bindir to avoid incorrect auto-construction on Unix.
    // When bindir is NULL, Julia constructs it as libdir/../bin (Unix) or libdir (Windows).
    // PackageCompiler has libdir=root/lib/julia and bindir=root/bin, so on Unix the
    // auto-constructed path would be root/lib/julia/../bin = root/lib/bin (incorrect).
    size_t bindir_len = strlen(root_dir) + 5;
    char *bindir = (char *)malloc(bindir_len);
    snprintf(bindir, bindir_len, "%s/bin", root_dir);
    jl_init_with_image_file(bindir, abs_sysimage_path);
    free(bindir);
#endif
    free(_sysimage_path);
}

DLLEXPORT void shutdown_julia(int retcode) { jl_atexit_hook(retcode); }
