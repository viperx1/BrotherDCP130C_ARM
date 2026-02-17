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
 * Copyright: 2026, based on Brother brscan2-src-0.2.5-1 API
 */
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>

typedef int           BOOL;
typedef unsigned char BYTE;
typedef char         *LPSTR;

#define TRUE  1
#define FALSE 0

/* Log library load for diagnostics */
__attribute__((constructor))
static void brcolor_init(void) {
    const char msg[] = "[BRCOLOR] Library loaded (ARM native stub)\n";
    write(STDERR_FILENO, msg, sizeof(msg) - 1);
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
    (void)d;
    return TRUE;
}

void ColorMatchingEnd(void) {}

BOOL ColorMatching(BYTE *d, long len, long cnt)
{
    (void)d;
    (void)len;
    (void)cnt;
    return TRUE;
}
