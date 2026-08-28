int zettide_spdk_storage_test_main(void);

int
main(void)
{
	return zettide_spdk_storage_test_main() == 0 ? 0 : 1;
}
