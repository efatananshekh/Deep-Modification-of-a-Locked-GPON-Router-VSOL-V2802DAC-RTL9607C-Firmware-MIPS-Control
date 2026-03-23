// smartqos — Smart QoS Watchdog Daemon for VSOL V2802DAC
// Monitors and auto-repairs: HW QoS, iptables rules, DHCP MTU, DNS
// Cross-compiled for MIPS big-endian (Realtek RTL9607C, Linux 3.18.24)

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <sys/stat.h>

#define VERSION "1.0"
#define CHECK_INTERVAL 30
#define LOG_FILE "/tmp/smartqos.log"
#define DHCP_CONF "/var/udhcpd/udhcpd.conf"
#define EXPECTED_RULES 32

static FILE *logfd = NULL;
static volatile int running = 1;

static void sighandler(int sig) {
    (void)sig;
    running = 0;
}

static void logmsg(const char *fmt, ...) {
    char timebuf[16];
    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    snprintf(timebuf, sizeof(timebuf), "%02d:%02d:%02d", t->tm_hour, t->tm_min, t->tm_sec);

    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    printf("[%s] %s\n", timebuf, buf);
    if (logfd) {
        fprintf(logfd, "[%s] %s\n", timebuf, buf);
        fflush(logfd);
    }
}

// Read a /proc file, return trimmed content
static int readproc(const char *path, char *buf, int bufsz) {
    FILE *f = fopen(path, "r");
    if (!f) { buf[0] = 0; return -1; }
    int n = fread(buf, 1, bufsz - 1, f);
    fclose(f);
    if (n < 0) n = 0;
    buf[n] = 0;
    // trim trailing whitespace
    while (n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r' || buf[n-1] == ' '))
        buf[--n] = 0;
    return n;
}

static int writeproc(const char *path, const char *val) {
    FILE *f = fopen(path, "w");
    if (!f) return -1;
    fputs(val, f);
    fclose(f);
    return 0;
}

// Run a command and capture output
static int runcmd(const char *cmd, char *out, int outsz) {
    FILE *p = popen(cmd, "r");
    if (!p) { if (out) out[0] = 0; return -1; }
    int total = 0;
    if (out) {
        total = fread(out, 1, outsz - 1, p);
        if (total < 0) total = 0;
        out[total] = 0;
    }
    int ret = pclose(p);
    return ret;
}

// Count occurrences of substring
static int countstr(const char *hay, const char *needle) {
    int count = 0;
    const char *p = hay;
    int nlen = strlen(needle);
    while ((p = strstr(p, needle)) != NULL) {
        count++;
        p += nlen;
    }
    return count;
}

// Check and fix HW QoS settings, return number of fixes
static int check_hwqos(void) {
    int fixes = 0;
    char buf[512];

    // ACK priority should be 6
    readproc("/proc/rg/assign_ack_priority", buf, sizeof(buf));
    if (!strstr(buf, "6")) {
        writeproc("/proc/rg/assign_ack_priority", "6");
        logmsg("FIX: Reset TCP ACK priority to 6");
        fixes++;
    }

    // DHCP priority should be 1
    readproc("/proc/rg/assign_dhcp_priority", buf, sizeof(buf));
    if (!strstr(buf, "1")) {
        writeproc("/proc/rg/assign_dhcp_priority", "1");
        logmsg("FIX: Re-enabled DHCP priority");
        fixes++;
    }

    // IGMP priority should be 1
    readproc("/proc/rg/assign_igmp_priority", buf, sizeof(buf));
    if (!strstr(buf, "1")) {
        writeproc("/proc/rg/assign_igmp_priority", "1");
        logmsg("FIX: Re-enabled IGMP priority");
        fixes++;
    }

    // HWNAT should be disabled
    readproc("/proc/rg/hwnat", buf, sizeof(buf));
    if (!strstr(buf, "DISABLED") && buf[0] != '0') {
        writeproc("/proc/rg/hwnat", "0");
        logmsg("FIX: Disabled HWNAT");
        fixes++;
    }

    // IPv4 shortcut off
    readproc("/proc/rg/turn_off_ipv4_shortcut", buf, sizeof(buf));
    if (buf[0] != '1') {
        writeproc("/proc/rg/turn_off_ipv4_shortcut", "1");
        logmsg("FIX: Disabled IPv4 shortcut");
        fixes++;
    }

    // IPv6 shortcut off
    readproc("/proc/rg/turn_off_ipv6_shortcut", buf, sizeof(buf));
    if (buf[0] != '1') {
        writeproc("/proc/rg/turn_off_ipv6_shortcut", "1");
        logmsg("FIX: Disabled IPv6 shortcut");
        fixes++;
    }

    return fixes;
}

// The SMART_QOS iptables rules
static const char *qos_rules[] = {
    "-A SMART_QOS -p udp --dport 53 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -p tcp --dport 53 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -s 192.168.1.36 -p udp --dport 7000:8181 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -s 192.168.1.36 -p udp --dport 27016:27024 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -s 192.168.1.36 -p udp --dport 54000:54012 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -d 192.168.1.36 -p udp --sport 7000:8181 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -d 192.168.1.36 -p udp --sport 27016:27024 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -d 192.168.1.36 -p udp --sport 54000:54012 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -s 192.168.1.36 -p tcp --dport 2099 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -s 192.168.1.36 -p tcp --dport 5222:5223 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -s 192.168.1.36 -p tcp --dport 8088 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -s 192.168.1.36 -p tcp --dport 8393:8400 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -d 192.168.1.36 -p tcp --sport 2099 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -d 192.168.1.36 -p tcp --sport 5222:5223 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -d 192.168.1.36 -p tcp --sport 8088 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -d 192.168.1.36 -p tcp --sport 8393:8400 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -p udp --dport 19302:19309 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -p udp --sport 19302:19309 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -p udp --dport 3478 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -p udp --sport 3478 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -p tcp --dport 443 -m iprange --dst-range 142.250.0.0-142.251.255.255 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -p tcp --sport 443 -m iprange --src-range 142.250.0.0-142.251.255.255 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -p tcp --dport 443 -m iprange --dst-range 172.217.0.0-172.217.255.255 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -p tcp --sport 443 -m iprange --src-range 172.217.0.0-172.217.255.255 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -p tcp --dport 443 -m iprange --dst-range 216.239.32.0-216.239.63.255 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -p tcp --sport 443 -m iprange --src-range 216.239.32.0-216.239.63.255 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -p tcp --dport 22 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -p tcp --sport 22 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -p tcp --dport 2222 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -p tcp --sport 2222 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -p udp --dport 123 -j TOS --set-tos Minimize-Delay",
    "-A SMART_QOS -p udp --sport 123 -j TOS --set-tos Minimize-Delay",
    NULL
};

static void reapply_smartqos(void) {
    system("iptables -t mangle -N SMART_QOS 2>/dev/null");
    system("iptables -t mangle -F SMART_QOS 2>/dev/null");
    system("iptables -t mangle -D FORWARD -j SMART_QOS 2>/dev/null");
    system("iptables -t mangle -A FORWARD -j SMART_QOS 2>/dev/null");
    system("iptables -t mangle -D OUTPUT -j SMART_QOS 2>/dev/null");
    system("iptables -t mangle -A OUTPUT -j SMART_QOS 2>/dev/null");

    int count = 0;
    for (int i = 0; qos_rules[i]; i++) {
        char cmd[512];
        snprintf(cmd, sizeof(cmd), "iptables -t mangle %s 2>/dev/null", qos_rules[i]);
        system(cmd);
        count++;
    }
    logmsg("Re-applied %d SMART_QOS rules", count);
}

static int check_smartqos(void) {
    char buf[8192];
    runcmd("iptables -t mangle -L SMART_QOS -n 2>/dev/null", buf, sizeof(buf));

    if (!strstr(buf, "TOS")) {
        logmsg("WARN: SMART_QOS chain missing — re-applying");
        reapply_smartqos();
        return 1;
    }

    int count = countstr(buf, "TOS set");
    if (count < EXPECTED_RULES - 2) {
        logmsg("WARN: SMART_QOS has %d rules (expected %d) — re-applying", count, EXPECTED_RULES);
        reapply_smartqos();
        return 1;
    }
    return 0;
}

static int check_dhcp_mtu(void) {
    char buf[4096];
    FILE *f = fopen(DHCP_CONF, "r");
    if (!f) return 0;
    int n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    if (n < 0) n = 0;
    buf[n] = 0;

    if (!strstr(buf, "opt mtu")) {
        f = fopen(DHCP_CONF, "a");
        if (!f) return 0;
        fprintf(f, "\nopt mtu 1492\n");
        fclose(f);
        system("killall udhcpd 2>/dev/null; sleep 1; udhcpd " DHCP_CONF " &");
        logmsg("FIX: Re-injected DHCP MTU 1492");
        return 1;
    }
    return 0;
}

static int check_dns(void) {
    char buf[1024];
    runcmd("nslookup google.com 127.0.0.1 2>&1", buf, sizeof(buf));

    if (strstr(buf, "timed out") || !strstr(buf, "Address") || countstr(buf, "Address") < 2) {
        logmsg("WARN: DNS not resolving — restarting dnsmasq");
        system("killall dnsmasq 2>/dev/null; sleep 1; dnsmasq --conf-file=/tmp/dnsmasq.conf &");
        return 1;
    }
    return 0;
}

// Parse traffic stats from iptables counters
typedef struct {
    unsigned long dns, gaming, meet, ssh, total;
} qos_stats_t;

static void get_stats(qos_stats_t *st) {
    memset(st, 0, sizeof(*st));
    char buf[16384];
    runcmd("iptables -t mangle -L SMART_QOS -n -v 2>/dev/null", buf, sizeof(buf));

    char *line = strtok(buf, "\n");
    while (line) {
        unsigned long pkts = 0;
        sscanf(line, " %lu", &pkts);
        st->total += pkts;

        if (strstr(line, "dpt:53") || strstr(line, "spt:53"))
            st->dns += pkts;
        else if (strstr(line, "192.168.1.36") && (strstr(line, "7000:8181") || strstr(line, "27016") ||
                 strstr(line, "54000") || strstr(line, "2099") || strstr(line, "5222") ||
                 strstr(line, "8088") || strstr(line, "8393")))
            st->gaming += pkts;
        else if (strstr(line, "142.250") || strstr(line, "172.217") || strstr(line, "216.239") ||
                 strstr(line, "19302") || strstr(line, "3478"))
            st->meet += pkts;
        else if (strstr(line, "dpt:22") || strstr(line, "spt:22") || strstr(line, "2222"))
            st->ssh += pkts;

        line = strtok(NULL, "\n");
    }
}

static void print_status(void) {
    char buf[8192];

    puts("=========================================");
    puts("       Smart QoS Status Report");
    puts("=========================================");

    readproc("/proc/rg/assign_ack_priority", buf, sizeof(buf));
    char *last = strrchr(buf, ' ');
    printf("  HW ACK Priority: %s\n", last ? last + 1 : buf);

    readproc("/proc/rg/hwnat", buf, sizeof(buf));
    printf("  HWNAT: %s\n", strstr(buf, "DISABLED") ? "OFF" : "ON");

    readproc("/proc/rg/turn_off_ipv4_shortcut", buf, sizeof(buf));
    printf("  IPv4 Shortcut: %s", buf[0] == '1' ? "OFF" : "ON");
    readproc("/proc/rg/turn_off_ipv6_shortcut", buf, sizeof(buf));
    printf("  IPv6 Shortcut: %s\n", buf[0] == '1' ? "OFF" : "ON");

    qos_stats_t st;
    get_stats(&st);
    printf("  QoS Hits: DNS:%lu Gaming:%lu Meet:%lu SSH:%lu Total:%lu\n",
           st.dns, st.gaming, st.meet, st.ssh, st.total);

    readproc("/proc/rg/flow_statistic", buf, sizeof(buf));
    char *p = strstr(buf, "path");
    if (p) {
        char *nl = strchr(p, '\n');
        if (nl) *nl = 0;
        printf("  Flows: %s\n", p);
    }

    runcmd("iptables -t mangle -L SMART_QOS -n 2>/dev/null", buf, sizeof(buf));
    int rules = countstr(buf, "TOS set");
    printf("  SMART_QOS Rules: %d/%d\n", rules, EXPECTED_RULES);

    // DHCP MTU
    FILE *f = fopen(DHCP_CONF, "r");
    if (f) {
        char dhcp[4096];
        int n = fread(dhcp, 1, sizeof(dhcp)-1, f);
        fclose(f);
        dhcp[n > 0 ? n : 0] = 0;
        printf("  DHCP MTU: %s\n", strstr(dhcp, "opt mtu") ? "1492 (set)" : "NOT SET!");
    }

    puts("=========================================");
}

static void print_help(void) {
    puts("smartqos v" VERSION " — VSOL V2802DAC Smart QoS Daemon");
    puts("Usage:");
    puts("  smartqos          Start watchdog daemon");
    puts("  smartqos status   Show QoS status report");
    puts("  smartqos stats    Show traffic counters");
    puts("  smartqos check    Run single health check");
    puts("  smartqos version  Show version");
}

int main(int argc, char *argv[]) {
    if (argc > 1) {
        if (strcmp(argv[1], "status") == 0) {
            print_status();
            return 0;
        }
        if (strcmp(argv[1], "version") == 0) {
            printf("smartqos v%s — VSOL V2802DAC Smart QoS Daemon\n", VERSION);
            return 0;
        }
        if (strcmp(argv[1], "stats") == 0) {
            qos_stats_t st;
            get_stats(&st);
            printf("DNS:%lu Gaming:%lu Meet:%lu SSH:%lu Total:%lu\n",
                   st.dns, st.gaming, st.meet, st.ssh, st.total);
            return 0;
        }
        if (strcmp(argv[1], "check") == 0) {
            int fixes = check_hwqos() + check_smartqos() + check_dhcp_mtu() + check_dns();
            if (fixes > 0)
                printf("Applied %d fixes\n", fixes);
            else
                puts("All systems OK");
            return 0;
        }
        print_help();
        return 0;
    }

    // Daemon mode
    signal(SIGTERM, sighandler);
    signal(SIGINT, sighandler);

    logfd = fopen(LOG_FILE, "a");
    logmsg("smartqos v%s starting — interval %ds", VERSION, CHECK_INTERVAL);

    int fixes = check_hwqos() + check_smartqos() + check_dhcp_mtu() + check_dns();
    logmsg("Initial check: %d fixes applied", fixes);

    int checks = 1;
    int total_fixes = fixes;

    while (running) {
        sleep(CHECK_INTERVAL);
        if (!running) break;

        checks++;
        int f = check_hwqos() + check_smartqos() + check_dhcp_mtu();
        total_fixes += f;

        // DNS check every 5 minutes
        if (checks % 10 == 0)
            f += check_dns();

        if (f > 0)
            logmsg("Check #%d: %d fixes (total: %d)", checks, f, total_fixes);

        // Log stats every 10 minutes
        if (checks % 20 == 0) {
            qos_stats_t st;
            get_stats(&st);
            logmsg("Stats: DNS:%lu Gaming:%lu Meet:%lu SSH:%lu Total:%lu",
                   st.dns, st.gaming, st.meet, st.ssh, st.total);
        }
    }

    logmsg("Shutdown (%d checks, %d fixes)", checks, total_fixes);
    if (logfd) fclose(logfd);
    return 0;
}
