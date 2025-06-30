#define _XOPEN_SOURCE 700

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

// ASCII art logo
static const char *logo =
    "\n"
    "    _   _  ___        __                              \n"
    "   | | | ||_ _|_ __  / _| ___ _ __ ___ _ __   ___ ___ \n"
    "   | |_| | | || '_ \\| |_ / _ \\ '__/ _ \\ '_ \\ / __/ _ \\\n"
    "   |  _  | | || | | |  _|  __/ | |  __/ | | | (_|  __/\n"
    "   |_| |_||___|_| |_|_|  \\___|_|  \\___|_| |_|\\___\\___|\n"
    "\n"
    "   Minimal Inference Server for Edge Deployment\n"
    "   LLaMA Model: stories15M (15M parameters)\n"
    "\n";

static const char *usage =
    "  === USAGE INSTRUCTIONS ===\n"
    "  * Run inference:     talk \"Your prompt here\"\n"
    "  * Short alias:       t \"Your prompt here\"\n"
    "  * View kernel log:   dmesg\n"
    "  * Exit QEMU:         Ctrl-A then X\n"
    "\n";

int main() {
    sigset_t set;
    int status;
    
    // Check if we're PID 1
    if (getpid() != 1) {
        fprintf(stderr, "ERROR: Not PID 1. This must be run as init.\n");
        return 1;
    }

    // Handle signals properly for init
    sigfillset(&set);
    sigprocmask(SIG_BLOCK, &set, 0);
    if (fork())
        for (;;)
            wait(&status);
    sigprocmask(SIG_UNBLOCK, &set, 0);
    setsid();
    setpgid(0, 0);

    // Print logo and usage
    printf("%s", logo);
    printf("%s", usage);

    // Setup shell with aliases
    char *argv[] = {
        "/bin/busybox", 
        "ash", 
        "-c", 
        "alias talk='/l2e /model.bin -n 256 -i'; alias t='talk'; exec ash",
        NULL
    };
    
    char *envp[] = {
        "HOME=/root/",
        "TERM=linux",
        "PATH=/:/bin",
        "TZ=UTC0",
        "USER=root",
        "LOGNAME=root",
        "PS1=\\033[1;32mμInference\\033[0m # ",
        NULL
    };

    // Setup userspace
    pid_t child = fork();
    if (child == 0) {
        char *setup[] = {"/bin/busybox", "--install", "-s", "/bin", NULL};
        execve(setup[0], setup, envp);
        _exit(1);
    }
    waitpid(child, NULL, 0);

    // Mount proc
    child = fork();
    if (child == 0) {
        char *mount[] = {"/bin/busybox", "mount", "-t", "proc", "proc", "/proc", NULL};
        execve(mount[0], mount, envp);
        _exit(1);
    }
    waitpid(child, NULL, 0);

    // Mount sys
    child = fork();
    if (child == 0) {
        char *mount[] = {"/bin/busybox", "mount", "-t", "sysfs", "sysfs", "/sys", NULL};
        execve(mount[0], mount, envp);
        _exit(1);
    }
    waitpid(child, NULL, 0);

    // Open console as controlling terminal
    int fd = open("/dev/console", O_RDWR);
    if (fd >= 0) {
        ioctl(fd, TIOCSCTTY, 1);
        dup2(fd, 0);
        dup2(fd, 1);
        dup2(fd, 2);
        if (fd > 2) close(fd);
    }

    // Hand off to shell
    execve(argv[0], argv, envp);
    
    // Should never reach here
    fprintf(stderr, "CRITICAL: Init handoff failed!\n");
    return 1;
}