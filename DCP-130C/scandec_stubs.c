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
 * Debug diagnostics: set BROTHER_DEBUG=1 to enable timing and statistics
 * output on stderr.  Useful for diagnosing CPU usage and scanning pauses.
 *
 * Copyright: 2026, based on Brother brscan2-src-0.2.5-1 API
 */
#include <string.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <time.h>

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

/* Debug diagnostics — enabled by BROTHER_DEBUG=1 environment variable */
static int g_debug = 0;

static double timespec_ms(struct timespec *ts) {
    return ts->tv_sec * 1000.0 + ts->tv_nsec / 1e6;
}

static double elapsed_ms(struct timespec *start, struct timespec *end) {
    return timespec_ms(end) - timespec_ms(start);
}

/*
 * Format current wall-clock time as "HH:MM:SS.mmm" into a static buffer.
 * Returns pointer to the static buffer (not thread-safe, fine for debug).
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

/* Scan statistics for debug reporting */
static struct {
    unsigned long lines_total;
    unsigned long lines_white;
    unsigned long lines_noncomp;
    unsigned long lines_pack;
    unsigned long lines_unknown;
    unsigned long bytes_in;
    unsigned long bytes_out;
    unsigned long rgb_planes;
    double        decode_ms;     /* total time in decode_packbits */
    double        convert_ms;    /* total time in gray8_to_1bit */
    double        write_ms;      /* total time in ScanDecWrite */
    struct timespec open_time;   /* when ScanDecOpen was called */
    struct timespec last_write;  /* timestamp of last ScanDecWrite */
    struct timespec last_progress; /* timestamp of last progress report */
    double        max_gap_ms;    /* longest gap between writes */
    double        max_write_ms;  /* longest single ScanDecWrite call */
    double        first_data_ms; /* latency from Open to first Write (scanner warm-up) */
    int           got_first;     /* flag: have we received first Write yet? */
    unsigned long gaps_over_100; /* gaps > 100 ms */
    unsigned long gaps_over_1s;  /* gaps > 1 second */
    unsigned long gaps_over_5s;  /* gaps > 5 seconds */
} g_stats;

__attribute__((constructor))
static void scandec_init(void) {
    struct sigaction sa;
    sa.sa_handler = scandec_segfault_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, NULL);

    const char *env = getenv("BROTHER_DEBUG");
    if (env && env[0] == '1') {
        g_debug = 1;
        fprintf(stderr, "%s [SCANDEC] debug diagnostics enabled (BROTHER_DEBUG=1)\n", debug_ts());
    }
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

    /* Reset statistics */
    memset(&g_stats, 0, sizeof(g_stats));
    clock_gettime(CLOCK_MONOTONIC, &g_stats.open_time);
    g_stats.last_write = g_stats.open_time;
    g_stats.last_progress = g_stats.open_time;

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

    if (g_debug) {
        const char *mode = (g_bpp == 3) ? "24-bit RGB" :
                           (g_bpp == 1) ? "8-bit gray" : "1-bit B&W";
        fprintf(stderr, "%s [SCANDEC] ScanDecOpen: %lux%lu px, reso %dx%d→%dx%d, "
                "mode=%s, outLine=%lu bytes\n",
                debug_ts(),
                (unsigned long)p->dwInLinePixCnt,
                (unsigned long)p->dwOutLinePixCnt,
                p->nInResoX, p->nInResoY,
                p->nOutResoX, p->nOutResoY,
                mode, (unsigned long)p->dwOutLineByte);
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
    struct timespec t_start, t_end;
    if (g_debug)
        clock_gettime(CLOCK_MONOTONIC, &t_start);

    if (!w || !w->pLineData || !w->pWriteBuff) {
        if (st) *st = -1;
        return 0;
    }

    DWORD outLine = g_open.dwOutLineByte;
    if (outLine == 0 || outLine > w->dwWriteBuffSize) {
        if (st) *st = 0;
        return 0;
    }

    if (g_debug) {
        /* Track gap between consecutive writes (inter-call latency) */
        double gap = elapsed_ms(&g_stats.last_write, &t_start);
        if (gap > g_stats.max_gap_ms)
            g_stats.max_gap_ms = gap;
        /* Gap histogram: count long gaps for pattern analysis */
        if (gap > 5000.0) g_stats.gaps_over_5s++;
        else if (gap > 1000.0) g_stats.gaps_over_1s++;
        else if (gap > 100.0) g_stats.gaps_over_100++;
        /* First-data latency (scanner warm-up time) */
        if (!g_stats.got_first) {
            g_stats.first_data_ms = elapsed_ms(&g_stats.open_time, &t_start);
            g_stats.got_first = 1;
        }
        g_stats.last_write = t_start;
        g_stats.bytes_in += w->dwLineDataSize;
    }

    /*
     * 24-bit color mode: the scanner sends separate R, G, B planes
     * (nInDataKind 2=Red, 3=Green, 4=Blue). Buffer each plane and
     * only emit a pixel-interleaved RGB line when all three are received.
     */
    if (g_bpp == 3 && g_red_plane && g_green_plane && g_blue_plane
        && w->nInDataKind >= 2 && w->nInDataKind <= 4)
    {
        if (g_debug) g_stats.rgb_planes++;

        BYTE *planeBuf;
        switch (w->nInDataKind) {
        case 2:  planeBuf = g_red_plane;   g_have_red = 1;   break;
        case 3:  planeBuf = g_green_plane; g_have_green = 1;  break;
        default: planeBuf = g_blue_plane;                      break;
        }

        switch (w->nInDataComp) {
        case SCIDC_WHITE:
            if (g_debug) g_stats.lines_white++;
            memset(planeBuf, 0xFF, g_plane_pixels);
            break;
        case SCIDC_NONCOMP: {
            if (g_debug) g_stats.lines_noncomp++;
            DWORD cpLen = w->dwLineDataSize;
            if (cpLen > g_plane_pixels) cpLen = g_plane_pixels;
            memcpy(planeBuf, w->pLineData, cpLen);
            if (cpLen < g_plane_pixels)
                memset(planeBuf + cpLen, 0, g_plane_pixels - cpLen);
            break;
        }
        case SCIDC_PACK:
            if (g_debug) g_stats.lines_pack++;
            decode_packbits(w->pLineData, w->dwLineDataSize,
                            planeBuf, g_plane_pixels);
            break;
        default: {
            if (g_debug) g_stats.lines_unknown++;
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

        if (g_debug) {
            g_stats.lines_total++;
            g_stats.bytes_out += outLine;
            clock_gettime(CLOCK_MONOTONIC, &t_end);
            double call_ms = elapsed_ms(&t_start, &t_end);
            g_stats.write_ms += call_ms;
            if (call_ms > g_stats.max_write_ms)
                g_stats.max_write_ms = call_ms;
            if ((g_stats.lines_total % 100) == 0) {
                double total_ms = elapsed_ms(&g_stats.open_time, &t_end);
                double interval_ms = elapsed_ms(&g_stats.last_progress, &t_end);
                g_stats.last_progress = t_end;
                fprintf(stderr, "%s [SCANDEC] progress: %lu lines, %.1f ms elapsed, "
                        "last 100 in %.1f ms (%.1f ms/line), "
                        "%.2f ms/line decode avg, max gap %.1f ms\n",
                        debug_ts(),
                        g_stats.lines_total, total_ms,
                        interval_ms, interval_ms / 100.0,
                        g_stats.write_ms / g_stats.lines_total,
                        g_stats.max_gap_ms);
            }
        }

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
        if (g_debug) g_stats.lines_white++;
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
        if (g_debug) g_stats.lines_noncomp++;
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
        if (g_debug) g_stats.lines_pack++;
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
        if (g_debug) g_stats.lines_unknown++;
        /* Unknown compression: try direct copy */
        rawLen = w->dwLineDataSize;
        if (rawLen > outLine) rawLen = outLine;
        memcpy(w->pWriteBuff, w->pLineData, rawLen);
        rawLen = outLine;
        break;
    }

    if (g_debug) {
        g_stats.lines_total++;
        g_stats.bytes_out += outLine;
        clock_gettime(CLOCK_MONOTONIC, &t_end);
        double call_ms = elapsed_ms(&t_start, &t_end);
        g_stats.write_ms += call_ms;
        if (call_ms > g_stats.max_write_ms)
            g_stats.max_write_ms = call_ms;
        if ((g_stats.lines_total % 100) == 0) {
            double total_ms = elapsed_ms(&g_stats.open_time, &t_end);
            double interval_ms = elapsed_ms(&g_stats.last_progress, &t_end);
            g_stats.last_progress = t_end;
            fprintf(stderr, "%s [SCANDEC] progress: %lu lines, %.1f ms elapsed, "
                    "last 100 in %.1f ms (%.1f ms/line), "
                    "%.2f ms/line decode avg, max gap %.1f ms\n",
                    debug_ts(),
                    g_stats.lines_total, total_ms,
                    interval_ms, interval_ms / 100.0,
                    g_stats.write_ms / g_stats.lines_total,
                    g_stats.max_gap_ms);
        }
    }

    if (st) *st = 1;
    return outLine;
}

DWORD ScanDecPageEnd(SCANDEC_WRITE *w, INT *st)
{
    if (g_debug) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double total_ms = elapsed_ms(&g_stats.open_time, &now);
        fprintf(stderr, "%s [SCANDEC] ScanDecPageEnd: %lu lines in %.1f ms "
                "(%.1f lines/sec)\n",
                debug_ts(),
                g_stats.lines_total, total_ms,
                g_stats.lines_total ? g_stats.lines_total / (total_ms / 1000.0) : 0);
    }
    (void)w;
    if (st) *st = 0;
    return 0;
}

BOOL ScanDecClose(void)
{
    if (g_debug) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double total_ms = elapsed_ms(&g_stats.open_time, &now);
        double throughput = g_stats.bytes_out ?
            (g_stats.bytes_out / 1024.0) / (total_ms / 1000.0) : 0;
        double backend_ms = total_ms - g_stats.write_ms;
        double tail_ms = g_stats.got_first
            ? elapsed_ms(&g_stats.last_write, &now) : 0;
        double scan_ms = g_stats.got_first
            ? total_ms - g_stats.first_data_ms - tail_ms : 0;
        double scan_rate = (g_stats.lines_total && scan_ms > 0)
            ? scan_ms / g_stats.lines_total : 0;
        /* Estimate minimum transfer time based on data size and USB bandwidth */
        double min_xfer_sec = g_stats.bytes_out > 0
            ? g_stats.bytes_out / (70.0 * 1024.0) : 0;  /* ~70 KB/s Full-Speed */
        /* Compression ratio: bytes_in is what the scanner sent (compressed),
         * bytes_out is the decompressed raster output */
        double compress_ratio = (g_stats.bytes_in > 0 && g_stats.bytes_out > 0)
            ? (double)g_stats.bytes_out / g_stats.bytes_in : 1.0;
        /* Estimate transfer time using actual wire bytes, not output bytes */
        double min_xfer_wire_sec = g_stats.bytes_in > 0
            ? g_stats.bytes_in / (70.0 * 1024.0) : 0;
        fprintf(stderr,
                "%s [SCANDEC] === scan session summary ===\n"
                "[SCANDEC]   total time:    %.1f ms (%.1f sec)\n"
                "[SCANDEC]   lines:         %lu (white=%lu noncomp=%lu pack=%lu unknown=%lu)\n"
                "[SCANDEC]   RGB planes:    %lu\n"
                "[SCANDEC]   data in/out:   %lu / %lu bytes (%.1f MB)\n"
                "[SCANDEC]   compression:   %.1fx ratio (scanner sent %lu bytes for %lu bytes output)\n"
                "[SCANDEC]   decode time:   %.1f ms total (%.3f ms/line avg)\n"
                "[SCANDEC]   backend time:  %.1f ms (%.1f%% — USB I/O + protocol)\n"
                "[SCANDEC]   max write:     %.3f ms (single call)\n"
                "[SCANDEC]   max gap:       %.1f ms (between writes — I/O or backend wait)\n"
                "[SCANDEC]   long gaps:     %lu >100ms, %lu >1s, %lu >5s\n"
                "[SCANDEC]   first data:    %.1f ms after open (scanner warm-up)\n"
                "[SCANDEC]   tail latency:  %.1f ms after last data (stall detection)\n"
                "[SCANDEC]   scan rate:     %.1f ms/line (%.1f lines/sec during active scan)\n"
                "[SCANDEC]   throughput:    %.1f KB/s (output), %.1f KB/s (USB wire)\n"
                "[SCANDEC]   min USB xfer:  %.1f sec for %.1f MB at ~70 KB/s Full-Speed\n",
                debug_ts(),
                total_ms, total_ms / 1000.0,
                g_stats.lines_total,
                g_stats.lines_white, g_stats.lines_noncomp,
                g_stats.lines_pack, g_stats.lines_unknown,
                g_stats.rgb_planes,
                g_stats.bytes_in, g_stats.bytes_out,
                g_stats.bytes_out / (1024.0 * 1024.0),
                compress_ratio, g_stats.bytes_in, g_stats.bytes_out,
                g_stats.write_ms,
                g_stats.lines_total ? g_stats.write_ms / g_stats.lines_total : 0,
                backend_ms,
                total_ms > 0 ? (backend_ms / total_ms) * 100.0 : 0,
                g_stats.max_write_ms,
                g_stats.max_gap_ms,
                g_stats.gaps_over_100, g_stats.gaps_over_1s,
                g_stats.gaps_over_5s,
                g_stats.first_data_ms,
                tail_ms,
                scan_rate,
                scan_rate > 0 ? 1000.0 / scan_rate : 0,
                throughput,
                g_stats.bytes_in ? (g_stats.bytes_in / 1024.0) / (total_ms / 1000.0) : 0,
                min_xfer_sec,
                g_stats.bytes_out / (1024.0 * 1024.0));
        /* Human-readable diagnosis */
        double decode_pct = total_ms > 0
            ? (g_stats.write_ms / total_ms) * 100.0 : 0;
        /* Compression analysis */
        if (g_stats.lines_pack > 0 || g_stats.lines_white > 0) {
            unsigned long compressed_lines = g_stats.lines_pack + g_stats.lines_white;
            unsigned long total_lines = compressed_lines + g_stats.lines_noncomp + g_stats.lines_unknown;
            double pct_compressed = total_lines > 0
                ? (compressed_lines * 100.0) / total_lines : 0;
            fprintf(stderr,
                "[SCANDEC] compression: %.0f%% of lines used compression (PackBits=%lu, White=%lu, Raw=%lu)\n"
                "[SCANDEC]   The scanner DOES compress data before sending (PackBits run-length encoding).\n"
                "[SCANDEC]   Compression ratio: %.1fx — %.1f MB sent over USB for %.1f MB of pixel data.\n",
                pct_compressed,
                g_stats.lines_pack, g_stats.lines_white, g_stats.lines_noncomp,
                compress_ratio,
                g_stats.bytes_in / (1024.0 * 1024.0),
                g_stats.bytes_out / (1024.0 * 1024.0));
        } else if (g_stats.lines_noncomp > 0) {
            fprintf(stderr,
                "[SCANDEC] compression: scanner sent all lines uncompressed (no PackBits or White lines).\n"
                "[SCANDEC]   Compression ratio: %.1fx — no compression benefit for this scan.\n",
                compress_ratio);
        }
        if (decode_pct < 1.0 && g_stats.lines_total > 0) {
            fprintf(stderr,
                "[SCANDEC] diagnosis: scan is USB-bandwidth limited "
                "(decode < 1%% of time). %.1f KB/s is normal for Full-Speed USB.\n",
                throughput);
            fprintf(stderr,
                "[SCANDEC] advice: this is a hardware limit of the DCP-130C's Full-Speed USB interface.\n"
                "[SCANDEC]   - The scanner itself is the bottleneck, not the software.\n"
                "[SCANDEC]   - Lower resolutions (e.g. 150 DPI) scan faster than higher ones.\n"
                "[SCANDEC]   - Grayscale mode transfers 3x less data than 24-bit color.\n"
                "[SCANDEC]   - Ensure no other process contends for the USB device (check: lsof /dev/bus/usb/*).\n");
            if (min_xfer_sec > 0) {
                fprintf(stderr,
                    "[SCANDEC] note: the scanner head may finish physically before the USB transfer\n"
                    "[SCANDEC]   completes. The DCP-130C buffers scan data internally and continues\n"
                    "[SCANDEC]   transmitting over USB after the head returns home. %.1f MB of data\n"
                    "[SCANDEC]   requires at least %.0f seconds to transfer at Full-Speed USB.\n",
                    g_stats.bytes_out / (1024.0 * 1024.0), min_xfer_sec);
            }
            fprintf(stderr,
                "[SCANDEC] windows: the original Windows driver had the same USB bandwidth limit.\n"
                "[SCANDEC]   Windows may have appeared faster because its driver UI showed a progress\n"
                "[SCANDEC]   bar during transfer (making the wait feel shorter) or used a different\n"
                "[SCANDEC]   scan resolution/mode by default. The physical USB transfer speed is\n"
                "[SCANDEC]   identical — 12 Mbit/s Full-Speed is a hardware constant.\n");
        } else if (g_stats.lines_total > 0) {
            fprintf(stderr,
                "[SCANDEC] diagnosis: decode uses %.1f%% of scan time "
                "(%.3f ms/line). Check CPU load if scan is slow.\n",
                decode_pct,
                g_stats.write_ms / g_stats.lines_total);
        }
    }

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
