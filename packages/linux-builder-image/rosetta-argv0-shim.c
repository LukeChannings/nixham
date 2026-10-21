// binfmt_misc interpreter for x86_64 ELFs, registered with the P flag, which
// hands us an argv the kernel otherwise throws away:
//
//   argv[0] = this shim
//   argv[1] = full path of the binary being executed
//   argv[2] = the caller's original argv[0]
//   argv[3..] = the caller's argv[1..]
//
// `rosetta <elf>` is Rosetta's entire interface: the guest always sees the path
// Rosetta was handed as its own argv[0]. So an exec that deliberately runs one
// path under a DIFFERENT argv[0] cannot be expressed through Rosetta at all,
// and goes to qemu-user's -0 instead.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef ROSETTA
#error "define ROSETTA as the path to the rosetta binary"
#endif

#ifndef QEMU_BINFMT_P
#error "define QEMU_BINFMT_P as the path to qemu's binfmt preserve-argv0 wrapper"
#endif

int main(int argc, char *argv[]) {
  if (argc < 3) {
    fprintf(stderr,
            "%s: only usable as a binfmt_misc interpreter registered with the P flag\n",
            argv[0]);
    return 1;
  }

  char *binary = argv[1];
  char *argv0 = argv[2];

  if (strcmp(binary, argv0) != 0 && strchr(argv0, '/') != NULL) {
    argv[0] = QEMU_BINFMT_P;
    execv(QEMU_BINFMT_P, argv);
    perror(QEMU_BINFMT_P);
    return 126;
  }

  char **rosetta_argv = malloc((size_t)argc * sizeof(char *));
  if (rosetta_argv == NULL) {
    perror("malloc");
    return 126;
  }
  rosetta_argv[0] = ROSETTA;
  rosetta_argv[1] = binary;
  memcpy(&rosetta_argv[2], &argv[3], (size_t)(argc - 3) * sizeof(char *));
  rosetta_argv[argc - 1] = NULL;

  execv(ROSETTA, rosetta_argv);
  perror(ROSETTA);
  return 126;
}
