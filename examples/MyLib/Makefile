# Makefile

JULIA ?= julia
DLEXT := $(shell $(JULIA) --startup-file=no -e 'using Libdl; print(Libdl.dlext)')

TARGET="../MyLibCompiled"

MYLIB_INCLUDES = $(TARGET)/include/julia_init.h $(TARGET)/include/mylib.h
MYLIB_PATH := $(TARGET)/lib/libmylib.$(DLEXT)

$(MYLIB_PATH) $(MYLIB_INCLUDES): build/build.jl src/MyLib.jl
	julia --startup-file=no --project=. -e 'using Pkg; Pkg.instantiate()'
	# Remove the following line when `create_library()` is merged upstream
	$(JULIA) --startup-file=no --project=build -e 'import Pkg; Pkg.add(url="https://github.com/kmsquire/PackageCompiler.jl.git", rev="kms/create_library")'
	julia --startup-file=no --project=build -e 'using Pkg; Pkg.instantiate()'
	julia --startup-file=no --project=build build/build.jl

.PHONY: clean
clean:
	$(RM) *~ *.o *.$(DLEXT)
	$(RM) -Rf $(TARGET)
