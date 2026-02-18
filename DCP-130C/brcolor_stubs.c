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

typedef int           BOOL;
typedef unsigned char BYTE;
typedef char         *LPSTR;

#define TRUE  1
#define FALSE 0

static int g_colm_debug = 0;
static unsigned long g_colm_calls = 0;
static unsigned long g_colm_bytes = 0;

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
        fprintf(stderr, "[BRCOLOR] ColorMatchingInit: rgbLine=%d paperType=%d "
                "machineId=%d (pass-through, no ICC applied)\n",
                d.nRgbLine, d.nPaperType, d.nMachineId);
    }
    (void)d;
    return TRUE;
}

void ColorMatchingEnd(void)
{
    if (g_colm_debug) {
        fprintf(stderr, "[BRCOLOR] ColorMatchingEnd: %lu calls, %lu bytes processed "
                "(pass-through)\n", g_colm_calls, g_colm_bytes);
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
