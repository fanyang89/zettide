#include <stdio.h>

int zettide_spdk_catalog_nvmf_benchmark(const char *ready_path, const char *member_path);

int
main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: %s READY_FILE MEMBER_FILE\n", argv[0]);
		return 2;
	}
	return zettide_spdk_catalog_nvmf_benchmark(argv[1], argv[2]);
}
