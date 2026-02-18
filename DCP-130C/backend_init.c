/*
 * Backend initialization stub — linked into libsane-brother2.so
 *
 * Installs a SIGSEGV handler so crashes in the SANE backend produce
 * a visible error on stderr before the process dies (the default
 * behavior is a silent crash).
 *
 * Debug diagnostics: set BROTHER_DEBUG=1 to log backend load on stderr.
 * When enabled, also probes the USB environment to report:
 *   - USB bus speed (1.1 / 2.0 / 3.0)
 *   - Whether the usblp kernel module is bound to the scanner
 *   - Whether QEMU binfmt_misc handlers are registered (can cause
 *     USB contention on ARM when i386 helpers touch device nodes)
 */
#include <signal.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <dirent.h>

/* Brother USB vendor ID */
#define BROTHER_VID "04f9"

static void backend_segfault_handler(int sig) {
    const char msg[] = "\n[BROTHER2] FATAL: Segmentation fault in SANE brother2 backend!\n";
    write(STDERR_FILENO, msg, sizeof(msg) - 1);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(sig, &sa, NULL);
    raise(sig);
}

/*
 * Read a single-line sysfs attribute into buf (NUL-terminated, no newline).
 * Returns number of bytes read, or 0 on failure.
 */
static int read_sysfs(const char *path, char *buf, int bufsz) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    if (!fgets(buf, bufsz, f)) { fclose(f); buf[0] = '\0'; return 0; }
    fclose(f);
    int len = (int)strlen(buf);
    while (len > 0 && (buf[len-1] == '\n' || buf[len-1] == '\r'))
        buf[--len] = '\0';
    return len;
}

/*
 * Probe USB environment for Brother devices.
 * Reports bus speed, usblp binding status, and product info.
 */
static void probe_usb_environment(void) {
    DIR *d = opendir("/sys/bus/usb/devices");
    if (!d) {
        fprintf(stderr, "[BROTHER2] usb: cannot read /sys/bus/usb/devices\n");
        return;
    }

    int found = 0;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        /* Skip . and .. and interfaces (contain ':') */
        if (ent->d_name[0] == '.' || strchr(ent->d_name, ':'))
            continue;

        char path[512], val[128];

        snprintf(path, sizeof(path), "/sys/bus/usb/devices/%s/idVendor", ent->d_name);
        if (read_sysfs(path, val, sizeof(val)) == 0)
            continue;
        if (strcmp(val, BROTHER_VID) != 0)
            continue;

        found = 1;

        /* Read product ID */
        char pid[16] = "????";
        snprintf(path, sizeof(path), "/sys/bus/usb/devices/%s/idProduct", ent->d_name);
        read_sysfs(path, pid, sizeof(pid));

        /* Read product name */
        char product[128] = "";
        snprintf(path, sizeof(path), "/sys/bus/usb/devices/%s/product", ent->d_name);
        read_sysfs(path, product, sizeof(product));

        /* Read USB speed (link rate in Mbit/s) */
        char speed[16] = "?";
        snprintf(path, sizeof(path), "/sys/bus/usb/devices/%s/speed", ent->d_name);
        read_sysfs(path, speed, sizeof(speed));

        /* Read USB spec version from device descriptor (e.g. "2.00", "1.10") */
        char version[16] = "";
        snprintf(path, sizeof(path), "/sys/bus/usb/devices/%s/version", ent->d_name);
        read_sysfs(path, version, sizeof(version));
        /* Trim leading whitespace (sysfs pads with spaces) */
        const char *ver = version;
        while (*ver == ' ') ver++;

        const char *speed_label = "unknown";
        int speed_mbit = atoi(speed);
        int usb_ver_major = atoi(ver);  /* "2.00" → 2, "1.10" → 1 */

        if (speed_mbit == 12) {
            /*
             * 12 Mbit/s = Full-Speed. The DCP-130C is a "USB 2.0 Full-Speed"
             * device — it's USB 2.0 compliant but only supports Full-Speed
             * (same 12 Mbit/s as USB 1.1), NOT High-Speed (480 Mbit/s).
             * The sysfs 'version' tells us the USB spec the device claims.
             */
            if (usb_ver_major >= 2)
                speed_label = "USB 2.0 Full-Speed (12 Mbit/s)";
            else
                speed_label = "USB 1.1 Full-Speed (12 Mbit/s)";
        }
        else if (speed_mbit == 480)  speed_label = "USB 2.0 High-Speed (480 Mbit/s)";
        else if (speed_mbit == 5000) speed_label = "USB 3.0 SuperSpeed (5 Gbit/s)";
        else if (strcmp(speed, "1.5") == 0) { speed_mbit = 1; speed_label = "USB 1.0 Low-Speed (1.5 Mbit/s)"; }

        fprintf(stderr, "[BROTHER2] usb: found %s (04f9:%s) at %s, speed: %s\n",
                product[0] ? product : "Brother device", pid, ent->d_name, speed_label);
        if (ver[0])
            fprintf(stderr, "[BROTHER2] usb: device descriptor version: USB %s\n", ver);

        if (speed_mbit == 12) {
            fprintf(stderr, "[BROTHER2] usb: NOTE — Full-Speed (12 Mbit/s) limits throughput to ~70 KB/s.\n");
            if (usb_ver_major >= 2) {
                fprintf(stderr, "[BROTHER2] usb: The DCP-130C is \"USB 2.0 Full-Speed\" — it is USB 2.0 compliant\n"
                        "[BROTHER2] usb: but only supports Full-Speed (12 Mbit/s), NOT High-Speed (480 Mbit/s).\n"
                        "[BROTHER2] usb: This is BY DESIGN — the scanner hardware has no High-Speed capability.\n"
                        "[BROTHER2] usb: ~70 KB/s is the expected maximum throughput for this device.\n");
            }
        }

        /* Check if usblp is bound to any interface */
        DIR *d2 = opendir("/sys/bus/usb/devices");
        if (d2) {
            struct dirent *ent2;
            while ((ent2 = readdir(d2)) != NULL) {
                /* Look for interfaces of this device: name starts with device name + ':' */
                if (strncmp(ent2->d_name, ent->d_name, strlen(ent->d_name)) != 0
                    || ent2->d_name[strlen(ent->d_name)] != ':')
                    continue;

                char driver_link[512], driver_target[256];
                snprintf(driver_link, sizeof(driver_link),
                         "/sys/bus/usb/devices/%s/driver", ent2->d_name);
                int dlen = (int)readlink(driver_link, driver_target, sizeof(driver_target) - 1);
                if (dlen > 0) {
                    driver_target[dlen] = '\0';
                    /* basename of the link target is the driver name */
                    const char *drv = strrchr(driver_target, '/');
                    drv = drv ? drv + 1 : driver_target;
                    if (strcmp(drv, "usblp") == 0) {
                        fprintf(stderr, "[BROTHER2] usb: WARNING — usblp driver is bound to %s. "
                                "This can block SANE USB access. Run: "
                                "echo '%s' | sudo tee /sys/bus/usb/drivers/usblp/unbind\n",
                                ent2->d_name, ent2->d_name);
                    }
                }
            }
            closedir(d2);
        }
    }
    closedir(d);

    if (!found)
        fprintf(stderr, "[BROTHER2] usb: no Brother device (vendor %s) found on USB bus\n",
                BROTHER_VID);

    /* Check for QEMU binfmt_misc registration */
    DIR *binfmt = opendir("/proc/sys/fs/binfmt_misc");
    if (binfmt) {
        struct dirent *bf;
        int qemu_found = 0;
        while ((bf = readdir(binfmt)) != NULL) {
            if (strncmp(bf->d_name, "qemu-", 5) == 0) {
                if (!qemu_found) {
                    fprintf(stderr, "[BROTHER2] qemu: binfmt_misc QEMU handlers detected\n");
                    qemu_found = 1;
                }
            }
        }
        if (qemu_found) {
            fprintf(stderr, "[BROTHER2] qemu: i386 binaries (e.g. brsaneconfig2) run via QEMU. "
                    "This is normal for configuration but should NOT affect scan speed.\n"
                    "[BROTHER2] qemu: if QEMU processes access the USB device during scanning, "
                    "contention may slow I/O. Check with: ps aux | grep qemu\n");
        }
        closedir(binfmt);
    }
}

__attribute__((constructor))
static void backend_init(void) {
    struct sigaction sa;
    sa.sa_handler = backend_segfault_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, NULL);

    const char *env = getenv("BROTHER_DEBUG");
    if (env && env[0] == '1') {
        fprintf(stderr, "[BROTHER2] SANE brother2 backend loaded "
                "(BROTHER_DEBUG=1, diagnostics enabled)\n");
        probe_usb_environment();
    }
}
