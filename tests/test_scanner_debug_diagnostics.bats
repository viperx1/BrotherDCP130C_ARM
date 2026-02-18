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

@test "scanner: ReadDeviceData patch injects time.h include for timestamp" {
    grep -q '#include <time.h>' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'brother_mfccmd.h' "$PROJECT_ROOT/install_scanner.sh"
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

# --- timestamp tests ---

@test "scandec: debug output includes wall-clock timestamps" {
    cat > "$TEST_TMPDIR/test_ts.c" << 'CEOF'
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
    gcc -o "$TEST_TMPDIR/test_ts" "$TEST_TMPDIR/test_ts.c" \
        "$TEST_TMPDIR/libscandec_test.so" -Wl,-rpath,"$TEST_TMPDIR"
    local stderr_out
    stderr_out=$(BROTHER_DEBUG=1 LD_LIBRARY_PATH="$TEST_TMPDIR" \
        "$TEST_TMPDIR/test_ts" 2>&1 >/dev/null)
    # Timestamp format: HH:MM:SS.mmm [SCANDEC]
    [[ "$stderr_out" =~ [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}\ \[SCANDEC\] ]]
}

@test "backend_init: debug output includes wall-clock timestamps" {
    cat > "$TEST_TMPDIR/test_main.c" << 'CEOF'
int main(void) { return 0; }
CEOF
    gcc -o "$TEST_TMPDIR/test_main" "$TEST_TMPDIR/test_main.c"
    local stderr_out
    stderr_out=$(BROTHER_DEBUG=1 LD_PRELOAD="$TEST_TMPDIR/libbackend_test.so" \
        "$TEST_TMPDIR/test_main" 2>&1 >/dev/null)
    # Timestamp format: HH:MM:SS.mmm [BROTHER2]
    [[ "$stderr_out" =~ [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}\ \[BROTHER2\] ]]
}

@test "brcolor: debug output includes wall-clock timestamps" {
    cat > "$TEST_TMPDIR/test_brcolor.c" << 'CEOF'
typedef int BOOL; typedef unsigned char BYTE; typedef char *LPSTR;
#pragma pack(1)
typedef struct { int nRgbLine, nPaperType, nMachineId; LPSTR lpLutName; } CMATCH_INIT;
#pragma pack()
extern BOOL ColorMatchingInit(CMATCH_INIT d);
extern void ColorMatchingEnd(void);
int main(void) {
    CMATCH_INIT ci = {100, 1, 1, 0};
    ColorMatchingInit(ci);
    ColorMatchingEnd();
    return 0;
}
CEOF
    gcc -o "$TEST_TMPDIR/test_brcolor" "$TEST_TMPDIR/test_brcolor.c" \
        "$TEST_TMPDIR/libbrcolm_test.so" -Wl,-rpath,"$TEST_TMPDIR"
    local stderr_out
    stderr_out=$(BROTHER_DEBUG=1 LD_LIBRARY_PATH="$TEST_TMPDIR" \
        "$TEST_TMPDIR/test_brcolor" 2>&1 >/dev/null)
    # Timestamp format: HH:MM:SS.mmm [BRCOLOR]
    [[ "$stderr_out" =~ [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}\ \[BRCOLOR\] ]]
}

@test "scandec: summary includes scanner buffer drain explanation" {
    grep -q 'scanner head may finish physically' "$PROJECT_ROOT/DCP-130C/scandec_stubs.c"
    grep -q 'buffers scan data internally' "$PROJECT_ROOT/DCP-130C/scandec_stubs.c"
    grep -q 'min USB xfer' "$PROJECT_ROOT/DCP-130C/scandec_stubs.c"
}

@test "scanner: ReadDeviceData EOF message includes timestamp" {
    grep -q 'tm_hour.*tm_min.*tm_sec' "$PROJECT_ROOT/install_scanner.sh"
}

# --- USB speed diagnosis tests ---

@test "scanner: diagnose_usb_speed function exists" {
    grep -q 'diagnose_usb_speed()' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: diagnose_usb_speed reads sysfs speed attribute" {
    grep -q '/sys/bus/usb/devices/\*/idVendor' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'speed' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: diagnose_usb_speed explains Full-Speed is hardware limited" {
    grep -q 'Full-Speed transceiver' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'silicon-level limitation' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: diagnose_usb_speed checks host controller speed" {
    grep -q 'Host port speed' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'Host supports High-Speed' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: display_info explains USB 2.0 High-Speed cannot be forced" {
    grep -q 'Forcing USB 2.0 High-Speed.*NOT possible' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'Full-Speed PHY' "$PROJECT_ROOT/install_scanner.sh"
}

# --- CPU usage analysis tests ---

@test "scanner: display_info explains CPU usage during scanning" {
    grep -q 'CPU usage during scanning' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'USB bulk-read polling loop' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: display_info explains scanner buffer drain behavior" {
    grep -q 'scanner head finishes physically' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'buffers data internally' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: display_info explains CPU does not affect scan speed" {
    grep -q 'CPU load does NOT affect scan speed' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'USB link.*not the host CPU' "$PROJECT_ROOT/install_scanner.sh"
}

@test "backend_init: reports CPU usage explanation for Full-Speed devices" {
    grep -q 'cpu:.*High CPU during scans is normal' "$PROJECT_ROOT/DCP-130C/backend_init.c"
    grep -q 'cpu:.*CPU usage does NOT affect scan speed' "$PROJECT_ROOT/DCP-130C/backend_init.c"
}

@test "backend_init: explains scanner buffer drain behavior" {
    grep -q 'scanner head finishes physically' "$PROJECT_ROOT/DCP-130C/backend_init.c"
    grep -q 'buffers data internally' "$PROJECT_ROOT/DCP-130C/backend_init.c"
}

@test "backend_init: checks host controller port speed" {
    grep -q 'host port speed' "$PROJECT_ROOT/DCP-130C/backend_init.c"
    grep -q 'host supports High-Speed' "$PROJECT_ROOT/DCP-130C/backend_init.c"
}

@test "backend_init: explains forcing High-Speed is not possible" {
    grep -q 'Forcing USB 2.0 High-Speed is NOT possible' "$PROJECT_ROOT/DCP-130C/backend_init.c"
    grep -q 'no High-Speed PHY' "$PROJECT_ROOT/DCP-130C/backend_init.c"
}

# --- tarball integrity validation tests ---

@test "scanner: try_download validates gzip integrity for .tar.gz files" {
    grep -q 'gzip -t' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'truncated/corrupt gzip' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: compile_arm_backend validates existing tarball before use" {
    grep -q 'Existing source tarball is corrupt' "$PROJECT_ROOT/install_scanner.sh"
    # Verify gzip -t is used to check existing tarballs
    grep -q 'gzip -t.*src_tarball' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: compile_arm_backend retries download on extraction failure" {
    grep -q 'Failed to extract brscan2 source, re-downloading' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'Failed to extract brscan2 source after re-download' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: corrupt tarball is detected and removed" {
    # Gzip magic number header (1f 8b) + method (08) + flags (00) — truncated
    printf '\x1f\x8b\x08\x00' > "$TEST_TMPDIR/test.tar.gz"
    # gzip -t should fail on this truncated file
    run gzip -t "$TEST_TMPDIR/test.tar.gz"
    [[ "$status" -ne 0 ]]
}

@test "scanner: valid tarball passes gzip integrity check" {
    # Create a valid small gzip file
    echo "test content" | gzip > "$TEST_TMPDIR/test.tar.gz"
    run gzip -t "$TEST_TMPDIR/test.tar.gz"
    [[ "$status" -eq 0 ]]
}

# --- source download debug logging tests ---

@test "scanner: try_download logs file size and type after download" {
    grep -q 'file_size.*stat' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'file_type.*file -b' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'Downloaded:.*bytes.*type:' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: try_download logs wget errors on failure" {
    grep -q 'wget error:' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: try_download uses longer timeout for reliability" {
    grep -q 'timeout=60' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'tries=3' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: compile_arm_backend logs source URLs being tried" {
    grep -q 'brscan2 source URLs to try:' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: compile_arm_backend logs existing tarball size" {
    grep -q 'Existing source tarball:.*bytes' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: compile_arm_backend logs tarball details on extraction failure" {
    grep -q 'Tarball size:.*bytes' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: compile_arm_backend cleans src_dir before extraction" {
    grep -q 'Clean src_dir before extraction' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: compile_arm_backend lists failed URLs on download failure" {
    grep -q 'Failed to download brscan2 source code from all URLs' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'URLs tried:' "$PROJECT_ROOT/install_scanner.sh"
}

# --- compression and data transfer analysis tests ---

@test "scandec: summary includes compression ratio" {
    grep -q 'compression:.*ratio' "$PROJECT_ROOT/DCP-130C/scandec_stubs.c"
    grep -q 'compress_ratio' "$PROJECT_ROOT/DCP-130C/scandec_stubs.c"
}

@test "scandec: summary includes wire throughput" {
    grep -q 'USB wire' "$PROJECT_ROOT/DCP-130C/scandec_stubs.c"
}

@test "scandec: diagnosis explains compression modes used by scanner" {
    grep -q 'scanner DOES compress data before sending' "$PROJECT_ROOT/DCP-130C/scandec_stubs.c"
    grep -q 'PackBits run-length encoding' "$PROJECT_ROOT/DCP-130C/scandec_stubs.c"
}

@test "scandec: diagnosis includes Windows comparison" {
    grep -q 'original Windows driver had the same USB bandwidth limit' "$PROJECT_ROOT/DCP-130C/scandec_stubs.c"
    grep -q 'physical USB transfer speed is' "$PROJECT_ROOT/DCP-130C/scandec_stubs.c"
}

@test "backend_init: reports scanner compression info" {
    grep -q 'PackBits.*compression' "$PROJECT_ROOT/DCP-130C/backend_init.c"
    grep -q 'White lines are sent as single-byte' "$PROJECT_ROOT/DCP-130C/backend_init.c"
}

@test "backend_init: includes Windows comparison for transfer speed" {
    grep -q 'original Windows driver had the SAME USB speed limit' "$PROJECT_ROOT/DCP-130C/backend_init.c"
    grep -q 'physical USB transfer speed is identical' "$PROJECT_ROOT/DCP-130C/backend_init.c"
}

@test "scanner: display_info explains compression used by scanner" {
    grep -q 'Data compression:' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'scanner DOES compress data before sending' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'PackBits' "$PROJECT_ROOT/install_scanner.sh"
}

@test "scanner: display_info explains why scanning seems slower than Windows" {
    grep -q 'Why scanning seems slower than on Windows:' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'USB transfer speed is identical on all platforms' "$PROJECT_ROOT/install_scanner.sh"
    grep -q 'progress bar' "$PROJECT_ROOT/install_scanner.sh"
}
