#include <stdio.h>

int zettide_spdk_vhost_export_test_main(const char *socket_directory);

int
main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s SOCKET_DIRECTORY\n", argv[0]);
		return 2;
	}
	return zettide_spdk_vhost_export_test_main(argv[1]) == 0 ? 0 : 1;
}
