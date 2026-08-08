#include <stdio.h>
#include <string.h>

int zettide_spdk_catalog_nvmf_benchmark(const char *ready_path, const char *member_path, int mapped);

int
main(int argc, char **argv)
{
	if (argc != 3 && argc != 4) {
		fprintf(stderr, "usage: %s READY_FILE MEMBER_FILE [mapped]\n", argv[0]);
		return 2;
	}
	if (argc == 4 && strcmp(argv[3], "mapped") != 0) {
		fprintf(stderr, "invalid Catalog mode: %s\n", argv[3]);
		return 2;
	}
	return zettide_spdk_catalog_nvmf_benchmark(argv[1], argv[2], argc == 4);
}
