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
