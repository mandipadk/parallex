#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

int main(int argc, char *argv[]) {
    const char *home = getenv("HOME");
    char datadir[1024];
    snprintf(datadir, sizeof(datadir),
             "--user-data-dir=%s/Library/Application Support/Claude-ParallexPoC", home);
    char *args[] = {
        "/Applications/Claude.app/Contents/MacOS/Claude",
        datadir,
        NULL
    };
    execv(args[0], args);
    perror("execv failed");
    return 1;
}
