/*
 * Backend initialization stub — linked into libsane-brother2.so
 *
 * Installs a SIGSEGV handler that prints a diagnostic message before
 * the process dies, helping identify which library caused the crash.
 * The handler is replaced by the scandec_stubs.c handler when
 * libbrscandec2.so is dlopen()ed later.
 */
#include <signal.h>
#include <unistd.h>
#include <string.h>

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
}
