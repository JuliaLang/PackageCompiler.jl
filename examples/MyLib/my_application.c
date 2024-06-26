#include <stdio.h>

#include "julia_init.h"
#include "mylib.h"

int main(int argc, char *argv[])
{
    init_julia(argc, argv);

    int incremented = increment32(3);
    printf("Incremented value: %i", incremented);

    shutdown_julia(0);
    return 0;
}

