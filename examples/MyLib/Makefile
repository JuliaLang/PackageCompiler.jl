# Makefile

.DEFAULT_GOAL := all

JULIA ?= julia
DLEXT := $(shell $(JULIA) --startup-file=no -e 'using Libdl; print(Libdl.dlext)')

TARGET="MyLibCompiled"

MYLIB_INCLUDES = $(TARGET)/include/julia_init.h $(TARGET)/include/mylib.h
MYLIB_PATH := $(TARGET)/lib/libmylib.$(DLEXT)

build-library: build/build.jl src/MyLib.jl
	$(JULIA) --startup-file=no --project=. -e 'using Pkg; Pkg.instantiate()'
	$(JULIA) --startup-file=no --project=build -e 'using Pkg; Pkg.instantiate(); include("build/build.jl")'

INCLUDE_DIR = $(TARGET)/include

build-executable:
	gcc my_application.c -o my_application.out -I$(INCLUDE_DIR) -L$(TARGET)/lib -ljulia -lmylib

all: build-library build-executable

clean:
	$(RM) *~ *.o *.$(DLEXT)
	$(RM) -Rf $(TARGET)

.PHONY: build-library build-executable clean all
