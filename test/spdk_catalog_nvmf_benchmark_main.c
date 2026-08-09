#include <stdio.h>
#include <string.h>

int zettide_spdk_catalog_nvmf_benchmark(const char *ready_path, const char *member_path,
		int mode, const char *expected_pool_id);

int
main(int argc, char **argv)
{
	int mode = 0;
	const char *expected_pool_id = NULL;

	if (argc < 3 || argc > 5) {
		fprintf(stderr, "usage: %s READY_FILE MEMBER_FILE [mapped|existing|provision|reformat [POOL_ID]]\n", argv[0]);
		return 2;
	}
	if (argc >= 4 && strcmp(argv[3], "mapped") == 0) {
		mode = 1;
	} else if (argc == 5 && strcmp(argv[3], "existing") == 0) {
		mode = 2;
		expected_pool_id = argv[4];
	} else if (argc == 5 && strcmp(argv[3], "provision") == 0) {
		mode = 3;
		expected_pool_id = argv[4];
	} else if (argc == 5 && strcmp(argv[3], "reformat") == 0) {
		mode = 4;
		expected_pool_id = argv[4];
	} else if (argc != 3) {
		fprintf(stderr, "invalid Catalog mode: %s\n", argv[3]);
		return 2;
	}
	return zettide_spdk_catalog_nvmf_benchmark(argv[1], argv[2], mode, expected_pool_id);
}
