/*
 * ARM stub for libbrscandec2 — scan data decode
 *
 * This replaces Brother's proprietary i386-only libbrscandec2.so with a
 * native ARM implementation. It handles the three compression modes used
 * by Brother scanners:
 *   SCIDC_WHITE   (1) — entire line is white
 *   SCIDC_NONCOMP (2) — uncompressed raster data
 *   SCIDC_PACK    (3) — PackBits (run-length) compressed data
 *
 * Output format must match what SANE expects (set by brother2.c
 * sane_get_parameters):
 *   SC_2BIT  modes (BW/ED): 1-bit packed, (pixels+7)/8 bytes/line
 *   SC_8BIT  modes (TG/256): 8-bit gray, pixels bytes/line
 *   SC_24BIT modes (FUL):    24-bit RGB, pixels*3 bytes/line
 *
 * Copyright: 2026, based on Brother brscan2-src-0.2.5-1 API
 */
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <signal.h>
#include <unistd.h>

/* SIGSEGV handler: write crash info to stderr before dying */
static void scandec_segfault_handler(int sig) {
    const char msg[] = "\n[SCANDEC] FATAL: Segmentation fault (SIGSEGV) in scan backend!\n"
                       "[SCANDEC] The crash occurred during scanning. Check BrMfc32.log for details.\n";
    /* Use write() not fprintf() — async-signal-safe */
    write(STDERR_FILENO, msg, sizeof(msg) - 1);
    /* Restore default handler and re-raise for core dump */
    struct sigaction sa;
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(sig, &sa, NULL);
    raise(sig);
}

/* Install signal handler on library load */
__attribute__((constructor))
static void scandec_init(void) {
    struct sigaction sa;
    sa.sa_handler = scandec_segfault_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, NULL);
    /* Use write() for signal-safe consistency */
    const char msg[] = "[SCANDEC] Library loaded (ARM native stub)\n";
    write(STDERR_FILENO, msg, sizeof(msg) - 1);
}

typedef int            BOOL;
typedef int            INT;
typedef unsigned char  BYTE;
typedef unsigned long  DWORD;
typedef void          *HANDLE;

#define TRUE  1
#define FALSE 0

/* Compression modes (from brother_scandec.h) */
#define SCIDC_WHITE   1
#define SCIDC_NONCOMP 2
#define SCIDC_PACK    3

/* Color type bit masks (from brother_deccom.h) */
#define SC_2BIT  (0x01 << 8)   /* 1-bit B&W output */
#define SC_8BIT  (0x02 << 8)   /* 8-bit grayscale output */
#define SC_24BIT (0x04 << 8)   /* 24-bit RGB output */

typedef struct {
    INT   nInResoX;
    INT   nInResoY;
    INT   nOutResoX;
    INT   nOutResoY;
    INT   nColorType;
    DWORD dwInLinePixCnt;
    INT   nOutDataKind;
    BOOL  bLongBoundary;
    /* Set by ScanDecOpen: */
    DWORD dwOutLinePixCnt;
    DWORD dwOutLineByte;
    DWORD dwOutWriteMaxSize;
} SCANDEC_OPEN;

typedef struct {
    INT   nInDataComp;
    INT   nInDataKind;
    BYTE *pLineData;
    DWORD dwLineDataSize;
    BYTE *pWriteBuff;
    DWORD dwWriteBuffSize;
    BOOL  bReverWrite;
} SCANDEC_WRITE;

static SCANDEC_OPEN g_open;
static int g_write_count = 0;
static int g_nonzero_lines = 0;
static int g_bpp = 0;  /* bytes per pixel for the output format */

/*
 * PackBits decompression (TIFF/Apple standard)
 * Returns number of bytes written to output.
 */
static DWORD decode_packbits(const BYTE *in, DWORD inLen,
                              BYTE *out, DWORD outMax)
{
    DWORD iP = 0, oP = 0;
    while (iP < inLen && oP < outMax) {
        signed char n = (signed char)in[iP++];
        if (n >= 0) {
            /* Copy next n+1 bytes literally */
            DWORD c = (DWORD)(n + 1);
            if (iP + c > inLen) c = inLen - iP;
            if (oP + c > outMax) c = outMax - oP;
            memcpy(out + oP, in + iP, c);
            iP += c;
            oP += c;
        } else if (n != -128) {
            /* Repeat next byte 1-n times */
            DWORD c = (DWORD)(1 - n);
            if (iP >= inLen) break;
            BYTE v = in[iP++];
            if (oP + c > outMax) c = outMax - oP;
            memset(out + oP, v, c);
            oP += c;
        }
        /* n == -128: no-op */
    }
    return oP;
}

/*
 * Convert 8-bit grayscale data to 1-bit packed (for B&W modes).
 * Threshold: pixel >= 128 → white (1), else black (0).
 * MSB first within each byte.
 */
static void gray8_to_1bit(const BYTE *gray, DWORD nPixels,
                           BYTE *packed, DWORD packedSize)
{
    memset(packed, 0, packedSize);
    for (DWORD i = 0; i < nPixels; i++) {
        if (gray[i] >= 128) {
            packed[i / 8] |= (0x80 >> (i % 8));
        }
    }
}

BOOL ScanDecOpen(SCANDEC_OPEN *p)
{
    if (!p) {
        fprintf(stderr, "[SCANDEC] ScanDecOpen: NULL pointer\n");
        return FALSE;
    }

    g_write_count = 0;
    g_nonzero_lines = 0;

    p->dwOutLinePixCnt = p->dwInLinePixCnt;

    /*
     * Determine output bytes per line based on color type.
     * Must match sane_get_parameters() in brother2.c:
     *   SC_2BIT  → depth=1, bytes_per_line = (pixels+7)/8
     *   SC_8BIT  → depth=8, bytes_per_line = pixels
     *   SC_24BIT → depth=8, bytes_per_line = pixels*3
     */
    if (p->nColorType & SC_24BIT) {
        g_bpp = 3;
        p->dwOutLineByte = p->dwOutLinePixCnt * 3;
    } else if (p->nColorType & SC_8BIT) {
        g_bpp = 1;
        p->dwOutLineByte = p->dwOutLinePixCnt;
    } else {
        /* SC_2BIT: B&W / Error Diffusion — 1-bit packed output */
        g_bpp = 0;  /* special: 1-bit packed */
        p->dwOutLineByte = (p->dwOutLinePixCnt + 7) / 8;
    }

    if (p->bLongBoundary)
        p->dwOutLineByte = (p->dwOutLineByte + 3) & ~3UL;

    /* Max output per ScanDecWrite call (multiple lines possible) */
    p->dwOutWriteMaxSize = p->dwOutLineByte * 16;

    memcpy(&g_open, p, sizeof(*p));

    fprintf(stderr, "[SCANDEC] ScanDecOpen: nColorType=0x%x pixels=%lu "
            "bpp=%d dwOutLineByte=%lu dwOutWriteMaxSize=%lu "
            "bLongBoundary=%d inReso=%dx%d outReso=%dx%d\n",
            p->nColorType, (unsigned long)p->dwInLinePixCnt, g_bpp,
            (unsigned long)p->dwOutLineByte,
            (unsigned long)p->dwOutWriteMaxSize,
            p->bLongBoundary,
            p->nInResoX, p->nInResoY, p->nOutResoX, p->nOutResoY);
    return TRUE;
}

void ScanDecSetTblHandle(HANDLE h1, HANDLE h2)
{
    (void)h1;
    (void)h2;
}

BOOL ScanDecPageStart(void)
{
    fprintf(stderr, "[SCANDEC] ScanDecPageStart\n");
    return TRUE;
}

DWORD ScanDecWrite(SCANDEC_WRITE *w, INT *st)
{
    if (!w || !w->pLineData || !w->pWriteBuff) {
        fprintf(stderr, "[SCANDEC] ScanDecWrite: NULL pointers "
                "w=%p pLineData=%p pWriteBuff=%p\n",
                (void*)w,
                w ? (void*)w->pLineData : NULL,
                w ? (void*)w->pWriteBuff : NULL);
        if (st) *st = -1;
        return 0;
    }

    DWORD outLine = g_open.dwOutLineByte;
    if (outLine == 0 || outLine > w->dwWriteBuffSize) {
        fprintf(stderr, "[SCANDEC] ScanDecWrite: bad outLine=%lu "
                "writeBuffSize=%lu\n",
                (unsigned long)outLine, (unsigned long)w->dwWriteBuffSize);
        if (st) *st = 0;
        return 0;
    }

    g_write_count++;

    /* Clear output buffer */
    memset(w->pWriteBuff, 0, outLine);

    /* Temporary buffer for decompressed 8-bit data (for B&W conversion) */
    BYTE *rawBuf = NULL;
    DWORD rawLen = 0;
    DWORD pixelsPerLine = g_open.dwOutLinePixCnt;

    switch (w->nInDataComp) {
    case SCIDC_WHITE:
        /* White line: fill output with white */
        if (g_bpp == 0) {
            /* 1-bit packed: white = all 1s = 0xFF */
            memset(w->pWriteBuff, 0xFF, outLine);
        } else {
            /* 8-bit gray or 24-bit RGB: white = 0xFF */
            memset(w->pWriteBuff, 0xFF, outLine);
        }
        rawLen = outLine;
        break;

    case SCIDC_NONCOMP:
        if (g_bpp == 0) {
            /* B&W: input is 8-bit gray, convert to 1-bit packed */
            gray8_to_1bit(w->pLineData, pixelsPerLine,
                         w->pWriteBuff, outLine);
        } else {
            /* Direct copy for grayscale/color */
            rawLen = w->dwLineDataSize;
            if (rawLen > outLine) rawLen = outLine;
            memcpy(w->pWriteBuff, w->pLineData, rawLen);
        }
        rawLen = outLine;
        break;

    case SCIDC_PACK:
        if (g_bpp == 0) {
            /* B&W: decompress to temp buffer, then convert to 1-bit */
            rawBuf = (BYTE *)malloc(pixelsPerLine);
            if (rawBuf) {
                DWORD decompressed = decode_packbits(w->pLineData,
                    w->dwLineDataSize, rawBuf, pixelsPerLine);
                (void)decompressed;
                gray8_to_1bit(rawBuf, pixelsPerLine,
                             w->pWriteBuff, outLine);
                free(rawBuf);
            }
        } else {
            /* Decompress directly to output */
            decode_packbits(w->pLineData, w->dwLineDataSize,
                          w->pWriteBuff, outLine);
        }
        rawLen = outLine;
        break;

    default:
        /* Unknown compression: try direct copy */
        rawLen = w->dwLineDataSize;
        if (rawLen > outLine) rawLen = outLine;
        memcpy(w->pWriteBuff, w->pLineData, rawLen);
        rawLen = outLine;
        break;
    }

    /* Check for non-zero data */
    int has_data = 0;
    for (DWORD i = 0; i < outLine && !has_data; i++)
        if (w->pWriteBuff[i] != 0) has_data = 1;
    if (has_data) g_nonzero_lines++;

    /* Log first 50 calls, then every 50th, for scan progress visibility */
    if (g_write_count <= 50 || g_write_count % 50 == 0)
        fprintf(stderr, "[SCANDEC] Write #%d: comp=%d kind=%d "
                "inLen=%lu outLine=%lu hasData=%d bpp=%d "
                "outBuf=%p writeBufSz=%lu\n",
                g_write_count, w->nInDataComp, w->nInDataKind,
                (unsigned long)w->dwLineDataSize,
                (unsigned long)outLine, has_data, g_bpp,
                (void*)w->pWriteBuff,
                (unsigned long)w->dwWriteBuffSize);

    if (st) *st = 1;
    return outLine;
}

DWORD ScanDecPageEnd(SCANDEC_WRITE *w, INT *st)
{
    fprintf(stderr, "[SCANDEC] ScanDecPageEnd: total_writes=%d "
            "nonzero_lines=%d\n", g_write_count, g_nonzero_lines);
    (void)w;
    if (st) *st = 0;
    return 0;
}

BOOL ScanDecClose(void)
{
    fprintf(stderr, "[SCANDEC] ScanDecClose: total_writes=%d "
            "nonzero_lines=%d\n", g_write_count, g_nonzero_lines);
    memset(&g_open, 0, sizeof(g_open));
    g_bpp = 0;
    return TRUE;
}
