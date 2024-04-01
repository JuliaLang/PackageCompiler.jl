int increment32(int);
long increment64(long);
void *instantiate_FMU(
    const char *name,
    int type,
    const char *guid,
    const char *location,
    void *callbacks,
    int visible,
    int loggingOn);
