/*
 * Apple "s5l" UART (compatible = "apple,s5l-uart"), a Samsung S3C2410-style
 * register file with Apple's interrupt-status extensions.
 *
 * Register offsets: include/linux/serial_s3c.h (S3C2410_U*), m1n1 src/uart_regs.h.
 *   0x00 ULCON   0x04 UCON    0x08 UFCON   0x0c UMCON
 *   0x10 UTRSTAT 0x14 UERSTAT 0x18 UFSTAT  0x1c UMSTAT
 *   0x20 UTXH    0x24 URXH    0x28 UBRDIV
 * UTRSTAT: bit0 RXD, bit1 TX buffer empty (TXBE/TXFE), bit2 TX empty (TXE),
 *   Apple: bit3 RXTO_LEGACY, bit4 RXTHRESH, bit5 TXTHRESH, bit9 RXTO
 * UFSTAT: [3:0] RX count, [7:4] TX count, bit8 RX full, bit9 TX full
 * UCON (Apple): bit9 RXTO_ENA, bit11 RXTO_LEGACY_ENA, bit12 RXTHRESH_ENA, bit13 TXTHRESH_ENA
 *   (include/linux/serial_s3c.h APPLE_S5L_UCON_*, drivers/tty/serial/samsung_tty.c).
 *
 * Model: TX is instantaneous (FIFO always empty; bytes go straight to stdout).
 * RX is a 256-byte ring fed from a host stdin thread. The interrupt line
 * (AIC hwirq 605) is the OR of the enabled threshold conditions, computed as a
 * level; the "write 1 to clear" UTRSTAT bits are accepted and ignored because
 * the status is derived from FIFO state. A pending TXTHRESH with TXTHRESH_ENA
 * therefore fires continuously (as on hardware, where the FIFO is under its
 * trigger level), which is what samsung_tty.c expects (it disables the enable).
 */
#include "coolvm.h"

#include <termios.h>
#include <unistd.h>

#define ULCON 0x00
#define UCON 0x04
#define UFCON 0x08
#define UMCON 0x0c
#define UTRSTAT 0x10
#define UERSTAT 0x14
#define UFSTAT 0x18
#define UMSTAT 0x1c
#define UTXH 0x20
#define URXH 0x24
#define UBRDIV 0x28

#define UCON_RXTO_ENA (1u << 9)
#define UCON_RXTO_LEGACY_ENA (1u << 11)
#define UCON_RXTHRESH_ENA (1u << 12)
#define UCON_TXTHRESH_ENA (1u << 13)

static struct {
    uint32_t ulcon, ucon, ufcon, umcon, ubrdiv;
    uint8_t rx[256];
    int rxh, rxn;
    bool stdin_thread;
} u;

static pthread_t stdin_th;
static struct termios saved_tio;
static bool tio_saved;

static uint32_t utrstat_val(void)
{
    uint32_t v = (1u << 1) | (1u << 2); /* TX buffer empty, TX empty */
    if (u.rxn)
        v |= 1u;
    if ((u.ucon & UCON_RXTHRESH_ENA) && u.rxn)
        v |= 1u << 4;
    if ((u.ucon & UCON_RXTO_ENA) && u.rxn)
        v |= 1u << 9;
    if ((u.ucon & UCON_RXTO_LEGACY_ENA) && u.rxn)
        v |= 1u << 3;
    if (u.ucon & UCON_TXTHRESH_ENA)
        v |= 1u << 5;
    return v;
}

bool uart_irq_level(void)
{
    return (utrstat_val() & ((1u << 3) | (1u << 4) | (1u << 5) | (1u << 9))) != 0;
}

void uart_init(void)
{
    memset(&u, 0, sizeof(u));
}

const char *uart_regname(uint64_t off)
{
    switch (off) {
    case ULCON: return "ULCON";
    case UCON: return "UCON";
    case UFCON: return "UFCON";
    case UMCON: return "UMCON";
    case UTRSTAT: return "UTRSTAT";
    case UERSTAT: return "UERSTAT";
    case UFSTAT: return "UFSTAT";
    case UMSTAT: return "UMSTAT";
    case UTXH: return "UTXH";
    case URXH: return "URXH";
    case UBRDIV: return "UBRDIV";
    default: return "?";
    }
}

bool uart_mmio(cpu_t *c, uint64_t off, int size, bool wr, uint64_t *val)
{
    (void)c;
    if (size != 4 && !(size == 1 && (off == UTXH || off == URXH))) {
        LOGE("uart: unsupported %d-byte access at +0x%llx\n", size, (unsigned long long)off);
        return false;
    }
    if (wr) {
        uint32_t v = (uint32_t)*val;
        switch (off) {
        case ULCON: u.ulcon = v; break;
        case UCON: u.ucon = v; break;
        case UFCON:
            u.ufcon = v & ~((1u << 1) | (1u << 2)); /* reset bits self-clear */
            if (v & (1u << 1)) { u.rxh = u.rxn = 0; } /* RESETRX */
            break;
        case UMCON: u.umcon = v; break;
        case UTRSTAT: break; /* write-1-to-clear; status is derived */
        case UERSTAT: case UMSTAT: break;
        case UTXH: {
            uint8_t ch = (uint8_t)v;
            ssize_t r = write(1, &ch, 1);
            (void)r;
            break;
        }
        case UBRDIV: u.ubrdiv = v; break;
        default:
            LOGE("uart: write to unknown register +0x%llx = 0x%x\n", (unsigned long long)off, v);
            return false;
        }
        aic_update_locked();
        return true;
    }
    uint32_t r = 0;
    switch (off) {
    case ULCON: r = u.ulcon; break;
    case UCON: r = u.ucon; break;
    case UFCON: r = u.ufcon; break;
    case UMCON: r = u.umcon; break;
    case UTRSTAT: r = utrstat_val(); break;
    case UERSTAT: r = 0; break;
    case UFSTAT: r = (u.rxn > 15 ? 15u : (uint32_t)u.rxn) | (u.rxn >= 16 ? (1u << 8) : 0); break;
    case UMSTAT: r = 1; break; /* CTS asserted */
    case UTXH: r = 0; break;
    case URXH:
        if (u.rxn) {
            r = u.rx[u.rxh];
            u.rxh = (u.rxh + 1) & 255;
            u.rxn--;
            aic_update_locked();
        }
        break;
    case UBRDIV: r = u.ubrdiv; break;
    default:
        LOGE("uart: read from unknown register +0x%llx\n", (unsigned long long)off);
        return false;
    }
    *val = r;
    return true;
}

/* Host stdin -> RX FIFO. */
static void *stdin_main(void *arg)
{
    (void)arg;
    uint8_t ch;
    while (!g.stop) {
        ssize_t n = read(0, &ch, 1);
        if (n <= 0)
            break;
        pthread_mutex_lock(&g.lock);
        if (u.rxn < 256) {
            u.rx[(u.rxh + u.rxn) & 255] = ch;
            u.rxn++;
        }
        aic_update_locked();
        pthread_mutex_unlock(&g.lock);
    }
    return NULL;
}

static void restore_tty(void)
{
    if (tio_saved)
        tcsetattr(0, TCSANOW, &saved_tio);
}

void uart_start_stdin(void)
{
    if (isatty(0) && tcgetattr(0, &saved_tio) == 0) {
        struct termios t = saved_tio;
        t.c_lflag &= ~(ICANON | ECHO);
        t.c_cc[VMIN] = 1;
        t.c_cc[VTIME] = 0;
        tcsetattr(0, TCSANOW, &t);
        tio_saved = true;
        atexit(restore_tty);
    }
    if (pthread_create(&stdin_th, NULL, stdin_main, NULL) == 0) {
        pthread_detach(stdin_th);
        u.stdin_thread = true;
    }
}

void uart_stop_stdin(void)
{
    restore_tty();
    tio_saved = false;
}
