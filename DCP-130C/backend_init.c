/*
 * Backend initialization stub — linked into libsane-brother2.so
 *
 * This constructor runs when the SANE DLL layer dlopen()s the backend.
 * It logs the load event to stderr so that crashes during backend
 * initialization can be traced (the Brother WriteLog() function writes
 * to BrMfc32.log which may not be opened yet at crash time).
 *
 * Also installs a SIGSEGV handler that prints a diagnostic message
 * before the process dies, helping identify which library caused the
 * crash (the handler is replaced by the scandec_stubs.c handler when
 * libbrscandec2.so is dlopen()ed later).
 */
#include <stdio.h>
#include <signal.h>
#include <unistd.h>
#include <string.h>

static void backend_segfault_handler(int sig) {
    const char msg[] = "\n[BROTHER2] FATAL: Segmentation fault in SANE brother2 backend!\n"
                       "[BROTHER2] Crash occurred during backend init or scan setup.\n"
                       "[BROTHER2] Run with: LD_DEBUG=libs scanimage -L 2>&1\n"
                       "[BROTHER2] to trace library loading.\n";
    write(STDERR_FILENO, msg, sizeof(msg) - 1);
    struct sigaction sa;
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(sig, &sa, NULL);
    raise(sig);
}

__attribute__((constructor))
static void backend_init(void) {
    const char msg[] = "[BROTHER2] Backend library loaded (ARM native)\n";
    write(STDERR_FILENO, msg, sizeof(msg) - 1);

    struct sigaction sa;
    sa.sa_handler = backend_segfault_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, NULL);
}
