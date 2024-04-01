#include <stdio.h>

#include "julia_init.h"
#include "mylib.h"

int main(int argc, char *argv[])
{
    init_julia(argc, argv);

    int incremented = increment32(3);
    printf("Incremented value: %i\n", incremented);

    void *instantiated = instantiate_FMU("name", 0, "guid", "location", NULL, 0, 0);
    printf("Instantiated FMU: %p\n", instantiated);

    shutdown_julia(0);
    return 0;
}

