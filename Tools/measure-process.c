// macOS-only, read-only CPU/physical footprint sampler. No UI access.
#include <libproc.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
static double seconds(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: measure-process PID [seconds]\n"); return 2; }
    int pid = atoi(argv[1]), duration = argc > 2 ? atoi(argv[2]) : 10;
    struct rusage_info_v4 a = {0}, b = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&a)) { perror("proc_pid_rusage"); return 1; }
    double start = seconds(); sleep(duration); double elapsed = seconds() - start;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&b)) { perror("proc_pid_rusage"); return 1; }
    printf("{\"pid\":%d,\"elapsedSeconds\":%.3f,\"cpuPercent\":%.4f,\"cpuMilliseconds\":%.3f,\"physicalFootprintMiB\":%.3f,\"residentMiB\":%.3f,\"diskReadBytes\":%llu,\"diskWrittenBytes\":%llu,\"idleWakeups\":%llu}\n", pid, elapsed,
        (b.ri_user_time-a.ri_user_time+b.ri_system_time-a.ri_system_time)/1e9/elapsed*100,
        (b.ri_user_time-a.ri_user_time+b.ri_system_time-a.ri_system_time)/1e6,
        b.ri_phys_footprint/1048576., b.ri_resident_size/1048576.,
        b.ri_diskio_bytesread-a.ri_diskio_bytesread, b.ri_diskio_byteswritten-a.ri_diskio_byteswritten,
        b.ri_pkg_idle_wkups-a.ri_pkg_idle_wkups);
}
