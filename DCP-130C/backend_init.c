/*
 * Backend initialization stub — linked into libsane-brother2.so
 *
 * Installs a SIGSEGV handler so crashes in the SANE backend produce
 * a visible error on stderr before the process dies (the default
 * behavior is a silent crash).
 *
 * Debug diagnostics: set BROTHER_DEBUG=1 to log backend load on stderr.
 */
#include <signal.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

static void backend_segfault_handler(int sig) {
    const char msg[] = "\n[BROTHER2] FATAL: Segmentation fault in SANE brother2 backend!\n";
    write(STDERR_FILENO, msg, sizeof(msg) - 1);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(sig, &sa, NULL);
    raise(sig);
}

__attribute__((constructor))
static void backend_init(void) {
    struct sigaction sa;
    sa.sa_handler = backend_segfault_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, NULL);

    const char *env = getenv("BROTHER_DEBUG");
    if (env && env[0] == '1') {
        fprintf(stderr, "[BROTHER2] SANE brother2 backend loaded "
                "(BROTHER_DEBUG=1, diagnostics enabled)\n");
    }
}
