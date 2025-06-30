#define _XOPEN_SOURCE 700

#include <math.h>
#include <ctype.h>
#include <err.h>
#include <errno.h>
#include <locale.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysinfo.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <wchar.h>

// PRINT LOGO TEXT
static char *infotext =
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

/* START RAINBOWCOLORS*/
/* Contains Rainbow Color Codes from "lolcat" by jaseg
 * "lolcat" is Copyright (C) 2020 jaseg <github@jaseg.net>
 * and distributed under "DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
 * Version 2, December 2004"
 */
char *rainbowbuffer = "";
#define ARRAY_SIZE(foo) (sizeof(foo) / sizeof(foo[0]))
const unsigned char codes[] = {39,  38,  44,  43,  49,  48,  84,  83,  119, 118,
                               154, 148, 184, 178, 214, 208, 209, 203, 204, 198,
                               199, 163, 164, 128, 129, 93,  99,  63,  69,  33};

static void find_escape_sequences(wint_t c, int *state) {
  if (c == '\033') {
    *state = 1;
  } else if (*state == 1) {
    if (('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z'))
      *state = 2;
  } else {
    *state = 0;
  }
}

static wint_t color_hack(FILE *_ignored) {
  (void)_ignored;
  static size_t idx = 0;
  char c = rainbowbuffer[idx++];
  if (c)
    return c;
  idx = 0;
  return WEOF;
}

int rainbow(double hf, double vf, int fc, int fl, int rd, int tc, int cs,
            double co, char *message) {
  rainbowbuffer = message;
  int cc = -1, i, l = 0;
  wint_t c;
  int colors = isatty(STDOUT_FILENO);
  int force_locale = 1;
  int random = 0;
  int start_color = 0;
  int rgb = 0;
  double freq_h = 0.23, freq_v = 0.1;
  int rand_offset = 0;
  struct timeval tv;
  gettimeofday(&tv, NULL);
  double offx = 0;

  if (co >= 0) {
    offx = co;
  } else {
    offx = (tv.tv_sec % 300) / 300.0;
  }

  if (hf >= 0) {
    freq_h = hf;
  }
  if (vf >= 0) {
    freq_v = vf;
  }
  if (fc == 1) {
    colors = 1;
  }
  if (fl == 1) {
    force_locale = 0;
  }
  if (rd == 1) {
    random = 1;
  }
  if (cs >= 0) {
    start_color = cs;
  }
  if (tc == 1) {
    rgb = 1;
  }

  if (random) {
    srand(time(NULL));
    rand_offset = rand();
  }

  char *env_lang = getenv("LANG");
  if (force_locale && env_lang && !strstr(env_lang, "UTF-8")) {
    if (!setlocale(LC_ALL, "C.UTF-8")) {
      /* C.UTF-8 may not be available on all platforms */
      setlocale(LC_ALL, "");
      /* Let's hope for the best */
    }
  } else {
    setlocale(LC_ALL, "");
  }

  i = 0;

  wint_t (*this_file_read_wchar)(FILE *);
  FILE *f;

  int escape_state = 0;
  this_file_read_wchar = &color_hack;
  f = 0;

  while ((c = this_file_read_wchar(f)) != WEOF) {
    if (colors) {
      find_escape_sequences(c, &escape_state);

      if (!escape_state) {
        if (c == '\n') {
          l++;
          i = 0;

        } else {
          if (rgb) {
            i += wcwidth(c);
            float theta =
                i * freq_h / 5.0f + l * freq_v +
                (offx + 2.0f * (rand_offset + start_color) / (float)RAND_MAX) *
                    M_PI;
            float offset = 0.1;

            uint8_t red = lrintf(
                (offset + (1.0f - offset) * (0.5f + 0.5f * sin(theta + 0))) *
                255.0f);
            uint8_t green = lrintf(
                (offset +
                 (1.0f - offset) * (0.5f + 0.5f * sin(theta + 2 * M_PI / 3))) *
                255.0f);
            uint8_t blue = lrintf(
                (offset +
                 (1.0f - offset) * (0.5f + 0.5f * sin(theta + 4 * M_PI / 3))) *
                255.0f);
            wprintf(L"\033[38;2;%d;%d;%dm", red, green, blue);

          } else {
            int ncc = offx * ARRAY_SIZE(codes) +
                      (int)((i += wcwidth(c)) * freq_h + l * freq_v);
            if (cc != ncc)
              wprintf(L"\033[38;5;%hhum",
                      codes[(rand_offset + start_color + (cc = ncc)) %
                            ARRAY_SIZE(codes)]);
          }
        }
      }
    }

    putwchar(c);
    /* implies "colors" */
    if (escape_state == 2)
      wprintf(L"\033[0m");
  }

  if (colors) {
    wprintf(L"\033[0m");
  }

  return 0;
}

int rainbowprint(char *message) {
  rainbow(-1, -1, -1, -1, -1, 1, -1, -1, message);
  return 0;
}

/* END RAINBOW COLORS*/

int main() {

  struct sysinfo sys_info;
  if (sysinfo(&sys_info) != 0) {
    perror("sysinfo");
  }
  
  sigset_t set;
  int status;
  if (getpid() != 1) {
    rainbowprint(infotext);
    fprintf(stderr, "  *** ERROR: Not PID 1. This must be run as init.\n");
    return 1;
  }

  sigfillset(&set);
  sigprocmask(SIG_BLOCK, &set, 0);
  if (fork())
    for (;;)
      wait(&status);
  sigprocmask(SIG_UNBLOCK, &set, 0);
  setsid();
  setpgid(0, 0);

  char *argv[] = {
      "/bin/busybox", 
      "ash", 
      "-c", 
      "alias talk='/l2e /model.bin -n 256 -i'; alias t='talk'; exec ash",
      NULL
  };  
  char *envp[] = {"HOME=/root/", "TERM=linux", "PATH=/:/bin", "TZ=UTC0", "USER=root",
  		  "LOGNAME=[init]", "PS1=\\033[1;32mμInference\\033[0m # ", NULL};

  pid_t child;
  
  char *createuserspace[] = {"/bin/busybox", "--install", "-s", "/bin", NULL};
  char *mountproc[] = {"/bin/busybox", "mount", "proc", "-t", "proc", "-o", "nosuid,noexec,nodev", "/proc", NULL};
  char *mountsys[] = {"/bin/busybox", "mount", "sysfs", "-t", "sysfs", "-o", "nosuid,noexec,nodev", "/sys", NULL};

  int childstatus;

  rainbowprint("  *** μInference Init System Starting...\n");

  // USERSPACE CREATION
  child = fork();
  if (child == -1) {
    fprintf(stderr, "  *** Userspace creation failed! ***\n");
  }
  if (child == 0) {
    if (execve(createuserspace[0], createuserspace, envp)) {
      fprintf(stderr, "  *** Userspace creation failed! ***\n");
      return (-1);
    }
  }

  child = fork();
  if (child == -1) {
    fprintf(stderr, "  *** Mounting failed! ***\n");
  }
  if (child == 0) {
    if (execve(mountproc[0], mountproc, envp)) {
      fprintf(stderr, "  *** Mounting procfs failed! ***\n");
      return (-1);
    }
  }

  child = fork();
  if (child == -1) {
    fprintf(stderr, "  *** Mounting failed! ***\n");
  }
  if (child == 0) {
    if (execve(mountsys[0], mountsys, envp)) {
      fprintf(stderr, "  *** Mounting sysfs failed! ***\n");
      return (-1);
    }
  }

  if (child > 0) {
    while ((child = wait(&childstatus)) > 0)
      ;
    if (childstatus == 0) {
      rainbowprint("  *** System initialization complete!\n");
    } else {
      fprintf(stderr, "  *** Some actions failed! ***\n");
    }
  }

  // BOOT INFO
  rainbowprint(infotext);
  rainbowprint("  *** Boot completed in ");
  printf("%ld", sys_info.uptime % 60);
  rainbowprint(" seconds\n\n");
  rainbowprint("  === USAGE INSTRUCTIONS ===\n");
  rainbowprint("  * Run LLaMA inference:     /l2e\n");
  rainbowprint("  * View kernel messages:    dmesg\n");
  rainbowprint("  * Check kernel module:     dmesg | grep T25\n");
  rainbowprint("  * Stop kernel module:      killall l2e\n");
  rainbowprint("  * Exit QEMU:              Ctrl-A then X\n");
  rainbowprint("\n");
  
  // HAND OFF
  if (execve(argv[0], &argv[0], envp) == -1) {
    fprintf(stderr, "  *** CRITICAL: Init handoff failed! ***\n");
    return 1;
  }
}