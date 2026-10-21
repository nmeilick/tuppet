/* The POSIX headers tuppet calls into, translated for the "c" module. */
#ifndef _WIN32
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#endif
