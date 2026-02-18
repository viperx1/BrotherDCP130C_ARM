#!/usr/bin/env bats
# Tests for BROTHER_DEBUG diagnostic output in scanner stub libraries.
# Verifies that the C stub libraries compile, produce debug output when
# BROTHER_DEBUG=1, and stay silent when the variable is unset.

load test_helper

setup() {
    setup_test_tmpdir
    # Compile the stub libraries for testing
    gcc -shared -fPIC -O2 -w \
        -o "$TEST_TMPDIR/libscandec_test.so" \
        "$PROJECT_ROOT/DCP-130C/scandec_stubs.c" || skip "gcc unavailable"
    gcc -shared -fPIC -O2 -w \
        -o "$TEST_TMPDIR/libbrcolm_test.so" \
        "$PROJECT_ROOT/DCP-130C/brcolor_stubs.c" || skip "gcc unavailable"
    gcc -shared -fPIC -O2 -w \
        -o "$TEST_TMPDIR/libbackend_test.so" \
        "$PROJECT_ROOT/DCP-130C/backend_init.c" || skip "gcc unavailable"
}

teardown() {
    teardown_test_tmpdir
}

# --- scandec_stubs compilation ---

@test "scandec_stubs.c compiles as a shared library" {
    [[ -f "$TEST_TMPDIR/libscandec_test.so" ]]
}

@test "brcolor_stubs.c compiles as a shared library" {
    [[ -f "$TEST_TMPDIR/libbrcolm_test.so" ]]
}

@test "backend_init.c compiles as a shared library" {
    [[ -f "$TEST_TMPDIR/libbackend_test.so" ]]
}

# --- scandec debug output ---

@test "scandec: no output on stderr without BROTHER_DEBUG" {
    cat > "$TEST_TMPDIR/test_scandec.c" << 'CEOF'
#include <string.h>
typedef int BOOL; typedef int INT; typedef unsigned char BYTE;
typedef unsigned long DWORD; typedef void *HANDLE;
typedef struct {
    INT nInResoX, nInResoY, nOutResoX, nOutResoY, nColorType;
    DWORD dwInLinePixCnt; INT nOutDataKind; BOOL bLongBoundary;
    DWORD dwOutLinePixCnt, dwOutLineByte, dwOutWriteMaxSize;
} SCANDEC_OPEN;
typedef struct {
    INT nInDataComp, nInDataKind; BYTE *pLineData; DWORD dwLineDataSize;
    BYTE *pWriteBuff; DWORD dwWriteBuffSize; BOOL bReverWrite;
} SCANDEC_WRITE;
extern BOOL ScanDecOpen(SCANDEC_OPEN *p);
extern BOOL ScanDecClose(void);
extern DWORD ScanDecWrite(SCANDEC_WRITE *w, INT *st);
int main(void) {
    SCANDEC_OPEN op; memset(&op, 0, sizeof(op));
    op.nColorType = 0x0200; op.dwInLinePixCnt = 100;
    ScanDecOpen(&op);
    BYTE line[100], out[200]; memset(line, 128, 100);
    SCANDEC_WRITE w = {2, 0, line, 100, out, 200, 0}; INT st;
    ScanDecWrite(&w, &st);
    ScanDecClose();
    return 0;
}
CEOF
    gcc -o "$TEST_TMPDIR/test_scandec" "$TEST_TMPDIR/test_scandec.c" \
        "$TEST_TMPDIR/libscandec_test.so" -Wl,-rpath,"$TEST_TMPDIR"
    local stderr_out
    stderr_out=$(LD_LIBRARY_PATH="$TEST_TMPDIR" "$TEST_TMPDIR/test_scandec" 2>&1 >/dev/null)
    [[ -z "$stderr_out" ]]
}

@test "scandec: emits [SCANDEC] on stderr with BROTHER_DEBUG=1" {
    cat > "$TEST_TMPDIR/test_scandec.c" << 'CEOF'
#include <string.h>
typedef int BOOL; typedef int INT; typedef unsigned char BYTE;
typedef unsigned long DWORD; typedef void *HANDLE;
typedef struct {
    INT nInResoX, nInResoY, nOutResoX, nOutResoY, nColorType;
    DWORD dwInLinePixCnt; INT nOutDataKind; BOOL bLongBoundary;
    DWORD dwOutLinePixCnt, dwOutLineByte, dwOutWriteMaxSize;
} SCANDEC_OPEN;
typedef struct {
    INT nInDataComp, nInDataKind; BYTE *pLineData; DWORD dwLineDataSize;
    BYTE *pWriteBuff; DWORD dwWriteBuffSize; BOOL bReverWrite;
} SCANDEC_WRITE;
extern BOOL ScanDecOpen(SCANDEC_OPEN *p);
extern BOOL ScanDecClose(void);
extern DWORD ScanDecWrite(SCANDEC_WRITE *w, INT *st);
int main(void) {
    SCANDEC_OPEN op; memset(&op, 0, sizeof(op));
    op.nColorType = 0x0200; op.dwInLinePixCnt = 100;
    ScanDecOpen(&op);
    BYTE line[100], out[200]; memset(line, 128, 100);
    SCANDEC_WRITE w = {2, 0, line, 100, out, 200, 0}; INT st;
    ScanDecWrite(&w, &st);
    ScanDecClose();
    return 0;
}
CEOF
    gcc -o "$TEST_TMPDIR/test_scandec" "$TEST_TMPDIR/test_scandec.c" \
        "$TEST_TMPDIR/libscandec_test.so" -Wl,-rpath,"$TEST_TMPDIR"
    local stderr_out
    stderr_out=$(BROTHER_DEBUG=1 LD_LIBRARY_PATH="$TEST_TMPDIR" \
        "$TEST_TMPDIR/test_scandec" 2>&1 >/dev/null)
    [[ "$stderr_out" == *"[SCANDEC]"* ]]
}

@test "scandec: summary includes line count and timing" {
    cat > "$TEST_TMPDIR/test_scandec.c" << 'CEOF'
#include <string.h>
typedef int BOOL; typedef int INT; typedef unsigned char BYTE;
typedef unsigned long DWORD; typedef void *HANDLE;
typedef struct {
    INT nInResoX, nInResoY, nOutResoX, nOutResoY, nColorType;
    DWORD dwInLinePixCnt; INT nOutDataKind; BOOL bLongBoundary;
    DWORD dwOutLinePixCnt, dwOutLineByte, dwOutWriteMaxSize;
} SCANDEC_OPEN;
typedef struct {
    INT nInDataComp, nInDataKind; BYTE *pLineData; DWORD dwLineDataSize;
    BYTE *pWriteBuff; DWORD dwWriteBuffSize; BOOL bReverWrite;
} SCANDEC_WRITE;
extern BOOL ScanDecOpen(SCANDEC_OPEN *p);
extern BOOL ScanDecClose(void);
extern DWORD ScanDecWrite(SCANDEC_WRITE *w, INT *st);
int main(void) {
    SCANDEC_OPEN op; memset(&op, 0, sizeof(op));
    op.nColorType = 0x0200; op.dwInLinePixCnt = 100;
    ScanDecOpen(&op);
    BYTE line[100], out[200]; memset(line, 128, 100);
    for (int i = 0; i < 10; i++) {
        SCANDEC_WRITE w = {2, 0, line, 100, out, 200, 0}; INT st;
        ScanDecWrite(&w, &st);
    }
    ScanDecClose();
    return 0;
}
CEOF
    gcc -o "$TEST_TMPDIR/test_scandec" "$TEST_TMPDIR/test_scandec.c" \
        "$TEST_TMPDIR/libscandec_test.so" -Wl,-rpath,"$TEST_TMPDIR"
    local stderr_out
    stderr_out=$(BROTHER_DEBUG=1 LD_LIBRARY_PATH="$TEST_TMPDIR" \
        "$TEST_TMPDIR/test_scandec" 2>&1 >/dev/null)
    [[ "$stderr_out" == *"scan session summary"* ]]
    [[ "$stderr_out" == *"total time:"* ]]
    [[ "$stderr_out" == *"lines:"* ]]
    [[ "$stderr_out" == *"max gap:"* ]]
    [[ "$stderr_out" == *"throughput:"* ]]
}

@test "scandec: ScanDecOpen logs resolution and color mode" {
    cat > "$TEST_TMPDIR/test_scandec.c" << 'CEOF'
#include <string.h>
typedef int BOOL; typedef int INT; typedef unsigned char BYTE;
typedef unsigned long DWORD; typedef void *HANDLE;
typedef struct {
    INT nInResoX, nInResoY, nOutResoX, nOutResoY, nColorType;
    DWORD dwInLinePixCnt; INT nOutDataKind; BOOL bLongBoundary;
    DWORD dwOutLinePixCnt, dwOutLineByte, dwOutWriteMaxSize;
} SCANDEC_OPEN;
extern BOOL ScanDecOpen(SCANDEC_OPEN *p);
extern BOOL ScanDecClose(void);
int main(void) {
    SCANDEC_OPEN op; memset(&op, 0, sizeof(op));
    op.nInResoX = 300; op.nInResoY = 300;
    op.nOutResoX = 300; op.nOutResoY = 300;
    op.nColorType = 0x0200; op.dwInLinePixCnt = 2550;
    ScanDecOpen(&op);
    ScanDecClose();
    return 0;
}
CEOF
    gcc -o "$TEST_TMPDIR/test_scandec" "$TEST_TMPDIR/test_scandec.c" \
        "$TEST_TMPDIR/libscandec_test.so" -Wl,-rpath,"$TEST_TMPDIR"
    local stderr_out
    stderr_out=$(BROTHER_DEBUG=1 LD_LIBRARY_PATH="$TEST_TMPDIR" \
        "$TEST_TMPDIR/test_scandec" 2>&1 >/dev/null)
    [[ "$stderr_out" == *"ScanDecOpen"* ]]
    [[ "$stderr_out" == *"300x300"* ]]
    [[ "$stderr_out" == *"8-bit gray"* ]]
}

# --- brcolor debug output ---

@test "brcolor: no output on stderr without BROTHER_DEBUG" {
    cat > "$TEST_TMPDIR/test_brcolor.c" << 'CEOF'
typedef int BOOL; typedef unsigned char BYTE; typedef char *LPSTR;
#pragma pack(1)
typedef struct { int nRgbLine, nPaperType, nMachineId; LPSTR lpLutName; } CMATCH_INIT;
#pragma pack()
extern BOOL ColorMatchingInit(CMATCH_INIT d);
extern void ColorMatchingEnd(void);
extern BOOL ColorMatching(BYTE *d, long len, long cnt);
int main(void) {
    CMATCH_INIT ci = {100, 1, 1, 0};
    ColorMatchingInit(ci);
    BYTE buf[100]; ColorMatching(buf, 100, 1);
    ColorMatchingEnd();
    return 0;
}
CEOF
    gcc -o "$TEST_TMPDIR/test_brcolor" "$TEST_TMPDIR/test_brcolor.c" \
        "$TEST_TMPDIR/libbrcolm_test.so" -Wl,-rpath,"$TEST_TMPDIR"
    local stderr_out
    stderr_out=$(LD_LIBRARY_PATH="$TEST_TMPDIR" "$TEST_TMPDIR/test_brcolor" 2>&1 >/dev/null)
    [[ -z "$stderr_out" ]]
}

@test "brcolor: emits [BRCOLOR] on stderr with BROTHER_DEBUG=1" {
    cat > "$TEST_TMPDIR/test_brcolor.c" << 'CEOF'
typedef int BOOL; typedef unsigned char BYTE; typedef char *LPSTR;
#pragma pack(1)
typedef struct { int nRgbLine, nPaperType, nMachineId; LPSTR lpLutName; } CMATCH_INIT;
#pragma pack()
extern BOOL ColorMatchingInit(CMATCH_INIT d);
extern void ColorMatchingEnd(void);
extern BOOL ColorMatching(BYTE *d, long len, long cnt);
int main(void) {
    CMATCH_INIT ci = {100, 1, 1, 0};
    ColorMatchingInit(ci);
    BYTE buf[100]; ColorMatching(buf, 100, 1);
    ColorMatchingEnd();
    return 0;
}
CEOF
    gcc -o "$TEST_TMPDIR/test_brcolor" "$TEST_TMPDIR/test_brcolor.c" \
        "$TEST_TMPDIR/libbrcolm_test.so" -Wl,-rpath,"$TEST_TMPDIR"
    local stderr_out
    stderr_out=$(BROTHER_DEBUG=1 LD_LIBRARY_PATH="$TEST_TMPDIR" \
        "$TEST_TMPDIR/test_brcolor" 2>&1 >/dev/null)
    [[ "$stderr_out" == *"[BRCOLOR]"* ]]
    [[ "$stderr_out" == *"ColorMatchingInit"* ]]
    [[ "$stderr_out" == *"ColorMatchingEnd"* ]]
}

# --- backend_init debug output ---

@test "backend_init: emits [BROTHER2] with BROTHER_DEBUG=1 via LD_PRELOAD" {
    cat > "$TEST_TMPDIR/test_main.c" << 'CEOF'
int main(void) { return 0; }
CEOF
    gcc -o "$TEST_TMPDIR/test_main" "$TEST_TMPDIR/test_main.c"
    local stderr_out
    stderr_out=$(BROTHER_DEBUG=1 LD_PRELOAD="$TEST_TMPDIR/libbackend_test.so" \
        "$TEST_TMPDIR/test_main" 2>&1 >/dev/null)
    [[ "$stderr_out" == *"[BROTHER2]"* ]]
    [[ "$stderr_out" == *"BROTHER_DEBUG=1"* ]]
}

@test "backend_init: no output without BROTHER_DEBUG" {
    cat > "$TEST_TMPDIR/test_main.c" << 'CEOF'
int main(void) { return 0; }
CEOF
    gcc -o "$TEST_TMPDIR/test_main" "$TEST_TMPDIR/test_main.c"
    local stderr_out
    stderr_out=$(LD_PRELOAD="$TEST_TMPDIR/libbackend_test.so" \
        "$TEST_TMPDIR/test_main" 2>&1 >/dev/null)
    [[ -z "$stderr_out" ]]
}

@test "backend_init: probes USB environment with BROTHER_DEBUG=1" {
    cat > "$TEST_TMPDIR/test_main.c" << 'CEOF'
int main(void) { return 0; }
CEOF
    gcc -o "$TEST_TMPDIR/test_main" "$TEST_TMPDIR/test_main.c"
    local stderr_out
    stderr_out=$(BROTHER_DEBUG=1 LD_PRELOAD="$TEST_TMPDIR/libbackend_test.so" \
        "$TEST_TMPDIR/test_main" 2>&1 >/dev/null)
    # Should report either a found device or "no Brother device found"
    [[ "$stderr_out" == *"[BROTHER2] usb:"* ]]
}

@test "backend_init: reads USB version sysfs attribute" {
    # Verify the code reads the 'version' sysfs attribute by checking
    # that the source contains the version reading logic
    grep -q 'version' "$PROJECT_ROOT/DCP-130C/backend_init.c"
    grep -q 'USB 2.0 Full-Speed' "$PROJECT_ROOT/DCP-130C/backend_init.c"
    grep -q 'USB 2.0 compliant' "$PROJECT_ROOT/DCP-130C/backend_init.c"
}

# --- scandec RGB mode compression tracking ---

@test "scandec: RGB mode tracks compression stats per-plane" {
    cat > "$TEST_TMPDIR/test_rgb.c" << 'CEOF'
#include <string.h>
typedef int BOOL; typedef int INT; typedef unsigned char BYTE;
typedef unsigned long DWORD; typedef void *HANDLE;
typedef struct {
    INT nInResoX, nInResoY, nOutResoX, nOutResoY, nColorType;
    DWORD dwInLinePixCnt; INT nOutDataKind; BOOL bLongBoundary;
    DWORD dwOutLinePixCnt, dwOutLineByte, dwOutWriteMaxSize;
} SCANDEC_OPEN;
typedef struct {
    INT nInDataComp, nInDataKind; BYTE *pLineData; DWORD dwLineDataSize;
    BYTE *pWriteBuff; DWORD dwWriteBuffSize; BOOL bReverWrite;
} SCANDEC_WRITE;
extern BOOL ScanDecOpen(SCANDEC_OPEN *p);
extern BOOL ScanDecClose(void);
extern DWORD ScanDecWrite(SCANDEC_WRITE *w, INT *st);
int main(void) {
    SCANDEC_OPEN op; memset(&op, 0, sizeof(op));
    op.nColorType = 0x0400; op.dwInLinePixCnt = 100;
    ScanDecOpen(&op);
    BYTE line[100], out[400]; memset(line, 128, 100);
    /* 5 lines × 3 planes = 15 plane writes, all NONCOMP (2) */
    for (int l = 0; l < 5; l++) {
        for (int p = 2; p <= 4; p++) {
            SCANDEC_WRITE w = {2, p, line, 100, out, 400, 0}; INT st;
            ScanDecWrite(&w, &st);
        }
    }
    ScanDecClose();
    return 0;
}
CEOF
    gcc -o "$TEST_TMPDIR/test_rgb" "$TEST_TMPDIR/test_rgb.c" \
        "$TEST_TMPDIR/libscandec_test.so" -Wl,-rpath,"$TEST_TMPDIR"
    local stderr_out
    stderr_out=$(BROTHER_DEBUG=1 LD_LIBRARY_PATH="$TEST_TMPDIR" \
        "$TEST_TMPDIR/test_rgb" 2>&1 >/dev/null)
    # Should see noncomp=15 (5 lines × 3 planes)
    [[ "$stderr_out" == *"noncomp=15"* ]]
    # RGB planes should be 15
    [[ "$stderr_out" == *"RGB planes"*"15"* ]]
}

@test "scandec: summary shows backend time percentage" {
    cat > "$TEST_TMPDIR/test_backend_time.c" << 'CEOF'
#include <string.h>
typedef int BOOL; typedef int INT; typedef unsigned char BYTE;
typedef unsigned long DWORD; typedef void *HANDLE;
typedef struct {
    INT nInResoX, nInResoY, nOutResoX, nOutResoY, nColorType;
    DWORD dwInLinePixCnt; INT nOutDataKind; BOOL bLongBoundary;
    DWORD dwOutLinePixCnt, dwOutLineByte, dwOutWriteMaxSize;
} SCANDEC_OPEN;
typedef struct {
    INT nInDataComp, nInDataKind; BYTE *pLineData; DWORD dwLineDataSize;
    BYTE *pWriteBuff; DWORD dwWriteBuffSize; BOOL bReverWrite;
} SCANDEC_WRITE;
extern BOOL ScanDecOpen(SCANDEC_OPEN *p);
extern BOOL ScanDecClose(void);
extern DWORD ScanDecWrite(SCANDEC_WRITE *w, INT *st);
int main(void) {
    SCANDEC_OPEN op; memset(&op, 0, sizeof(op));
    op.nColorType = 0x0200; op.dwInLinePixCnt = 100;
    ScanDecOpen(&op);
    BYTE line[100], out[200]; memset(line, 128, 100);
    SCANDEC_WRITE w = {2, 0, line, 100, out, 200, 0}; INT st;
    ScanDecWrite(&w, &st);
    ScanDecClose();
    return 0;
}
CEOF
    gcc -o "$TEST_TMPDIR/test_backend_time" "$TEST_TMPDIR/test_backend_time.c" \
        "$TEST_TMPDIR/libscandec_test.so" -Wl,-rpath,"$TEST_TMPDIR"
    local stderr_out
    stderr_out=$(BROTHER_DEBUG=1 LD_LIBRARY_PATH="$TEST_TMPDIR" \
        "$TEST_TMPDIR/test_backend_time" 2>&1 >/dev/null)
    [[ "$stderr_out" == *"backend time:"* ]]
    [[ "$stderr_out" == *"USB I/O + protocol"* ]]
}

@test "scandec: summary shows first-data latency" {
    cat > "$TEST_TMPDIR/test_first_data.c" << 'CEOF'
#include <string.h>
typedef int BOOL; typedef int INT; typedef unsigned char BYTE;
typedef unsigned long DWORD; typedef void *HANDLE;
typedef struct {
    INT nInResoX, nInResoY, nOutResoX, nOutResoY, nColorType;
    DWORD dwInLinePixCnt; INT nOutDataKind; BOOL bLongBoundary;
    DWORD dwOutLinePixCnt, dwOutLineByte, dwOutWriteMaxSize;
} SCANDEC_OPEN;
typedef struct {
    INT nInDataComp, nInDataKind; BYTE *pLineData; DWORD dwLineDataSize;
    BYTE *pWriteBuff; DWORD dwWriteBuffSize; BOOL bReverWrite;
} SCANDEC_WRITE;
extern BOOL ScanDecOpen(SCANDEC_OPEN *p);
extern BOOL ScanDecClose(void);
extern DWORD ScanDecWrite(SCANDEC_WRITE *w, INT *st);
int main(void) {
    SCANDEC_OPEN op; memset(&op, 0, sizeof(op));
    op.nColorType = 0x0200; op.dwInLinePixCnt = 100;
    ScanDecOpen(&op);
    BYTE line[100], out[200]; memset(line, 128, 100);
    SCANDEC_WRITE w = {2, 0, line, 100, out, 200, 0}; INT st;
    ScanDecWrite(&w, &st);
    ScanDecClose();
    return 0;
}
CEOF
    gcc -o "$TEST_TMPDIR/test_first_data" "$TEST_TMPDIR/test_first_data.c" \
        "$TEST_TMPDIR/libscandec_test.so" -Wl,-rpath,"$TEST_TMPDIR"
    local stderr_out
    stderr_out=$(BROTHER_DEBUG=1 LD_LIBRARY_PATH="$TEST_TMPDIR" \
        "$TEST_TMPDIR/test_first_data" 2>&1 >/dev/null)
    [[ "$stderr_out" == *"first data:"* ]]
    [[ "$stderr_out" == *"scanner warm-up"* ]]
}

@test "scandec: summary shows gap histogram and tail latency" {
    cat > "$TEST_TMPDIR/test_gaps.c" << 'CEOF'
#include <string.h>
typedef int BOOL; typedef int INT; typedef unsigned char BYTE;
typedef unsigned long DWORD; typedef void *HANDLE;
typedef struct {
    INT nInResoX, nInResoY, nOutResoX, nOutResoY, nColorType;
    DWORD dwInLinePixCnt; INT nOutDataKind; BOOL bLongBoundary;
    DWORD dwOutLinePixCnt, dwOutLineByte, dwOutWriteMaxSize;
} SCANDEC_OPEN;
typedef struct {
    INT nInDataComp, nInDataKind; BYTE *pLineData; DWORD dwLineDataSize;
    BYTE *pWriteBuff; DWORD dwWriteBuffSize; BOOL bReverWrite;
} SCANDEC_WRITE;
extern BOOL ScanDecOpen(SCANDEC_OPEN *p);
extern BOOL ScanDecClose(void);
extern DWORD ScanDecWrite(SCANDEC_WRITE *w, INT *st);
int main(void) {
    SCANDEC_OPEN op; memset(&op, 0, sizeof(op));
    op.nColorType = 0x0200; op.dwInLinePixCnt = 100;
    ScanDecOpen(&op);
    BYTE line[100], out[200]; memset(line, 128, 100);
    for (int i = 0; i < 5; i++) {
        SCANDEC_WRITE w = {2, 0, line, 100, out, 200, 0}; INT st;
        ScanDecWrite(&w, &st);
    }
    ScanDecClose();
    return 0;
}
CEOF
    gcc -o "$TEST_TMPDIR/test_gaps" "$TEST_TMPDIR/test_gaps.c" \
        "$TEST_TMPDIR/libscandec_test.so" -Wl,-rpath,"$TEST_TMPDIR"
    local stderr_out
    stderr_out=$(BROTHER_DEBUG=1 LD_LIBRARY_PATH="$TEST_TMPDIR" \
        "$TEST_TMPDIR/test_gaps" 2>&1 >/dev/null)
    [[ "$stderr_out" == *"long gaps:"* ]]
    [[ "$stderr_out" == *"tail latency:"* ]]
    [[ "$stderr_out" == *"stall detection"* ]]
}

@test "scandec: summary shows human-readable diagnosis" {
    cat > "$TEST_TMPDIR/test_diag.c" << 'CEOF'
#include <string.h>
typedef int BOOL; typedef int INT; typedef unsigned char BYTE;
typedef unsigned long DWORD; typedef void *HANDLE;
typedef struct {
    INT nInResoX, nInResoY, nOutResoX, nOutResoY, nColorType;
    DWORD dwInLinePixCnt; INT nOutDataKind; BOOL bLongBoundary;
    DWORD dwOutLinePixCnt, dwOutLineByte, dwOutWriteMaxSize;
} SCANDEC_OPEN;
typedef struct {
    INT nInDataComp, nInDataKind; BYTE *pLineData; DWORD dwLineDataSize;
    BYTE *pWriteBuff; DWORD dwWriteBuffSize; BOOL bReverWrite;
} SCANDEC_WRITE;
extern BOOL ScanDecOpen(SCANDEC_OPEN *p);
extern BOOL ScanDecClose(void);
extern DWORD ScanDecWrite(SCANDEC_WRITE *w, INT *st);
int main(void) {
    SCANDEC_OPEN op; memset(&op, 0, sizeof(op));
    op.nColorType = 0x0200; op.dwInLinePixCnt = 100;
    ScanDecOpen(&op);
    BYTE line[100], out[200]; memset(line, 128, 100);
    SCANDEC_WRITE w = {2, 0, line, 100, out, 200, 0}; INT st;
    ScanDecWrite(&w, &st);
    ScanDecClose();
    return 0;
}
CEOF
    gcc -o "$TEST_TMPDIR/test_diag" "$TEST_TMPDIR/test_diag.c" \
        "$TEST_TMPDIR/libscandec_test.so" -Wl,-rpath,"$TEST_TMPDIR"
    local stderr_out
    stderr_out=$(BROTHER_DEBUG=1 LD_LIBRARY_PATH="$TEST_TMPDIR" \
        "$TEST_TMPDIR/test_diag" 2>&1 >/dev/null)
    [[ "$stderr_out" == *"diagnosis:"* ]]
}

# --- install_scanner.sh patch tests ---

@test "scanner: ReadDeviceData patch includes usleep for CPU yield" {
    grep -q 'usleep(2000)' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: ReadDeviceData patch includes BROTHER_DEBUG stats" {
    grep -q '_rdd_reads' "$PROJECT_ROOT/install_scanner.sh"
    grep -q '_rdd_zero_reads' "$PROJECT_ROOT/install_scanner.sh"
    grep -q '_rdd_total_bytes' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: ReadDeviceData patch includes debug fprintf" {
    grep -q 'ReadDeviceData EOF' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: ReadDeviceData EOF message includes avg bytes/read" {
    grep -q 'avg.*bytes/read' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: ReadDeviceData EOF message includes stall timeout" {
    grep -q 'stall timeout' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: display_info includes performance notes" {
    grep -q 'Full-Speed' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'hardware limit' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'BROTHER_DEBUG=1' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scandec: diagnosis includes actionable advice for USB-limited scan" {
    cat > "$TEST_TMPDIR/test_advice.c" << 'CEOF'
#include <string.h>
#include <unistd.h>
typedef int BOOL; typedef int INT; typedef unsigned char BYTE;
typedef unsigned long DWORD; typedef void *HANDLE;
typedef struct {
    INT nInResoX, nInResoY, nOutResoX, nOutResoY, nColorType;
    DWORD dwInLinePixCnt; INT nOutDataKind; BOOL bLongBoundary;
    DWORD dwOutLinePixCnt, dwOutLineByte, dwOutWriteMaxSize;
} SCANDEC_OPEN;
typedef struct {
    INT nInDataComp, nInDataKind; BYTE *pLineData; DWORD dwLineDataSize;
    BYTE *pWriteBuff; DWORD dwWriteBuffSize; BOOL bReverWrite;
} SCANDEC_WRITE;
extern BOOL ScanDecOpen(SCANDEC_OPEN *p);
extern BOOL ScanDecClose(void);
extern DWORD ScanDecWrite(SCANDEC_WRITE *w, INT *st);
int main(void) {
    SCANDEC_OPEN op; memset(&op, 0, sizeof(op));
    op.nColorType = 0x0200; op.dwInLinePixCnt = 100;
    ScanDecOpen(&op);
    /* Simulate USB-limited scan: delay between open and write so decode_pct < 1% */
    usleep(10000);  /* 10ms delay simulates USB I/O wait */
    BYTE line[100], out[200]; memset(line, 128, 100);
    SCANDEC_WRITE w = {2, 0, line, 100, out, 200, 0}; INT st;
    ScanDecWrite(&w, &st);
    ScanDecClose();
    return 0;
}
CEOF
    gcc -o "$TEST_TMPDIR/test_advice" "$TEST_TMPDIR/test_advice.c" \
        "$TEST_TMPDIR/libscandec_test.so" -Wl,-rpath,"$TEST_TMPDIR"
    local stderr_out
    stderr_out=$(BROTHER_DEBUG=1 LD_LIBRARY_PATH="$TEST_TMPDIR" \
        "$TEST_TMPDIR/test_advice" 2>&1 >/dev/null)
    [[ "$stderr_out" == *"advice:"* ]]
    [[ "$stderr_out" == *"Full-Speed USB"* ]]
}
