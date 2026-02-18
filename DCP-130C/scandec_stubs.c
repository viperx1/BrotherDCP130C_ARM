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
#include <signal.h>
#include <unistd.h>

/* SIGSEGV handler: write crash info to stderr before dying */
static void scandec_segfault_handler(int sig) {
    const char msg[] = "\n[SCANDEC] FATAL: Segmentation fault (SIGSEGV) in scan backend!\n";
    write(STDERR_FILENO, msg, sizeof(msg) - 1);
    struct sigaction sa;
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(sig, &sa, NULL);
    raise(sig);
}

__attribute__((constructor))
static void scandec_init(void) {
    struct sigaction sa;
    sa.sa_handler = scandec_segfault_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, NULL);
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
static int g_bpp = 0;  /* bytes per pixel for the output format */

/* Color plane assembly for 24-bit RGB mode.
 * The scanner sends separate R, G, B planes (nInDataKind 2,3,4).
 * We buffer each plane and only emit interleaved RGB when all three
 * planes for a line have been received. */
static BYTE *g_red_plane = NULL;
static BYTE *g_green_plane = NULL;
static BYTE *g_blue_plane = NULL;
static DWORD g_plane_pixels = 0;
static int g_have_red = 0;
static int g_have_green = 0;

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
    if (!p) return FALSE;

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
        g_bpp = 0;
        p->dwOutLineByte = (p->dwOutLinePixCnt + 7) / 8;
    }

    if (p->bLongBoundary)
        p->dwOutLineByte = (p->dwOutLineByte + 3) & ~3UL;

    p->dwOutWriteMaxSize = p->dwOutLineByte * 16;

    memcpy(&g_open, p, sizeof(*p));

    /* Allocate plane buffers for 24-bit color mode */
    free(g_red_plane);   g_red_plane = NULL;
    free(g_green_plane); g_green_plane = NULL;
    free(g_blue_plane);  g_blue_plane = NULL;
    g_have_red = 0;
    g_have_green = 0;
    if (g_bpp == 3) {
        g_plane_pixels = p->dwInLinePixCnt;
        g_red_plane   = (BYTE *)calloc(g_plane_pixels, 1);
        g_green_plane = (BYTE *)calloc(g_plane_pixels, 1);
        g_blue_plane  = (BYTE *)calloc(g_plane_pixels, 1);
        if (!g_red_plane || !g_green_plane || !g_blue_plane) {
            free(g_red_plane);   g_red_plane = NULL;
            free(g_green_plane); g_green_plane = NULL;
            free(g_blue_plane);  g_blue_plane = NULL;
            return FALSE;
        }
    }

    return TRUE;
}

void ScanDecSetTblHandle(HANDLE h1, HANDLE h2)
{
    (void)h1;
    (void)h2;
}

BOOL ScanDecPageStart(void)
{
    return TRUE;
}

DWORD ScanDecWrite(SCANDEC_WRITE *w, INT *st)
{
    if (!w || !w->pLineData || !w->pWriteBuff) {
        if (st) *st = -1;
        return 0;
    }

    DWORD outLine = g_open.dwOutLineByte;
    if (outLine == 0 || outLine > w->dwWriteBuffSize) {
        if (st) *st = 0;
        return 0;
    }

    /*
     * 24-bit color mode: the scanner sends separate R, G, B planes
     * (nInDataKind 2=Red, 3=Green, 4=Blue). Buffer each plane and
     * only emit a pixel-interleaved RGB line when all three are received.
     */
    if (g_bpp == 3 && g_red_plane && g_green_plane && g_blue_plane
        && w->nInDataKind >= 2 && w->nInDataKind <= 4)
    {
        BYTE *planeBuf;
        switch (w->nInDataKind) {
        case 2:  planeBuf = g_red_plane;   g_have_red = 1;   break;
        case 3:  planeBuf = g_green_plane; g_have_green = 1;  break;
        default: planeBuf = g_blue_plane;                      break;
        }

        switch (w->nInDataComp) {
        case SCIDC_WHITE:
            memset(planeBuf, 0xFF, g_plane_pixels);
            break;
        case SCIDC_NONCOMP: {
            DWORD cpLen = w->dwLineDataSize;
            if (cpLen > g_plane_pixels) cpLen = g_plane_pixels;
            memcpy(planeBuf, w->pLineData, cpLen);
            if (cpLen < g_plane_pixels)
                memset(planeBuf + cpLen, 0, g_plane_pixels - cpLen);
            break;
        }
        case SCIDC_PACK:
            decode_packbits(w->pLineData, w->dwLineDataSize,
                            planeBuf, g_plane_pixels);
            break;
        default: {
            DWORD cpLen = w->dwLineDataSize;
            if (cpLen > g_plane_pixels) cpLen = g_plane_pixels;
            memcpy(planeBuf, w->pLineData, cpLen);
            break;
        }
        }

        /* If this is not the Blue plane, or we're missing a plane, buffer only */
        if (w->nInDataKind != 4 || !g_have_red || !g_have_green) {
            if (st) *st = 0;
            return 0;
        }

        /* All three planes received — interleave R,G,B into pixel RGB */
        DWORD safe_pixels = g_plane_pixels;
        if (safe_pixels > outLine / 3) safe_pixels = outLine / 3;
        memset(w->pWriteBuff, 0, outLine);
        for (DWORD i = 0; i < safe_pixels; i++) {
            w->pWriteBuff[i * 3 + 0] = g_red_plane[i];
            w->pWriteBuff[i * 3 + 1] = g_green_plane[i];
            w->pWriteBuff[i * 3 + 2] = g_blue_plane[i];
        }
        g_have_red = 0;
        g_have_green = 0;

        if (st) *st = 1;
        return outLine;
    }

    /*
     * Grayscale / B&W path
     */
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

    if (st) *st = 1;
    return outLine;
}

DWORD ScanDecPageEnd(SCANDEC_WRITE *w, INT *st)
{
    (void)w;
    if (st) *st = 0;
    return 0;
}

BOOL ScanDecClose(void)
{
    memset(&g_open, 0, sizeof(g_open));
    g_bpp = 0;
    free(g_red_plane);   g_red_plane = NULL;
    free(g_green_plane); g_green_plane = NULL;
    free(g_blue_plane);  g_blue_plane = NULL;
    g_plane_pixels = 0;
    g_have_red = 0;
    g_have_green = 0;
    return TRUE;
}
