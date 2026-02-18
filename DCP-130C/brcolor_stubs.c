/*
 * ARM stub for libbrcolm2 — color matching (pass-through)
 *
 * This replaces Brother's proprietary i386-only libbrcolm2.so with a
 * native ARM pass-through implementation. Color matching is a cosmetic
 * adjustment (ICC profile application) that is not essential for
 * scanning. Returning TRUE without modification produces uncorrected
 * but valid scan data.
 *
 * Function signatures must match the typedefs in brcolor.h:
 *   typedef BOOL (*COLORINIT)(CMATCH_INIT);
 *   typedef void (*COLOREND)(void);
 *   typedef BOOL (*COLORMATCHING)(BYTE *, long, long);
 *
 * Debug diagnostics: set BROTHER_DEBUG=1 to enable call tracking on stderr.
 *
 * Copyright: 2026, based on Brother brscan2-src-0.2.5-1 API
 */
#include <stdlib.h>
#include <stdio.h>
#include <time.h>

typedef int           BOOL;
typedef unsigned char BYTE;
typedef char         *LPSTR;

#define TRUE  1
#define FALSE 0

static int g_colm_debug = 0;
static unsigned long g_colm_calls = 0;
static unsigned long g_colm_bytes = 0;

/*
 * Format current wall-clock time as "HH:MM:SS.mmm" into a static buffer.
 */
static const char *debug_ts(void) {
    static char buf[16];
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tm;
    localtime_r(&ts.tv_sec, &tm);
    snprintf(buf, sizeof(buf), "%02d:%02d:%02d.%03d",
             tm.tm_hour, tm.tm_min, tm.tm_sec,
             (int)(ts.tv_nsec / 1000000));
    return buf;
}

#pragma pack(1)
typedef struct {
    int   nRgbLine;
    int   nPaperType;
    int   nMachineId;
    LPSTR lpLutName;
} CMATCH_INIT;
#pragma pack()

BOOL ColorMatchingInit(CMATCH_INIT d)
{
    const char *env = getenv("BROTHER_DEBUG");
    g_colm_debug = (env && env[0] == '1');
    g_colm_calls = 0;
    g_colm_bytes = 0;
    if (g_colm_debug) {
        fprintf(stderr, "%s [BRCOLOR] ColorMatchingInit: rgbLine=%d paperType=%d "
                "machineId=%d (pass-through, no ICC applied)\n",
                debug_ts(), d.nRgbLine, d.nPaperType, d.nMachineId);
    }
    (void)d;
    return TRUE;
}

void ColorMatchingEnd(void)
{
    if (g_colm_debug) {
        fprintf(stderr, "%s [BRCOLOR] ColorMatchingEnd: %lu calls, %lu bytes processed "
                "(pass-through)\n", debug_ts(), g_colm_calls, g_colm_bytes);
    }
}

BOOL ColorMatching(BYTE *d, long len, long cnt)
{
    if (g_colm_debug) {
        g_colm_calls++;
        g_colm_bytes += (unsigned long)(len > 0 ? len : 0) *
                        (unsigned long)(cnt > 0 ? cnt : 0);
    }
    (void)d;
    (void)len;
    (void)cnt;
    return TRUE;
}
